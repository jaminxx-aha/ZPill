#!/usr/bin/env python3
"""NikonPill USB PTP 探针(TODO.md USB 主线 P0)。

在写 iOS DriverKit dext / Android UsbManager 实现之前,先在 Mac 上对
真机跑通 PTP/USB 握手、核对容器字节布局 —— 与 tools/ptpip_probe 同纪律。
参考:USB Still Image 设备类规范、libgphoto2 ptp.c。

用法:
    前置(一次性):
        python3 -m venv tools/usb_probe/.venv
        tools/usb_probe/.venv/bin/pip install pyusb libusb-package
    运行(相机开机解锁,USB-C 线连 Mac):
        tools/usb_probe/.venv/bin/python tools/usb_probe/probe.py
    追加对象枚举:
        ... probe.py --handles
    核对对象格式码(NEF 真码以此为准):
        ... probe.py --objinfo 4
    拿事件抓到的 handle 直接问(解开「递归枚举列不出照片」):
        ... probe.py --peek 0x0A1A571E,0x291A571E
    缩略图/预览数据布局(相册网格与大图查看的依据):
        ... probe.py --thumb auto          # 自动找第一张 JPEG 和第一张 NEF 各 dump 一次
        ... probe.py --thumb 0x0A1A571E    # 指定 handle(逗号分隔多个)
    身份判别实验(唯一写操作,见 [4s]):
        ... probe.py --props d406 --setprop 0xd406=factory --setprop 0xd406= \
              --setprop "0xd406=NikonPill/1.0 (PTP host)" --getobj 0x291A16A1

只读纪律:默认仅枚举/读属性。唯一例外 --setprop(SetDevicePropValue),
仅用于 0xD406 MTP_SessionInitiatorInfo —— 2026-10-01 相机 op 表 119↔23 两副
面孔且 initiator 当前为 "Windows/… MTPClassDriver/…";libgphoto2 对 Panasonic
有同款先例(gphoto_library.c:设置 initiator 后 DeviceInfo 操作表当场改变)。
"""

from __future__ import annotations

import argparse
import struct
import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:
    print("缺 pyusb:tools/usb_probe/.venv/bin/pip install pyusb libusb-package")
    sys.exit(2)

NIKON_VID = 0x04B0

# PTP/USB 容器类型(bulk:命令 1/数据 2/响应 3;interrupt:事件 4)
CMD, DATA, RESP, EVENT = 1, 2, 3, 4
HDR = 12  # bulk 容器头:len u32 + type u16 + code u16 + txid u32
EVENT_HDR = 12  # 事件头:len u32 + type u16 + eventCode u16 + txid u32(与 bulk 头同构;libgphoto2 PTPUSBEventContainer)

# 操作码 / 响应码(与 lib/core/ptp/operation_codes.dart 对齐)
GET_DEVICE_INFO = 0x1001
OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_STORAGE_IDS = 0x1004
GET_STORAGE_INFO = 0x1005
GET_OBJECT_HANDLES = 0x1007
GET_OBJECT_INFO = 0x1008
GET_OBJECT = 0x1009
GET_THUMB = 0x100A
GET_PARTIAL_OBJECT = 0x101B
GET_DEVICE_PROP_DESC = 0x1014
GET_DEVICE_PROP_VALUE = 0x1015
SET_DEVICE_PROP_VALUE = 0x1016
OK = 0x2001
SESSION_ALREADY_OPEN = 0x201E

# 尼康厂商码(GetLargeThumb —— 大图预览的候选数据源)
NIKON_GET_LARGE_THUMB = 0x90C4

# GetObjectHandles 参数(全部存储 / 全部格式;父对象:0=仅根层,ALL=递归)
STORAGE_ALL = 0xFFFFFFFF
FORMAT_ALL = 0
PARENT_ROOT = 0x00000000
PARENT_ALL = 0xFFFFFFFF

# 候选码清单 —— 名称已按 libgphoto2 ptp.h 校正,再逐个对照 Zf 实际返回打 ✓/✗。
# (zcamera 参考项目的码表已证伪:AfDrive 实为 0x90C1、DeviceReady 实为 0x90C8、
#  ObjectAdded 实为 0x4002、GetPartialObject 实为 0x101B,勿再引用。)
NIKON_OC_CANDIDATES = {
    0x1009: "GetObject(标准,整文件)",
    0x1014: "GetDevicePropDesc(标准,可作心跳探针)",
    0x1019: "MoveObject(标准,移动对象 —— 预期 ✗)",
    0x101B: "GetPartialObject(标准,32 位偏移分块读 —— 断点续传根基)",
    0x90C0: "InitiateCaptureRecInSdram",
    0x90C1: "AfDrive(自动对焦)",
    0x90C4: "GetLargeThumb(大图预览,相册大图查看候选)",
    0x90C7: "GetEvent(旧名 CheckEvent;尼康事件轮询,data-in)",
    0x90C8: "DeviceReady(忙等探针)",
    0x9201: "StartLiveView", 0x9202: "EndLiveView", 0x9203: "GetLiveViewImg",
    0x9400: "GetPartialObjectHiSpeed(尼康高速分块读)",
    0x9421: "GetObjectSize(64 位对象大小)",
    0x9431: "GetPartialObjectEx(64 位偏移+长度 —— Z 系断点续传主力)",
}
NIKON_EVENT_CANDIDATES = {
    0x4002: "ObjectAdded(标准)", 0x400D: "CaptureComplete(标准)",
    0xC101: "Nikon_ObjectAddedInSDRAM", 0xC102: "Nikon_CaptureCompleteRecInSdram",
    0xC125: "?(gphoto 未收录,待真机事件核对)", 0xC700: "?(gphoto 未收录)",
}
NIKON_PROP_CANDIDATES = {
    0x5001: "BatteryLevel", 0x5005: "WhiteBalance", 0x5007: "FNumber",
    0x500D: "ExposureTime", 0x500F: "ExposureIndex(ISO)",
    0x5010: "ExposureBiasCompensation", 0x5013: "StillCaptureMode",
    0xD406: "?(gphoto 未收录)", 0xD407: "?(gphoto 未收录)",
}


# ── 小端编码助手(全字段小端,同 PTP-IP 纪律) ────────────────────────

def u16(v: int) -> bytes:
    return struct.pack("<H", v)


def u32(v: int) -> bytes:
    return struct.pack("<I", v)


def cmd_container(opcode: int, txid: int, params=()) -> bytes:
    """命令容器:dwLength + usType(1) + usCode + dwTransactionID + params。"""
    body = b"".join(u32(p) for p in params)
    return u32(HDR + len(body)) + u16(CMD) + u16(opcode) + u32(txid) + body


def parse_head(blob: bytes):
    """解析 bulk 容器头,返回 (length, type, code, txid)。"""
    return struct.unpack_from("<IHHI", blob, 0)


# ── USB 收发 ─────────────────────────────────────────────────────────

def make_backend():
    """优先用 libusb-package 自带的 dylib(免 brew);失败则回落系统查找。"""
    try:
        import libusb_package

        return libusb_package.get_libusb1_backend()
    except Exception:
        return None


def read_container(dev, ep_in: int, timeout: int = 5000) -> bytes:
    """读一个完整 bulk 容器:按长度字段跨读补齐(与 Dart 侧 bulkIn 契约一致)。"""
    blob = bytes(dev.read(ep_in, 1 << 16, timeout))
    if len(blob) < HDR:
        raise IOError(f"bulk 读不足容器头:仅 {len(blob)}B")
    (length, *_rest) = parse_head(blob)
    while len(blob) < length:
        blob += bytes(dev.read(ep_in, length - len(blob), timeout))
    if length != len(blob):
        print(f"[!] 容器长度字段 {length} ≠ 实读 {len(blob)} —— 真机数据,原样记录")
    return blob


def xact(dev, ep_out, ep_in, txid, opcode, params=()):
    """一次完整事务:发命令容器 → 可选读数据容器 → 读响应容器。

    返回 (txid, data_blob|None, 响应码)。数据容器只在相机先发数据时读
    (GetDeviceInfo/GetObjectHandles 这类 DataIn 操作);对纯响应操作,
    相机直接回响应容器,这里靠响应容器 type 区分(3=响应,2=数据)。
    """
    dev.write(ep_out, cmd_container(opcode, txid, params), 5000)
    blob = read_container(dev, ep_in)
    _len, rtype, rcode, _rtxid = parse_head(blob)
    if rtype == DATA:
        data_blob = blob
        resp = read_container(dev, ep_in)
        _l2, _t2, rcode, _x2 = parse_head(resp)
        return txid, data_blob, rcode
    return txid, None, rcode


def xact_out(dev, ep_out, ep_in, txid, opcode, params, payload: bytes):
    """数据 OUT 事务:命令容器 → DATA 容器(主机→相机)→ 响应容器。

    SetDevicePropValue(0x1016)等 DataOut 操作专用;DATA 头与命令同
    opcode/txid(USB Still Image 规范)。
    """
    dev.write(ep_out, cmd_container(opcode, txid, params), 5000)
    dc = u32(HDR + len(payload)) + u16(DATA) + u16(opcode) + u32(txid) + payload
    dev.write(ep_out, dc, 5000)
    resp = read_container(dev, ep_in)
    _l, rtype, rcode, _x = parse_head(resp)
    return txid, rcode


def ensure_session(dev, ep_out, ep_in, txid, session_id=1):
    """OpenSession;若上次探针异常退出留下未关会话(0x201E),先 Close 再开。"""
    txid, _data, rcode = xact(dev, ep_out, ep_in, txid, OPEN_SESSION, [session_id])
    if rcode == SESSION_ALREADY_OPEN:
        print(f"[4] OpenSession <- 0x201E(会话未关,上次探针遗留)→ CloseSession 恢复")
        txid += 1
        txid, _data, rcode = xact(dev, ep_out, ep_in, txid, CLOSE_SESSION)
        print(f"    CloseSession <- 0x{rcode:04X}")
        txid += 1
        txid, _data, rcode = xact(dev, ep_out, ep_in, txid, OPEN_SESSION, [session_id])
    return txid, rcode


def close_session(dev, ep_out, ep_in, txid):
    txid, _data, rcode = xact(dev, ep_out, ep_in, txid, CLOSE_SESSION)
    print(f"[7] CloseSession <- 0x{rcode:04X}(探针退出,不留悬挂会话)")
    return txid


# ── 描述符 / 端点 ─────────────────────────────────────────────────────

def dump_descriptors(dev) -> None:
    print(f"  idProduct=0x{dev.idProduct:04X}(记录:Zf 的 PID)")
    try:
        cfg = dev.get_active_configuration()
    except usb.core.USBError:
        dev.set_configuration()
        cfg = dev.get_active_configuration()
    for itf in cfg:
        names = {6: "Still Image(标准 PTP)", 0xFF: "vendor-specific"}
        label = names.get(itf.bInterfaceClass, f"class {itf.bInterfaceClass}")
        print(f"  接口 {itf.bInterfaceNumber} alt{itf.bAlternateSetting} {label}"
              f" sub=0x{itf.bInterfaceSubClass:02X} proto=0x{itf.bInterfaceProtocol:02X}")
        for ep in itf:
            direction = "IN" if ep.bEndpointAddress & 0x80 else "OUT"
            etype = {
                usb.util.ENDPOINT_TYPE_BULK: "bulk",
                usb.util.ENDPOINT_TYPE_INTR: "interrupt",
                usb.util.ENDPOINT_TYPE_ISO: "iso",
                usb.util.ENDPOINT_TYPE_CTRL: "control",
            }[usb.util.endpoint_type(ep.bmAttributes)]
            print(f"    ep 0x{ep.bEndpointAddress:02X} {direction} {etype} {ep.wMaxPacketSize}B")


def find_sti_endpoints(dev):
    """返回 (接口号, bulkOUT, bulkIN, interruptIN)。优先 class 6,回落含双 bulk 的接口。"""
    cfg = dev.get_active_configuration()
    candidates = [i for i in cfg if i.bInterfaceClass == 6]
    if not candidates:
        print("[!] 无 class-6(Still Image)接口,回落到首个含 bulk IN+OUT 的接口")
        candidates = list(cfg)
    for itf in candidates:
        def match(direction, etype):
            return usb.util.find_descriptor(
                itf,
                custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == direction
                and usb.util.endpoint_type(e.bmAttributes) == etype,
            )

        bulk_out = match(usb.util.ENDPOINT_OUT, usb.util.ENDPOINT_TYPE_BULK)
        bulk_in = match(usb.util.ENDPOINT_IN, usb.util.ENDPOINT_TYPE_BULK)
        if bulk_in is None or bulk_out is None:
            continue
        intr_in = match(usb.util.ENDPOINT_IN, usb.util.ENDPOINT_TYPE_INTR)
        if intr_in is None:
            print("[!] 该接口无 interrupt IN 端点(事件通道缺失,记录)")
        return itf.bInterfaceNumber, bulk_out.bEndpointAddress, bulk_in.bEndpointAddress, (
            intr_in.bEndpointAddress if intr_in else None
        )
    raise IOError("找不到含 bulk IN/OUT 的接口 —— 描述符见上文,发回分析")


# ── GetDeviceInfo 数据集解析(布局:ISO 15740 §9) ────────────────────

def read_ptp_str(buf: bytes, off: int):
    n = buf[off]
    off += 1
    if n == 0xFF:
        return "(未提供)", off
    s = buf[off:off + 2 * n].decode("utf-16-le", errors="replace")
    return s, off + 2 * n


def ptp_str(text: str) -> bytes:
    """PTP STRING 编码:u8 字符数 + UTF-16LE(空串即单个 0x00)。"""
    return bytes([len(text)]) + text.encode("utf-16-le")


def read_u16_array(buf: bytes, off: int):
    (n,) = struct.unpack_from("<I", buf, off)
    off += 4
    vals = struct.unpack_from(f"<{n}H", buf, off) if n else ()
    return vals, off + 2 * n


def check_candidates(info: dict) -> None:
    """把候选码清单与相机实际支持的码表对照,输出 ✓/✗ 供回填常量。"""
    print("    候选码核对(以相机返回为准):")
    for section, table in [("operationsSupported", NIKON_OC_CANDIDATES),
                           ("eventsSupported", NIKON_EVENT_CANDIDATES),
                           ("devicePropsSupported", NIKON_PROP_CANDIDATES)]:
        actual = set(info[section])
        for code, name in table.items():
            mark = "✓" if code in actual else "✗"
            print(f"      {mark} 0x{code:04X} {name}")


def parse_device_info(payload: bytes) -> dict:
    """GetDeviceInfo 数据集(ISO 15740 §9)→ 字段字典(不打印,[4s] 对比用)。"""
    r = {}
    off = 0
    (r["standardVersion"],) = struct.unpack_from("<H", payload, off); off += 2
    (r["vendorExtensionId"],) = struct.unpack_from("<I", payload, off); off += 4
    (r["vendorExtensionVersion"],) = struct.unpack_from("<H", payload, off); off += 2
    r["vendorExtensionDesc"], off = read_ptp_str(payload, off)
    (r["functionalMode"],) = struct.unpack_from("<H", payload, off); off += 2
    sections = ["operationsSupported", "eventsSupported", "devicePropsSupported",
                "captureFormats", "imageFormats"]
    for name in sections:
        r[name], off = read_u16_array(payload, off)
    for name in ["manufacturer", "model", "deviceVersion", "serialNumber"]:
        r[name], off = read_ptp_str(payload, off)
    return r


def dump_device_info(payload: bytes) -> dict:
    r = parse_device_info(payload)

    print(f"    型号: {r['model']}  固件: {r['deviceVersion']}  序列号: {r['serialNumber']}")
    print(f"    vendorExtensionId=0x{r['vendorExtensionId']:08X}"
          f"({r['vendorExtensionDesc']})  functionalMode={r['functionalMode']}")
    print(f"    支持的操作码({len(r['operationsSupported'])}): "
          + " ".join(f"0x{x:04X}" for x in r["operationsSupported"]))
    print(f"    支持的事件码({len(r['eventsSupported'])}): "
          + " ".join(f"0x{x:04X}" for x in r["eventsSupported"]))
    print(f"    支持的图像格式({len(r['imageFormats'])}): "
          + " ".join(f"0x{x:04X}" for x in r["imageFormats"]))
    check_candidates(r)
    print("    ↑ 回填对照:操作/事件码 → lib/core/ptp/operation_codes.dart;"
          "NEF 的 ObjectFormatCode → object_format.dart")
    return r


# ObjectFormatCode 备注(2026-09-27 真机落定:NEF 报 0x3000,靠扩展名区分)
FMT_NAMES = {
    0x3000: "Undefined(Zf 的 NEF 实测即此码)", 0x3001: "Association(文件夹)",
    0x3002: "Script", 0x3008: "WAV", 0x300D: "MOV(QuickTime)", 0x3801: "EXIF/JPEG",
    0x380D: "TIFF", 0xB200: "疑 HEIF(gphoto 未收录,未拍样张)", 0xB982: "MP4(MTP)",
}


def dump_storage_info(sid: int, payload: bytes) -> None:
    """GetStorageInfo 数据集(ISO 15740):解开双卷之谜。"""
    (stype, fstype, access) = struct.unpack_from("<HHH", payload, 0)
    (max_cap, free) = struct.unpack_from("<QQ", payload, 6)
    (free_imgs,) = struct.unpack_from("<I", payload, 22)
    desc, off = read_ptp_str(payload, 26)
    volume, _off = read_ptp_str(payload, off)  # StorageDescription 后还有 VolumeLabel
    # 码表对齐 libgphoto2:StorageType 0x0004=可移动 RAM(SD 卡)、FSType 0x0003=DCF
    tmap = {0: "未定义", 1: "固定ROM", 2: "可移除ROM", 3: "固定RAM", 4: "可移动RAM"}
    fmap = {0: "未定义", 1: "通用平面", 2: "通用层级", 3: "DCF"}
    amap = {0: "读写", 1: "只读", 2: "只读可删"}
    print(f"    0x{sid:08X} 卷标「{volume}」{desc}  "
          f"{tmap.get(stype, hex(stype))}/{fmap.get(fstype, hex(fstype))}"
          f"/{amap.get(access, hex(access))}"
          f"  容量 {max_cap / 1_073_741_824:.0f}GB 剩余 {free / 1_073_741_824:.1f}GB"
          f"  可存 {free_imgs} 张")


def parse_object_info(payload: bytes) -> dict:
    """GetObjectInfo 数据集(ISO 15740)→ 字段字典(dump 与 --thumb auto 共用)。"""
    (storage_id, fmt, _prot, size, _tf, _ts, _tw, _th,
     w, h, _depth, parent, _assoc, _ad, _seq) = struct.unpack_from(
        "<IHHIHIIIIIIIHII", payload, 0)
    name, off = read_ptp_str(payload, 52)
    captured, _off = read_ptp_str(payload, off)
    return {"storage_id": storage_id, "fmt": fmt, "size": size, "w": w, "h": h,
            "parent": parent, "name": name, "captured": captured}


def dump_object_info(handle: int, payload: bytes) -> None:
    """GetObjectInfo 数据集(ISO 15740):重点是 ObjectFormatCode 与父子关系。"""
    o = parse_object_info(payload)
    fmt, name, size = o["fmt"], o["name"], o["size"]
    size_h = f"{size / 1_048_576:.1f}MB" if size >= 1_048_576 else f"{size}B"
    print(f"    0x{handle:08X} {name}  fmt=0x{fmt:04X}({FMT_NAMES.get(fmt, '?')})"
          f"  {size_h}  {o['w']}x{o['h']}  存储 0x{o['storage_id']:08X} 父 0x{o['parent']:08X}"
          f"  拍摄时间 {o['captured']}")


# ── 缩略图/预览数据布局(GetThumb / Nikon GetLargeThumb) ─────────────

def jpeg_dimensions(data: bytes):
    """扫描 JPEG SOF 标记返回 (宽,高);非 JPEG 或扫不到返回 None。"""
    if len(data) < 4 or data[0:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker == 0xDA:  # SOS 之前必有 SOF,到这就放弃
            return None
        (seg_len,) = struct.unpack_from(">H", data, i + 2)
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            (hh, ww) = struct.unpack_from(">HH", data, i + 5)
            return (ww, hh)
        if seg_len <= 0:
            return None
        i += 2 + seg_len
    return None


def dump_object(dev, ep_out, ep_in, txid, opcode: int, op_name: str, handle: int,
                offset: int = 0, max_bytes: int | None = None) -> tuple:
    """对一个 handle 跑整文件/分块数据操作(--getobj / --partial)。

    只计数不落盘(读取不改变相机状态);记录字节数、耗时、速率与前 16B,
    用于「同一 handle 在 Mac 与手机两侧的数据可达性对照」。
    返回 (下一个 txid, 是否成功拿到数据)—— [4s] 身份实验靠它判解锁。
    """
    params = [handle, offset, max_bytes] if opcode == GET_PARTIAL_OBJECT else [handle]
    t0 = time.monotonic()
    try:
        txid, blob, rcode = xact(dev, ep_out, ep_in, txid, opcode, params)
    except usb.core.USBError as e:
        print(f"    {op_name} 0x{handle:08X} <- USB 错误:{e}")
        return txid, False
    dt = time.monotonic() - t0
    if rcode != OK or blob is None:
        print(f"    {op_name} 0x{handle:08X} <- 0x{rcode:04X}"
              + ("(无数据相位)" if blob is None else "") + f"  {dt*1000:.0f}ms")
        return txid, False
    n = len(blob) - HDR
    mbps = n / 1e6 / dt if dt > 0 else 0.0
    print(f"    {op_name} 0x{handle:08X} <- 0x{rcode:04X}  {n}B  "
          f"{dt*1000:.0f}ms  {mbps:.2f}MB/s")
    print(f"      前 16B: {blob[HDR:HDR+16].hex(' ')}")
    return txid, True


def dump_thumb(dev, ep_out, ep_in, txid, opcode: int, op_name: str, handle: int) -> int:
    """对一个 handle 跑一次缩略图类操作,记录数据布局并落盘原始字节。"""
    txid, blob, rcode = xact(dev, ep_out, ep_in, txid, opcode, [handle])
    if rcode != OK or blob is None:
        print(f"    {op_name} 0x{handle:08X} <- 0x{rcode:04X}"
              + ("(无数据相位)" if blob is None else ""))
        return txid
    data = blob[HDR:]
    soi = data.find(b"\xff\xd8")
    dims = jpeg_dimensions(data[soi:]) if soi >= 0 else None
    dim_s = f"{dims[0]}x{dims[1]}" if dims else "?"
    print(f"    {op_name} 0x{handle:08X} <- 0x{rcode:04X}  {len(data)}B  "
          f"SOI 偏移 {soi if soi >= 0 else '无(非 JPEG?)'}  尺寸 {dim_s}")
    print(f"      前 32B: {data[:32].hex(' ')}")
    out = f"/tmp/nikonpill_probe_{op_name}_{handle:08X}.bin"
    with open(out, "wb") as f:
        f.write(data)
    print(f"      原始字节已存:{out}(可直接改后缀 .jpg 查看)")
    return txid


def find_thumb_targets(dev, ep_out, ep_in, txid) -> tuple:
    """--thumb auto:全量枚举后扫 ObjectInfo,找第一张 JPEG 与第一张 NEF。"""
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_HANDLES,
                          [STORAGE_ALL, FORMAT_ALL, PARENT_ROOT])
    (cnt,) = struct.unpack_from("<I", blob, HDR)
    hs = struct.unpack_from(f"<{cnt}I", blob, HDR + 4) if cnt else ()
    jpeg = nef = None
    scanned = 0
    for h in hs[:80]:
        txid += 1
        txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
        if rcode != OK:
            continue
        scanned += 1
        o = parse_object_info(data_blob[HDR:])
        if o["fmt"] == 0x3801 and jpeg is None:
            jpeg = (h, o["name"])
        if o["fmt"] == 0x3000 and o["name"].lower().endswith(".nef") and nef is None:
            nef = (h, o["name"])
        if jpeg and nef:
            break
    print(f"    auto 扫描 {scanned} 个 ObjectInfo:JPEG={jpeg} NEF={nef}"
          + ("(未找齐,把范围放宽或改用 --thumb 0x… 指定)" if not (jpeg and nef) else ""))
    return txid, jpeg, nef


def hexdump(b: bytes, limit: int = 512) -> str:
    lines = []
    for i in range(0, min(len(b), limit), 16):
        lines.append(f"    {i:04x}  " + " ".join(f"{x:02x}" for x in b[i:i + 16]))
    if len(b) > limit:
        lines.append(f"    …(共 {len(b)} 字节,截断)")
    return "\n".join(lines)


# ── 主流程 ────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="PTP/USB 真机验证(尼康 Z 系列,只读)")
    ap.add_argument("--handles", action="store_true", help="追加 GetObjectHandles 计数")
    ap.add_argument("--objinfo", type=int, metavar="个", default=0,
                    help="对前 N 个对象调 GetObjectInfo(只读),核对 ObjectFormatCode")
    ap.add_argument("--events", type=int, metavar="秒", default=0,
                    help="监听 interrupt IN 事件 N 秒(期间在相机上按快门/转波轮)")
    ap.add_argument("--peek", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="直接对这些 handle 调 GetObjectInfo(如事件里抓到的 0x0A1A571E)")
    ap.add_argument("--thumb", type=str, metavar="auto|hex[,hex…]", default=None,
                    help="缩略图数据布局:GetThumb + Nikon GetLargeThumb 各 dump 一次"
                         "(auto=自动找第一张 JPEG/NEF;否则对指定 handle)")
    ap.add_argument("--getobj", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="对这些 handle 调 GetObject(整文件,只计数不落盘)"
                         " —— 数据操作可达性对照(手机侧 0x200F 问题的相机侧判别)")
    ap.add_argument("--partial", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="对这些 handle 调 GetPartialObject(0x101B,读前 2048B)"
                         " —— 替代数据通路探针")
    ap.add_argument("--probeops", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="对这批操作码逐个直发(先带第一个 --peek handle 作参数,"
                         "报错再试无参),记录响应码/数据量/前 16B —— 未知厂商码"
                         "行为摸底(2026-10-01:Zf 精简 op 表 0x943A-0x9442/0x9461)")
    ap.add_argument("--props", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="读这批设备属性的 Desc(0x1014)+Value(0x1015)—— "
                         "身份类属性摸底(0xD406 SessionInitiatorInfo / 0xD407 "
                         "PerceivedDeviceType)")
    ap.add_argument("--setprop", type=str, metavar="hex=text", action="append",
                    default=[],
                    help="SetDevicePropValue(0x1016)写属性 —— 本工具唯一写操作,"
                         "仅用于 0xD406 身份判别:text=factory 写回出厂值,"
                         "空文本=清空 initiator,其余为字面身份串;每候选后回读"
                         "+GetDeviceInfo 对比+数据操作重试,解锁即停"
                         "(先例:libgphoto2 对 Panasonic 写 initiator 改 op 表)")
    args = ap.parse_args()

    backend = make_backend()
    kwargs = {"idVendor": NIKON_VID}
    if backend is not None:
        kwargs["backend"] = backend
    try:
        devices = list(usb.core.find(find_all=True, **kwargs))
    except usb.core.NoBackendError:
        print("找不到 libusb 后端:pip install libusb-package(或 brew install libusb)")
        return 2
    if not devices:
        print("未发现尼康 USB 设备(VID 0x04B0):检查线缆,相机开机并解锁")
        return 1
    dev = devices[0]
    if len(devices) > 1:
        print(f"发现 {len(devices)} 台尼康设备,使用第一台")

    # Linux 下脱离内核驱动;macOS 无此机制,失败静默
    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
    except (NotImplementedError, usb.core.USBError):
        pass

    print("[1] 设备描述符:")
    # dev.speed 是 libusb 枚举值:1=Low(1.5M) 2=Full(12M) 3=High(480M) 4=Super(5G)
    # Full Speed + bulk 64B 包长 ≈ 实际 ~1MB/s;High Speed 应为 512B。
    # 若见 Full Speed:换线/换口复测,仍 Full 则该机身就是全速,直接影响主线决策。
    speed_map = {1: "Low 1.5Mbps", 2: "Full 12Mbps", 3: "High 480Mbps", 4: "Super 5Gbps"}
    print(f"  总线速率: {speed_map.get(getattr(dev, 'speed', 0), '?')} "
          f"(libusb enum={getattr(dev, 'speed', '?')})")
    dump_descriptors(dev)

    itf_no, ep_out, ep_in, ep_intr = find_sti_endpoints(dev)
    print(f"[2] 端点:bulkOUT=0x{ep_out:02X} bulkIN=0x{ep_in:02X} "
          f"interruptIN={f'0x{ep_intr:02X}' if ep_intr else '无'}(接口 {itf_no})")
    usb.util.claim_interface(dev, itf_no)

    txid = 0

    # 步骤 3:GetDeviceInfo(唯一可在 OpenSession 前调用的操作)
    txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
    dlen, dtype, dcode, dtxid = parse_head(data_blob)
    print(f"[3] GetDeviceInfo <- 数据容器 {dlen}B(type={dtype}) 响应 0x{rcode:04X} txid={dtxid}")
    if dtype != DATA or rcode != OK:
        print("    意外:数据/响应不符 —— 原始字节发回分析")
        print(hexdump(data_blob))
        return 1
    device_info = dump_device_info(data_blob[HDR:])
    print("    原始数据容器(备案):")
    print(hexdump(data_blob))

    # 步骤 4:OpenSession(sessionId=1;含 0x201E 悬挂会话恢复)
    txid += 1
    txid, rcode = ensure_session(dev, ep_out, ep_in, txid)
    print(f"[4] OpenSession <- 响应 0x{rcode:04X}")
    if rcode != OK:
        print("    OpenSession 失败:检查相机是否弹出连接确认(部分机身需在相机上确认)")
        return 1

    # 步骤 4t(可选,--thumb):缩略图/预览数据布局。GetThumb(0x100A)是标准码,
    # 数据应为内嵌缩略图(JPEG?多大?);Nikon GetLargeThumb(0x90C4)是厂商码,
    # 数据布局未经真机验证 —— SOI 偏移/尺寸/字节数全记录,供 Dart 侧解析回填。
    if args.thumb:
        print("[4t] 缩略图数据布局(GetThumb / GetLargeThumb):")
        supports_largethumb = NIKON_GET_LARGE_THUMB in device_info["operationsSupported"]
        print(f"    0x90C4 GetLargeThumb 在册:{'✓' if supports_largethumb else '✗(仅能 GetThumb)'}")
        if args.thumb.strip().lower() == "auto":
            txid, jpeg, nef = find_thumb_targets(dev, ep_out, ep_in, txid)
            targets = [t for t in (jpeg, nef) if t]
        else:
            try:
                targets = [(int(x, 16), "(指定)") for x in args.thumb.split(",")]
            except ValueError:
                print("    --thumb 参数应为 auto 或十六进制 handle 逗号列表")
                targets = []
        for h, name in targets:
            print(f"    对 {name} 0x{h:08X}:")
            txid = dump_thumb(dev, ep_out, ep_in, txid, GET_THUMB, "thumb", h)
            if supports_largethumb:
                txid = dump_thumb(dev, ep_out, ep_in, txid, NIKON_GET_LARGE_THUMB,
                                  "largethumb", h)
        if targets:
            print("    ↑ 回填位置:lib/core/ptp/ptp_session.dart(getThumb/getLargeThumb "
                  "是否需要剥头、网格用哪个码)")

    # 步骤 4g(可选,--getobj/--partial):数据操作可达性。手机侧全量
    # 0x200F 时,同 handle 在 Mac 侧过一遍即知「相机拒绝」还是「手机
    # 侧交互问题」—— 判别性实验,别删。
    if args.getobj or args.partial:
        print("[4g] 数据操作可达性对照:")
        for h in args.getobj:
            txid += 1
            txid, _ok = dump_object(dev, ep_out, ep_in, txid, GET_OBJECT, "GetObject", h)
        for h in args.partial:
            txid += 1
            txid, _ok = dump_object(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                                    "GetPartialObject(0..2047)", h, offset=0, max_bytes=2048)

    # 步骤 4p(可选,--probeops):未知操作码摸底。每个码两种姿势:
    # 带 handle 参数 / 无参;记录响应码、数据量与前 16B(数据即重大发现)。
    # 相机若等 data-out 阶段会挂 bulk 读,5s 超时捕获后继续下一个。
    if args.probeops:
        print("[4p] 未知操作码摸底:")
        param_handle = args.peek[0] if args.peek else 0

        def try_op(op: int, params: list) -> None:
            nonlocal txid
            tag = f"0x{op:04X}([{'0x%08X' % params[0] if params else ''}])"
            try:
                txid, blob, rc = xact(dev, ep_out, ep_in, txid, op, params)
            except (usb.core.USBError, IOError) as e:
                print(f"    {tag} <- USB 异常:{e}")
                # STALL(Pipe error)后必须 CLEAR_FEATURE(ENDPOINT_HALT)
                # 才能继续,两个 bulk 端点都清(参照 NikonPill UsbHostPlugin)。
                try:
                    dev.clear_halt(ep_out)
                    dev.clear_halt(ep_in)
                    print("      已 clear_halt 两端点")
                except usb.core.USBError:
                    pass
                return
            if blob is not None and rc == OK:
                data = blob[HDR:]
                print(f"    {tag} <- 0x{rc:04X}  data={len(data)}B  "
                      f"head={data[:16].hex(' ')}")
                if len(data) > 64:
                    out = f"/tmp/nikonpill_probe_op_{op:04X}_{len(data)}B.bin"
                    with open(out, "wb") as f:
                        f.write(data)
                    print(f"      数据已存:{out}")
            else:
                print(f"    {tag} <- 0x{rc:04X}  "
                      f"{'(无数据相位)' if blob is None else f'数据 {(len(blob)-HDR)}B(响应非 OK)'}")

        for op in args.probeops:
            txid += 1
            try_op(op, [param_handle])
            txid += 1
            try_op(op, [])

    # 步骤 4d(可选,--props):设备属性摸底。身份类属性是重点:
    # 0xD406 MTP_SessionInitiatorInfo(主机自报身份,MTP 规范里可写)、
    # 0xD407 MTP_PerceivedDeviceType(相机眼中的主机类型)—— 2026-10-01
    # 疑点:相机按「主机身份」切换 op 表(119 码全量 ↔ 23 码受限)。
    if args.props:
        print("[4d] 设备属性摸底(0x1014 Desc / 0x1015 Value):")
        for prop in args.props:
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  GET_DEVICE_PROP_DESC, [prop])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                # DevicePropDesc: PropCode u16 / DataType u16 / GetSet u8 / 值…
                dtype = struct.unpack_from("<H", d, 2)[0] if len(d) >= 4 else -1
                writable = d[4] if len(d) >= 5 else -1
                print(f"    0x{prop:04X} Desc <- OK  {len(d)}B  "
                      f"DataType=0x{dtype:04X}  GetSet={writable}")
                # STR 型:FactoryDefault 与 Current 并排解开 —— 谁写入了
                # "Windows/…" 一眼可辨(factory≠current ⇒ 主机写过)。
                if dtype == 0xFFFF and len(d) > 5:
                    try:
                        fac, off2 = read_ptp_str(d, 5)
                        cur, _off3 = read_ptp_str(d, off2)
                        print(f"      FactoryDefault={fac!r}")
                        print(f"      Current      ={cur!r}")
                    except (IndexError, struct.error):
                        pass
                print("      raw:")
                print(hexdump(d, limit=512))
            else:
                print(f"    0x{prop:04X} Desc <- 0x{rc:04X}")
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  GET_DEVICE_PROP_VALUE, [prop])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                shown = d[:48].hex(" ")
                # 字符串型(DataType 0xFFFF PTPTYPESTR)转可读
                text = ""
                if len(d) >= 2 and d[0] and d[0] <= 64:
                    try:
                        text = "  text=" + "".join(
                            chr(d[i]) for i in range(1, min(len(d), 1 + d[0] * 2))
                            if d[i])
                    except Exception:
                        pass
                print(f"    0x{prop:04X} Value <- OK  {len(d)}B  {shown}{text}")
            else:
                print(f"    0x{prop:04X} Value <- 0x{rc:04X}")

    # 步骤 4s(可选,--setprop):身份判别实验 —— 本工具唯一写操作。
    # 疑点链:0xD406 SessionInitiatorInfo 当前 "Windows/… MTPClassDriver/…",
    # 同期相机 op 表 119↔23 两副面孔;libgphoto2 对 Panasonic 有先例
    # (gphoto_library.c:写 initiator 后 GetDeviceInfo 当场增删操作码)。
    # 每个候选值:set → 回读 → GetDeviceInfo 对比 → GetObject/GetThumb 重试 →
    # 关/开会话再对比;一旦数据操作解锁,剩余候选跳过(不再折腾相机状态)。
    if args.setprop:
        print("[4s] SetDevicePropValue 身份实验:")
        test_handles = list(dict.fromkeys(list(args.getobj) + list(args.peek)))
        if not test_handles:
            print("    (无 --getobj/--peek handle,数据操作重试跳过,仅对比 op 表)")
        base_ops = set(device_info["operationsSupported"])
        unlocked = False

        def retry_data_ops() -> None:
            """对 test_handles 重试 GetObject/GetThumb,成功即置 unlocked。"""
            nonlocal txid, unlocked
            for h in test_handles:
                txid += 1
                txid, ok = dump_object(dev, ep_out, ep_in, txid, GET_OBJECT,
                                       "GetObject(重试)", h)
                unlocked = unlocked or ok
                txid += 1
                txid, ok2 = dump_object(dev, ep_out, ep_in, txid, GET_THUMB,
                                        "GetThumb(重试)", h)
                unlocked = unlocked or ok2

        for spec in args.setprop:
            if unlocked:
                print(f"    [跳过 {spec}:已有候选解锁数据操作]")
                continue
            if "=" not in spec:
                print(f"    [格式错 {spec!r}:应为 十六进制属性码=文本]")
                continue
            code_s, text = spec.split("=", 1)
            try:
                prop = int(code_s, 16)
            except ValueError:
                print(f"    [格式错 {spec!r}:属性码应为十六进制(如 0xd406)]")
                continue
            # factory = 写回 Desc 的 FactoryDefault;空文本 = 清空 initiator
            label = f"0x{prop:04X}={text!r}"
            payload = None
            if text == "factory":
                txid += 1
                txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                      GET_DEVICE_PROP_DESC, [prop])
                if rc == OK and blob is not None and len(blob[HDR:]) > 5 \
                        and struct.unpack_from("<H", blob[HDR:], 2)[0] == 0xFFFF:
                    try:
                        fac, off2 = read_ptp_str(blob[HDR:], 5)
                        cur, _o = read_ptp_str(blob[HDR:], off2)
                        if fac != cur:
                            payload = ptp_str(fac)
                            label = f"0x{prop:04X}=FactoryDefault({fac!r})"
                            print(f"    [factory] 当前 {cur!r} → 写回出厂 {fac!r}")
                        else:
                            print(f"    [factory] FactoryDefault == Current"
                                  f"({fac!r}),写回无意义 → 跳过该候选")
                    except (IndexError, struct.error):
                        pass
                if payload is None:
                    continue
            else:
                payload = ptp_str(text)
            print(f"  ▶ 候选 {label}(载荷 {len(payload)}B)")
            txid += 1
            try:
                txid, rc = xact_out(dev, ep_out, ep_in, txid,
                                    SET_DEVICE_PROP_VALUE, [prop], payload)
            except (usb.core.USBError, IOError) as e:
                print(f"    SetDevicePropValue <- USB 异常:{e}")
                try:
                    dev.clear_halt(ep_out)
                    dev.clear_halt(ep_in)
                    print("      已 clear_halt 两端点")
                except usb.core.USBError:
                    pass
                continue
            print(f"    SetDevicePropValue <- 0x{rc:04X}")
            if rc != OK:
                continue
            # 回读验证
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  GET_DEVICE_PROP_VALUE, [prop])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                back = ""
                if len(d) >= 1 and d[0] <= 64:
                    try:
                        back = "".join(
                            chr(d[i]) for i in range(1, min(len(d), 1 + d[0] * 2)) if d[i])
                    except Exception:
                        pass
                print(f"    回读 Value <- {back!r}")
            # GetDeviceInfo 对比(轻量:只看操作码集合)
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
            if rc == OK and blob is not None:
                post_ops = set(parse_device_info(blob[HDR:])["operationsSupported"])
                note = ""
                if post_ops != base_ops:
                    note = (f"\n      新增: {' '.join(f'0x{x:04X}' for x in sorted(post_ops - base_ops)) or '无'}"
                            f"\n      消失: {' '.join(f'0x{x:04X}' for x in sorted(base_ops - post_ops)) or '无'}")
                print(f"    GetDeviceInfo <- 操作码 {len(post_ops)} 个"
                      f"(实验前 {len(base_ops)} 个){note}")
                base_ops = post_ops
            retry_data_ops()
            # 关/开会话再对比(排除「本会话已定型」的可能)
            txid += 1
            txid, _d, rc = xact(dev, ep_out, ep_in, txid, CLOSE_SESSION)
            print(f"    CloseSession <- 0x{rc:04X}")
            txid += 1
            txid, rc = ensure_session(dev, ep_out, ep_in, txid)
            print(f"    OpenSession <- 0x{rc:04X}")
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
            if rc == OK and blob is not None:
                post_ops = set(parse_device_info(blob[HDR:])["operationsSupported"])
                print(f"    会话重开后 GetDeviceInfo <- 操作码 {len(post_ops)} 个")
            retry_data_ops()
        print(f"  [4s 小结] 数据操作解锁:{'是 ✓' if unlocked else '否 —— 身份假设不成立或需换姿势'}")

    # 步骤 4b:OpenSession 之后再取一次 GetDeviceInfo。Zf 的
    # OperationsSupported 会随相机连接状态变(2026-10-01:同固件 V3.00
    # 两天内 119 码 ↔ 23 码两副面孔),对比会话前后的能力集是否一致。
    txid += 1
    txid, blob2, rc2 = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
    if rc2 == OK and blob2 is not None:
        post = dump_device_info(blob2[HDR:])
        pre_ops = set(device_info["operationsSupported"])
        post_ops = set(post["operationsSupported"])
        print(f"[4b] 会话后 GetDeviceInfo <- 0x{rc2:04X} "
              f"操作码 {len(post_ops)} 个(会话前 {len(pre_ops)} 个)")
        if post_ops != pre_ops:
            only_post = " ".join(f"0x{x:04X}" for x in sorted(post_ops - pre_ops))
            only_pre = " ".join(f"0x{x:04X}" for x in sorted(pre_ops - post_ops))
            print(f"    会话后新增: {only_post or '无'}")
            print(f"    会话后消失: {only_pre or '无'}")
    else:
        print(f"[4b] 会话后 GetDeviceInfo <- 0x{rc2:04X}(失败,跳过对比)")

    # 步骤 5(可选):存储与对象多姿势枚举。Zf 实测疑点:parent=ALL 的
    # 「递归」只回根层文件夹,拍的照片藏在文件夹查询里;--peek 可拿事件里
    # 抓到的 handle 直接点名。--objinfo N 对发现的前 N 个对象调 GetObjectInfo。
    def list_objects(cur_txid, params, label):
        cur_txid, blob, rc = xact(dev, ep_out, ep_in, cur_txid, GET_OBJECT_HANDLES, params)
        (cnt,) = struct.unpack_from("<I", blob, HDR)
        hs = list(struct.unpack_from(f"<{cnt}I", blob, HDR + 4)) if cnt else []
        print(f"    {label} <- 0x{rc:04X} 共 {cnt} 个: "
              + " ".join(f"0x{h:08X}" for h in hs[:12]) + (" …" if cnt > 12 else ""))
        return cur_txid, hs

    handles: tuple = ()          # 递归姿势的结果,作 [6b] 对照基准
    discovered: list[int] = []   # 全部姿势去重后的对象
    if args.handles or args.objinfo or args.peek:
        txid += 1
        txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_STORAGE_IDS)
        # 不在册操作可能回空 DATA 容器(仅 12B 头,2026-10-01 Zf 实测)
        # 而非错误码 —— 按零存储处理,不崩。
        if data_blob is not None and len(data_blob) >= HDR + 4:
            (n_stor,) = struct.unpack_from("<I", data_blob, HDR)
            sids = struct.unpack_from(f"<{n_stor}I", data_blob, HDR + 4) if n_stor else ()
        else:
            n_stor, sids = 0, ()
        print(f"[5] GetStorageIDs <- 0x{rcode:04X} 共 {n_stor} 个: "
              + " ".join(f"0x{s:08X}" for s in sids))
        for s in sids:
            txid += 1
            txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_STORAGE_INFO, [s])
            if rcode == OK:
                dump_storage_info(s, data_blob[HDR:])
                print(f"      原始字节(核对对齐): {data_blob[HDR:HDR + 34].hex(' ')}")
        print("[5] GetObjectHandles 多姿势枚举:")
        txid, hs = list_objects(txid, [STORAGE_ALL, FORMAT_ALL, PARENT_ALL],
                                "全存储×递归(parent=ALL)")
        handles = tuple(hs)
        discovered += hs
        txid, hs = list_objects(txid, [STORAGE_ALL, FORMAT_ALL, PARENT_ROOT],
                                "全存储×仅根层(parent=0)")
        discovered += [h for h in hs if h not in discovered]
        for s in sids:
            txid, hs = list_objects(txid, [s, FORMAT_ALL, PARENT_ALL], f"存储 0x{s:08X}×递归")
            discovered += [h for h in hs if h not in discovered]
        for h in list(handles)[:8]:  # 根层文件夹逐个问内容(照片应在此现身)
            txid, hs = list_objects(txid, [STORAGE_ALL, FORMAT_ALL, h],
                                    f"文件夹 0x{h:08X} 之内")
            discovered += [h2 for h2 in hs if h2 not in discovered]
        print(f"    合计发现 {len(discovered)} 个不同对象")
        if args.peek:
            missing = [h for h in args.peek if h not in discovered]
            print(f"    --peek 的 handle 在枚举结果中现身: "
                  f"{len(args.peek) - len(missing)}/{len(args.peek)}"
                  + (";" + " ".join(f"0x{h:08X} 未现身" for h in missing) if missing else ""))

    # --peek 的 handle 最优先(事件里抓到的新照片就在这),枚举发现紧随其后
    info_targets = list(dict.fromkeys(list(args.peek) + discovered))
    info_targets = info_targets[:max(args.objinfo, len(args.peek))]
    if info_targets:
        print(f"[5b] GetObjectInfo×{len(info_targets)}(只读,格式码以此为准):")
    for h in info_targets:
        txid += 1
        txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
        if rcode == OK:
            dump_object_info(h, data_blob[HDR:])
        else:
            print(f"    handle 0x{h:08X}: GetObjectInfo <- 0x{rcode:04X}")

    # 步骤 6(可选,--events N):监听 interrupt IN 抓真实事件容器。
    # 此时在相机上做任意操作(半按快门/拍一张/转波轮),事件会推到 0x83。
    # 读法:按包(wMaxPacketSize=8)逐段收,再按 u32 长度字段补齐 —— 若一口气
    # 读 64B,整 8 字节倍数的事件(12B 头+1 参数=16B)会等不到短包而超时丢包。
    if args.events and ep_intr is not None:
        print(f"[6] 监听 interrupt IN {args.events} 秒 —— 现在在相机上按快门/转波轮…")
        import time as _time
        deadline = _time.monotonic() + args.events
        n = 0
        while _time.monotonic() < deadline:
            try:
                chunk = bytes(dev.read(ep_intr, 8, 500))
            except usb.core.USBError:
                continue  # 超时:窗口内无事发生
            if not chunk:
                continue  # ZLP:仅包界标志,无数据
            ev = chunk
            try:
                (elen,) = struct.unpack_from("<I", ev, 0)
                sane = EVENT_HDR <= elen <= 64
            except struct.error:
                sane = False
            if not sane:
                print(f"    疑非事件起始字节({len(ev)}B): {ev.hex(' ')}")
                continue
            try:
                while len(ev) < elen:
                    ev += bytes(dev.read(ep_intr, 8, 200))
            except usb.core.USBError:
                pass  # 补齐途中超时:半截事件也原样上报
            n += 1
            print(f"    事件 #{n} 原始字节({len(ev)}B): {ev.hex(' ')}")
            if len(ev) >= EVENT_HDR:
                elen, etype, ecode, etxid = struct.unpack_from("<IHHI", ev)
                print(f"      len={elen} type={etype} eventCode=0x{ecode:04X} txid={etxid}"
                      + ("(=0xFFFFFFFF,异步事件无关联事务)" if etxid == 0xFFFFFFFF else ""))
        if n == 0:
            print("    (窗口内无事件;试试 --events 期间按快门)")

    # 步骤 6b(--objinfo/--peek 且开了事件窗口):重枚举各姿势,核对窗口期间新拍的对象
    if (args.objinfo or args.peek) and args.events:
        refound: list[int] = []
        for params, label in [([STORAGE_ALL, FORMAT_ALL, PARENT_ALL], "全存储×递归"),
                              ([STORAGE_ALL, FORMAT_ALL, PARENT_ROOT], "仅根层")]:
            txid, hs = list_objects(txid, params, f"  重枚举 {label}")
            refound += [h for h in hs if h not in discovered]
        for h in list(handles)[:8]:
            txid, hs = list_objects(txid, [STORAGE_ALL, FORMAT_ALL, h],
                                    f"  重枚举 文件夹 0x{h:08X} 内")
            refound += [h2 for h2 in hs if h2 not in discovered]
        refound = list(dict.fromkeys(refound))
        print(f"[6b] 事件窗口后重枚举:新增 {len(refound)} 个")
        for h in refound[:max(args.objinfo, 4)]:
            txid += 1
            txid, data_blob, rcode = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
            if rcode == OK:
                dump_object_info(h, data_blob[HDR:])
            else:
                print(f"    handle 0x{h:08X}: GetObjectInfo <- 0x{rcode:04X}")

    # 收尾:关会话(不留悬挂状态,下次探针无需恢复)
    txid += 1
    close_session(dev, ep_out, ep_in, txid)

    # TODO(P0-usb): 相机以 STALL 表达"忙"时的 CLEAR_HALT + 重试(探针暂未实现,
    #   USBError(EPIPE) 时原样上报);大文件 GetObject 的分块读;错误注入对拍。
    usb.util.dispose_resources(dev)
    print("[OK] PTP/USB 握手通过;输出请整段发回,用于回填常量与布局订正")
    return 0


if __name__ == "__main__":
    sys.exit(main())

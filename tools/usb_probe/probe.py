#!/usr/bin/env python3
"""NikonPill USB PTP 探针。

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
    遥控域回归(曝光属性解码对照 / Live View 帧格式 / 快门事件时间线):
        ... probe.py --propdesc 5007,500d,500f
        ... probe.py --liveview 10
        ... probe.py --capture                    # 0x100E 标准
        ... probe.py --capture --capture-op 9207  # 尼康候选落卡拍

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
# 尼康厂商码(GetObjectsMetaData —— 批量 ObjectInfo,渐进式相册的快路候选;
# 姿势/数据布局未真机验证,--objmeta 摸底)
NIKON_GET_OBJECTS_META = 0x9434

# 遥控域(与 lib/core/ptp/operation_codes.dart 对齐;0x100E 为 ISO 标准,
# 其余尼康候选码 —— 姿势/数据布局待真机核对,--liveview/--capture 摸底)
INITIATE_CAPTURE = 0x100E
NIKON_INITIATE_CAPTURE_REC_IN_MEDIA = 0x9207
NIKON_INITIATE_CAPTURE_REC_IN_SDRAM = 0x90C0
NIKON_START_LIVEVIEW = 0x9201
NIKON_END_LIVEVIEW = 0x9202
NIKON_GET_LIVEVIEW_IMG = 0x9203
NIKON_GET_LIVEVIEW_IMG_EX = 0x9428  # OpenZCine 全系取帧码(应答带 display-info 头)
NIKON_CHANGE_AF_AREA = 0x9205  # p1/p2 = whole-size 坐标(OpenZCine PTPIPClientSession)
NIKON_CHANGE_APPLICATION_MODE = 0x9435  # 遥控 op 前须切应用模式(app enableAppControl 同款)
NIKON_DEVICE_READY = 0x90C8
NIKON_GET_PICTCTRL_DATA = 0x90CC  # 优化校准槽位详情:params[槽位,0],name=数据[3..23) ASCII(libgphoto2 在册;布局 = digiCamControl 实证)
DEVICE_BUSY = 0x2019  # ISO 15740 标准响应码(设备忙)

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
    0x90CC: "GetPictCtrlData(优化校准槽位详情,data-in;--picctrl 深化摸底)",
    0x9201: "StartLiveView", 0x9202: "EndLiveView", 0x9203: "GetLiveViewImg",
    0x9207: "InitiateCaptureRecInMedia(落卡拍,候选)",
    0x9400: "GetPartialObjectHiSpeed(尼康高速分块读)",
    0x9421: "GetObjectSize(64 位对象大小)",
    0x9431: "GetPartialObjectEx(64 位偏移+长度 —— Z 系断点续传主力)",
    0x9434: "GetObjectsMetaData(批量 ObjectInfo —— 渐进式相册快路候选)",
    0x9435: "ChangeApplicationMode(切应用模式,p1=1;不切遥控写被 0x200F 拒)",
    0x90C2: "ChangeCameraMode(切 remote/PC 模式,p1=1;OpenZCine USB 连接兜底)",
}
NIKON_EVENT_CANDIDATES = {
    0x4002: "ObjectAdded(标准)", 0x400D: "CaptureComplete(标准)",
    0xC101: "Nikon_ObjectAddedInSDRAM", 0xC102: "Nikon_CaptureCompleteRecInSdram",
    0xC125: "?(gphoto 未收录,待真机事件核对)", 0xC700: "?(gphoto 未收录)",
}
NIKON_PROP_CANDIDATES = {
    # 曝光写路径(OpenZCine Z 系口径:标准码 0x500D/0x500F 只读,写走厂商码)
    0xD0B4: "ExposureIndexEx(ISO 写,u32)", 0xD0B5: "IsoControlSensitivity(有效 ISO 读,u32)",
    0xD100: "StillShutterSpeed(快门读写,u32 分数打包 num<<16|den)",
    0xD1F0: "ApplicationMode(u8,一代机身切应用模式回退)",
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


# ── interrupt 事件读取(单包起读 + 按长度补齐,同步骤 [6] 纪律)────────

EVENT_NAMES = {
    0x4002: "ObjectAdded(标准)", 0x400D: "CaptureComplete(标准)",
    0xC101: "Nikon_ObjectAddedInSDRAM", 0xC102: "Nikon_CaptureCompleteRecInSdram",
    0xC10C: "Nikon_LiveViewStateChanged(候选,语义未实证)",
    0xC125: "?(gphoto 未收录)", 0xC700: "?(gphoto 未收录)",
}


def read_event_packet(dev, ep_intr, timeout_ms=50):
    """非阻塞读一个 interrupt 事件包;无事件/超时返回 None。

    疑非事件起始(长度字段不 sane)的包原样返回,由调用方判读 ——
    8B 起读 + 按 u32 长度补齐,整 8 字节倍数的事件才等得到短包。
    """
    try:
        chunk = bytes(dev.read(ep_intr, 8, timeout_ms))
    except usb.core.USBError:
        return None
    if not chunk:
        return None  # ZLP:仅包界标志
    try:
        (elen,) = struct.unpack_from("<I", chunk, 0)
        sane = EVENT_HDR <= elen <= 64
    except struct.error:
        sane = False
    if not sane:
        return chunk
    ev = chunk
    while len(ev) < elen:
        try:
            ev += bytes(dev.read(ep_intr, 8, 100))
        except usb.core.USBError:
            break  # 补齐途中超时:半截事件也原样上报
    return ev


def fmt_event(dt: float, ev: bytes) -> str:
    """事件时间线一行:t+时刻 事件码 名称 txid 参数。"""
    if len(ev) < EVENT_HDR:
        return f"t+{dt * 1000:.0f}ms  疑非事件({len(ev)}B): {ev.hex(' ')}"
    elen, _etype, ecode, etxid = struct.unpack_from("<IHHI", ev)
    n_params = max(0, (min(elen, len(ev)) - EVENT_HDR) // 4)
    params = struct.unpack_from(f"<{n_params}I", ev, EVENT_HDR) if n_params else ()
    ps = " ".join(f"0x{p:08X}" for p in params)
    name = EVENT_NAMES.get(ecode, "(未知名)")
    return (f"t+{dt * 1000:.0f}ms  0x{ecode:04X} {name} txid=0x{etxid:08X}"
            + (f" params=[{ps}]" if ps else ""))


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


# ── 设备属性数据集解码(镜像 lib/core/ptp/device_prop.dart)─────────────
# 用途:--propdesc 解码对照 —— 真机数据集与 Dart 解码对不上时,以本探针
# 备案的原始字节为准订正(何层失配一目了然:类型表?FORM?出厂组?)。

PTP_DTYPES = {
    # typecode -> (struct 格式, 字节宽, 名称);ISO 15740 §9.2
    0x0001: ("<b", 1, "INT8"), 0x0002: ("<B", 1, "UINT8"),
    0x0003: ("<h", 2, "INT16"), 0x0004: ("<H", 2, "UINT16"),
    0x0005: ("<i", 4, "INT32"), 0x0006: ("<I", 4, "UINT32"),
    0x0007: ("<q", 8, "INT64"), 0x0008: ("<Q", 8, "UINT64"),
    0xFFFF: (None, None, "STR"),
}

# ISO 15740 标准属性的数据集类型(与 kStandardPropDataType 对齐)
STANDARD_PROP_DTYPES = {
    0x5001: 0x0002,  # BatteryLevel u8
    0x5007: 0x0004,  # FNumber u16
    0x500D: 0x0006,  # ExposureTime u32
    0x500F: 0x0004,  # ExposureIndex u16
}


def read_ptp_value(buf: bytes, off: int, dtype: int):
    """按数据集类型读一个值,返回 (值, 下一偏移);未知类型抛 ValueError。"""
    entry = PTP_DTYPES.get(dtype)
    if entry is None:
        raise ValueError(f"未知数据集类型 0x{dtype:04X}")
    fmt, width, _name = entry
    if fmt is None:
        return read_ptp_str(buf, off)
    (v,) = struct.unpack_from(fmt, buf, off)
    return v, off + width


def parse_prop_desc(d: bytes) -> dict:
    """DevicePropDesc 数据集(ISO 15740 §10.5.1.3)防御性解码。

    布局(2026-10-06 订正,gphoto2 ptp_unpack_DPD 权威顺序):
    `u16 code + u16 type + u8 getSet + 出厂默认值 + 当前值 +
    u8 formFlag + FORM` —— **出厂默认值在前,当前值在后**(旧版读反:
    真机后果 = 光圈永远显示出厂默认 = 镜头最大光圈;更早版本漏读
    出厂值,把出厂值首字节当 formFlag,枚举域全丢)。
    与 Dart PtpDevicePropDesc.parse 同策略:值区截断 → 保描述弃 FORM;
    FORM 区异常 → 整组置空 + 整型属性扫描兜底
    (「0x02 + u16 计数 + count×宽度恰好收尾」定位枚举段)。
    """
    r = {"dataType": None, "getSet": None, "current": None, "factory": None,
         "rangeMin": None, "rangeMax": None, "rangeStep": None, "enumValues": None,
         "enumFromScan": False}
    try:
        (_prop, dtype) = struct.unpack_from("<HH", d, 0)
        r["dataType"] = dtype
        if dtype not in PTP_DTYPES:
            return r  # 未知类型码:头部之外不再解读
        r["getSet"] = bool(d[4])
        r["factory"], off = read_ptp_value(d, 5, dtype)
    except (IndexError, struct.error, ValueError):
        return r
    # 当前值(值区第二个;截断数据集可缺)
    values_intact = False
    try:
        if off < len(d):
            r["current"], off = read_ptp_value(d, off, dtype)
            values_intact = True
    except (IndexError, struct.error, ValueError):
        r["current"] = None
    if values_intact and off < len(d):
        try:
            form_flag = d[off]
            off += 1
            if form_flag == 0x01:  # Range FORM:最小 / 最大 / 步长
                r["rangeMin"], off = read_ptp_value(d, off, dtype)
                r["rangeMax"], off = read_ptp_value(d, off, dtype)
                r["rangeStep"], off = read_ptp_value(d, off, dtype)
            elif form_flag == 0x02:  # Enumeration FORM:u16 个数 + N 值
                (count,) = struct.unpack_from("<H", d, off)
                off += 2
                vals = []
                for _ in range(count):
                    v, off = read_ptp_value(d, off, dtype)
                    vals.append(v)
                r["enumValues"] = vals
        except (IndexError, struct.error, ValueError):
            r["rangeMin"] = r["rangeMax"] = r["rangeStep"] = None
            r["enumValues"] = None
    # 扫描兜底:FORM 没解出来时,整型属性按「u8 0x02 + u16 计数 +
    # count×宽度恰好填满缓冲」定位枚举段(OpenZCine 真机同款)。
    if r["enumValues"] is None and r["rangeMin"] is None:
        entry = PTP_DTYPES.get(dtype)
        if entry and entry[1] is not None:
            width = entry[1]
            for i in range(max(len(d) - 2, 0)):
                if d[i] != 0x02:
                    continue
                count = d[i + 1] | (d[i + 2] << 8)
                start = i + 3
                if count == 0 or start + count * width != len(d):
                    continue
                vals = []
                off2 = start
                for _ in range(count):
                    v, off2 = read_ptp_value(d, off2, dtype)
                    vals.append(v)
                r["enumValues"] = vals
                r["enumFromScan"] = True
                break
    return r


def decode_prop_value(prop: int, d: bytes, dtype_hint: int | None):
    """0x1015 裸值解码,返回 (值, 类型来源说明)。

    顺序:Desc 自描述类型 → ISO 标准表 → 长度嗅探(奇长且符合字符串
    布局 1+2n → STR;1/2/4/8 字节 → u8/u16/u32/u64,与
    PtpDevicePropValue.parse 同规则)。打印来源可直接回答「方言是否
    偏离标准表」。
    """
    n = len(d)
    dtype = None
    source = None
    if dtype_hint is not None and dtype_hint in PTP_DTYPES:
        dtype, source = dtype_hint, "Desc 自描述"
    elif prop in STANDARD_PROP_DTYPES:
        dtype, source = STANDARD_PROP_DTYPES[prop], "ISO 标准表"
    elif n >= 3 and n % 2 == 1 and d[0] == (n - 1) // 2:
        dtype, source = 0xFFFF, "嗅探(字符串布局)"
    elif n in (1, 2, 4, 8):
        dtype, source = {1: 0x0002, 2: 0x0004, 4: 0x0006, 8: 0x0008}[n], \
            "嗅探(字节宽)"
    if dtype is None:
        return None, f"无法嗅探({n}B)"
    try:
        v, _off = read_ptp_value(d, 0, dtype)
    except (IndexError, struct.error, ValueError) as e:
        return None, f"解码失败({e})"
    return v, f"{PTP_DTYPES[dtype][2]} / {source}"


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


# ── Nikon GetObjectsMetaData(0x9434)批量数据集布局判定 ────────────────

def parse_object_info_at(buf: bytes, off: int, handle: int | None = None) -> tuple:
    """游标版 ObjectInfo:从 off 读一条,返回 (字段字典, 下一偏移)。

    与 parse_object_info 的差别:第三个 STRING(modificationDate)也读完 ——
    批量数据集里记录紧密相邻,不读完会错位(单条数据集停在第二个串,
    因为后面没有下一条要解析)。尾部字符串缺失时容错停止(数据集恰好在
    此结束的情形;中间记录缺失则会被精确收尾校验否决,不致误判布局)。
    """
    (storage_id, fmt, _prot, size, _tf, _ts, _tw, _th,
     w, h, _depth, parent, _assoc, _ad, _seq) = struct.unpack_from(
        "<IHHIHIIIIIIIHII", buf, off)
    o = {"handle": handle, "storage_id": storage_id, "fmt": fmt, "size": size,
         "w": w, "h": h, "parent": parent}
    off += 52
    o["name"], off = read_ptp_str(buf, off)
    o["captured"], off = read_ptp_str(buf, off)
    try:
        _mod, off = read_ptp_str(buf, off)
    except (IndexError, struct.error):
        pass  # 尾部 modificationDate 缺失:容错收尾
    return o, off


def try_parse_meta(payload: bytes) -> tuple:
    """0x9434 数据载荷布局判定:候选逐个试,全收尾对齐才算命中。

    返回 (布局描述, 记录列表);全部对不上返回 ("", [])。候选(首 u32
    为记录数 N):
    - L2  N×(u32 handle + ObjectInfo)   句柄前缀,批量映射最理想
    - L3  N×ObjectInfo(无句柄,按请求序对齐)
    - L1  N×(u32 记录长 + ObjectInfo)   长度前缀(含/不含前缀两种口径)
    - L4  裸句柄数组(GetObjectHandles 同构,对元数据无用,仅记录)
    """
    if len(payload) < 4:
        return "", []
    (n,) = struct.unpack_from("<I", payload, 0)
    if n == 0 or n > len(payload) // 40:  # 每条 ObjectInfo ≥52B 头 + 至少两串
        return "", []
    if len(payload) == 4 + 4 * n:
        hs = struct.unpack_from(f"<{n}I", payload, 4)
        return "L4(裸句柄数组 —— 对元数据无用,等同 GetObjectHandles)", \
               [{"handle": h} for h in hs]
    # L2:句柄前缀
    recs, off = [], 4
    try:
        for _ in range(n):
            (h,) = struct.unpack_from("<I", payload, off)
            o, off = parse_object_info_at(payload, off + 4, h)
            recs.append(o)
    except (struct.error, IndexError):
        recs = []
    if recs and off == len(payload):
        return "L2(u32N + N×(u32句柄 + ObjectInfo))", recs
    # L3:无句柄,按请求序
    recs, off = [], 4
    try:
        for _ in range(n):
            o, off = parse_object_info_at(payload, off)
            recs.append(o)
    except (struct.error, IndexError):
        recs = []
    if recs and off == len(payload):
        return "L3(u32N + N×ObjectInfo,无句柄按请求序对齐)", recs
    # L1:长度前缀(先试「长度不含前缀」再试「含前缀」)
    for incl in (False, True):
        recs, off = [], 4
        try:
            for _ in range(n):
                (rlen,) = struct.unpack_from("<I", payload, off)
                o, _end = parse_object_info_at(payload, off + 4)
                recs.append(o)
                off = off + rlen if incl else off + 4 + rlen
                if off > len(payload):
                    raise IndexError
        except (struct.error, IndexError):
            recs = []
        if recs and off == len(payload):
            tag = "长度含前缀" if incl else "长度不含前缀"
            return f"L1(u32N + N×(u32记录长[{tag}] + ObjectInfo))", recs
    return "", []


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


# ── LiveViewObject 帧头解码(布局源 = OpenZCine PTPLiveViewObject.swift,
#    ZR/Z7 raw dump 实证;与 ptpip_probe decode_lv_header 镜像) ─────────

def _be16(p: bytes, o: int) -> int:
    return struct.unpack_from(">H", p, o)[0]

def _be32(p: bytes, o: int) -> int:
    return struct.unpack_from(">I", p, o)[0]

def _angle(p: bytes, o: int) -> str:
    """BE 有符号 16.16 定点角度(度);0xFFFFFFFF = 机身报不可靠。"""
    raw = _be32(p, o)
    if raw == 0xFFFFFFFF:
        return "unreliable"
    v = raw - (1 << 32) if raw >= (1 << 31) else raw
    return f"{v / 65536.0:.3f}°"

def decode_lv_header(p: bytes) -> None:
    """逐域打印 OpenZCine 布局的头字段 + 头部 hex(前 96B 与关键窗口)。"""
    soi = p.find(b"\xff\xd8")
    print(f"      [头解码] len={len(p)} SOI@{soi}")
    if len(p) < 56:
        print("      [头解码] < 56B,无 display-info 头")
        return
    print(f"        jpegLen(BE u32@12)={_be32(p, 12)}"
          f"  wholeSize(BE u16@16/18)={_be16(p, 16)}x{_be16(p, 18)}")
    print(f"        focusResult@42={p[42]} subjectActive@43={p[43]}"
          f" areaCount@44={p[44]} selectedIndex@45={p[45]}"
          f" trackingAF@46={p[46] if len(p) > 46 else '-'}")
    slots = min(max(p[44], 1), 96)
    for i in range(slots):
        base = 48 + i * 8
        if base + 8 > len(p):
            break
        w, h, cx, cy = struct.unpack_from(">HHHH", p, base)
        if w or h:
            print(f"        box[{i}] w={w} h={h} c=({cx},{cy})")
    if len(p) > 828:
        print(f"        recording@828={p[828]} tcOn@831={p[831]}"
              f" tc@832-835={p[832]:02d}:{p[833]:02d}:{p[834]:02d}:{p[835]:02d}"
              f" rotation@839={p[839]}")
    if len(p) >= 852:
        print(f"        level roll@840={_angle(p, 840)} pitch@844={_angle(p, 844)}"
              f" yaw@848={_angle(p, 848)}")
    for lo, hi in ((0, 96), (40, 64), (816, 852)):
        if len(p) < hi:
            continue
        print(f"        hex[{lo:#05x}:{hi:#05x}]:")
        for off in range(lo, min(hi, len(p)), 16):
            row = p[off:off + 16]
            print(f"          {off:04x}  {row.hex(' ')}")


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
    ap.add_argument("--objmeta", action="store_true",
                    help="Nikon 0x9434 GetObjectsMetaData 批量元数据摸底:"
                         "姿势矩阵(A 无参/B storageId/C 首 handle/D-F 数据出与"
                         "参数携带句柄)× 布局判定(L1-L4)+ 与逐个 GetObjectInfo "
                         "对拍;顺带句柄↔拍摄时间相关性(渐进加载「最新优先」"
                         "= 句柄倒序的依据)")
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
    ap.add_argument("--propdesc", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="Desc/Value 解码对照(--props 的深化版:镜像 Dart "
                         "device_prop.dart 的类型表/长度嗅探/FORM/MTP 出厂组"
                         "解码,并打印类型来源)—— 曝光三属性回归:"
                         "--propdesc 5007,500d,500f")
    ap.add_argument("--liveview", type=int, metavar="帧数", default=0,
                    help="Live View 摸底:0x9201 开取景 → 取帧轮询 N 帧"
                         "(间隔 200ms 对齐 app;连续 5 帧失败收口)→ 0x9202。"
                         "首帧落盘 /tmp + 逐域头解码,SOI 偏移直方图、帧率/"
                         "字节数/单帧往返延迟统计")
    ap.add_argument("--liveview-op", type=lambda s: int(s, 16), metavar="hex",
                    default=NIKON_GET_LIVEVIEW_IMG,
                    help="取帧操作码:0x9203(老码,默认)/ 0x9428(Ex 码,"
                         "应答带 display-info 头 = 对焦框/水平仪/录制态"
                         "唯一数据源)")
    ap.add_argument("--afarea", type=str, metavar="x,y", default=None,
                    help="4v 内:取帧完成后发 0x9205 ChangeAfArea(x,y),"
                         "再取 8 帧看 box[0] 是否移到 —— whole-size 坐标系实证")
    ap.add_argument("--capture", action="store_true",
                    help="快门释放摸底:发拍照 op + interrupt 事件时间线"
                         "+ 0x90C8 DeviceReady 忙等收口(300ms×30,事件先到"
                         "也继续听完)")
    ap.add_argument("--capture-op", type=lambda s: int(s, 16), metavar="hex",
                    default=INITIATE_CAPTURE,
                    help="拍照操作码:0x100E(标准,默认)/ 0x9207 / 0x90C0"
                         "(尼康候选,配合 --capture)")
    ap.add_argument("--vendorcodes", action="store_true",
                    help="0x9439 GetVendorCodes:厂商操作码(0x09)/属性码(0x0D)全表")
    ap.add_argument("--picctrl", action="store_true",
                    help="优化校准 0xD200 摸底:FORM 枚举全量(不截 12)"
                         "+ 每槽位 0x90CC GetPictCtrlData 读注册名"
                         "(自定义/云组真名;布局 = digiCamControl 实证:"
                         "[1]单色 [2]自定义 [3..23) ASCII 名)")
    ap.add_argument("--xact", type=str, metavar="OP[|p1,…][=hex]",
                    action="append", default=[],
                    help="任意事务梯:按序直发并打印响应码/数据量。OP 与参数"
                         "皆十六进制(如 9435|1 / 90C2|1 / 9201 / "
                         "1016|D1F0=01 后者为 data-out 载荷)。连接脚本对照"
                         "仪器:0x9435 → 0x90C2(1) → 0x9201 哪级解开 Zf "
                         "上传优先模式门(机身屏显由操作者目视对照)")
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

    # 步骤 4x(可选,--xact):任意事务梯 —— 连接脚本/模式门直发仪器。
    # 背景:OpenZCine 连接脚本(0x9435 → 0x90C2(1) USB 兜底)与 NikonPill
    # enableAppControl 同款,但 Zf 机身停上传优先横幅的病根未定 —— 逐级
    # 直发记录响应码,机身屏显由操作者目视对照(usbfs 直连人设与 iOS IC
    # 人设可能不同;usbfs 实证的 0xD406 身份钥匙在 IC 链不生效)。
    if args.xact:
        print("[4x] 事务梯直发:")
        for spec in args.xact:
            data_hex = None
            if "=" in spec:
                spec, data_hex = spec.split("=", 1)
            params: list = []
            if "|" in spec:
                spec, params_hex = spec.split("|", 1)
                params = [int(p, 16) for p in params_hex.split(",") if p]
            try:
                op = int(spec, 16)
            except ValueError:
                print(f"    无法解析:{spec}(格式 OP[|p1,p2…][=hexdata])")
                continue
            payload = None if data_hex is None else bytes.fromhex(data_hex)
            name = NIKON_OC_CANDIDATES.get(op, "?")
            tag = (f"0x{op:04X}({name})[{','.join('0x%X' % p for p in params)}]"
                   + (f" dataOut={len(payload)}B" if payload is not None else ""))
            try:
                txid += 1
                if payload is None:
                    txid, blob, rc = xact(dev, ep_out, ep_in, txid, op, params)
                else:
                    txid, rc = xact_out(dev, ep_out, ep_in, txid, op, params,
                                        payload)
                    blob = None
            except (usb.core.USBError, IOError) as e:
                print(f"    {tag} <- USB 异常:{e}")
                try:
                    dev.clear_halt(ep_out)
                    dev.clear_halt(ep_in)
                    print("      已 clear_halt 两端点")
                except usb.core.USBError:
                    pass
                continue
            if blob is not None and rc == OK:
                data = blob[HDR:]
                print(f"    {tag} <- 0x{rc:04X}  data={len(data)}B  "
                      f"head={data[:16].hex(' ')}")
            else:
                print(f"    {tag} <- 0x{rc:04X}"
                      + ("" if blob is None
                         else f"  数据 {(len(blob) - HDR)}B(响应非 OK)"))

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

    # 步骤 4m(可选,--objmeta):Nikon GetObjectsMetaData(0x9434)摸底 ——
    # 渐进式相册的快路候选:一次往返拿一批 ObjectInfo,代替 N+1 枚举。
    # 语义(参数/数据相位/返回布局)未真机验证:姿势矩阵逐个试 + 布局判定,
    # 再与逐个 GetObjectInfo 对拍。全部拒答 → 不做快路,N+1 分块兜底 UX。
    # 顺带做句柄↔拍摄时间相关性(渐进加载「最新优先 = 句柄倒序」的依据)。
    if args.objmeta:
        print("[4m] Nikon 0x9434 GetObjectsMetaData 摸底(渐进式相册快路):")
        supports = NIKON_GET_OBJECTS_META in device_info["operationsSupported"]
        print(f"    0x9434 在册:{'✓' if supports else '✗(受限码表欠报先例:0x100A/0x90C4 也曾缺席,仍继续直发摸底)'}")

        def meta_op(params: list, payload_out: bytes | None) -> tuple:
            """0x9434 一次姿势,返回 (数据载荷|None, 响应码)。

            数据出姿势在读回时按容器类型分叉:相机若在 data-out 后仍回
            数据相位(批量元数据正是这种形态),先把 DATA 收完再读响应,
            避免 xact_out 把 DATA 容器当响应、真响应留在缓冲毒化下一姿势。
            USB 异常照 [4p] 惯例 clear_halt 两端点后续姿势。
            """
            nonlocal txid
            try:
                if payload_out is None:
                    txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                          NIKON_GET_OBJECTS_META, params)
                    data = blob[HDR:] if (blob is not None and rc == OK) else None
                    return data, rc
                dev.write(ep_out, cmd_container(NIKON_GET_OBJECTS_META, txid,
                                                params), 5000)
                dc = (u32(HDR + len(payload_out)) + u16(DATA)
                      + u16(NIKON_GET_OBJECTS_META) + u32(txid) + payload_out)
                dev.write(ep_out, dc, 5000)
                blob = read_container(dev, ep_in)
                _l, rtype, rc, _x = parse_head(blob)
                if rtype == DATA:
                    data = blob[HDR:]
                    resp = read_container(dev, ep_in)
                    _l2, _t2, rc, _x2 = parse_head(resp)
                    return (data if rc == OK else None), rc
                return None, rc
            except (usb.core.USBError, IOError) as e:
                print(f"      USB 异常:{e}")
                try:
                    dev.clear_halt(ep_out)
                    dev.clear_halt(ep_in)
                    print("      已 clear_halt 两端点")
                except usb.core.USBError:
                    pass
                return None, -1

        # 前置:全量句柄(与 app 同参:Zf 实测 parent=0 才返回全部对象)
        txid += 1
        txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_HANDLES,
                              [STORAGE_ALL, FORMAT_ALL, PARENT_ROOT])
        (cnt,) = struct.unpack_from("<I", blob, HDR)
        all_handles = list(struct.unpack_from(f"<{cnt}I", blob, HDR + 4)) if cnt else []
        if not all_handles:
            print("    相机无对象,0x9434 无从对拍 —— 跳过")
        else:
            # 首句柄 storageId(姿势 B 用)+ 前 3 个句柄作提问样本
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO,
                                  [all_handles[0]])
            sid = struct.unpack_from("<I", blob[HDR:], 0)[0] if rc == OK else 0
            sample = all_handles[:3]
            print(f"    全量 {len(all_handles)} 个句柄;提问样本:"
                  + " ".join(f"0x{h:08X}" for h in sample)
                  + f";首对象存储 0x{sid:08X}" + ("" if sid else "(未取到,姿势 B 以 0 代替)"))
            poses = [
                ("A", "无参", [], None),
                ("B", "参数=storageId", [sid], None),
                ("C", "参数=首handle", [sample[0]], None),
                ("D", "数据出=计数+句柄", [], u32(3) + b"".join(u32(h) for h in sample)),
                ("E", "数据出=句柄(参数=个数)", [3], b"".join(u32(h) for h in sample)),
                ("F", "参数=个数+句柄", [3] + list(sample), None),
            ]
            for tag, desc, params, payload in poses:
                print(f"  ▶ 姿势 {tag}({desc})")
                data, rc = meta_op(params, payload)
                if rc == -1:
                    continue
                if data is None:
                    print(f"      <- 0x{rc:04X}" + ("(无数据相位)" if rc == OK else ""))
                    continue
                print(f"      <- 0x{rc:04X}  数据 {len(data)}B  头 64B: {data[:64].hex(' ')}")
                if len(data) > 64:
                    out = f"/tmp/nikonpill_probe_objmeta_{tag}.bin"
                    with open(out, "wb") as f:
                        f.write(data)
                    print(f"      原始字节已存:{out}")
                layout, recs = try_parse_meta(data)
                if not layout:
                    print("      布局:L1/L2/L3 均对不上(见 /tmp 原始字节,人工判读)")
                    continue
                print(f"      布局判定:{layout}  解出 {len(recs)} 条"
                      f"(请求 3,全量 {len(all_handles)})")
                for o in recs[:3]:
                    h_s = f"0x{o['handle']:08X}" if o.get("handle") is not None else "(无句柄,按请求序)"
                    print(f"        {h_s} {o['name']}  fmt=0x{o['fmt']:04X}"
                          f" size={o['size']} 父=0x{o['parent']:08X} 拍摄 {o.get('captured', '?')}")
                # 对拍:前 2 条与逐个 GetObjectInfo 比名称/大小/父句柄
                checked = mismatched = 0
                for i, o in enumerate(recs[:2]):
                    h = o.get("handle")
                    if h is None:
                        h = sample[i] if i < len(sample) else None  # 无句柄布局按请求序映射
                    if h is None:
                        continue
                    txid += 1
                    txid, b2, rc2 = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
                    if rc2 != OK:
                        continue
                    ref = parse_object_info(b2[HDR:])
                    same = (ref["name"] == o["name"] and ref["size"] == o["size"]
                            and ref["parent"] == o["parent"])
                    checked += 1
                    mismatched += 0 if same else 1
                    print(f"        对拍 0x{h:08X}:{'一致 ✓' if same else f'不一致!!单条参考:{ref}'}")
                if checked and not mismatched:
                    print(f"      ★ 姿势 {tag} 可用:{layout} —— 快路按此实现(Step 6)")
                elif mismatched:
                    print("      对拍不一致:布局或顺序判定存疑,人工核对 /tmp 字节")

        # 句柄↔拍摄时间相关性:前 40 + 后 40 个句柄逐个 GetObjectInfo,
        # 验证「句柄升序 ≈ 拍摄时间升序」(渐进加载最新优先 = 倒序请求的依据)。
        if all_handles:
            print("    句柄↔拍摄时间相关性(前 40 + 后 40,按枚举序):")
            picks = list(dict.fromkeys(all_handles[:40] + all_handles[-40:]))
            rows = []
            for h in picks:
                txid += 1
                txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
                if rc == OK:
                    o = parse_object_info(blob[HDR:])
                    if o["captured"] and o["captured"] != "(未提供)":
                        rows.append((h, o["captured"]))
            for h, t in rows[:6]:
                print(f"      0x{h:08X} {t}")
            if len(rows) > 12:
                print("      …")
            for h, t in rows[-6:]:
                print(f"      0x{h:08X} {t}")
            if len(rows) < 4:
                print("      样本不足,无法判定")
            else:
                # 拍摄时间是 YYYYMMDDTHHMMSS 定长格式,字典序即时间序
                asc = all(rows[i][1] <= rows[i + 1][1] for i in range(len(rows) - 1))
                desc = all(rows[i][1] >= rows[i + 1][1] for i in range(len(rows) - 1))
                if asc and not desc:
                    print("      结论:句柄升序 ≈ 时间升序 ✓"
                          " —— 渐进加载用句柄倒序 = 最新优先,保留反转")
                elif desc and not asc:
                    print("      结论:句柄升序 ≈ 时间降序 —— 渐进加载保持原序即最新优先,删除反转")
                else:
                    print("      结论:无单调关系 —— 最新优先不可靠,填充顺序任选(仅影响出现先后,不影响排序)")

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
            elif text.startswith("u16:"):
                # u16 载荷(如 0xD05D AF 区域模式):u16:0x8010
                payload = struct.pack("<H", int(text[4:], 0) & 0xFFFF)
            elif text.startswith("u8:"):
                # u8 载荷(如 0xD1A6 LiveViewSelector):u8:0 / u8:1
                payload = struct.pack("<B", int(text[3:], 0) & 0xFF)
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
                print(f"    回读 Value <- {back!r} hex={d.hex(' ')}")
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

    # 步骤 4r(可选,--propdesc):Desc/Value 解码对照 —— 镜像 Dart
    # device_prop.dart 的解码链(类型来源:Desc 自描述 → ISO 标准表 →
    # 长度嗅探;FORM 范围/枚举 + MTP 出厂组)。曝光三属性(遥控页)回归:
    # 真机数据集与 app 解码对不上时,以本步备案的原始字节订正哪层失配。
    if args.propdesc:
        print("[4r] 设备属性 Desc/Value 解码对照:")
        for prop in args.propdesc:
            dtype_hint = None
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  GET_DEVICE_PROP_DESC, [prop])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                print(f"  0x{prop:04X} Desc <- OK {len(d)}B")
                print(hexdump(d, limit=256))
                desc = parse_prop_desc(d)
                dtype_hint = desc["dataType"]
                if dtype_hint is not None and dtype_hint not in PTP_DTYPES:
                    print(f"    解码: DataType=0x{dtype_hint:04X}(未知类型码,头部外不解读)")
                else:
                    tname = PTP_DTYPES[dtype_hint][2] if dtype_hint is not None else "?"
                    print(f"    解码: DataType={tname}  getSet={desc['getSet']}"
                          f"({'可写' if desc['getSet'] else '只读'})"
                          f"  current={desc['current']!r}")
                    if desc["rangeMin"] is not None:
                        print(f"    FORM 范围: {desc['rangeMin']!r} ~ {desc['rangeMax']!r}"
                              f" 步长 {desc['rangeStep']!r}")
                    if desc["enumValues"]:
                        vals = desc["enumValues"]
                        print(f"    FORM 枚举({len(vals)}): "
                              + " ".join(repr(v) for v in vals[:12])
                              + (" …" if len(vals) > 12 else ""))
                    if desc["factory"]:
                        print(f"    MTP 出厂组: {desc['factory']!r}")
            else:
                print(f"  0x{prop:04X} Desc <- 0x{rc:04X}")
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  GET_DEVICE_PROP_VALUE, [prop])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                print(f"  0x{prop:04X} Value <- OK {len(d)}B  raw: {d[:48].hex(' ')}")
                v, src = decode_prop_value(prop, d, dtype_hint)
                print(f"    解码: {src} -> {v!r}")
            else:
                print(f"  0x{prop:04X} Value <- 0x{rc:04X}")

    # 步骤 4w(可选,--picctrl):优化校准(0xD200)槽位摸底 —— FORM 枚举
    # 全量(4r 截 12,这里 46 项全列)+ 每槽位 0x90CC GetPictCtrlData 读
    # 注册名(自定义/云组的真名在机身上由用户起,FORM 只有槽位号)。布局
    # = digiCamControl NikonBase.GetPictureControl 实证:[0]未知 [1]单色
    # 标志 [2]自定义标志 [3..23) 20 字节 ASCII 名 NUL 截断。回归点:
    # FORM 项数(用户真机 46)、getSet、0x90CC 应答形态与名字字节。
    if args.picctrl:
        print("[4w] 优化校准 0xD200 摸底(FORM 全量 + 0x90CC 槽位名):")
        txid += 1
        txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                              GET_DEVICE_PROP_DESC, [0xD200])
        slots = []
        if rc == OK and blob is not None:
            d = blob[HDR:]
            desc = parse_prop_desc(d)
            print(f"  Desc <- OK {len(d)}B  getSet={desc['getSet']}"
                  f"({'可写' if desc['getSet'] else '只读'})"
                  f"  current={desc['current']!r}")
            slots = list(desc["enumValues"])
            if slots:
                print(f"  FORM 枚举({len(slots)}): "
                      + " ".join(str(v) for v in slots))
            else:
                print("  FORM 枚举:无(只读裸值?—— 46 项清单得靠机身菜单)")
        else:
            print(f"  Desc <- 0x{rc:04X}(FORM 拿不到,跳过槽位名)")
        for slot in slots:
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                  NIKON_GET_PICTCTRL_DATA, [slot, 0])
            if rc == OK and blob is not None:
                d = blob[HDR:]
                name = (d[3:23].split(b"\x00")[0].decode("ascii", "replace")
                        if len(d) >= 23 else "")
                mono = d[1] if len(d) > 1 else -1
                custom = d[2] if len(d) > 2 else -1
                print(f"  0x90CC({slot}) <- OK {len(d)}B  mono={mono}"
                      f" custom={custom}  name={name!r}")
                print("      " + d[:48].hex(" "))
            else:
                print(f"  0x90CC({slot}) <- 0x{rc:04X}")

    # 步骤 4x(可选,--vendorcodes):0x9439 GetVendorCodes —— 厂商码
    # 全表的正规通道(2026-10-12 官方指令书 §6.2.2.1):param 0x09 = 厂商
    # 操作码表 / 0x0D = 厂商属性码表,应答 = u32 计数 + N×u32 码(4 字节
    # 扩展形态 0x0001_xxxx 全量在列)。自录厂商码表,免逐码盲试。
    if args.vendorcodes:
        for kind, label in ((0x09, "操作码"), (0x0D, "属性码")):
            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, 0x9439, [kind])
            if rc == OK and blob is not None and len(blob) >= HDR + 4:
                d = blob[HDR:]
                import struct as _struct
                count = _struct.unpack_from("<I", d, 0)[0]
                codes = list(_struct.unpack_from(
                    f"<{min(count, (len(d) - 4) // 4)}I", d, 4)) if count else []
                print(f"[4x] GetVendorCodes({label}, param 0x{kind:02X}) "
                      f"<- OK  count={count}")
                for c in codes:
                    print(f"    0x{c:08X}"
                          + (f"  (2 字节形态 0x{c & 0xFFFF:04X})"
                             if c > 0xFFFF else ""))
            else:
                print(f"[4x] GetVendorCodes({label}) <- 0x{rc:04X}"
                      f"(拒答不阻断 —— 不在表 ≠ 不应答,STA 9-op 同理)")

    # 步骤 4v(可选,--liveview N):Live View 轮询摸底 —— 0x9435 切应用
    # 模式 → 0x9201 开取景 → 取帧轮询直到 N 帧成功(间隔 200ms 对齐 app;
    # 失败同拍重试,连续 5 帧失败收口 —— LiveViewEngine 同策略)→ 0x9202
    # 收尾。首帧落盘 + 逐域头解码;取帧码 --liveview-op:0x9203(老码)vs
    # 0x9428(Ex,OpenZCine 全系取帧码,应答带 display-info 头)对拍。
    # 0x9435 前置:Z 系方言,遥控 op 前须切应用模式(2026-10-07 Zf STA
    # 实证:无 0x9435 的 0x9201 一发即断链;app enableAppControl 同款)。
    if args.liveview:
        fetch_op = args.liveview_op
        print(f"[4v] Live View 摸底(0x9435 → 0x9201 → 0x{fetch_op:04X}"
              f" ×{args.liveview} 帧 → 0x9202):")
        txid += 1
        txid, _, rc = xact(dev, ep_out, ep_in, txid,
                           NIKON_CHANGE_APPLICATION_MODE, [1])
        print(f"    ChangeApplicationMode(0x9435,1) <- 0x{rc:04X}")
        txid += 1
        txid, blob, rc = xact(dev, ep_out, ep_in, txid, NIKON_START_LIVEVIEW)
        print(f"    StartLiveView <- 0x{rc:04X}")
        if rc == OK:
            t0 = time.monotonic()
            sizes, latencies, soi_hist = [], [], {}
            fails = got = attempt = 0

            def drain_events() -> None:
                """排空 interrupt 事件(0xC10C 取景态变迁语义在此落定)。"""
                while ep_intr is not None:
                    ev = read_event_packet(dev, ep_intr, 50)
                    if ev is None:
                        return
                    print("      " + fmt_event(time.monotonic() - t0, ev))

            drain_events()
            while got < args.liveview and fails < 5:
                time.sleep(0.2)  # 开取景后相机就绪需拍前摇,失败亦同拍重试
                attempt += 1
                t_x = time.monotonic()
                try:
                    txid += 1
                    txid, blob, rc = xact(dev, ep_out, ep_in, txid, fetch_op)
                except (usb.core.USBError, IOError) as e:
                    print(f"    尝试 #{attempt} <- USB 异常:{e}")
                    try:
                        dev.clear_halt(ep_out)
                        dev.clear_halt(ep_in)
                        print("      已 clear_halt 两端点")
                    except usb.core.USBError:
                        pass
                    fails += 1
                    continue
                latencies.append(time.monotonic() - t_x)
                drain_events()
                if rc != OK or blob is None:
                    print(f"    尝试 #{attempt} <- 0x{rc:04X}")
                    fails += 1
                    continue
                fails = 0
                got += 1
                data = blob[HDR:]
                soi = data.find(b"\xff\xd8")
                sizes.append(len(data))
                soi_hist[soi] = soi_hist.get(soi, 0) + 1
                print(f"    帧 #{got}: {len(data)}B  SOI@{soi}")
                if got == 1:
                    ext = ".jpg" if soi >= 0 else ".bin"
                    out = f"/tmp/nikonpill_probe_liveview_first{ext}"
                    with open(out, "wb") as f:
                        f.write(data)
                    print(f"      头 32B: {data[:32].hex(' ')}  原始帧已存:{out}")
                    decode_lv_header(data)
            elapsed = max(time.monotonic() - t0, 1e-6)
            print(f"    小结:取得 {got}/{args.liveview} 帧(失败 {fails} 连击即止)"
                  f"  用时 {elapsed:.1f}s  实测帧率 {got / elapsed:.1f}fps")
            if sizes:
                print(f"    帧大小:min {min(sizes)}B / 均值 {sum(sizes) // len(sizes)}B"
                      f" / max {max(sizes)}B")
            if latencies:
                ms = sorted(x * 1000 for x in latencies)
                print(f"    单帧事务往返:min {ms[0]:.0f}ms / 中位 {ms[len(ms) // 2]:.0f}ms"
                      f" / max {ms[-1]:.0f}ms(app 间隔 200ms 是否够/过看这里)")
            if soi_hist:
                print("    SOI 偏移直方图: "
                      + "  ".join(f"@{k}×{v}" for k, v in sorted(soi_hist.items())))
                print("      (@0 = JPEG 裸流直接解码;@-1 = 无 SOI,非 JPEG 帧,"
                      "头 32B 备案判读 —— _sniffJpegStart 剥离策略以此回填)")

            # 4v-a(可选,--afarea x,y):0x9205 ChangeAfArea 坐标系实证 ——
            # 发指定坐标,取 8 帧看对焦框(box[0])是否移动到位。whole-size
            # 空间(头 @16/18)与 SOF 帧像素空间各试一次即可分辨坐标系。
            if args.afarea and got > 0:
                ax, ay = (int(v) for v in args.afarea.split(","))
                print(f"    [4v-a] ChangeAfArea(0x9205) x={ax} y={ay}:")
                txid += 1
                txid, _, rc = xact(dev, ep_out, ep_in, txid,
                                   NIKON_CHANGE_AF_AREA,
                                   [ax & 0xFFFFFFFF, ay & 0xFFFFFFFF])
                print(f"      ChangeAfArea <- 0x{rc:04X}")
                if rc == OK:
                    for i in range(8):
                        time.sleep(0.25)
                        try:
                            txid += 1
                            txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                                                  fetch_op)
                        except (usb.core.USBError, IOError) as e:
                            print(f"      帧 a#{i + 1} <- USB 异常:{e}")
                            break
                        if rc != OK or blob is None:
                            print(f"      帧 a#{i + 1} <- 0x{rc:04X}")
                            continue
                        data = blob[HDR:]
                        soi = data.find(b"\xff\xd8")
                        if len(data) >= 56:
                            w, h, cx, cy = struct.unpack_from(">HHHH", data, 48)
                            print(f"      帧 a#{i + 1}: box[0] w={w} h={h} c=({cx},{cy})"
                                  f" focusResult@42={data[42]} areaCount@44={data[44]}"
                                  f" SOI@{soi}")
                        else:
                            print(f"      帧 a#{i + 1}: {len(data)}B SOI@{soi}(无头)")

            txid += 1
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, NIKON_END_LIVEVIEW)
            print(f"    EndLiveView <- 0x{rc:04X}")
            drain_events()  # 0xC10C 若在停止时推送,语义在此落定

    # 步骤 4c(可选,--capture):快门释放摸底 —— 0x100E(标准)/0x9207/
    # 0x90C0(尼康候选)发一次,事件时间线(interrupt 轮询穿插,非阻塞)
    # + 0x90C8 DeviceReady 忙等收口(300ms×30,长曝余量;就绪后再听 2s
    # 收 ObjectAdded 拖尾)。事件语义(CaptureComplete 先后/双格式双
    # ObjectAdded/0xC10C)以此时间线落定,回填 RemoteController 消费表。
    if args.capture:
        names = {INITIATE_CAPTURE: "InitiateCapture 0x100E(标准)",
                 NIKON_INITIATE_CAPTURE_REC_IN_MEDIA:
                     "InitiateCaptureRecInMedia 0x9207(候选)",
                 NIKON_INITIATE_CAPTURE_REC_IN_SDRAM:
                     "InitiateCaptureRecInSdram 0x90C0(候选)"}
        label = names.get(args.capture_op, f"0x{args.capture_op:04X}")
        print(f"[4c] 快门释放摸底({label},参数 0,0):")
        if ep_intr is None:
            print("    [!] 无 interrupt IN 端点,事件时间线缺失(仅忙等)")
        t0 = time.monotonic()

        def drain_events() -> None:
            """排空 interrupt 事件(每条即打,时间线内联)。"""
            while ep_intr is not None:
                ev = read_event_packet(dev, ep_intr, 50)
                if ev is None:
                    return
                print("    " + fmt_event(time.monotonic() - t0, ev))

        txid += 1
        try:
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, args.capture_op,
                                  [0, 0])
        except (usb.core.USBError, IOError) as e:
            print(f"    t+0ms  op <- USB 异常:{e}")
            try:
                dev.clear_halt(ep_out)
                dev.clear_halt(ep_in)
                print("      已 clear_halt 两端点")
            except usb.core.USBError:
                pass
            rc = -1
        else:
            print(f"    t+0ms  op <- 0x{rc:04X}")
        if rc == OK:
            drain_events()
            for i in range(30):  # 300ms × 30 ≈ 9s:app 的 10×300ms 放宽,长曝余量
                time.sleep(0.3)
                drain_events()
                txid += 1
                t_x = time.monotonic()
                txid, blob, rc2 = xact(dev, ep_out, ep_in, txid,
                                       NIKON_DEVICE_READY)
                dt = (time.monotonic() - t_x) * 1000
                if rc2 == OK:
                    print(f"    t+{(time.monotonic() - t0) * 1000:.0f}ms  "
                          f"DeviceReady <- OK(落地,第 {i + 1} 轮,事务 {dt:.0f}ms)")
                    break
                if rc2 == DEVICE_BUSY:
                    print(f"    t+{(time.monotonic() - t0) * 1000:.0f}ms  "
                          f"DeviceReady <- 0x2019 忙(事务 {dt:.0f}ms)")
                    continue
                print(f"    DeviceReady <- 0x{rc2:04X}(非忙,放弃兜底 —— "
                      "命令已被接受,等事件即可)")
                break
            # 就绪后再听 2s:ObjectAdded 常晚于 CaptureComplete/就绪
            if ep_intr is not None:
                end = time.monotonic() + 2.0
                while time.monotonic() < end:
                    ev = read_event_packet(dev, ep_intr, 200)
                    if ev is not None:
                        print("    " + fmt_event(time.monotonic() - t0, ev))

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

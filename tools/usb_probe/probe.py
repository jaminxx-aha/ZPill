#!/usr/bin/env python3
"""NikonBridge USB PTP 探针(TODO.md USB 主线 P0)。

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

只读探针:仅 OpenSession / GetDeviceInfo / GetObjectHandles,
不发送任何写操作(不拍片、不删文件、不改设置)。
"""

from __future__ import annotations

import argparse
import struct
import sys

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
EVENT_HDR = 10  # 事件头:len u16 + type u16 + eventCode u16 + txid u32

# 操作码 / 响应码(与 lib/core/ptp/operation_codes.dart 对齐)
GET_DEVICE_INFO = 0x1001
OPEN_SESSION = 0x1002
GET_OBJECT_HANDLES = 0x1007
OK = 0x2001

# GetObjectHandles 参数(全部存储 / 全部格式 / 全部对象)
STORAGE_ALL = 0xFFFFFFFF
FORMAT_ALL = 0
PARENT_ALL = 0xFFFFFFFF


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
                usb.util.ENDPOINT_TYPE_INTERRUPT: "interrupt",
                usb.util.ENDPOINT_TYPE_ISO: "iso",
                usb.util.ENDPOINT_TYPE_CONTROL: "control",
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
        intr_in = match(usb.util.ENDPOINT_IN, usb.util.ENDPOINT_TYPE_INTERRUPT)
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


def read_u16_array(buf: bytes, off: int):
    (n,) = struct.unpack_from("<I", buf, off)
    off += 4
    vals = struct.unpack_from(f"<{n}H", buf, off) if n else ()
    return vals, off + 2 * n


def dump_device_info(payload: bytes) -> None:
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

    print(f"    型号: {r['model']}  固件: {r['deviceVersion']}  序列号: {r['serialNumber']}")
    print(f"    vendorExtensionId=0x{r['vendorExtensionId']:08X}"
          f"({r['vendorExtensionDesc']})  functionalMode={r['functionalMode']}")
    print(f"    支持的操作码({len(r['operationsSupported'])}): "
          + " ".join(f"0x{x:04X}" for x in r["operationsSupported"]))
    print(f"    支持的事件码({len(r['eventsSupported'])}): "
          + " ".join(f"0x{x:04X}" for x in r["eventsSupported"]))
    print(f"    支持的图像格式({len(r['imageFormats'])}): "
          + " ".join(f"0x{x:04X}" for x in r["imageFormats"]))
    print("    ↑ 回填对照:操作/事件码 → lib/core/ptp/operation_codes.dart;"
          "NEF 的 ObjectFormatCode → object_format.dart")


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
    dump_descriptors(dev)

    itf_no, ep_out, ep_in, ep_intr = find_sti_endpoints(dev)
    print(f"[2] 端点:bulkOUT=0x{ep_out:02X} bulkIN=0x{ep_in:02X} "
          f"interruptIN={f'0x{ep_intr:02X}' if ep_intr else '无'}(接口 {itf_no})")
    usb.util.claim_interface(dev, itf_no)

    txid = 0

    # 步骤 3:GetDeviceInfo(唯一可在 OpenSession 前调用的操作)
    dev.write(ep_out, cmd_container(GET_DEVICE_INFO, txid), 5000)
    data_blob = read_container(dev, ep_in)
    dlen, dtype, dcode, dtxid = parse_head(data_blob)
    resp_blob = read_container(dev, ep_in)
    rlen, rtype, rcode, _rtxid = parse_head(resp_blob)
    print(f"[3] GetDeviceInfo <- 数据容器 {dlen}B(type={dtype}) 响应 0x{rcode:04X} txid={dtxid}")
    if dtype != DATA or rcode != OK:
        print("    意外:数据/响应不符 —— 原始字节发回分析")
        print(hexdump(data_blob))
        return 1
    dump_device_info(data_blob[HDR:])
    print("    原始数据容器(备案):")
    print(hexdump(data_blob))

    # 步骤 4:OpenSession(sessionId=1)
    txid += 1
    dev.write(ep_out, cmd_container(OPEN_SESSION, txid, [1]), 5000)
    resp_blob = read_container(dev, ep_in)
    _rlen, rtype, rcode, rtxid = parse_head(resp_blob)
    print(f"[4] OpenSession <- type={rtype} 响应 0x{rcode:04X} txid={rtxid}")
    if rcode != OK:
        print("    OpenSession 失败:检查相机是否弹出连接确认(部分机身需在相机上确认)")
        return 1

    # 步骤 5(可选):GetObjectHandles 计数
    if args.handles:
        txid += 1
        dev.write(ep_out, cmd_container(
            GET_OBJECT_HANDLES, txid, [STORAGE_ALL, FORMAT_ALL, PARENT_ALL]), 5000)
        data_blob = read_container(dev, ep_in)
        resp_blob = read_container(dev, ep_in)
        _rlen, rtype, rcode, _rtxid = parse_head(resp_blob)
        (count,) = struct.unpack_from("<I", data_blob, HDR)
        handles = struct.unpack_from(f"<{min(count, 8)}I", data_blob, HDR + 4) if count else ()
        print(f"[5] GetObjectHandles <- 0x{rcode:04X} 共 {count} 个对象"
              + (f",前 {len(handles)} 个 handle: " + " ".join(f"0x{h:08X}" for h in handles)
                 if handles else ""))

    # 步骤 6:interrupt IN 试读(验证事件容器 u16 长度布局)
    if ep_intr is not None:
        try:
            ev = bytes(dev.read(ep_intr, 64, 200))
            print(f"[6] 事件原始字节({len(ev)}B): {ev.hex(' ')}")
            if len(ev) >= EVENT_HDR:
                elen, etype, ecode, etxid = struct.unpack_from("<HHHI", ev)
                print(f"    按 u16 长度布局解析:len={elen} type={etype} "
                      f"eventCode=0x{ecode:04X} txid={etxid}")
                print("    ↑ 与 containers.dart 的 decodeUsbEvent 对照,不一致则回填修正")
        except usb.core.USBError:
            print("[6] 200ms 内无事件(正常,只读探针不触发事件)")

    # TODO(P0-usb): 相机以 STALL 表达"忙"时的 CLEAR_HALT + 重试(探针暂未实现,
    #   USBError(EPIPE) 时原样上报);大文件 GetObject 的分块读;错误注入对拍。
    usb.util.dispose_resources(dev)
    print("[OK] PTP/USB 握手通过;输出请整段发回,用于回填常量与布局订正")
    return 0


if __name__ == "__main__":
    sys.exit(main())

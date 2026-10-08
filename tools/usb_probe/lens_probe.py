#!/usr/bin/env python3
"""镜头型号数据源定案(2026-10-09 相机页信息卡「镜头型号不显示」)。

app 镜头行唯一数据源 = 枚举完成事件 → 汇总相册(拍摄时间倒序)首个带
JPG 的组 → GetPartialObject(handle, 0, 64KB) → readJpegExif → Exif IFD
0xA434 LensModel。真机(iOS/IC 链)镜头行为空,根因未定;RAW+JPG 已由
用户确认(JPG 源存在)。本脚本在 Mac USB 直连把同一条路原样走一遍:

  [1] 设备/端点  [2] GetDeviceInfo(序列号回归 + 0x101B 在册门禁核对)
  [3] OpenSession  [4] 0x5008/0x5007/0x5001 裸值(焦距标度回归)
  [5] 全量句柄 → 逐个 ObjectInfo → 拍摄时间倒序最新 JPG
  [6] GetPartialObject 0..64KB(失败降级 16KB/2048B,对齐 app 阶梯)
  [7] JPEG 段布局 + EXIF 解码(镜像 watermark.dart readJpegExif 的扫描
      止步规则 —— APP1 被 64KB 截断时 app 侧返回 null,这里要能看出来)

只读;复用 probe.py 底层(xact/ensure_session/parse_*)。运行:
  tools/usb_probe/.venv/bin/python tools/usb_probe/lens_probe.py
"""
from __future__ import annotations

import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import usb.core
import usb.util

from probe import (DATA, GET_DEVICE_INFO,
                   GET_DEVICE_PROP_VALUE, GET_OBJECT_HANDLES, GET_OBJECT_INFO,
                   GET_PARTIAL_OBJECT, HDR, NIKON_VID, OK,
                   ensure_session, find_sti_endpoints, make_backend,
                   parse_device_info, parse_object_info, xact)

STORAGE_ALL = 0xFFFFFFFF
FORMAT_ALL = 0
PARENT_ROOT = 0  # Zf 语义:parent=0 才是全量(0 与 0xFFFFFFFF 做反了)

FMT_JPEG = 0x3801
FMT_UNDEFINED = 0x3000  # NEF 落在这格(按扩展名判)

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 4, 9: 8,
             10: 8, 11: 4, 12: 8}


def scan_segments(jpeg: bytes) -> list:
    """段布局:循环与止步条件逐条镜像 watermark.dart readJpegExif。

    返回 (标记, 位置, 段长|None, 逐字节数据摘要) 列表 —— APP1 是否完整
    落在头读范围内,一眼可判。"""
    segs = []
    pos = 2
    n = len(jpeg)
    while pos + 4 <= n:
        if jpeg[pos] != 0xFF:
            segs.append(("非 FF(熵编码,扫描止步)", pos, None))
            return segs
        marker = jpeg[pos + 1]
        if marker == 0xD8 or 0xD0 <= marker <= 0xD9:
            segs.append((f"marker 0x{marker:02X}(规范止步)", pos, None))
            return segs
        seg_len = jpeg[pos + 2] << 8 | jpeg[pos + 3]
        if seg_len < 2 or pos + 2 + seg_len > n:
            segs.append((f"marker 0x{marker:02X} len={seg_len} "
                         f"越界({pos}+2+{seg_len} > {n} → app 侧 break 返回 null)",
                         pos, seg_len))
            return segs
        note = ""
        if marker == 0xE1 and jpeg[pos + 4:pos + 10] == b"Exif\x00\x00":
            note = " ← Exif APP1"
        segs.append((f"marker 0x{marker:02X} len={seg_len}{note}", pos, seg_len))
        pos += 2 + seg_len
    segs.append(("头读耗尽(pos+4 > len,循环自然结束)", pos, None))
    return segs


def walk_exif(tiff: bytes) -> dict | None:
    """TIFF 头 → IFD0 + Exif 子表(只解 app 用到的域 + MakerNote 布局)。"""
    if len(tiff) < 8 or tiff[:2] not in (b"II", b"MM"):
        return None
    bo = "<" if tiff[:2] == b"II" else ">"
    (magic,) = struct.unpack_from(bo + "H", tiff, 2)
    if magic != 42:
        return None

    def read_ifd(off: int):
        entries = {}
        if off + 2 > len(tiff):
            return entries
        (cnt,) = struct.unpack_from(bo + "H", tiff, off)
        for i in range(cnt):
            e = off + 2 + i * 12
            if e + 12 > len(tiff):
                return entries
            tag, typ, c = struct.unpack_from(bo + "HHI", tiff, e)
            tsize = TYPE_SIZE.get(typ)
            if tsize is None:
                continue
            total = tsize * c
            if total <= 4:
                raw = tiff[e + 8:e + 8 + total]
                off_out = None
            else:
                (vo,) = struct.unpack_from(bo + "I", tiff, e + 8)
                if vo + total > len(tiff):
                    continue  # 越界:按缺项处理(镜像 app 不抛)
                raw = tiff[vo:vo + total]
                off_out = vo
            entries[tag] = (typ, c, raw, off_out)
        return entries

    (ifd0_off,) = struct.unpack_from(bo + "I", tiff, 4)
    ifd0 = read_ifd(ifd0_off)

    def ascii_of(tag):
        v = ifd0.get(tag)
        if not v:
            return None
        _t, _c, raw, _o = v
        return raw.split(b"\x00")[0].decode("latin-1", "replace")

    result = {
        "byteOrder": tiff[:2].decode(),
        "make": ascii_of(0x010F),
        "model": ascii_of(0x0110),
        "dateTime": ascii_of(0x0132),
    }
    ptr = ifd0.get(0x8769)
    if ptr is None:
        result["exifIfd"] = None
        return result
    _t, _c, raw, _o = ptr
    (exif_off,) = struct.unpack_from(bo + "I", raw, 0)
    exif = read_ifd(exif_off)
    result["exifIfdOffset"] = exif_off

    def ascii_exif(tag):
        v = exif.get(tag)
        if not v:
            return None
        _t, _c, raw, _o = v
        return raw.split(b"\x00")[0].decode("latin-1", "replace")

    def rational(tag):
        v = exif.get(tag)
        if not v or v[0] != 5:
            return None
        num, den = struct.unpack_from(bo + "II", v[2], 0)
        return None if den == 0 else num / den

    v = exif.get(0x8827)
    if v and v[0] == 3:
        (result["iso"],) = struct.unpack_from(bo + "H", v[2], 0)
    mn = exif.get(0x927C)
    if mn:
        result["makerNote"] = f"{mn[1]}B @偏移 {mn[3]}"
    result["lensMake"] = ascii_exif(0xA433)
    result["lensModel"] = ascii_exif(0xA434)
    result["fNumber"] = rational(0x829D)
    result["exposureSec"] = rational(0x829A)
    result["focalLengthMm"] = rational(0x920A)
    return result


def main() -> int:
    backend = make_backend()
    kwargs = {"idVendor": NIKON_VID}
    if backend is not None:
        kwargs["backend"] = backend
    try:
        devices = list(usb.core.find(find_all=True, **kwargs))
    except usb.core.NoBackendError:
        print("找不到 libusb 后端")
        return 2
    if not devices:
        print("未发现尼康 USB 设备(VID 0x04B0):检查线缆,相机开机并解锁")
        return 1
    dev = devices[0]

    itf_no, ep_out, ep_in, ep_intr = find_sti_endpoints(dev)
    print(f"[1] 端点:bulkOUT=0x{ep_out:02X} bulkIN=0x{ep_in:02X}(接口 {itf_no})")
    usb.util.claim_interface(dev, itf_no)
    txid = 0

    # [2] GetDeviceInfo:序列号回归 + 0x101B 门禁核对
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
    if rc != OK or blob is None:
        print(f"[2] GetDeviceInfo <- 0x{rc:04X}(数据 {'有' if blob else '无'})")
        return 1
    info = parse_device_info(blob[HDR:])
    serial = info["serialNumber"]
    print(f"[2] GetDeviceInfo:型号 {info['model']} 固件 {info['deviceVersion']}")
    print(f"    序列号(原始 32 字):{serial!r} 长度 {len(serial)}")
    stripped = serial.lstrip("0")
    print(f"    剥前导零后:{stripped!r}"
          + ("(全零占位 → app 侧 null)" if not stripped else ""))
    ops = set(info["operationsSupported"])
    for op, name in [(0x101B, "GetPartialObject(镜头头读)"),
                     (0x1007, "GetObjectHandles"), (0x1008, "GetObjectInfo")]:
        print(f"    0x{op:04X} {name} 在册:{'✓' if op in ops else '✗ ✗ ✗(app 门禁会静默放弃)'}")
    props = set(info["devicePropsSupported"])
    for p, name in [(0x5008, "FocalLength"), (0x5007, "FNumber"),
                    (0x5001, "BatteryLevel")]:
        print(f"    属性 0x{p:04X} {name} 在册:{'✓' if p in props else '✗'}")

    # [3] OpenSession
    txid += 1
    txid, rc = ensure_session(dev, ep_out, ep_in, txid)
    print(f"[3] OpenSession <- 0x{rc:04X}")
    if rc != OK:
        return 1

    # [4] 属性裸值(焦距标度回归:期望 u32=4000 → 40mm)
    print("[4] GetDevicePropValue 裸值:")
    for prop, note in [(0x5008, "焦距,期望 u32 4000=40.00mm"),
                       (0x5007, "光圈 ×100"), (0x5001, "电池 u8")]:
        txid += 1
        txid, blob, rc = xact(dev, ep_out, ep_in, txid,
                              GET_DEVICE_PROP_VALUE, [prop])
        data = blob[HDR:] if blob is not None else b""
        line = f"    0x{prop:04X} <- 0x{rc:04X}  {len(data)}B  raw={data.hex(' ')}"
        if rc == OK and len(data) == 4:
            (v,) = struct.unpack_from("<I", data, 0)
            line += f"  u32 LE={v}"
        elif rc == OK and len(data) == 2:
            (v,) = struct.unpack_from("<H", data, 0)
            line += f"  u16 LE={v}"
        elif rc == OK and len(data) == 1:
            line += f"  u8={data[0]}"
        print(line + f"   ({note})")

    # [5] 全量句柄 → ObjectInfo → 拍摄时间倒序
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_HANDLES,
                          [STORAGE_ALL, FORMAT_ALL, PARENT_ROOT])
    if rc != OK or blob is None:
        print(f"[5] GetObjectHandles <- 0x{rc:04X}")
        return 1
    (cnt,) = struct.unpack_from("<I", blob, HDR)
    hs = struct.unpack_from(f"<{cnt}I", blob, HDR + 4) if cnt else ()
    print(f"[5] GetObjectHandles <- {cnt} 个(倒序枚举 = 最新优先)")

    photos = []
    others = {}  # (fmt, 扩展名) → 计数:NEF 疑云(用户 RAW+JPG 但 0 NEF)直方图
    scanned = 0
    t0 = time.monotonic()
    for h in reversed(hs):
        txid += 1
        txid, ob, orc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
        if orc != OK or ob is None:
            continue
        scanned += 1
        o = parse_object_info(ob[HDR:])
        name = o["name"]
        lower = name.lower()
        if o["fmt"] == FMT_JPEG or lower.endswith((".jpg", ".jpeg", ".jpe")):
            kind = "JPG"
        elif o["fmt"] == FMT_UNDEFINED and lower.endswith(".nef"):
            kind = "NEF"
        elif lower.endswith((".mov", ".mp4")):
            kind = "video"
        else:
            kind = "other"
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else "(无)"
            key = (f"0x{o['fmt']:04X}", ext)
            others[key] = others.get(key, 0) + 1
        if kind in ("JPG", "NEF"):
            # 注意:parse_object_info 自带 h=高度字段,handle 必须独立键名
            photos.append({"handle": h, "kind": kind, **o})
    dt = time.monotonic() - t0
    print(f"    ObjectInfo 扫描 {scanned} 个({dt:.1f}s):"
          f"JPG {sum(1 for p in photos if p['kind'] == 'JPG')}"
          f" / NEF {sum(1 for p in photos if p['kind'] == 'NEF')}")
    if others:
        print("    「其他」对象 fmt/扩展名分布:")
        for (fmt, ext), c in sorted(others.items(), key=lambda kv: -kv[1]):
            print(f"      fmt={fmt} .{ext} ×{c}")
    if scanned < len(hs):
        print(f"    ⚠ 仅扫到 {scanned}/{len(hs)}(部分 ObjectInfo 失败)")

    photos.sort(key=lambda p: (p["captured"], p["handle"]), reverse=True)
    print("    拍摄时间倒序前 5:")
    for p in photos[:5]:
        print(f"      0x{p['handle']:08X} {p['name']}  {p['kind']}"
              f"  {p['size'] / 1_048_576:.1f}MB  {p['captured']}")
    newest_jpg = next((p for p in photos if p["kind"] == "JPG"), None)
    if newest_jpg is None:
        print("    ✗ 一张 JPG 都没有 —— 镜头行注定为空(拍摄设置?)")
        return 0
    print(f"    → 最新 JPG:0x{newest_jpg['handle']:08X} {newest_jpg['name']}"
          f"({newest_jpg['captured']})")

    # [6] GetPartialObject 阶梯(64KB → 16KB → 2048B,对齐 app)
    print("[6] GetPartialObject 头读阶梯:")
    head = None
    used = None
    for size in (64 * 1024, 16 * 1024, 2048):
        txid += 1
        try:
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                                  [newest_jpg["handle"], 0, size])
        except usb.core.USBError as e:
            print(f"    0..{size - 1} <- USB 错误:{e}")
            continue
        data = blob[HDR:] if blob is not None else b""
        n = len(data)
        print(f"    0..{size - 1} <- 0x{rc:04X}  {n}B"
              + (f"(要 {size} 回 {n},相机侧截短)" if rc == OK and 0 < n < size else ""))
        if rc == OK and n > 0:
            head = data
            used = size
            break
    if head is None:
        print("    ✗ 全档被拒 —— 相机侧(USB 直连)就不给 0x101B 数据")
        return 0

    out = f"/tmp/nikonpill_lens_head_{newest_jpg['handle']:08X}.bin"
    Path(out).write_bytes(head)
    print(f"    首档成功:{used}B 已存 {out}")

    # [7] 段布局 + EXIF(镜像 app 解码路径)
    print(f"[7] JPEG 段布局(头读 {len(head)}B):")
    for desc, pos, seg_len in scan_segments(head):
        print(f"    @{pos:<6} {desc}")
    soi_ok = head[0:2] == b"\xff\xd8"
    exif_payload = None
    pos = 2
    while pos + 4 <= len(head):
        if head[pos] != 0xFF:
            break
        marker = head[pos + 1]
        if marker == 0xD8 or 0xD0 <= marker <= 0xD9:
            break
        seg_len = head[pos + 2] << 8 | head[pos + 3]
        if seg_len < 2 or pos + 2 + seg_len > len(head):
            break
        if marker == 0xE1 and head[pos + 4:pos + 10] == b"Exif\x00\x00":
            exif_payload = head[pos + 10:pos + 2 + seg_len]
            break
        pos += 2 + seg_len
    if not soi_ok:
        print("    ✗ 非 SOI 开头(不是 JPEG?)")
        return 0
    if exif_payload is None:
        print("    ✗ 头读内无完整 Exif APP1 —— app readJpegExif 会返回 null"
              "(这就是镜头行为空的相机侧根因)")
        return 0
    print(f"    Exif APP1 载荷 {len(exif_payload)}B → TIFF 解码:")
    card = walk_exif(exif_payload)
    if card is None:
        print("    ✗ TIFF 头不合(II/MM+42)")
        return 0
    for k in ("byteOrder", "make", "model", "dateTime", "exifIfdOffset",
              "lensMake", "lensModel", "focalLengthMm", "fNumber",
              "exposureSec", "iso", "makerNote"):
        if k in card:
            print(f"      {k}: {card[k]}")
    lens = card.get("lensModel")
    print()
    if lens:
        print(f"✔ 定案:最新 JPG 头部 EXIF 里有 LensModel = {lens!r} ——"
              f"相机侧(USB 直连)这条路全通;app 镜头行为空 → iOS IC 链/"
              f"枚举侧问题,下一步查手机端")
    else:
        print("✗ EXIF 解通但无 0xA434 —— Zf JPG 不写 LensModel?"
              f"(需换 ExifTool 对拍确认)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

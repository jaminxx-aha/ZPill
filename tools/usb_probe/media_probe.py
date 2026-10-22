#!/usr/bin/env python3
"""媒体预览数据源探针(2026-10-09 视频播放 + NEF 查看)。

三件事(只读):
  [T] 最新 NEF / MOV / JPG 各跑 GetThumb(0x100A)+ Nikon GetLargeThumb
      (0x90C4)—— 响应码/字节数/SOI 偏移/尺寸。历史坑:当年 --thumb auto
      因 read_ptp_str 的 NUL 尾没匹配上 .nef,0x90C4 对 NEF/MOV 从未验过。
  [N] 最新 NEF 头 64KB 部分读 → TIFF 结构走查(IFD0 全条目 + 0x014A
      SubIFD + IFD1 链)→ 找内嵌 JPEG 预览的偏移+长度(0x0201/0x0202、
      0x0111/0x0117,Compression 6/7)→ 逐候选部分读验证尺寸。
      「不下载整档只拉预览段」的可行性在此定案。
  [M] 最新 MOV 头 64KB → 原子框走查(ftyp/moov/mdat 偏移)→ moov 在
      mdat 前 = faststart(未来流式播放的依据;下载后播放不依赖此)。
  [S] 最新 NEF 全档拉回(1MB 分块 GetPartialObject)→ SOI/EOI 全档扫描
      + 尺寸解析。2026-10-10 ① 证伪收尾:头 256KB 走查只见 160×120
      缩略 JPEG,1620×1080/320×212 预览是 Compression=34713 NEF 条带
      (非 JPEG)—— RAW 条带(止于 ~24.4MB)之后是否还藏大 JPEG,
      本模式一次定案(nico 头读内嵌 JPEG 预览方案在 Zf 的终裁)。

运行:tools/usb_probe/.venv/bin/python tools/usb_probe/media_probe.py
"""
from __future__ import annotations

import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import usb.core
import usb.util

from probe import (GET_DEVICE_INFO, GET_OBJECT_HANDLES, GET_OBJECT_INFO,
                   GET_PARTIAL_OBJECT, GET_THUMB, HDR, NIKON_VID,
                   NIKON_GET_LARGE_THUMB, OK, ensure_session,
                   find_sti_endpoints, jpeg_dimensions, make_backend,
                   parse_device_info, parse_object_info, xact)

STORAGE_ALL = 0xFFFFFFFF
FORMAT_ALL = 0
PARENT_ROOT = 0

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 4, 9: 8,
             10: 8, 11: 4, 12: 8}
TAG_NAMES = {
    0x00FE: "NewSubfileType", 0x0100: "ImageWidth", 0x0101: "ImageLength",
    0x0103: "Compression", 0x0111: "StripOffsets", 0x0115: "SamplesPerPixel",
    0x0117: "StripByteCounts", 0x014A: "SubIFDs", 0x0201: "JPEGInterchangeFormat",
    0x0202: "JPEGInterchangeFormatLength", 0x8769: "ExifIFD",
}
COMPRESSION_NAMES = {1: "无压缩", 6: "老 JPEG", 7: "JPEG", 34713: "NEF(RAW)",
                     34892: "LossyJPEG", 34925: "H.265(Lossless RAW)"}


def ptp_name(raw: str) -> str:
    """剥 read_ptp_str 的 NUL 尾(名字匹配的前置;probe.py 老坑)。"""
    return raw.split("\x00")[0]


def read_prop_value(txid, dev, ep_out, ep_in, prop):
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, 0x1015, [prop])
    return txid, (blob[HDR:] if blob is not None else b""), rc


def try_thumb_ops(dev, ep_out, ep_in, txid, handle, label) -> int:
    """GetThumb + GetLargeThumb 各一次,报码/字节/SOI/尺寸。"""
    for opcode, name in [(GET_THUMB, "GetThumb 0x100A"),
                         (NIKON_GET_LARGE_THUMB, "GetLargeThumb 0x90C4")]:
        txid += 1
        try:
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, opcode, [handle])
        except usb.core.USBError as e:
            print(f"      {name} <- USB 错误:{e}")
            continue
        data = blob[HDR:] if blob is not None else b""
        if rc != OK or not data:
            print(f"      {name} <- 0x{rc:04X}"
                  + (f"  {len(data)}B" if data else ""))
            continue
        soi = data.find(b"\xff\xd8")
        dims = jpeg_dimensions(data[soi:]) if soi >= 0 else None
        dim_s = f"{dims[0]}x{dims[1]}" if dims else "?"
        print(f"      {name} <- 0x{rc:04X}  {len(data)}B"
              f"  SOI 偏移 {soi if soi >= 0 else '无(非 JPEG?)'}  尺寸 {dim_s}")
        if soi < 0 and data:
            out = f"/tmp/zpill_{name.split()[0]}_nonjpeg_{handle:08X}.bin"
            Path(out).write_bytes(data)
            print(f"        非 JPEG 数据已存:{out} 前 32B:{data[:32].hex(' ')}")
    return txid


def parse_ifd(tiff: bytes, off: int, bo: str, depth: int = 0,
              max_depth: int = 4) -> dict | None:
    """读一个 IFD:条目表 + 下一 IFD 指针;条目含偏移类 tag 全程记录。"""
    if off + 2 > len(tiff) or depth > max_depth:
        return None
    (cnt,) = struct.unpack_from(bo + "H", tiff, off)
    entries = []
    for i in range(cnt):
        e = off + 2 + i * 12
        if e + 12 > len(tiff):
            break
        tag, typ, c = struct.unpack_from(bo + "HHI", tiff, e)
        tsize = TYPE_SIZE.get(typ)
        raw = tiff[e + 8:e + 12]
        entries.append({"tag": tag, "typ": typ, "count": c, "raw": raw,
                        "tsize": tsize or 0})
    nxt = None
    if off + 2 + cnt * 12 + 4 <= len(tiff):
        (nxt,) = struct.unpack_from(bo + "I", tiff, off + 2 + cnt * 12)
        nxt = nxt or None
    return {"off": off, "entries": entries, "next": nxt}


def ifd_value(entry, tiff: bytes, bo: str):
    """解 IFD 条目的数值(数组取列表;偏移类仍返回数值列表)。"""
    total = (entry["tsize"] or 0) * entry["count"]
    if entry["tsize"] == 0:
        return None
    if total <= 4:
        raw = entry["raw"][:total]
    else:
        (vo,) = struct.unpack_from(bo + "I", entry["raw"], 0)
        if vo + total > len(tiff):
            return None
        raw = tiff[vo:vo + total]
    fmt = {1: "B", 3: "H", 4: "I", 6: "b", 8: "i", 9: "q"}[entry["typ"]] \
        if entry["typ"] in (1, 3, 4, 6, 8, 9) else None
    if fmt:
        vals = list(struct.unpack_from(bo + fmt * entry["count"], raw, 0))
        return vals if entry["count"] > 1 else vals[0]
    return raw  # ASCII/UNDEFINED/RATIONAL 原始字节


def walk_nef(dev, ep_out, ep_in, txid, handle, name: str) -> int:
    """NEF 头 256KB → TIFF 走查 → 内嵌 JPEG 预览候选定位与验证。

    (2026-10-09 实测:SubIFD 偏移 111824-113764,64KB 头盖不住,须 256KB。)
    """
    print(f"    [N] {name} 头读 TIFF 走查:")
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                          [handle, 0, 256 * 1024])
    head = blob[HDR:] if blob is not None else b""
    if rc != OK or len(head) < 16:
        print(f"      头读 <- 0x{rc:04X} {len(head)}B(结构走查作罢)")
        return txid
    Path(f"/tmp/zpill_nef_head_{handle:08X}.bin").write_bytes(head)
    print(f"      头读 <- 0x{rc:04X}  {len(head)}B(已存 /tmp)")

    if head[:2] not in (b"II", b"MM"):
        print(f"      非 TIFF 头:{head[:8].hex(' ')}")
        return txid
    bo = "<" if head[:2] == b"II" else ">"
    (magic,) = struct.unpack_from(bo + "H", head, 2)
    if magic != 42:
        print(f"      TIFF magic 异常:{magic}")
        return txid
    (ifd0_off,) = struct.unpack_from(bo + "I", head, 4)

    candidates = []  # (说明, 文件偏移, 长度)

    def visit(off: int, label: str, depth: int) -> None:
        ifd = parse_ifd(head, off, bo, depth)
        if ifd is None:
            print(f"      {label}: 偏移 {off} 越界/过深,止")
            return
        interesting = []
        for entry in ifd["entries"]:
            t = entry["tag"]
            if t in TAG_NAMES:
                v = ifd_value(entry, head, bo)
                interesting.append(f"{TAG_NAMES[t]}(0x{t:04X})={v!r}")
                if t == 0x014A and isinstance(v, list):  # SubIFDs 数组
                    for j, sub in enumerate(v):
                        visit(sub, f"{label}→SubIFD{j}", depth + 1)
                elif t == 0x0111:  # StripOffsets
                    strips = v if isinstance(v, list) else [v]
                    counts_entry = next(
                        (e for e in ifd["entries"] if e["tag"] == 0x0117), None)
                    if counts_entry:
                        counts = ifd_value(counts_entry, head, bo)
                        counts = counts if isinstance(counts, list) else [counts]
                        if len(strips) == len(counts):
                            for s_off, s_len in zip(strips, counts):
                                candidates.append(
                                    (f"{label} strip", s_off, s_len))
                elif t == 0x0201:  # JPEGInterchangeFormat
                    len_entry = next(
                        (e for e in ifd["entries"] if e["tag"] == 0x0202), None)
                    if len_entry:
                        ln = ifd_value(len_entry, head, bo)
                        candidates.append((f"{label} JIF", v, ln))
        comp = next((s for s in interesting if "Compression" in s), "?")
        print(f"      {label} @{off}:{'  '.join(interesting) if interesting else '(无关注条目)'}")
        if ifd["next"]:
            visit(ifd["next"], f"{label}→next", depth + 1)

    visit(ifd0_off, "IFD0", 0)

    if not candidates:
        print("      ✗ 没找到内嵌 JPEG 候选(0x0111/0x0201 路都空)")
        return txid
    print(f"      候选 {len(candidates)} 个,逐个部分读验证(≤12MB):")
    seen = set()
    for label, off, ln in candidates:
        if not isinstance(off, int) or not isinstance(ln, int) or ln <= 0:
            print(f"        {label}: off/len 非法({off!r},{ln!r})")
            continue
        if ln > 12 * 1024 * 1024:
            print(f"        {label}: @{off} {ln / 1e6:.1f}MB 超上限跳过"
                  "(可能就是 RAW 数据条带)")
            continue
        key = (off, ln)
        if key in seen:
            continue
        seen.add(key)
        txid += 1
        try:
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                                  [handle, off, ln])
        except usb.core.USBError as e:
            print(f"        {label}: @{off} {ln}B <- USB 错误:{e}")
            continue
        data = blob[HDR:] if blob is not None else b""
        if rc != OK:
            print(f"        {label}: @{off} {ln}B <- 0x{rc:04X}(偏移部分读被拒!)")
            continue
        soi = data.find(b"\xff\xd8")
        dims = jpeg_dimensions(data[soi:]) if soi >= 0 else None
        dim_s = f"{dims[0]}x{dims[1]}" if dims else "非 JPEG"
        print(f"        {label}: @{off} {ln}B(实回 {len(data)}B)"
              f"  SOI 偏移 {soi if soi >= 0 else '无'}  尺寸 {dim_s}")
        if dims:
            out = f"/tmp/zpill_nef_preview_{handle:08X}_{off}.jpg"
            Path(out).write_bytes(data)
            print(f"          预览 JPEG 已存:{out}")
    return txid


def scan_nef_jpegs(dev, ep_out, ep_in, txid, handle, name: str, size: int) -> int:
    """[S] NEF 全档拉回(1MB 分块)→ SOI/EOI 全档扫描 + 尺寸解析。

    SOI 匹配 b"\\xff\\xd8\\xff"(SOI + 紧随标记字节 —— 真 JPEG 流必有;
    熵编码区 0xFF 全部转义成 0xFF00,扫描数据里不会出现该序列,RAW
    条带内的伪命中靠「找不到 EOI / 解不出 SOF」过滤)。
    """
    print(f"    [S] {name} 全档 SOI 扫描({size / 1e6:.1f}MB,1MB 分块):")
    if size <= 0:
        print("      对象大小异常,跳过")
        return txid
    whole = bytearray()
    t0 = time.monotonic()
    off = 0
    while off < size:
        want = min(1024 * 1024, size - off)
        txid += 1
        try:
            txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                                  [handle, off, want])
        except usb.core.USBError as e:
            print(f"      @{off} 分块读 <- USB 错误:{e}(扫描中止)")
            return txid
        chunk = blob[HDR:] if blob is not None else b""
        if rc != OK or len(chunk) != want:
            print(f"      @{off} 请求 {want}B 实回 {len(chunk)}B(0x{rc:04X})"
                  "—— 分块大小相机不接受,扫描中止")
            return txid
        whole += chunk
        off += want
    dt = time.monotonic() - t0
    print(f"      全档拉回 {len(whole)}B,耗时 {dt:.1f}s"
          f"({len(whole) / dt / 1e6:.1f}MB/s),本地扫描…")

    soi = b"\xff\xd8\xff"
    eoi_m = b"\xff\xd9"
    jpegs = []  # (偏移, 长度, 尺寸|None)
    pos = whole.find(soi)
    while pos >= 0:
        eoi = whole.find(eoi_m, pos + 2)
        if eoi < 0:
            print(f"        SOI @{pos} 无 EOI(截断/伪命中,忽略)")
        else:
            dims = jpeg_dimensions(bytes(whole[pos:pos + 65536]))
            jpegs.append((pos, eoi + 2 - pos, dims))
        pos = whole.find(soi, pos + 1)
    if not jpegs:
        print("      ✗ 全档无 SOI/EOI 完整对(连缩略都没有 = 结构异常)")
        return txid
    for off_j, ln, dims in jpegs:
        dim_s = f"{dims[0]}x{dims[1]}" if dims else "SOF 未见(伪?)"
        out = f"/tmp/zpill_nef_scan_{handle:08X}_{off_j}.jpg"
        Path(out).write_bytes(whole[off_j:off_j + ln])
        print(f"        JPEG @{off_j}  {ln}B  {dim_s}  已存 {out}")
    real = [j for j in jpegs if j[2]]
    if real:
        off_b, len_b, dims_b = max(real, key=lambda j: j[2][0] * j[2][1])
        if dims_b[0] <= 200:
            print(f"      → 定案:最大 JPEG 仅 {dims_b[0]}x{dims_b[1]}"
                  f"(@{off_b})—— Zf NEF 内无高清 JPEG,nico 头读方案对 Zf"
                  "正式证伪,高清预览维持整档两席位管线")
        else:
            print(f"      → 最大 JPEG {dims_b[0]}x{dims_b[1]} @{off_b}"
                  f" {len_b / 1e3:.0f}KB —— RAW 之外藏有预览!头读方案有救,"
                  "回 ZPill 重开 ①")
    else:
        print("      → 无可解析尺寸的 JPEG(伪命中或异常,人工看 /tmp)")
    return txid


def walk_mov_atoms(dev, ep_out, ep_in, txid, handle, name: str) -> int:
    """MOV 头 64KB → 顶层原子框(ftyp/moov/mdat…)偏移图。"""
    print(f"    [M] {name} 头读原子框走查:")
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_PARTIAL_OBJECT,
                          [handle, 0, 64 * 1024])
    head = blob[HDR:] if blob is not None else b""
    if rc != OK or len(head) < 16:
        print(f"      头读 <- 0x{rc:04X} {len(head)}B")
        return txid
    print(f"      头读 <- 0x{rc:04X}  {len(head)}B  前 32B:{head[:32].hex(' ')}")
    pos = 0
    found = []
    while pos + 8 <= len(head):
        (size,) = struct.unpack_from(">I", head, pos)
        typ = head[pos + 4:pos + 8]
        if size == 0:  # 到文件尾的框
            found.append((typ, pos, "到文件尾"))
            break
        if size == 1:  # 64 位大小
            if pos + 16 > len(head):
                found.append((typ, pos, "64 位大小(超头读)"))
                break
            (size64,) = struct.unpack_from(">Q", head, pos + 8)
            found.append((typ, pos, f"{size64 / 1e6:.1f}MB(64 位)"))
            size = size64
        else:
            found.append((typ, pos, f"{size / 1e6:.2f}MB"))
        if len(found) > 12 or size < 8:
            break
        pos += size
    for typ, off, note in found:
        t = typ.decode("latin-1", "replace")
        print(f"      @{off:<8} {t}  {note}")
    moov = next((f for f in found if f[1] == b"moov"), None)
    mdat = next((f for f in found if f[1] == b"mdat"), None)
    if moov and mdat:
        verdict = "faststart(moov 在前,未来可流式)" if moov[0] < mdat[0] \
            else "moov 在 mdat 后(下载完才能播)"
        print(f"      → {verdict}")
    elif moov or mdat:
        print("      → 只见其一,头 64KB 内框不全(大框截断)")
    return txid


def main() -> int:
    backend = make_backend()
    kwargs = {"idVendor": NIKON_VID}
    if backend is not None:
        kwargs["backend"] = backend
    devices = list(usb.core.find(find_all=True, **kwargs))
    if not devices:
        print("未发现尼康 USB 设备:检查线缆,相机开机并解锁(Photos 抢接口先退)")
        return 1
    dev = devices[0]
    itf_no, ep_out, ep_in, ep_intr = find_sti_endpoints(dev)
    usb.util.claim_interface(dev, itf_no)
    txid = 0

    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_DEVICE_INFO)
    if rc != OK or blob is None:
        print(f"GetDeviceInfo <- 0x{rc:04X}")
        return 1
    info = parse_device_info(blob[HDR:])
    ops = set(info["operationsSupported"])
    print(f"[0] {info['model']} 固件 {info['deviceVersion']}"
          f"  0x90C4 在册:{'✓' if NIKON_GET_LARGE_THUMB in ops else '✗'}"
          f"  0x101B 在册:{'✓' if GET_PARTIAL_OBJECT in ops else '✗'}")

    txid += 1
    txid, rc = ensure_session(dev, ep_out, ep_in, txid)
    print(f"[0] OpenSession <- 0x{rc:04X}")
    if rc != OK:
        return 1

    # 全量枚举,后缀分类(NUL 已剥)—— JPG/NEF/MOV 最新各一
    txid += 1
    txid, blob, rc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_HANDLES,
                          [STORAGE_ALL, FORMAT_ALL, PARENT_ROOT])
    (cnt,) = struct.unpack_from("<I", blob, HDR)
    hs = struct.unpack_from(f"<{cnt}I", blob, HDR + 4) if cnt else ()
    kinds = {}
    photos = []
    for h in reversed(hs):
        txid += 1
        txid, ob, orc = xact(dev, ep_out, ep_in, txid, GET_OBJECT_INFO, [h])
        if orc != OK or ob is None:
            continue
        o = parse_object_info(ob[HDR:])
        name = ptp_name(o["name"])
        lower = name.lower()
        if lower.endswith((".jpg", ".jpeg", ".jpe")):
            kind = "JPG"
        elif lower.endswith(".nef"):
            kind = "NEF"
        elif lower.endswith((".mov", ".mp4")):
            kind = "MOV"
        else:
            kind = None
        if kind:
            kinds[kind] = kinds.get(kind, 0) + 1
            photos.append({"handle": h, "kind": kind, "name": name,
                           "size": o["size"], "captured": o["captured"],
                           "fmt": o["fmt"]})
    print(f"[1] 枚举 {cnt} 句柄:JPG {kinds.get('JPG', 0)}"
          f" / NEF {kinds.get('NEF', 0)} / MOV {kinds.get('MOV', 0)}")
    for kind in ("NEF", "MOV", "JPG"):
        pool = [p for p in photos if p["kind"] == kind]
        pool.sort(key=lambda p: (p["captured"], p["handle"]), reverse=True)
        newest = pool[0] if pool else None
        if not newest:
            print(f"[{kind[0]}] 卡上没有{kind}")
            continue
        print(f"[{kind[0]}] 最新 {kind}:0x{newest['handle']:08X} {newest['name']}"
              f"  {newest['size'] / 1e6:.1f}MB  fmt=0x{newest['fmt']:04X}"
              f"  {newest['captured']}")
        txid = try_thumb_ops(dev, ep_out, ep_in, txid, newest["handle"], kind)
        if kind == "NEF":
            txid = walk_nef(dev, ep_out, ep_in, txid, newest["handle"],
                            newest["name"])
            txid = scan_nef_jpegs(dev, ep_out, ep_in, txid, newest["handle"],
                                  newest["name"], newest["size"])
        elif kind == "MOV":
            txid = walk_mov_atoms(dev, ep_out, ep_in, txid, newest["handle"],
                                  newest["name"])
    return 0


if __name__ == "__main__":
    sys.exit(main())

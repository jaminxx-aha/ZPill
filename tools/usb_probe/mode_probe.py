"""照片/视频拨杆位置快照器 —— 模式读侧定案工具(2026-10-11)。

对比机身「照片/视频」切换拨杆两个位置下的属性全集,找随拨杆变的属性
(「界面跟随相机」的信号源候选)。只读(GetDeviceInfo / GetDevicePropValue),
零写操作。

用法(相机 USB 连 Mac;跑前先 pkill ptpcamerad/mscamerad):
  .venv/bin/python mode_probe.py snap a.json    # 拨杆当前位置全量快照
  .venv/bin/python mode_probe.py diff a.json b.json
"""

import json
import sys
import time

import usb

import probe  # 同目录底座:xact/端点发现/会话恢复/GetDeviceInfo 解析

# 范围扫覆盖:ISO 标准属性区 + 尼康厂商区 + MTP 扩展区
# (相机自报清单可能不全,范围扫能抓到未上报的属性;两处取并集)
SWEEP_RANGES = [range(0x5000, 0x5020), range(0xD000, 0xD300), range(0xD400, 0xD420)]


def open_camera():
    backend = probe.make_backend()
    kwargs = {"idVendor": probe.NIKON_VID}
    if backend is not None:
        kwargs["backend"] = backend
    devices = list(usb.core.find(find_all=True, **kwargs))
    if not devices:
        sys.exit("未发现尼康 USB 设备(VID 0x04B0):检查线缆与开机状态")
    dev = devices[0]
    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
    except (NotImplementedError, usb.core.USBError):
        pass
    itf_no, ep_out, ep_in, _ep_intr = probe.find_sti_endpoints(dev)
    usb.util.claim_interface(dev, itf_no)
    return dev, ep_out, ep_in


def sweep(dev, ep_out, ep_in) -> dict:
    """全量属性值快照:{codeHex: {rc, n, v}}。"""
    txid = 0
    txid, blob, rc = probe.xact(dev, ep_out, ep_in, txid, probe.GET_DEVICE_INFO)
    if rc != probe.OK or blob is None:
        sys.exit(f"GetDeviceInfo 失败:0x{rc:04X}")
    info = probe.parse_device_info(blob[probe.HDR:])
    reported = set(info["devicePropsSupported"])
    codes = sorted(reported | {c for r in SWEEP_RANGES for c in r})
    print(f"自报属性 {len(reported)} 个,扫 {len(codes)} 个码"
          f"(自报 ∪ {['%04X-%04X' % (r.start, r[-1]) for r in SWEEP_RANGES]})", flush=True)

    snap: dict = {}
    t0 = time.time()
    for i, code in enumerate(codes):
        txid += 1
        txid, blob, rc = probe.xact(dev, ep_out, ep_in, txid,
                                    probe.GET_DEVICE_PROP_VALUE, [code])
        if rc == probe.OK and blob is not None:
            d = blob[probe.HDR:]
            snap[f"{code:04X}"] = {"rc": "OK", "n": len(d), "v": d.hex()}
        else:
            snap[f"{code:04X}"] = {"rc": f"{rc:04X}", "n": 0, "v": ""}
        if (i + 1) % 200 == 0:
            print(f"  … {i + 1}/{len(codes)}({time.time() - t0:.1f}s)", flush=True)
    ok = sum(1 for e in snap.values() if e["rc"] == "OK")
    print(f"完成:{ok} 个在册应答,{len(snap) - ok} 个拒/缺,{time.time() - t0:.1f}s")
    return snap


def diff(a: dict, b: dict) -> None:
    changed, appeared, vanished = [], [], []
    for k in sorted(a):
        if k not in b:
            vanished.append(k)
        elif a[k] != b[k]:
            (changed if a[k]["rc"] == "OK" and b[k]["rc"] == "OK"
             else appeared).append(k)
    for k in sorted(set(b) - set(a)):
        appeared.append(k)

    def show(k):
        ea, eb = a.get(k), b.get(k)
        va = ea["v"][:96] if ea else "-"
        vb = eb["v"][:96] if eb else "-"
        print(f"  0x{k}: {ea['rc'] if ea else '缺'} → {eb['rc'] if eb else '缺'}")
        if ea and ea["rc"] == "OK":
            print(f"      A: n={ea['n']} {va}")
        if eb and eb["rc"] == "OK":
            print(f"      B: n={eb['n']} {vb}")

    print(f"== 两位置都在册且值不同({len(changed)}个)==")
    for k in changed:
        show(k)
    print(f"== 在册状态翻转 OK↔拒({len(appeared)}个)==")
    for k in appeared:
        show(k)
    print(f"== 仅单侧存在({len(vanished)}个)==")
    for k in vanished:
        show(k)
    if not (changed or appeared or vanished):
        print("  (无差异)")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "snap":
        dev, ep_out, ep_in = open_camera()
        txid = 0
        txid, _rcode = probe.ensure_session(dev, ep_out, ep_in, txid)
        snap = sweep(dev, ep_out, ep_in)
        with open(path, "w") as f:
            json.dump(snap, f, ensure_ascii=False, indent=0)
        print(f"已存 {path}")
    elif cmd == "diff":
        with open(sys.argv[2]) as f:
            a = json.load(f)
        with open(sys.argv[3]) as f:
            b = json.load(f)
        diff(a, b)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

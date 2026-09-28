#!/usr/bin/env python3
"""从仓库根 nikonpill.png 生成 iOS 与 ohos 应用图标。

原图本身已是完整的方形图标设计(黄底上 56° 斜向飞行的药丸,
红头右上、金尾左下),因此按原图方向与构图原样导出:
不旋转、不镜像、不重绘,只做尺寸缩放与平台遮罩。

输出
----
- ios/Runner/Assets.xcassets/AppIcon.appiconset/*(按 Contents.json 全尺寸,RGB 无 alpha)
- ohos/AppScope/resources/base/media/app_icon.png(114px,圆角 23,四角透明)
- ohos/entry/src/main/resources/base/media/icon.png(同上)
- ohos/entry/src/ohosTest/resources/base/media/icon.png(同上)

用法:python3 tools/make_icons.py [源图](默认 <repo>/nikonpill.png)
依赖:Pillow。
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]

IOS_ICONSET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
OHOS_ICONS = [
    ROOT / "ohos/AppScope/resources/base/media/app_icon.png",
    ROOT / "ohos/entry/src/main/resources/base/media/icon.png",
    ROOT / "ohos/entry/src/ohosTest/resources/base/media/icon.png",
]
OHOS_SIZE = 114
OHOS_RADIUS = 23  # 与 flutter-ohos 模板默认图标一致(114 边长圆角 23,四角透明)


# ---------------------------------------------------------------- 导出

def export_ios(master):
    meta = json.loads((IOS_ICONSET / "Contents.json").read_text())
    for img in meta["images"]:
        fn = img.get("filename")
        if not fn:
            continue
        px = int(round(float(img["size"].split("x")[0]) * float(img["scale"].rstrip("x"))))
        out = master.resize((px, px), Image.LANCZOS).convert("RGB")
        out.save(IOS_ICONSET / fn)
        yield fn, px


def ohos_icon(master):
    """114px 圆角图标:4x 超采样圆角蒙板保证边缘平滑,四角透明。"""
    s = OHOS_SIZE
    base = master.resize((s, s), Image.LANCZOS).convert("RGBA")
    ss = 4
    m = Image.new("L", (s * ss, s * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, s * ss - 1, s * ss - 1], radius=OHOS_RADIUS * ss, fill=255)
    alpha = m.resize((s, s), Image.LANCZOS)
    base.putalpha(alpha)
    return base


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "nikonpill.png"
    # 原图直出:保持源图方向与构图,仅做平台所需的尺寸与遮罩处理
    master = Image.open(src).convert("RGB")
    print(f"master: {master.size[0]}x{master.size[1]}")

    for fn, px in export_ios(master):
        print(f"ios  {fn}  {px}px")
    icon = ohos_icon(master)
    for target in OHOS_ICONS:
        target.parent.mkdir(parents=True, exist_ok=True)
        icon.save(target)
        print(f"ohos {target.relative_to(ROOT)}  {icon.size[0]}px rgba")


if __name__ == "__main__":
    main()

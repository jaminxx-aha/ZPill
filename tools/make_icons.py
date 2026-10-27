#!/usr/bin/env python3
"""从品牌图标生成 iOS、Android 与 OHOS 应用图标及启动占位图。

原图本身已是完整的方形图标设计(黄底上 56° 斜向飞行的药丸,
红头右上、金尾左下),因此按原图方向与构图原样导出:
不旋转、不镜像、不重绘,只做尺寸缩放与平台遮罩。

输出
----
- ios/Runner/Assets.xcassets/AppIcon.appiconset/*(按 Contents.json 全尺寸,RGB 无 alpha)
- ohos/AppScope/resources/base/media/app_icon.png(114px,圆角 23,四角透明)
- ohos/entry/src/main/resources/base/media/icon.png(同上)
- ohos/entry/src/ohosTest/resources/base/media/icon.png(同上)
- ios/Runner/Assets.xcassets/LaunchImage.imageset/*(120pt 三档,圆角,启动屏居中占位)
- android/.../mipmap-{m,h,x,xh,xxh,xxxh}dpi/launch_image.png(96dp 网格,圆角)
- android/.../mipmap-{m,h,x,xh,xxh,xxxh}dpi/ic_launcher.png(48dp 网格,圆角,替换默认 Flutter 图)

用法:python3 tools/make_icons.py [源图](默认 <repo>/branding/zpill/icon.png)
依赖:Pillow。
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]

IOS_ICONSET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
IOS_LAUNCH_IMAGESET = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
ANDROID_RES = ROOT / "android/app/src/main/res"
OHOS_ICONS = [
    ROOT / "ohos/AppScope/resources/base/media/app_icon.png",
    ROOT / "ohos/entry/src/main/resources/base/media/icon.png",
    ROOT / "ohos/entry/src/ohosTest/resources/base/media/icon.png",
]
OHOS_SIZE = 114
OHOS_RADIUS = 23  # 与 flutter-ohos 模板默认图标一致(114 边长圆角 23,四角透明)
ROUND_RATIO = OHOS_RADIUS / OHOS_SIZE
LAUNCH_IOS_PT = 120  # iOS 启动屏 @1x 点尺寸,约屏宽 1/3
LAUNCH_ANDROID_DP = 96
LAUNCHER_ANDROID_DP = 48
ANDROID_LAUNCH_DPI = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


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


def rounded(master, size):
    """size px 圆角方形:4x 超采样蒙板保证边缘平滑,四角透明。

    圆角比例与 ohos 应用图标一致(23/114),启动占位图沿用同一观感。
    """
    ss = 4
    base = master.resize((size, size), Image.LANCZOS).convert("RGBA")
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1],
        radius=round(size * ROUND_RATIO) * ss,
        fill=255,
    )
    base.putalpha(m.resize((size, size), Image.LANCZOS))
    return base


def ohos_icon(master):
    return rounded(master, OHOS_SIZE)


def export_launch(master):
    for suffix, px in (("", LAUNCH_IOS_PT), ("@2x", LAUNCH_IOS_PT * 2), ("@3x", LAUNCH_IOS_PT * 3)):
        out = rounded(master, px)
        out.save(IOS_LAUNCH_IMAGESET / f"LaunchImage{suffix}.png")
        print(f"ios   LaunchImage{suffix}.png  {px}px rgba")
    for dpi, mult in ANDROID_LAUNCH_DPI.items():
        px = round(LAUNCH_ANDROID_DP * mult)
        out = rounded(master, px)
        target = ANDROID_RES / f"mipmap-{dpi}" / "launch_image.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        out.save(target)
        print(f"android mipmap-{dpi}/launch_image.png  {px}px rgba")


def export_launcher(master):
    for dpi, mult in ANDROID_LAUNCH_DPI.items():
        px = round(LAUNCHER_ANDROID_DP * mult)
        out = rounded(master, px)
        target = ANDROID_RES / f"mipmap-{dpi}" / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        out.save(target)
        print(f"android mipmap-{dpi}/ic_launcher.png  {px}px rgba")


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "branding/zpill/icon.png"
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
    export_launch(master)
    export_launcher(master)


if __name__ == "__main__":
    main()

/// 图库内编辑(TODO §五 T4):非破坏性参数 + 两档执行。
///
/// 参数全部分辨率无关 —— 旋转按 90° 档、裁剪用归一化矩形(旋转后
/// 坐标系)、调节是标量、LUT 与像素数无关 —— 交互期在预览小图
///(长边 ≤ [EditController.maxPreviewEdge])上跑,保存时同一组参数
/// 应用到原分辨率图([applyEdit])。
///
/// 管线顺序:方向烘焙(bakeOrientation,EXIF Orientation 清零、像素
/// 转正)→ 顺时针旋转 90°×n → 裁剪 → 亮度/对比度/饱和度/暖调 →
/// LUT → JPEG 重编码(quality 92)。变换产新画布,image 包经
/// Image.fromResized 会克隆 EXIF,机型/日期等卡片字段随行。
///
/// 失败语义同水印:非 JPEG / 解码失败 → 原样返回(同一实例)。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

import 'cube_lut.dart';

/// 标量调节(全部 1/0 = 不动):亮度/对比度/饱和度 0..2(1 = 原样),
/// 暖调 -1..1(正 = 阴影压蓝、高光限蓝;负 = 反向偏冷)。
final class EditAdjustments {
  const EditAdjustments({
    this.brightness = 1,
    this.contrast = 1,
    this.saturation = 1,
    this.warmth = 0,
  });

  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;

  bool get isNeutral =>
      brightness == 1 && contrast == 1 && saturation == 1 && warmth == 0;

  EditAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
  }) =>
      EditAdjustments(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
      );
}

/// 一次编辑的完整参数(可序列化快照:撤销/重做/复现的基础)。
final class PhotoEdit {
  const PhotoEdit({
    this.rotationQuarter = 0,
    this.cropRect,
    this.adjustments = const EditAdjustments(),
    this.lut,
  });

  /// 顺时针 90° 的整倍数(0..3)。
  final int rotationQuarter;

  /// 归一化裁剪矩形(0..1,旋转后坐标系);null = 不裁。
  final Rect? cropRect;

  final EditAdjustments adjustments;

  /// 应用中的 3D LUT;null = 无。
  final CubeLut? lut;

  bool get isNeutral =>
      rotationQuarter % 4 == 0 &&
      cropRect == null &&
      adjustments.isNeutral &&
      lut == null;

  PhotoEdit copyWith({
    int? rotationQuarter,
    Rect? cropRect,
    bool clearCrop = false,
    EditAdjustments? adjustments,
    CubeLut? lut,
    bool clearLut = false,
  }) =>
      PhotoEdit(
        rotationQuarter: rotationQuarter ?? this.rotationQuarter,
        cropRect:
            clearCrop ? null : (cropRect ?? this.cropRect),
        adjustments: adjustments ?? this.adjustments,
        lut: clearLut ? null : (lut ?? this.lut),
      );
}

/// 裁剪矩形随画面顺时针转 90°(旋转后坐标系换轴:x' = 1-y、y' = x)。
Rect rotateRectClockwise(Rect r) => Rect.fromLTRB(
      1 - r.bottom,
      r.left,
      1 - r.top,
      r.right,
    );

/// 裁剪矩形随画面逆时针转 90°(x' = y、y' = 1-x)。
Rect rotateRectCounterClockwise(Rect r) => Rect.fromLTRB(
      r.top,
      1 - r.right,
      r.bottom,
      1 - r.left,
    );

/// 编辑管线核心:解码 → 方向烘焙 → 旋转 → 裁剪 → 调节 → LUT → 重编码。
/// 非 JPEG / 解码失败 → 原样返回(同一实例)。
Uint8List applyEdit(Uint8List jpeg, PhotoEdit edit) {
  if (edit.isNeutral) return jpeg;
  img.Image? image;
  try {
    image = img.decodeJpg(jpeg);
  } on Exception {
    return jpeg;
  }
  if (image == null) return jpeg;
  try {
    var out = img.bakeOrientation(image);
    out = applyEditToImage(out, edit);
    return img.encodeJpg(out, quality: 92);
  } on Exception {
    return jpeg;
  }
}

/// 在已烘焙方向的位图上执行参数([decodeForEdit] 预览与 [applyEdit]
/// 全分辨率共用,保证两档行为一致)。
img.Image applyEditToImage(img.Image baked, PhotoEdit edit) {
  var out = baked;
  final quarter = edit.rotationQuarter % 4;
  if (quarter != 0) {
    out = img.copyRotate(out, angle: 90 * quarter);
  }
  final crop = edit.cropRect;
  if (crop != null && out.width > 0 && out.height > 0) {
    final x = (crop.left * out.width).round().clamp(0, out.width - 1);
    final y = (crop.top * out.height).round().clamp(0, out.height - 1);
    final w =
        (crop.width * out.width).round().clamp(1, out.width - x);
    final h =
        (crop.height * out.height).round().clamp(1, out.height - y);
    out = img.copyCrop(out, x: x, y: y, width: w, height: h);
  }
  final a = edit.adjustments;
  if (!a.isNeutral || edit.lut != null) {
    out = img.Image.from(out); // adjustColor 就地改写,别动预览底图
    final w = a.warmth.clamp(-1.0, 1.0);
    if (w != 0) {
      img.Color blacks, whites;
      if (w > 0) {
        blacks = img.ColorRgb8((24 * w).round(), (10 * w).round(), 0);
        whites =
            img.ColorRgb8(255, (255 - 8 * w).round(), (255 - 20 * w).round());
      } else {
        final c = -w;
        blacks = img.ColorRgb8(0, (10 * c).round(), (24 * c).round());
        whites = img.ColorRgb8(
            (255 - 20 * c).round(), (255 - 8 * c).round(), 255);
      }
      // image 包陷阱:blacks/whites 缺省值是 0(黑),不是 1;mids 缺省
      // 时指数 = 1/0 = ∞ 会把图二值化。两者必须成套给,缺一全黑。
      img.adjustColor(
        out,
        blacks: blacks,
        whites: whites,
        mids: img.ColorRgb8(128, 128, 128),
      );
    }
    if (a.brightness != 1 || a.contrast != 1 || a.saturation != 1) {
      img.adjustColor(
        out,
        brightness: a.brightness == 1 ? null : a.brightness,
        contrast: a.contrast == 1 ? null : a.contrast,
        saturation: a.saturation == 1 ? null : a.saturation,
      );
    }
    final lut = edit.lut;
    if (lut != null) {
      for (final p in out) {
        final rgb = lut.apply(p.r / 255, p.g / 255, p.b / 255);
        p
          ..r = (rgb[0] * 255).round().clamp(0, 255)
          ..g = (rgb[1] * 255).round().clamp(0, 255)
          ..b = (rgb[2] * 255).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// 预览解码:方向烘焙 + 长边缩到 [maxEdge](交互期处理小图,保存时
/// [applyEdit] 用原字节)。缩放不裁剪,归一化裁剪矩形两档通用。
img.Image? decodeForEdit(Uint8List jpeg, {int maxEdge = 1600}) {
  img.Image? image;
  try {
    image = img.decodeJpg(jpeg);
  } on Exception {
    return null;
  }
  if (image == null) return null;
  final baked = img.bakeOrientation(image);
  final long = math.max(baked.width, baked.height);
  if (long <= maxEdge) return baked;
  return img.copyResize(
    baked,
    width: baked.width >= baked.height ? maxEdge : null,
    height: baked.width >= baked.height ? null : maxEdge,
  );
}

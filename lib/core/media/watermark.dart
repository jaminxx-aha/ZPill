/// 水印合成(角落水印 / 摄影卡片模板)。
///
/// 两种模板:
/// - **角标**(corner):文本绘制在照片右下角,白字 + 投影,画幅不变;
///   文本空时回落相机型号(EXIF)。
/// - **摄影卡片**(card):照片裱在白色衬纸上,下方三行 —— 相机型号 /
///   参数(焦段 光圈 快门 ISO)/ 拍摄日期(可拼自定义落款)。
///   参数从 JPEG APP1 EXIF 解析(image 包;尼康 JPG 的 EXIF 齐全)。
///
/// 管线:decodeJpg(纯 Dart)→ EXIF 方向烘焙 → 文本位图叠加 →
/// encodeJpg(quality 92,EXIF 一并写回)。文本渲染走 dart:ui
/// TextPainter(系统字体、抗锯齿、CJK 免内嵌字体),光栅成 RGBA 位图
/// 后叠回 image 画布;[TextRaster] 可注入,测试用色块假实现。
///
/// 失败语义同 XMP 注入:非 JPEG / 解码失败 / 渲染异常 → 原样返回
///(同一实例),水印是锦上添花,不拖垮传输。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../../data/settings_store.dart' show WatermarkStyle;

final class WatermarkOptions {
  const WatermarkOptions({required this.style, this.text});

  final WatermarkStyle style;

  /// 角标 = 水印字样;卡片 = 日期行追加落款;空 = 用相机型号。
  final String? text;
}

/// 文本位图渲染器:返回带 alpha 的 RGBA 位图([img.Image],4 通道)。
typedef TextRaster = Future<img.Image> Function(
    String text, double fontSizePx, int color);

/// 卡片/角标用的 EXIF 摘要(JPEG APP1 解析结果)。
final class ExifCardData {
  const ExifCardData({
    this.make,
    this.model,
    this.lens,
    this.focalLengthMm,
    this.fNumber,
    this.exposureSec,
    this.iso,
    this.takenAt,
  });

  final String? make;
  final String? model;
  final String? lens;
  final double? focalLengthMm;
  final double? fNumber;
  final double? exposureSec;
  final int? iso;
  final DateTime? takenAt;

  /// 标题行:`NIKON Z f`(型号已含厂牌时不重复)。尼康 Make 是
  /// `NIKON CORPORATION`,整串永远匹配不上型号,故取厂牌首词作前缀。
  String get titleLine {
    final make = this.make?.trim();
    final model = this.model?.trim();
    if (make == null || make.isEmpty) return model ?? '';
    if (model == null || model.isEmpty) return make;
    final makePrefix =
        make.split(RegExp(r'\s+')).first.toUpperCase();
    if (model.toUpperCase().startsWith(makePrefix)) return model;
    return '$make $model';
  }

  /// 参数行:`85mm ƒ/1.8 · 1/250s · ISO 100`(缺哪项跳哪项;
  /// 焦段与光圈是同一组,空格相连;组间以 · 分隔)。
  String get paramLine {
    final lensPart = <String>[
      if (focalLengthMm != null && focalLengthMm! > 0)
        '${focalLengthMm!.round()}mm',
      if (fNumber != null && fNumber! > 0) 'ƒ/${_formatNumber(fNumber!)}',
    ].join(' ');
    return [
      if (lensPart.isNotEmpty) lensPart,
      if (exposureSec != null && exposureSec! > 0) _formatExposure(exposureSec!),
      if (iso != null && iso! > 0) 'ISO $iso',
    ].join(' · ');
  }
}

/// 主入口:对 JPEG 合成水印;不合成 / 失败 → 返回原实例(免拷贝)。
Future<Uint8List> applyWatermark(Uint8List jpeg, WatermarkOptions options,
    {TextRaster raster = defaultTextRaster}) async {
  if (options.style == WatermarkStyle.off) return jpeg;
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
  img.Image? photo;
  try {
    photo = img.decodeJpg(jpeg);
  } on Exception {
    return jpeg;
  }
  if (photo == null) return jpeg;
  img.ExifData? exif;
  try {
    exif = readJpegExif(jpeg);
  } on Exception {
    exif = null;
  }
  try {
    if (exif != null) photo.exif = exif;
    // 方向烘焙进像素(竖幅照片的画布方向由 Orientation 决定)。
    photo = img.bakeOrientation(photo);
    final card = exif == null ? null : exifCardDataOf(exif);
    // null = 无从落笔(图太小/无内容):原样返回,免一次无谓重编码。
    final drawn = switch (options.style) {
      WatermarkStyle.corner =>
        await _drawCornerBadge(photo, card, options, raster),
      WatermarkStyle.card => await _composeCard(photo, card, options, raster),
      WatermarkStyle.off => null,
    };
    if (drawn == null) return jpeg;
    return img.encodeJpg(drawn, quality: 92);
  } on Exception {
    return jpeg; // 渲染失败保原图(水印不应把传输拖成失败)
  }
}

// ---- EXIF 解析 ----------------------------------------------------------

/// 从 JPEG 的 APP1(`Exif\0\0`)段解析 EXIF;无段/损坏 → null。
///
/// 头读截断容忍(2026-10-09 Zf 实测定案):最新 JPG 的 EXIF APP1 段
/// 声明 65534B(MakerNote 40KB+ 撑大),64KB 头读盖不住整段(差 2B),
/// 但 IFD0/ExifIFD/LensModel 数据全在前段 —— 段尾夹到可用字节照解,
/// image 包对越界条目按缺项处理不抛。非 Exif 的截断段无法跨过,止步。
img.ExifData? readJpegExif(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  const header = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // 'Exif\0\0'
  var pos = 2;
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) break; // 熵编码数据:扫描止步
    final marker = jpeg[pos + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) break;
    final segLen = jpeg[pos + 2] << 8 | jpeg[pos + 3];
    if (segLen < 2) break;
    final segEnd = pos + 2 + segLen;
    final end = segEnd > jpeg.length ? jpeg.length : segEnd;
    final payloadStart = pos + 4;
    if (marker == 0xE1 && end - payloadStart >= header.length) {
      var matches = true;
      for (var i = 0; i < header.length; i++) {
        if (jpeg[payloadStart + i] != header[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        try {
          return img.ExifData.fromInputBuffer(img.InputBuffer(
              Uint8List.sublistView(
                  jpeg, payloadStart + header.length, end)));
        } on Exception {
          return null;
        }
      }
    }
    if (end < segEnd) break; // 本段被截断:后续段全在头读之外
    pos = segEnd;
  }
  return null;
}

/// 文件头统一解析 EXIF 摘要:JPG(FFD8 → APP1)与 NEF/TIFF(II/MM
/// 开头,文件头即 IFD0)同路;非两者 / 无 EXIF / 解析失败回 null。
/// 查看器信息栏用(头读 ≤64KB,不整档下载;NEF 与 JPG 头部结构
/// 同源,APP1 段本就是一段裸 TIFF)。
ExifCardData? exifCardFromHead(Uint8List head) {
  if (head.length < 8) return null;
  img.ExifData? exif;
  if (head[0] == 0xFF && head[1] == 0xD8) {
    exif = readJpegExif(head);
  } else if ((head[0] == 0x49 && head[1] == 0x49) ||
      (head[0] == 0x4D && head[1] == 0x4D)) {
    try {
      exif = img.ExifData.fromInputBuffer(img.InputBuffer(head));
    } on Exception {
      return null;
    }
  }
  if (exif == null) return null;
  return exifCardDataOf(exif);
}

/// EXIF → 卡片摘要;畸形数据(缺 IFD 等)按缺项处理,不抛。
/// 无 Exif 子表的头(如只有 Make/Model 的裁剪档)也保留 IFD0 字段。
ExifCardData exifCardDataOf(img.ExifData exif) {
  try {
    final ifd0 = exif.imageIfd;
    final exifIfd = ifd0.sub['exif'];
    return ExifCardData(
      make: _ascii(ifd0[0x010F]),
      model: _ascii(ifd0[0x0110]),
      lens: _ascii(exifIfd[0xA434]),
      focalLengthMm: _rational(exifIfd[0x920A]),
      fNumber: _rational(exifIfd[0x829D]),
      exposureSec: _rational(exifIfd[0x829A]),
      iso: exifIfd[0x8827]?.toInt(),
      takenAt: _parseExifDate(_ascii(ifd0[0x0132])),
    );
  } on Exception {
    return const ExifCardData();
  }
}

String? _ascii(img.IfdValue? value) {
  if (value == null) return null;
  final raw = value.toString();
  // image 包的 ASCII 值带结尾 NUL(规范如此):截到首个 NUL。
  final nul = raw.indexOf('\x00');
  final s = (nul >= 0 ? raw.substring(0, nul) : raw).trim();
  return s.isEmpty ? null : s;
}

double? _rational(img.IfdValue? value) {
  final d = value?.toDouble();
  return d == null || d.isNaN || d <= 0 ? null : d;
}

/// EXIF 日期 `YYYY:MM:DD HH:MM:SS`(本地时间)→ DateTime;失败 null。
DateTime? _parseExifDate(String? raw) {
  if (raw == null || raw.length < 19) return null;
  final normalized =
      '${raw.substring(0, 10).replaceAll(':', '-')}T${raw.substring(11, 19)}';
  return DateTime.tryParse(normalized);
}

// ---- 合成 ---------------------------------------------------------------

/// 角标:右下角白字 + 投影;文本空时回落型号,再空回落 'ZPill'。
/// 图太小放不下 → null(调用方跳过重编码)。
Future<img.Image?> _drawCornerBadge(img.Image photo, ExifCardData? card,
    WatermarkOptions options, TextRaster raster) async {
  final custom = options.text?.trim() ?? '';
  final text = custom.isNotEmpty
      ? custom
      : card?.titleLine.isNotEmpty == true
          ? card!.titleLine
          : 'ZPill';
  final fontSize = (photo.width * 0.03).clamp(16.0, 96.0);
  var badge = await raster(text, fontSize, 0xFFFFFFFF);
  final margin = (fontSize * 0.7).round();
  final maxW = photo.width - margin * 2;
  if (maxW <= 0) return null; // 图太小放不下
  if (badge.width > maxW) {
    badge = img.copyResize(badge, width: maxW);
  }
  final dstX = photo.width - badge.width - margin;
  final dstY = photo.height - badge.height - margin;
  if (dstX < 0 || dstY < 0) return null;
  img.compositeImage(photo, badge, dstX: dstX, dstY: dstY);
  return photo;
}

/// 摄影卡片:白衬纸 + 照片居中 + 下方三行(型号/参数/日期·落款)。
/// 无 EXIF 也无落款(无行可写)→ null(调用方跳过重编码)。
Future<img.Image?> _composeCard(img.Image photo, ExifCardData? card,
    WatermarkOptions options, TextRaster raster) async {
  final w = photo.width;
  final sidePad = (w * 0.045).round();
  final topPad = sidePad;
  const textColor = 0xFF3C3C43;

  final titleSize = (w * 0.040).clamp(14.0, 120.0);
  final lineSize = (w * 0.024).clamp(10.0, 64.0);

  final footer = _cardFooter(card, options);
  final lines = <img.Image>[
    if (card?.titleLine.isNotEmpty == true)
      await raster(card!.titleLine, titleSize, textColor),
    if (card?.paramLine.isNotEmpty == true)
      await raster(card!.paramLine, lineSize, textColor),
    if (footer.isNotEmpty) await raster(footer, lineSize, textColor),
  ];
  if (lines.isEmpty) return null; // 无 EXIF 也无落款:卡片无从落笔

  final lineGap = (lineSize * 0.8).round();
  final cardPad = (w * 0.028).round();
  final textHeight = lines.fold<int>(0, (h, l) => h + l.height);
  final cardHeight =
      cardPad * 2 + textHeight + lineGap * (lines.length - 1);
  final out = img.Image(
      width: photo.width + sidePad * 2,
      height: topPad + photo.height + cardHeight);
  out.exif = img.ExifData.from(photo.exif); // 衬纸是新建画布,EXIF 手动随行
  img.fill(out, color: img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF));
  img.compositeImage(out, photo, dstX: sidePad, dstY: topPad);
  var y = topPad + photo.height + cardPad;
  for (final line in lines) {
    img.compositeImage(out, line, dstX: (out.width - line.width) ~/ 2, dstY: y);
    y += line.height + lineGap;
  }
  return out;
}

/// 日期行:`2026.10.02 09:05 · 自定义落款`。
String _cardFooter(ExifCardData? card, WatermarkOptions options) {
  final takenAt = card?.takenAt;
  final custom = options.text?.trim() ?? '';
  return [
    if (takenAt != null) _formatDate(takenAt),
    if (custom.isNotEmpty) custom,
  ].join(' · ');
}

// ---- 文本光栅(dart:ui)-------------------------------------------------

/// 生产渲染器:TextPainter → Picture → RGBA 字节 → image 位图。
/// 投影烘进位图(角标白字压在照片上靠它保读性)。
Future<img.Image> defaultTextRaster(
    String text, double fontSizePx, int color) async {
  if (text.isEmpty) return img.Image(width: 1, height: 1);
  final blur = fontSizePx / 5;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: ui.Color(color),
        fontSize: fontSizePx,
        fontWeight: FontWeight.w600,
        shadows: [
          ui.Shadow(color: const ui.Color(0x96000000), blurRadius: blur),
        ],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final pad = (blur * 2).ceil();
  final w = tp.width.ceil() + pad * 2;
  final h = tp.height.ceil() + pad * 2;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  tp.paint(canvas, ui.Offset(pad.toDouble(), pad.toDouble()));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(w, h);
  final data =
      await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (data == null) return img.Image(width: 1, height: 1);
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: data.buffer,
    bytesOffset: data.offsetInBytes,
    numChannels: 4,
  );
}

// ---- 小工具 -------------------------------------------------------------

String _formatNumber(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

String _formatExposure(double sec) {
  if (sec < 1) return '1/${(1 / sec).round()}s';
  return '${_formatNumber(sec)}s';
}

String _formatDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}.${two(t.month)}.${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

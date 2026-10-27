/// 水印合成(角落水印 / 摄影卡片模板)。
///
/// 两种模板:
/// - **角标**(corner):文本绘制在照片右下角,白字 + 投影,画幅不变;
///   文本空时回落相机型号(EXIF)。
/// - **摄影卡片**(card):照片裱在白色衬纸上,下方三行 —— 相机型号 /
///   参数(焦段 光圈 快门 ISO)/ 拍摄日期(可拼自定义落款)。
///   参数从 JPEG APP1 EXIF 解析(image 包;尼康 JPG 的 EXIF 齐全)。
///
/// 管线:主 isolate 预光栅文本(dart:ui TextPainter,系统字体、抗锯齿、
/// CJK 免内嵌字体;画幅从 JPEG 帧头嗅探免解码,字号等比)→ 子 isolate
/// decodeJpg(纯 Dart)→ EXIF 方向烘焙 → 文本位图叠印 → encodeJpg
/// (quality 92,EXIF 一并写回)。文本渲染只能主 isolate(dart:ui 仅根
/// isolate 可用),重活(解码/像素合成/重编码)全在子 isolate;
/// [TextRaster] 可注入,测试用色块假实现。
///
/// 失败语义同 XMP 注入:非 JPEG / 解码失败 / 渲染异常 → 原样返回
///(同一实例),水印是锦上添花,不拖垮传输。
library;

import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import 'jpeg_limits.dart';


final class WatermarkOptions {
  const WatermarkOptions({required this.style, this.text});

  final WatermarkStyle style;

  /// 角标 = 水印字样;卡片 = 日期行追加落款;空 = 用相机型号。
  final String? text;
}

/// 水印模板(设置页「水印」三态;枚举归 watermark 域,data 层设置
/// 店引用 —— core→data 反向边消解,2026-10-22 上提)。
enum WatermarkStyle { off, corner, card }

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
///
/// 耗时大头(整帧解码/像素合成/重编码,高像素相机 JPG 数秒级)走
/// [Isolate.run] 子 isolate(即起即收,spawn 开销 ~ms 级,同帧分析);
/// 文本预光栅留在主 isolate(dart:ui 仅根 isolate 可用),画幅取帧头
/// 嗅探值([jpegEncodedCanvasSize]),免为定字号而解码。
Future<Uint8List> applyWatermark(Uint8List jpeg, WatermarkOptions options,
    {TextRaster raster = defaultTextRaster}) async {
  if (options.style == WatermarkStyle.off) return jpeg;
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
  final canvas = jpegEncodedCanvasSize(jpeg);
  if (canvas == null) return jpeg; // 帧头无 SOF:解码必失败,原样直返
  if (canvas.$1 * canvas.$2 > kMaxJpegDecodePixels) return jpeg;
  img.ExifData? exif;
  try {
    exif = readJpegExif(jpeg);
  } on Exception {
    exif = null;
  }
  // 显示宽:EXIF Orientation 5~8 烘焙时宽高互换(与 bakeOrientation 同口径)。
  final orientation = exif?.imageIfd.orientation ?? 1;
  final displayWidth =
      orientation >= 5 && orientation <= 8 ? canvas.$2 : canvas.$1;
  final card = exif == null ? null : exifCardDataOf(exif);
  _WatermarkJob? plan;
  try {
    plan = switch (options.style) {
      WatermarkStyle.corner =>
        await _planCorner(displayWidth, jpeg, card, options, raster),
      WatermarkStyle.card =>
        await _planCard(displayWidth, jpeg, card, options, raster),
      WatermarkStyle.off => null,
    };
  } on Exception {
    return jpeg; // 文本光栅失败保原图(水印不应把传输拖成失败)
  }
  if (plan == null) return jpeg; // 无从落笔(无行可写):免一次无谓重编码
  final _WatermarkJob job = plan;
  try {
    final out = await Isolate.run(() => _composeJob(job));
    return out ?? jpeg; // 子 isolate 报 null(解码/合成失败)→ 原字节
  } on Object {
    return jpeg; // 子 isolate 传输级失败(spawn/消息异常)保原图,不上抛
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

/// 从 JPEG 帧头嗅探画幅(首个 SOF 段的宽高),免整帧解码;水印字号按
/// 画幅等比用。SOF0~SOF15 通吃基线与渐进式(无尺寸段 DHT/JPG/DAC 照段
/// 长跳过);结构异常(非 SOI / 段长畸形 / 走到熵编码仍无 SOF)→ null
/// —— 与 decodeJpg 对同类文件的失败面一致(能嗅出画幅的基本都能解)。
(int, int)? jpegEncodedCanvasSize(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  var pos = 2;
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) return null; // 熵编码数据:此前无 SOF,扫描止步
    final marker = jpeg[pos + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) return null;
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      if (pos + 9 > jpeg.length) return null;
      // SOF 段:FF marker len(2) precision(1) height(2) width(2)。
      final height = jpeg[pos + 5] << 8 | jpeg[pos + 6];
      final width = jpeg[pos + 7] << 8 | jpeg[pos + 8];
      if (width <= 0 || height <= 0) return null;
      return (width, height);
    }
    final segLen = jpeg[pos + 2] << 8 | jpeg[pos + 3];
    if (segLen < 2) return null;
    pos += 2 + segLen;
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

// ---- 合成规划(主 isolate)----------------------------------------------

/// 子 isolate 作业快照:纯值对象(jpeg 字节 + 预光栅文本位图 + 字号标量),
/// 经 [Isolate.run] 复制传输 —— dart:ui 对象不可跨 isolate,文本一律先
/// 在主 isolate 光栅成位图。
final class _WatermarkJob {
  _WatermarkJob({
    required this.jpeg,
    required this.style,
    required this.stamps,
    this.fontSize = 0,
    this.lineSize = 0,
  });

  /// 原始 JPEG 字节(子 isolate 侧解码与 EXIF 重读的唯一来源)。
  final Uint8List jpeg;

  final WatermarkStyle style;

  /// 预光栅文本位图:角标 1 张;卡片 title/param/footer 有几行算几张。
  final List<img.Image> stamps;

  /// 角标字号(margin 比例源)。
  final double fontSize;

  /// 卡片行字号(行距比例源)。
  final double lineSize;
}

/// 角标规划:文本回落链(自定义 → EXIF 型号 → 'ZPill')+ 等比字号,
/// 主 isolate 预光栅。
Future<_WatermarkJob> _planCorner(int displayWidth, Uint8List jpeg,
    ExifCardData? card, WatermarkOptions options, TextRaster raster) async {
  final custom = options.text?.trim() ?? '';
  final text = custom.isNotEmpty
      ? custom
      : card?.titleLine.isNotEmpty == true
          ? card!.titleLine
          : 'ZPill';
  final fontSize = (displayWidth * 0.03).clamp(16.0, 96.0);
  final badge = await raster(text, fontSize, 0xFFFFFFFF);
  return _WatermarkJob(
      jpeg: jpeg,
      style: WatermarkStyle.corner,
      stamps: [badge],
      fontSize: fontSize);
}

/// 卡片规划:三行(型号/参数/日期·落款)有内容才收,主 isolate 预光栅;
/// 无 EXIF 也无落款(无行可写)→ null(调用方跳过重编码)。
Future<_WatermarkJob?> _planCard(int displayWidth, Uint8List jpeg,
    ExifCardData? card, WatermarkOptions options, TextRaster raster) async {
  final titleSize = (displayWidth * 0.040).clamp(14.0, 120.0);
  final lineSize = (displayWidth * 0.024).clamp(10.0, 64.0);
  final footer = _cardFooter(card, options);
  final specs = <(String, double)>[
    if (card?.titleLine.isNotEmpty == true) (card!.titleLine, titleSize),
    if (card?.paramLine.isNotEmpty == true) (card!.paramLine, lineSize),
    if (footer.isNotEmpty) (footer, lineSize),
  ];
  if (specs.isEmpty) return null;
  final stamps = <img.Image>[];
  for (final (text, size) in specs) {
    stamps.add(await raster(text, size, 0xFF3C3C43));
  }
  return _WatermarkJob(
      jpeg: jpeg,
      style: WatermarkStyle.card,
      stamps: stamps,
      lineSize: lineSize);
}

// ---- 合成(子 isolate)---------------------------------------------------

/// 子 isolate 合成主体:解码 → EXIF 回挂 → 方向烘焙 → 文本叠印 → 重编码。
/// 任何失败返回 null(调用方回原字节)。
Uint8List? _composeJob(_WatermarkJob job) {
  try {
    img.Image? photo = img.decodeJpg(job.jpeg);
    if (photo == null) return null;
    img.ExifData? exif;
    try {
      exif = readJpegExif(job.jpeg);
    } on Exception {
      exif = null;
    }
    if (exif != null) {
      // image 4.10.1 解码器已按 Orientation 烘焙像素并剥除该标签
      //(getImageFromJpeg);回挂前同步剥除,防 bakeOrientation 二次
      // 旋转 —— 原实现重挂带标签 EXIF 再 bake,竖拍被转回编码方向、
      // 角标错位(横幅夹具全覆盖不到,本批顺根修)。
      exif.imageIfd.orientation = null;
      photo.exif = exif;
    }
    // 方向烘焙进像素(竖幅照片的画布方向由 Orientation 决定);解码器
    // 已烘焙时此处为直通拷贝,EXIF 随行。
    photo = img.bakeOrientation(photo);
    final drawn = switch (job.style) {
      WatermarkStyle.corner =>
        _drawCornerBadge(photo, job.stamps.single, job.fontSize),
      WatermarkStyle.card => _composeCard(photo, job.stamps, job.lineSize),
      WatermarkStyle.off => null,
    };
    if (drawn == null) return null;
    return img.encodeJpg(drawn, quality: 92);
  } on Exception {
    return null;
  }
}

/// 角标叠印:右下角白字 + 投影(投影已烘在文本位图里),画幅不变。
/// 图太小放不下 → null(调用方跳过重编码)。
img.Image? _drawCornerBadge(img.Image photo, img.Image badge, double fontSize) {
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

/// 摄影卡片:白衬纸 + 照片居中 + 下方预光栅文本行按序居中排布。
/// 调用方保证 [lines] 非空(规划侧已把无行可写拦下)。
img.Image _composeCard(
    img.Image photo, List<img.Image> lines, double lineSize) {
  final w = photo.width;
  final sidePad = (w * 0.045).round();
  final topPad = sidePad;
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

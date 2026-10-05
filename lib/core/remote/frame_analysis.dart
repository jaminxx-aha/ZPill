/// 监看辅助的帧分析(TODO §二 Live View 监看辅助):直方图 + 过曝斑马纹
/// 掩码,从 Live View JPEG 帧解码降采样计算。
///
/// 纯 Dart(image 包解码),链路/UI 无关可测;调用方按帧率抽帧(全帧
/// 分析无必要,CPU 也扛不住 —— 见 [FrameAnalyzer])。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

final class FrameAnalysis {
  const FrameAnalysis({
    required this.width,
    required this.height,
    required this.lumaHistogram,
    required this.overexposedMask,
    required this.maskCols,
    required this.maskRows,
    required this.lumaThreshold,
  });

  final int width;
  final int height;

  /// 亮度直方图([lumaHistogram].length 桶,值 = 采样像素数)。
  final List<int> lumaHistogram;

  /// 斑马纹掩码:maskRows × maskCols 行主序,1 = 该格含过曝采样像素。
  final Uint8List overexposedMask;

  final int maskCols;
  final int maskRows;

  /// 过曝判定的 luma 阈值(0-255)。
  final int lumaThreshold;

  bool get hasOverexposure =>
      overexposedMask.any((c) => c != 0);

  /// 直方图归一化(最大桶 = 1.0),画柱状图用。
  List<double> get normalizedHistogram {
    final max = lumaHistogram.reduce((a, b) => a > b ? a : b);
    if (max <= 0) return List.filled(lumaHistogram.length, 0.0);
    return [for (final v in lumaHistogram) v / max];
  }
}

/// 解析 JPEG SOF 标记取帧尺寸(宽高,像素)。只走标记结构不解码 ——
/// 触控对焦的坐标映射用(0x9205 参数是取景帧像素坐标;OpenZCine 帧头
/// coordinateWidth 空间,此处以解码帧尺寸作候选,标定待真机核对)。
///
/// 扫不到(截断/畸形/无 SOF)返回 null,宁失败不错值。
/// SOF 家族 = 0xC0-0xCF 去掉 C4(DHT)/C8(JPG)/CC(DAC);
/// 扫描上限 64KB(LV 帧的 SOF 在量化/哈夫曼表之后,离头部不远)。
({int width, int height})? jpegSofSize(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  final limit = jpeg.length < 65536 ? jpeg.length : 65536;
  var i = 2;
  while (i + 4 <= limit) {
    if (jpeg[i] != 0xFF) return null; // 标记流错位:数据段长度对不上
    var marker = jpeg[i + 1];
    while (marker == 0xFF && i + 2 < limit) {
      // 填充 FF:跳过再看
      i++;
      marker = jpeg[i + 1];
    }
    if (marker == 0xD9 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      return null; // 无长度段的标记/EOI:走到图像数据了仍没遇到 SOF
    }
    final segLen = (jpeg[i + 2] << 8) | jpeg[i + 3];
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      // SOF 载荷:precision(1) height(2) width(2)
      if (i + 9 > jpeg.length) return null;
      final h = (jpeg[i + 5] << 8) | jpeg[i + 6];
      final w = (jpeg[i + 7] << 8) | jpeg[i + 8];
      if (h <= 0 || w <= 0) return null;
      return (width: w, height: h);
    }
    i += 2 + segLen; // 跳过本段(长度含自身 2 字节)
  }
  return null;
}

/// 解码 JPEG 帧并分析。解码失败/空帧返回 null(调用方保持上次结果)。
///
/// 采样步长 = 一个掩码格的像素宽,保证每格至少被扫到;直方图与掩码
/// 共用同一批采样。luma = 0.299R + 0.587G + 0.114B(Rec.601)。
FrameAnalysis? analyzeJpegFrame(
  Uint8List jpeg, {
  int histogramBins = 64,
  int maskCols = 32,
  int maskRows = 24,
  int lumaThreshold = 250,
}) {
  // 解码器对畸形/截断字节可能抛 Error(image 包格式嗅探的越界读,
  // 实测 4B 垃圾触发 RangeError)—— 任何失败一律 null,不上抛。
  Object? decoded;
  try {
    decoded = img.decodeImage(jpeg);
  } on Object {
    return null;
  }
  final image = decoded as img.Image?;
  if (image == null || image.width <= 0 || image.height <= 0) return null;

  final histogram = List<int>.filled(histogramBins, 0);
  final mask = Uint8List(maskCols * maskRows);
  final cellW = image.width / maskCols;
  final cellH = image.height / maskRows;
  final stepX = cellW.ceil().clamp(1, image.width);
  final stepY = cellH.ceil().clamp(1, image.height);
  final binScale = histogramBins / 256;

  for (var y = 0; y < image.height; y += stepY) {
    for (var x = 0; x < image.width; x += stepX) {
      final p = image.getPixel(x, y);
      final luma = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      histogram[(luma * binScale).floor().clamp(0, histogramBins - 1)]++;
      if (luma >= lumaThreshold) {
        final col = (x / cellW).floor().clamp(0, maskCols - 1);
        final row = (y / cellH).floor().clamp(0, maskRows - 1);
        mask[row * maskCols + col] = 1;
      }
    }
  }

  return FrameAnalysis(
    width: image.width,
    height: image.height,
    lumaHistogram: histogram,
    overexposedMask: mask,
    maskCols: maskCols,
    maskRows: maskRows,
    lumaThreshold: lumaThreshold,
  );
}

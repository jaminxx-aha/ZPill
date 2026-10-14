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
    required this.falseColorCells,
    required this.peakingMask,
    required this.peakingCols,
    required this.peakingRows,
    required this.waveform,
    required this.waveformCols,
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

  /// 伪色分类:与斑马纹同网格,每格 = 采样均值落入的亮度带索引
  /// (见 [falseColorBandEdges];带色表在 UI 层)。
  final Uint8List falseColorCells;

  /// 对焦峰值掩码:peakingRows × peakingCols 行主序,1 = 该格处于强
  /// 亮度梯度(相邻格均值差 ≥ [peakingGradientThreshold])。
  final Uint8List peakingMask;
  final int peakingCols;
  final int peakingRows;

  /// 波形示波器数据:waveformCols × 直方图桶数(列外/桶内行主序),
  /// 值 = 该列该亮度桶的采样像素数 —— x = 画面列、y = 亮度的密度图
  /// (上白下黑),过曝亮脊/欠曝底脊一眼可读。
  final Uint32List waveform;

  /// 波形列数(与画面等宽分列;0 = 无波形数据)。
  final int waveformCols;

  /// 波形亮度桶数(与直方图同一分桶,采样环共用一次 bin 计算)。
  int get waveformBins => lumaHistogram.length;

  /// 峰值判定的相邻格亮度梯度阈值(0-255):分析缺省档(= 监看灵敏度
  /// 「中」档)。**调优值非协议常量** —— 用户可配档位(低/中/高)在
  /// 监看桥接层映射(features/remote/monitor_toggles.dart 的
  /// monitorPeakingThresholdOf),经 [analyzeJpegFrame] 的
  /// peakingThreshold 参数传入。
  static const int peakingGradientThreshold = 40;

  /// 伪色亮度带边界(升序;带索引 = luma 落入的区间序号,共
  /// 边界数 + 1 带)。UI 层按索引取色。
  static const falseColorBandEdges = [16, 48, 96, 160, 216, 250];

  /// luma → 伪色带索引。
  static int falseColorBandOf(int luma) {
    for (var i = 0; i < falseColorBandEdges.length; i++) {
      if (luma < falseColorBandEdges[i]) return i;
    }
    return falseColorBandEdges.length;
  }

  bool get hasOverexposure =>
      overexposedMask.any((c) => c != 0);

  bool get hasPeaking => peakingMask.any((c) => c != 0);

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
/// 采样步长 = 一个掩码格的像素宽,保证每格至少被扫到;直方图/斑马纹/
/// 伪色(格均值 → 亮度带)共用同一批采样;对焦峰值用更细的
/// [peakingCols]×[peakingRows] 均值网格做相邻梯度,梯度阈值
/// [peakingThreshold](缺省 = [FrameAnalysis.peakingGradientThreshold]
/// 中档,用户可配)。luma = 0.299R + 0.587G + 0.114B(Rec.601)。
FrameAnalysis? analyzeJpegFrame(
  Uint8List jpeg, {
  int histogramBins = 64,
  int maskCols = 32,
  int maskRows = 24,
  int lumaThreshold = 250,
  int peakingCols = 64,
  int peakingRows = 48,
  int peakingThreshold = FrameAnalysis.peakingGradientThreshold,
  int waveformCols = 64,
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
  final waveform = Uint32List(waveformCols * histogramBins);
  final mask = Uint8List(maskCols * maskRows);
  // 伪色:格内 luma 累加(采样数不定,最后取均值)
  final lumaSums = List<int>.filled(maskCols * maskRows, 0);
  final lumaCounts = List<int>.filled(maskCols * maskRows, 0);
  // 峰值:细网格均值
  final peakSums = List<int>.filled(peakingCols * peakingRows, 0);
  final peakCounts = List<int>.filled(peakingCols * peakingRows, 0);
  final cellW = image.width / maskCols;
  final cellH = image.height / maskRows;
  final peakCellW = image.width / peakingCols;
  final peakCellH = image.height / peakingRows;
  final waveCellW = image.width / waveformCols;
  // 采样步长取两网格较细者:峰值网格(64×48)比斑马纹(32×24)细时,
  // 按粗网格采样会在峰值格间留空(空格不参与梯度 → 边缘漏检)。
  final stepX =
      (cellW < peakCellW ? cellW : peakCellW).ceil().clamp(1, image.width);
  final stepY =
      (cellH < peakCellH ? cellH : peakCellH).ceil().clamp(1, image.height);
  final binScale = histogramBins / 256;

  for (var y = 0; y < image.height; y += stepY) {
    for (var x = 0; x < image.width; x += stepX) {
      final p = image.getPixel(x, y);
      final luma = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      final bin = (luma * binScale).floor().clamp(0, histogramBins - 1);
      histogram[bin]++;
      // 波形:列-亮度桶计数(bin 与直方图同一次计算,零额外遍历)。
      final wcol = (x / waveCellW).floor().clamp(0, waveformCols - 1);
      waveform[wcol * histogramBins + bin]++;
      final col = (x / cellW).floor().clamp(0, maskCols - 1);
      final row = (y / cellH).floor().clamp(0, maskRows - 1);
      final cell = row * maskCols + col;
      if (luma >= lumaThreshold) {
        mask[cell] = 1;
      }
      lumaSums[cell] += luma;
      lumaCounts[cell]++;
      final pcol = (x / peakCellW).floor().clamp(0, peakingCols - 1);
      final prow = (y / peakCellH).floor().clamp(0, peakingRows - 1);
      final pcell = prow * peakingCols + pcol;
      peakSums[pcell] += luma;
      peakCounts[pcell]++;
    }
  }

  // 伪色:格均值 → 亮度带索引
  final falseColor = Uint8List(maskCols * maskRows);
  for (var i = 0; i < falseColor.length; i++) {
    final n = lumaCounts[i];
    if (n > 0) {
      falseColor[i] = FrameAnalysis.falseColorBandOf(lumaSums[i] ~/ n);
    }
  }

  // 峰值:细网格均值 → 相邻梯度(右/下);双方都有采样才比较
  // (稀疏采样下的空格均值是 0,当真值比会满屏误报)
  final peakMeans = List<double>.filled(peakingCols * peakingRows, 0);
  for (var i = 0; i < peakMeans.length; i++) {
    final n = peakCounts[i];
    peakMeans[i] = n > 0 ? peakSums[i] / n : 0;
  }
  final peaking = Uint8List(peakingCols * peakingRows);
  final grad = peakingThreshold;
  for (var row = 0; row < peakingRows; row++) {
    for (var col = 0; col < peakingCols; col++) {
      final i = row * peakingCols + col;
      if (peakCounts[i] == 0) continue; // 空格不参与
      final m = peakMeans[i];
      final strong =
          (col + 1 < peakingCols &&
                  peakCounts[i + 1] > 0 &&
                  (peakMeans[i + 1] - m).abs() >= grad) ||
              (row + 1 < peakingRows &&
                  peakCounts[i + peakingCols] > 0 &&
                  (peakMeans[i + peakingCols] - m).abs() >= grad);
      if (strong) peaking[i] = 1;
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
    falseColorCells: falseColor,
    peakingMask: peaking,
    peakingCols: peakingCols,
    peakingRows: peakingRows,
    waveform: waveform,
    waveformCols: waveformCols,
  );
}

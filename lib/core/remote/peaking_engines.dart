/// 对焦峰值判定引擎(TODO §二 监看辅助):单尺度相邻梯度(经典,
/// 2026-10-14 前的唯一路径)与双尺度比值(新默认)。
///
/// 经典引擎只看单尺度相邻格梯度 —— 散景高亮(亮斑软边)的对比度
/// 摆在那里,软边梯度照样过阈值,被误判成合焦:单阈值把「对比度」
/// 和「合焦程度」混进同一个数,不存在能分开两者的阈值。双尺度比值
/// 把图像与它的**再模糊副本**相比:合焦边缘再模糊后边缘能量大降
/// (比值高),失焦/散景边缘本来已经糊、再模糊一次能量几乎不变
/// (比值≈1)—— 边缘幅度在分子分母同时出现而相消,比值只随模糊
/// 半径走,散景误报从判据上消失。cf. Zhuo & Sim, *Defocus map
/// estimation from a single image*, Pattern Recognition 2011;工程语义
/// 对齐 OpenZCine Sources/OpenZCineCore/FocusAssist.swift(Apache-2.0,
/// 常量同源,Dart 重写)。
///
/// 两引擎共用 analyzeJpegFrame 的同一份峰格均值平面
/// (peakMeans/peakCounts),产出同构掩码 —— 叠层/设置消费方无感。
library;

import 'dart:typed_data';

/// 峰值引擎二选一(设置「峰值算法」档,默认双尺度,经典 = 手感回退)。
enum PeakingEngine {
  /// 双尺度比值(默认):原平面 vs 再模糊副本,失焦/散景不亮。
  dualScale,

  /// 单尺度相邻梯度(经典):只看相邻格均值差,行为 = 2026-10-14 前。
  gradient,
}

/// 再模糊核:7 抽头可分离(行、列各卷一遍,2×7 次乘加/格)。与
/// OpenZCine 的 reblurWeights 同源 —— CIGaussianBlur radius 1.0 的
/// 实测冲激响应(≈σ1.04 高斯但非精确:±2 抽低 0.4%、±3 抽低 1.3%,
/// 方差 1.0777)。**调优常量非协议值**,网格口径(1 格 = 1 单位)。
const List<double> peakingReblurWeights = [
  0.006044, 0.060662, 0.241798, 0.382992, 0.241798, 0.060662, 0.006044,
];

/// 比值饱和上限(OpenZCine ratioCeiling 同源):完美合焦的理论比值
/// 无穷,网格上单格台阶实测 ~6.8,一律钳到 4.0 —— 与档位阈值
/// (1.90~2.30)同一值域。
const double peakingRatioCeiling = 4.0;

/// 双尺度中档参数([peakingDualScaleParamsOf] 的 1 档,亦是
/// analyzeJpegFrame 的参数缺省)。
const double peakingRatioThresholdMedium = 2.10;
const int peakingNoiseGateMedium = 450;

/// 灵敏度档(0 低 / 1 中 / 2 高,与监看桥接层的
/// monitorPeakingThresholdOf 同口径)→ 双尺度参数(比值阈值 + 噪声
/// 门槛)。**调优档非协议常量,真机标定留账(TODO §二)**:
///
/// - 比值阈值取 OpenZCine 的标定梯子(其 Low/Med/High =
///   2.30/2.10/1.90;我方档名方向与其相反 —— 我方「低」= 更灵敏 =
///   阈值更低):低 1.90 / 中 2.10 / 高 2.30。
/// - 噪声门槛(255 域平方 Roberts 单位,加在再模糊后的粗尺度能量上)
///   锚定经典引擎同档手感:锐边(单格台阶)再模糊后能量
///   E_B = 2×(0.383·A)² ≈ 0.293·A²,取 A = 经典档梯度阈值
///   (24/40/64)换算得 169/469/1202,就低取整:低 160 / 中 450 /
///   高 1200 —— 对锐利边缘,两引擎同档的最低可圈幅度一致,差别
///   全在失焦边(比值判据剔除)。
/// - 两参数随档同向移动(OpenZCine 教训:只动其一,档位语义漂移)。
/// - 表外档回落中档(与 monitorPeakingThresholdOf 同口径)。
({double ratioThreshold, int noiseGate}) peakingDualScaleParamsOf(int level) =>
    switch (level) {
      0 => (ratioThreshold: 1.90, noiseGate: 160),
      2 => (ratioThreshold: 2.30, noiseGate: 1200),
      _ => (
          ratioThreshold: peakingRatioThresholdMedium,
          noiseGate: peakingNoiseGateMedium,
        ),
    };

/// 双尺度比值:E_A/E_B 钳 [peakingRatioCeiling]。合焦 → 高(→4.0),
/// 失焦/散景 → ≈1;E_B ≤ 0(全黑/平坦,除零守卫)→ 0 = 不亮。
double peakingSharpnessRatio(double fine, double coarse) {
  if (coarse <= 0) return 0;
  final r = fine / coarse;
  return r > peakingRatioCeiling ? peakingRatioCeiling : r;
}

/// 双尺度比值掩码:rows×cols 行主序,1 = 该格判为合焦。
///
/// 输入 = analyzeJpegFrame 的峰格均值平面([means],[counts][i] == 0
/// 的空格所在 quad 不参与,与经典引擎同口径)。四步(见库注释):
/// ① 尺度 A = 原平面;② 尺度 B = [peakingReblurWeights] 可分离
/// 再模糊(边界**镜像反射**取样 —— 与 OpenZCine 的钳位 + 6px 死边距
/// 不同:钳位会把高频噪声在边界复制成假边、需要死边距压住,镜像
/// 保持局部结构,贴边真边缘也能亮,64 格网格上不留死框);③ 逐格点
/// 能量 = 2×2 quad 平方 Roberts 交叉(两对角差平方和,与 OpenZCine
/// 的 robertsSquared 同算子),quad 锚在左上格、亮也标左上格
/// (OpenZCine 在锚点像素画描边同口径);④ 比值 =
/// [peakingSharpnessRatio];合焦判据 = E_B ≥ [noiseGate] **且**
/// 比值 ≥ [ratioThreshold] —— 能量门槛先行,低光/平坦/噪声一律
/// 不亮,比值只在过门槛后参与。
///
/// 性能:网格 ≤64×48 时再模糊 2 遍 × 7 抽 + 能量遍 ≈ 十万次运算,
/// 远小于帧解码本身,不引入新帧延迟。
Uint8List dualScalePeakingMask({
  required List<double> means,
  required List<int> counts,
  required int cols,
  required int rows,
  required double ratioThreshold,
  required int noiseGate,
}) {
  final mask = Uint8List(cols * rows);
  if (cols < 2 || rows < 2) return mask; // 无完整 quad,恒不亮
  // ② 尺度 B:可分离再模糊,水平一遍 → 垂直一遍(镜像反射边界)
  final taps = peakingReblurWeights.length ~/ 2;
  final n = cols * rows;
  final h = Float64List(n);
  final blurred = Float64List(n);
  for (var y = 0; y < rows; y++) {
    final base = y * cols;
    for (var x = 0; x < cols; x++) {
      var t = 0.0;
      for (var j = -taps; j <= taps; j++) {
        var sx = x + j;
        if (sx < 0) sx = -sx; // 镜像反射(极小网格兜底钳位)
        if (sx >= cols) sx = 2 * cols - 2 - sx;
        if (sx < 0) sx = 0;
        if (sx >= cols) sx = cols - 1;
        t += peakingReblurWeights[j + taps] * means[base + sx];
      }
      h[base + x] = t;
    }
  }
  for (var y = 0; y < rows; y++) {
    final base = y * cols;
    for (var x = 0; x < cols; x++) {
      var t = 0.0;
      for (var j = -taps; j <= taps; j++) {
        var sy = y + j;
        if (sy < 0) sy = -sy;
        if (sy >= rows) sy = 2 * rows - 2 - sy;
        if (sy < 0) sy = 0;
        if (sy >= rows) sy = rows - 1;
        t += peakingReblurWeights[j + taps] * h[sy * cols + x];
      }
      blurred[base + x] = t;
    }
  }
  // ③④ 能量 → 比值 → 判据
  for (var y = 0; y + 1 < rows; y++) {
    for (var x = 0; x + 1 < cols; x++) {
      final i = y * cols + x;
      if (counts[i] == 0 ||
          counts[i + 1] == 0 ||
          counts[i + cols] == 0 ||
          counts[i + cols + 1] == 0) {
        continue; // 空格不参与
      }
      final d1 = means[i + cols + 1] - means[i];
      final d2 = means[i + cols] - means[i + 1];
      final fine = d1 * d1 + d2 * d2;
      final c1 = blurred[i + cols + 1] - blurred[i];
      final c2 = blurred[i + cols] - blurred[i + 1];
      final coarse = c1 * c1 + c2 * c2;
      if (coarse < noiseGate) continue; // 能量门槛先行
      if (peakingSharpnessRatio(fine, coarse) >= ratioThreshold) mask[i] = 1;
    }
  }
  return mask;
}

/// 经典单尺度梯度掩码(2026-10-14 前的唯一路径,自 analyzeJpegFrame
/// 抽出为纯函数):相邻格均值差(右/下任一)≥ [threshold] 即亮,
/// 空格不参与。保留作「峰值算法 = 经典」的手感回退。
Uint8List gradientPeakingMask({
  required List<double> means,
  required List<int> counts,
  required int cols,
  required int rows,
  required int threshold,
}) {
  final mask = Uint8List(cols * rows);
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      final i = row * cols + col;
      if (counts[i] == 0) continue; // 空格不参与
      final m = means[i];
      final strong =
          (col + 1 < cols &&
                  counts[i + 1] > 0 &&
                  (means[i + 1] - m).abs() >= threshold) ||
              (row + 1 < rows &&
                  counts[i + cols] > 0 &&
                  (means[i + cols] - m).abs() >= threshold);
      if (strong) mask[i] = 1;
    }
  }
  return mask;
}

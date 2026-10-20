/// 帧分析调度(监看辅助):挂在 LiveViewEngine 的帧通知上,
/// 每 N 帧算一次 [FrameAnalysis](直方图/斑马纹),禁用时零开销。
library;

import 'package:flutter/foundation.dart';

import 'frame_analysis.dart';
import 'peaking_engines.dart';

final class FrameAnalyzer {
  FrameAnalyzer({this.everyNth = 5});

  /// 抽帧间隔:基础 200ms 帧率下 = 每 ~1s 一算(image 包全帧解码在
  /// 中端机 ~20-50ms,全帧算会挤 UI)。
  final int everyNth;

  /// 分析开关(斑马纹/直方图任一开启时置 true;false 时帧到达即返回)。
  final enabled = ValueNotifier<bool>(false);

  /// 峰值引擎(默认双尺度比值;经典 = 单尺度梯度回退):页面按
  /// 「峰值算法」设置同步,改档下一帧分析起生效(分析结果是快照,
  /// 无须清缓存重算)。
  PeakingEngine peakingEngine = PeakingEngine.dualScale;

  /// 经典引擎的相邻格梯度阈值(0-255;双尺度引擎不读):页面按灵敏
  /// 度档同步。
  int peakingThreshold = FrameAnalysis.peakingGradientThreshold;

  /// 双尺度引擎的比值阈值与噪声门槛(经典引擎不读;缺省 = 中档):
  /// 页面按灵敏度档同步,映射见 peakingDualScaleParamsOf。
  double peakingRatioThreshold = peakingRatioThresholdMedium;
  int peakingNoiseGate = peakingNoiseGateMedium;

  /// 最近一次分析(null = 尚无/最近帧解码失败;禁用重开时清)。
  final ValueNotifier<FrameAnalysis?> analysis = ValueNotifier<FrameAnalysis?>(null);

  ValueListenable<Uint8List?>? _frames;
  int _seen = 0;

  void attach(ValueListenable<Uint8List?> frames) {
    detach();
    _frames = frames;
    frames.addListener(_onFrame);
  }

  void detach() {
    _frames?.removeListener(_onFrame);
    _frames = null;
    _seen = 0;
    analysis.value = null;
  }

  void _onFrame() {
    if (!enabled.value) return;
    if (_seen++ % everyNth != 0) return;
    final frame = _frames?.value;
    if (frame == null) return;
    analysis.value = analyzeJpegFrame(
      frame,
      peakingEngine: peakingEngine,
      peakingThreshold: peakingThreshold,
      peakingRatioThreshold: peakingRatioThreshold,
      peakingNoiseGate: peakingNoiseGate,
    );
  }

  void dispose() {
    detach();
    enabled.dispose();
    analysis.dispose();
  }
}

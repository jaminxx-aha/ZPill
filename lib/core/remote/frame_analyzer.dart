/// 帧分析调度(TODO §二 监看辅助):挂在 LiveViewEngine 的帧通知上,
/// 每 N 帧算一次 [FrameAnalysis](直方图/斑马纹),禁用时零开销。
library;

import 'package:flutter/foundation.dart';

import 'frame_analysis.dart';

final class FrameAnalyzer {
  FrameAnalyzer({this.everyNth = 5});

  /// 抽帧间隔:基础 200ms 帧率下 = 每 ~1s 一算(image 包全帧解码在
  /// 中端机 ~20-50ms,全帧算会挤 UI)。
  final int everyNth;

  /// 分析开关(斑马纹/直方图任一开启时置 true;false 时帧到达即返回)。
  final enabled = ValueNotifier<bool>(false);

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
    analysis.value = analyzeJpegFrame(frame);
  }

  void dispose() {
    detach();
    enabled.dispose();
    analysis.dispose();
  }
}

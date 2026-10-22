/// 帧分析调度(监看辅助):挂在 LiveViewEngine 的帧通知上,
/// 每 N 帧算一次 [FrameAnalysis](直方图/斑马纹),禁用时零开销;
/// 解码+逐像素扫描走 [Isolate.run](image 包纯 Dart 解整帧 JPEG +
/// 全帧采样 30-100ms/次,是取景期主 isolate 最大卡顿源,2026-10-22
/// 迁出主 isolate;每次调用即起即收的短命 isolate,spawn 开销 ~ms
/// 级,相对解码可接受,不设常驻 isolate)。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../log/app_log.dart';

import 'frame_analysis.dart';
import 'peaking_engines.dart';

/// 子 isolate 分析入口(**顶层函数**):闭包上下文只含纯值参数 ——
/// 实例方法里写 [Isolate.run] 会沿闭包 context 链捕获 `this`(分析器 →
/// 引擎通知器 → 监听闭包 → 控制器),控制器含 Completer 随信发送即炸
///(2026-10-22 真机实证)。顶层函数无 this、无父链,构造性消除。
Future<FrameAnalysis?> analyzeInIsolate(
  Uint8List frame, {
  required PeakingEngine peakingEngine,
  required int peakingThreshold,
  required double peakingRatioThreshold,
  required int peakingNoiseGate,
}) =>
    Isolate.run(() => analyzeJpegFrame(
          frame,
          peakingEngine: peakingEngine,
          peakingThreshold: peakingThreshold,
          peakingRatioThreshold: peakingRatioThreshold,
          peakingNoiseGate: peakingNoiseGate,
        ));

final class FrameAnalyzer {
  FrameAnalyzer({this.everyNth = 5});

  /// 抽帧间隔:基础 200ms 帧率下 = 每 ~1s 一算。分析虽已迁子 isolate
  /// (不再卡 UI),全帧解码仍吃整核 CPU —— 抽帧控的是 CPU 占用预算。
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

  /// 分析在途旗标:在途时后续触发直接丢(丢的是分析帧,取景帧照常走
  /// UI)—— 防 Isolate.run 任务积压排队,结果回来后下一个抽帧沿恢复
  /// 触发(最新帧优先,不补算积压的旧帧)。
  bool _inFlight = false;

  /// 世代号:attach/detach(dispose 内含)各翻一次。在途任务的结果
  /// 回来世代不符即弃 —— detach 清态后不得被迟到结果复活,dispose 后
  /// 不得写已 dispose 的 notifier。
  int _epoch = 0;

  void attach(ValueListenable<Uint8List?> frames) {
    detach();
    _inFlight = false; // 上一世代的在途任务与本世代无关(结果被世代闸弃)
    _frames = frames;
    frames.addListener(_onFrame);
  }

  void detach() {
    _epoch++;
    _frames?.removeListener(_onFrame);
    _frames = null;
    _seen = 0;
    analysis.value = null;
  }

  void _onFrame() {
    if (!enabled.value) return;
    if (_seen++ % everyNth != 0) return;
    if (_inFlight) return;
    final frame = _frames?.value;
    if (frame == null) return;
    // 参数快照:isolate 闭包只捕获这些局部与帧字节,不捕获 this
    //(ValueNotifier 不可跨 isolate 发送)。帧字节即使是 sublistView
    //(头剥离路径)也按视图区间复制到子 isolate,实证无共享。
    final engine = peakingEngine;
    final threshold = peakingThreshold;
    final ratioThreshold = peakingRatioThreshold;
    final noiseGate = peakingNoiseGate;
    final epoch = _epoch;
    _inFlight = true;
    unawaited(() async {
      // analyzeJpegFrame 已把解码失败收编为 null;这里再兜 isolate 传输
      // 级失败(spawn/消息异常),口径同前:不上抛、保持上次结果。
      FrameAnalysis? result;
      try {
        result = await analyzeInIsolate(
          frame,
          peakingEngine: engine,
          peakingThreshold: threshold,
          peakingRatioThreshold: ratioThreshold,
          peakingNoiseGate: noiseGate,
        );
      } on Object catch (e) {
        // isolate 信报失败落盘(2026-10-22 真机实证:实例方法里写
        // Isolate.run,闭包沿 context 链捕获 this → 引擎通知器 → 监听
        // 闭包 → 控制器,其 _AsyncCompleter 随链入信即
        // 「object is unsendable」,分析全程静默失败、叠层只余黑盒;
        // 顶层函数入口构造性消除,此日志留作运营证据不再吞错无声)。
        AppLog.e(AppLog.live, '帧分析失败: ${e.runtimeType} $e');
        result = null;
      }
      if (epoch != _epoch) return; // 已 detach/dispose(或重挂):迟到结果弃
      _inFlight = false;
      analysis.value = result;
    }());
  }

  void dispose() {
    detach();
    enabled.dispose();
    analysis.dispose();
  }
}

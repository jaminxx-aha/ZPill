/// Live View 轮询引擎(链路无关、UI 无关)。
///
/// 生命周期:0x9201 StartLiveView(候选码)→ 轮询 0x9203 GetLiveViewImage
/// → 0x9202 EndLiveView。每帧一个短事务,与拍照/属性读在 PtpSession 的
/// 全局串行锁上自然交错;间隔从**上一帧完成时刻**起算。
///
/// 失败策略:指数退避(间隔 ×2,封顶 2s),连续 5 帧失败转 failed 并停轮
/// —— 链路死亡(拔线/无线断)时 5s 内收口,不会无限打链路。
/// 0xC10C LiveViewStateChanged 事件**不参与启停**:引擎纯轮询自治
/// (事件语义未实证,待真机核对)。
///
/// pause/resume 供拍照期间挂起轮询(快门/DeviceReady 事务不被取帧
/// 挤占串行锁);末帧保留(pause 不闪黑,failed 后回到页面仍见最后画面)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ptp/ptp_session.dart';
import 'live_view_header.dart';

enum LiveViewStatus { idle, running, failed }

final class LiveViewEngine {
  LiveViewEngine({
    required this.session,
    this.interval = const Duration(milliseconds: 200),
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final PtpSession session;

  /// 轮询基础间隔(失败退避从它翻倍)。
  final Duration interval;

  final Future<void> Function(Duration) _delay;

  /// 最近一帧(JPEG 字节,SOI 起);null = 尚未收到/从未开启。
  final frame = ValueNotifier<Uint8List?>(null);

  /// 最近一帧的 display-info 头(相机自报的 AF 框/水平仪/录制态;
  /// null = 裸 JPEG/头解析不出/尚未收到)。与 [frame] 同步发布。
  final header = ValueNotifier<LiveViewHeader?>(null);

  final status = ValueNotifier<LiveViewStatus>(LiveViewStatus.idle);

  /// 转 failed 时的最后错误(展示用)。
  String? lastError;

  static const int _maxFailures = 5;
  static const Duration _maxBackoff = Duration(seconds: 2);
  static const Duration _pausedTick = Duration(milliseconds: 50);

  /// start/stop 轮换世代:旧循环的迟到迭代不得触碰新状态。
  int _runId = 0;
  bool _paused = false;
  int _failures = 0;

  /// 取景是否已向相机开启(EndLiveView 只在开启过才发 —— 断连兜底的
  /// stop() 不得给从未开过取景的相机发多余命令)。
  bool _viewOn = false;

  /// 开启取景(幂等):StartLiveView 失败即转 failed,不进轮询。
  Future<void> start() async {
    if (status.value == LiveViewStatus.running) return;
    _failures = 0;
    _paused = false;
    lastError = null;
    try {
      await session.startLiveView();
    } on Exception catch (e) {
      lastError = '取景开启失败:$e';
      status.value = LiveViewStatus.failed;
      return;
    }
    status.value = LiveViewStatus.running;
    _viewOn = true;
    final run = ++_runId;
    unawaited(_loop(run));
  }

  /// 停止取景(幂等):立即废掉循环;开启过才发 EndLiveView,尽力而为
  /// (链路已死时它必然失败,吞掉)。
  Future<void> stop() async {
    _runId++;
    _paused = false;
    if (status.value != LiveViewStatus.failed) {
      status.value = LiveViewStatus.idle;
    }
    if (!_viewOn) return;
    _viewOn = false;
    try {
      await session.endLiveView();
    } on Object {
      // 链路已断/相机拒绝/transport 已关(StateError):本地循环已停,足够
    }
  }

  /// 挂起轮询(在途事务自然完成);不影响 Start/EndLiveView 状态。
  void pause() => _paused = true;

  void resume() => _paused = false;

  Future<void> _loop(int run) async {
    while (status.value == LiveViewStatus.running && run == _runId) {
      if (_paused) {
        await _delay(_pausedTick);
        continue;
      }
      try {
        final raw = await session.getLiveViewObject();
        if (run != _runId) return; // 停止后的迟到结果不发布
        header.value = parseLiveViewHeader(raw);
        frame.value = extractLiveViewJpeg(raw);
        _failures = 0;
        await _delay(interval);
      } on Object catch (e) {
        if (run != _runId) return;
        _failures++;
        if (_failures >= _maxFailures) {
          lastError = '取景中断:$e';
          status.value = LiveViewStatus.failed;
          _runId++; // 废掉本循环
          return;
        }
        await _delay(_backoff());
      }
    }
  }

  Duration _backoff() {
    final ms = interval.inMilliseconds * (1 << (_failures - 1));
    final capped = ms < _maxBackoff.inMilliseconds ? ms : _maxBackoff.inMilliseconds;
    return Duration(milliseconds: capped);
  }
}

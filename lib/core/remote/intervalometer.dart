/// 间隔拍摄调度器(纯 Dart 可测单元:零 Timer、零平台依赖,延迟与
/// 动作全注入)。
///
/// 结构借鉴 N-link IntervalConfig/IntervalProgress(该仓无 LICENSE,只借
/// 参数域/每拍记账/「单拍失败不炸整轮」思路,不搬码),其缺口由本仓
/// 口径补齐:① 每拍先探就绪 —— N-link 直接发快门,相机忙时整拍扑空,
/// 本仓按 0x90C8 DeviceReady 忙等语义(session 层已把 0x2019/0xA200/
/// 0xA201 收敛成 false)有界等待,预算耗尽按「忙超时跳拍」记账;
/// ② 连拍失败自停 —— N-link 只累计失败张数跑完全程,本仓连续
/// [maxConsecutiveFailures] 拍不成即停(卡满/拨杆档/链路僵一类系统性
/// 问题不空转);③ 暂停/停止即时 —— 在途等待与注入的 delay 竞速
/// (Future.any),stop/pause 不等睡眠到期;④ 无限张数(null)。
///
/// 时钟零依赖(仓内 BulbClosePolicy / ReconnectPolicy 同款口径):本单元
/// 只编排「到点 → 探就绪 → 拍 → 记账」,睡眠由注入的 [delay] 执行,
/// 测试用假 delay 手动放行,不真等间隔。状态变化经 ChangeNotifier 通知
/// 宿主(RemoteController 转发刷新 UI)。
///
/// 错误处置 = 跳过继续:单拍失败(快门被拒/异常)只记账不炸整轮;
/// 断链检测不归本单元 —— 宿主在断连沿调 [stop](控制器 _invalidate
/// 接线),探针异常按「放行去拍」处理(快门事务自证,链路死则宿主停)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 调度器状态:idle(未启动/已重置)→ running ⇄ paused → stopped
/// (终态;张数满/连续失败自停/宿主停)。stopped 后可再 start。
enum IntervalometerStatus { idle, running, paused, stopped }

/// 一轮的结束原因(stopped 态非 null)。
enum IntervalStopReason {
  /// 张数拍满。
  completed,

  /// 连续失败达 [Intervalometer.maxConsecutiveFailures],自动停。
  autoStopped,

  /// 宿主主动停(用户点停 / 断链 / dispose)。
  stopped,
}

/// 单拍结果。
enum IntervalShotOutcome {
  /// 快门事务成功(落地等待完成)。
  success,

  /// 就绪探测预算耗尽,本拍未发快门(相机持续忙)。
  busyTimeout,

  /// 快门事务失败(被拒/异常;[IntervalShotRecord.detail] 带原因)。
  failure,
}

/// 间隔拍摄配置(构造即钳制;真机标定后只改 [IntervalConfig] 钳制常量,
/// 不动调度器结构)。
final class IntervalConfig {
  IntervalConfig({
    required Duration interval,
    int? shotCount,
    Duration firstShotDelay = Duration.zero,
  })  : interval = _clampInterval(interval),
        firstShotDelay =
            firstShotDelay < Duration.zero ? Duration.zero : firstShotDelay,
        shotCount =
            shotCount == null ? null : (shotCount < 1 ? 1 : shotCount);

  /// 间隔钳制:下限 1s(连拍驱动档另有屏上快门按住链,间隔拍摄不抢
  /// 人设;Zf 实际写卡速度与下限的匹配留真机账),上限 1h。
  static Duration _clampInterval(Duration d) {
    if (d < const Duration(seconds: 1)) return const Duration(seconds: 1);
    if (d > const Duration(hours: 1)) return const Duration(hours: 1);
    return d;
  }

  /// 拍摄间隔(钳制 1s..1h)。
  final Duration interval;

  /// 张数:null = 无限(直到停止);提供值 <1 按 1 记(UI 的「∞」
  /// 传 null,不以 0 哨兵)。
  final int? shotCount;

  /// 首拍延迟(钳制 ≥0;默认立即拍)。
  final Duration firstShotDelay;
}

/// 单拍记账(第 [index] 拍,1 基;[detail] = 失败/跳拍原因,诊断透出)。
final class IntervalShotRecord {
  const IntervalShotRecord({
    required this.index,
    required this.outcome,
    this.detail,
  });

  final int index;
  final IntervalShotOutcome outcome;
  final String? detail;
}

/// 等待竞速结果:到点 / 暂停打断 / 停止打断。
enum _Tick { elapsed, paused, stopped }

/// 就绪探测结果。
enum _ReadyResult { ready, busyTimeout, paused, stopped }

/// 间隔拍摄调度器。宿主注入三件:[delay](睡眠)、[probeReady](就绪
/// 探测,session.deviceReady —— false = 忙,异常 = 放行去拍)、
/// [shoot](单拍事务,返回 (是否成功, 失败原因/成功附注))。启动后自治
/// 循环,状态/记账变化 notifyListeners。
final class Intervalometer extends ChangeNotifier {
  Intervalometer({
    required Future<void> Function(Duration) delay,
    required Future<bool> Function() probeReady,
    required Future<(bool, String?)> Function() shoot,
    this.readyPolls = defaultReadyPolls,
    this.readyPollInterval = defaultReadyPollInterval,
    this.maxConsecutiveFailures = defaultMaxConsecutiveFailures,
  })  : _delay = delay,
        _probeReady = probeReady,
        _shoot = shoot;

  /// 就绪探测预算(每拍至多探 [readyPolls] 次,间隔 [readyPollInterval];
  /// 同控制器单拍落定轮询口径 —— 真机标定可调)。
  static const int defaultReadyPolls = 10;

  /// 就绪探测节拍(300ms × 10 ≈ 3s 等待窗)。
  static const Duration defaultReadyPollInterval = Duration(milliseconds: 300);

  /// 连续失败自停阈值(单拍失败/忙超时只跳拍;连续 3 拍不成 = 系统性
  /// 问题,停轮留真因 —— 真机标定后改常量,不动结构)。
  static const int defaultMaxConsecutiveFailures = 3;

  /// 每拍就绪探测预算(实例字段:测试拨小)。
  int readyPolls;

  /// 就绪探测节拍(实例字段:测试拨小)。
  Duration readyPollInterval;

  /// 连续失败自停阈值(实例字段:测试拨小)。
  int maxConsecutiveFailures;

  final Future<void> Function(Duration) _delay;
  final Future<bool> Function() _probeReady;
  final Future<(bool, String?)> Function() _shoot;

  IntervalometerStatus _status = IntervalometerStatus.idle;
  IntervalConfig? _config;
  IntervalStopReason? _stopReason;
  final List<IntervalShotRecord> _shots = [];
  int _consecutiveFailures = 0;
  Completer<void>? _stopSignal;
  Completer<void>? _pauseSignal;
  Completer<void>? _resumeSignal;
  Future<void>? _runFuture;

  IntervalometerStatus get status => _status;
  IntervalConfig? get config => _config;
  IntervalStopReason? get stopReason => _stopReason;

  /// 已尝试拍数(成功 + 失败 + 忙超时跳拍)。
  int get attempted => _shots.length;

  /// 成功张数。
  int get taken =>
      _shots.where((s) => s.outcome == IntervalShotOutcome.success).length;

  /// 失败张数(含忙超时跳拍)。
  int get failed => _shots.length - taken;

  /// 当前连续失败拍数(成功即清零)。
  int get consecutiveFailures => _consecutiveFailures;

  /// 单拍记账(只读视图)。
  List<IntervalShotRecord> get shots => List.unmodifiable(_shots);

  /// 最近一拍;空轮 null。
  IntervalShotRecord? get lastShot =>
      _shots.isEmpty ? null : _shots.last;

  /// 运行中(含暂停)—— 宿主互锁门用(屏上快门让位等)。
  bool get active =>
      _status == IntervalometerStatus.running ||
      _status == IntervalometerStatus.paused;

  /// 本轮收口 Future(宿主/测试 await 用;未启动过立即完成)。
  Future<void> get done => _runFuture ?? Future<void>.value();

  /// 启动一轮(运行/暂停中拒绝,返回 false;上一轮 stopped 后计数
  /// 重置可再启)。
  bool start(IntervalConfig config) {
    if (active) return false;
    _config = config;
    _shots.clear();
    _consecutiveFailures = 0;
    _stopReason = null;
    _stopSignal = Completer<void>();
    _pauseSignal = null;
    _resumeSignal = null;
    _status = IntervalometerStatus.running;
    notifyListeners();
    _runFuture = _run(config);
    return true;
  }

  /// 暂停:即时打断在途等待(间隔/首拍延迟/就绪探测);在途单拍事务
  /// 让其落地(快门已发,弃之危险),落账后在下一拍前挂起。恢复后
  /// 间隔重新起算。
  void pause() {
    if (_status != IntervalometerStatus.running) return;
    _status = IntervalometerStatus.paused;
    _pauseSignal = Completer<void>()..complete();
    notifyListeners();
  }

  /// 恢复(间隔从恢复时刻重新起算)。
  void resume() {
    if (_status != IntervalometerStatus.paused) return;
    _status = IntervalometerStatus.running;
    final resume = _resumeSignal;
    _resumeSignal = null;
    _pauseSignal = null;
    if (resume != null && !resume.isCompleted) resume.complete();
    notifyListeners();
  }

  /// 停止:即时(取消在途等待,不等睡眠到期);在途单拍事务落地记账
  /// 后收口。终态 reason = stopped(张数满/自停优先由循环侧收口)。
  void stop() {
    if (!active) return;
    _status = IntervalometerStatus.stopped;
    _stopReason = IntervalStopReason.stopped;
    _finishSignals();
    notifyListeners();
  }

  void _finishSignals() {
    final stop = _stopSignal;
    if (stop != null && !stop.isCompleted) stop.complete();
    final resume = _resumeSignal;
    if (resume != null && !resume.isCompleted) resume.complete();
    _pauseSignal = null;
    _resumeSignal = null;
  }

  /// 等待竞速:注入 delay 到点 / 停止信号 / 暂停信号 —— 暂停与停止
  /// 即时打断,不等睡眠到期。
  Future<_Tick> _wait(Duration d) {
    final stop = _stopSignal!;
    final futures = <Future<_Tick>>[
      _delay(d).then((_) => _Tick.elapsed),
      stop.future.then((_) => _Tick.stopped),
    ];
    final pause = _pauseSignal;
    if (pause != null) futures.add(pause.future.then((_) => _Tick.paused));
    return Future.any(futures);
  }

  /// 暂停门:挂起直到恢复或停止。
  Future<void> _holdPaused() async {
    while (_status == IntervalometerStatus.paused) {
      final resume = _resumeSignal ??= Completer<void>();
      final tick = await Future.any([
        resume.future.then((_) => _Tick.elapsed),
        _stopSignal!.future.then((_) => _Tick.stopped),
      ]);
      if (tick == _Tick.stopped) return;
      // 恢复沿若又立即暂停:顶部 while 重挂
    }
  }

  /// 每拍就绪探测:忙等码语义(session.deviceReady false = 忙)按
  /// [readyPolls]/[readyPollInterval] 有界等待;探针异常放行去拍
  /// (快门事务自证;链路死由宿主停)。暂停/停止即时打断。
  Future<_ReadyResult> _awaitReady() async {
    for (var i = 0; i < readyPolls; i++) {
      if (i > 0) {
        final tick = await _wait(readyPollInterval);
        if (tick == _Tick.paused) return _ReadyResult.paused;
        if (tick == _Tick.stopped) return _ReadyResult.stopped;
      }
      bool ready;
      try {
        ready = await _probeReady();
      } on Exception {
        return _ReadyResult.ready; // 探针不支持/异常不拦拍
      }
      if (ready) return _ReadyResult.ready;
    }
    return _ReadyResult.busyTimeout;
  }

  Future<void> _run(IntervalConfig config) async {
    if (config.firstShotDelay > Duration.zero) {
      final tick = await _wait(config.firstShotDelay);
      if (tick == _Tick.paused) await _holdPaused();
      if (_status != IntervalometerStatus.running) {
        _finish(IntervalStopReason.stopped);
        return;
      }
    }
    while (_status != IntervalometerStatus.stopped) {
      if (_status == IntervalometerStatus.paused) await _holdPaused();
      if (_status != IntervalometerStatus.running) break;

      final ready = await _awaitReady();
      if (ready == _ReadyResult.paused) continue; // 暂停门;恢复后重探
      if (ready == _ReadyResult.stopped) break;

      if (ready == _ReadyResult.ready) {
        final (ok, detail) = await _fireOne();
        _record(
            ok ? IntervalShotOutcome.success : IntervalShotOutcome.failure,
            detail);
      } else {
        _record(IntervalShotOutcome.busyTimeout, '相机持续忙,跳过本拍');
      }

      // 用户停落在单拍事务中:本拍已记账,收口(张数满让位停止意图)。
      if (_status == IntervalometerStatus.stopped) break;

      if (config.shotCount != null && _shots.length >= config.shotCount!) {
        _finish(IntervalStopReason.completed);
        return;
      }
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        _finish(IntervalStopReason.autoStopped);
        return;
      }

      final tick = await _wait(config.interval);
      if (tick == _Tick.paused) continue; // 暂停门;恢复后间隔重新起算
      if (tick == _Tick.stopped) break;
    }
    _finish(IntervalStopReason.stopped);
  }

  /// 单拍事务:异常兜成失败记账(不炸整轮)。
  Future<(bool, String?)> _fireOne() async {
    try {
      return await _shoot();
    } on Exception catch (e) {
      return (false, '$e');
    }
  }

  void _record(IntervalShotOutcome outcome, String? detail) {
    _shots.add(IntervalShotRecord(
        index: _shots.length + 1, outcome: outcome, detail: detail));
    if (outcome == IntervalShotOutcome.success) {
      _consecutiveFailures = 0;
    } else {
      _consecutiveFailures++;
    }
    notifyListeners();
  }

  void _finish(IntervalStopReason reason) {
    if (_status == IntervalometerStatus.stopped) return; // 已收口
    _status = IntervalometerStatus.stopped;
    _stopReason = reason;
    _pauseSignal = null;
    _resumeSignal = null;
    notifyListeners();
  }
}

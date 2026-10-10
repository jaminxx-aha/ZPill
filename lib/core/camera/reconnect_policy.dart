/// 自动重连策略(纯值类,2026-10-10 自动重连功能)。
///
/// 设计移植自 OpenZCine ReconnectBackoff/SessionRecovery(理念可移植,
/// 数值全是其 ZR 现场标定起点,标 verify-on-HW —— 真机标定后只改本文件
/// 的构造默认值,不动结构):
/// - **抖动指数退避**:base×2^(n-1) 封顶,±jitter 随机扩散(纯翻倍会让
///   所有客户端同时醒来重试,给脆弱的相机 AP 造成同步风暴);
///   第 0 次失败**立即重试**(多数断线是一次抖动,下一次 Init 就能清除)。
/// - **busy 慢拍**:InitFail(相机单连接槽位被占)绝不快锤 —— 快锤会
///   双倍打击正在移交的会话槽,把机身 PTP 栈推进楔死态;恒 5s 慢速重试,
///   不耗预算(相机被别人占用是外部状态,等就是了)。
/// - **cameraAbsent 慢拍**:USB 拔插典型时长分钟级,按退避节拍照走、
///   不耗预算,独立上限拍(≈5 分钟)后放弃。
/// - **风暴保护**:DROP = 「恢复循环建立的连接再次断链」(不含首断、
///   不含尝试失败)。周期性外部杀手(他设备探测相机等)会造成秒连秒断
///   无限风暴 —— 这正是把尼康机身 PTP 栈打进「拔电池才能恢复」楔死的
///   模式;stormWindow 内 stormDrops 次 DROP 即粘住暂停,账本只在
///   **操作员动作**(手动 connect/disconnect)时清零,重连成功绝不重置
///   (「成功正是风暴最擅长伪装的东西」)。
///
/// 时钟/随机源全注入:单测零真实挂钟(仓内 ProbeKeepalive 同款口径)。
/// iOS 后台 Dart Timer 挂起 → 恢复循环在后台实际暂停、回前台续跑
/// (退避不烧预算),已知形态,可接受。
library;

import 'dart:math';

/// 恢复拨号失败的分类(决定下一拍节拍与预算消耗)。
enum ReconnectFailureKind {
  /// 普通失败(超时/网络错/会话拒):耗预算,抖动指数退避。
  normal,

  /// 相机忙(InitFail:单连接槽位被 SnapBridge 等占用):恒 5s 慢拍,
  /// 不耗预算。
  busy,

  /// USB 相机未归位(listCameras 空,拔插等待中):退避节拍照走,
  /// 不耗预算,独立上限拍。
  cameraAbsent,
}

final class ReconnectPolicy {
  ReconnectPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    this.jitterRatio = 0.30,
    this.busyRetryDelay = const Duration(seconds: 5),
    this.absentMaxAttempts = 40,
    this.stormWindow = const Duration(seconds: 120),
    this.stormDrops = 3,
    this.settleDelay = const Duration(milliseconds: 1200),
    Random? random,
  }) : _random = random ?? Random();

  /// [ReconnectFailureKind.normal] 的失败预算(verify-on-HW)。
  final int maxAttempts;

  final Duration baseDelay;
  final Duration maxDelay;

  /// 抖动比例(±30%)。
  final double jitterRatio;

  /// busy 拍的固定慢节拍(不耗预算)。
  final Duration busyRetryDelay;

  /// cameraAbsent 拍的上限(退避封顶 8s 一拍 ≈ 5 分钟,verify-on-HW)。
  final int absentMaxAttempts;

  final Duration stormWindow;
  final int stormDrops;

  /// 断链后首拨前的静置:相机拆会话槽需要时间,零静置立刻 Init 正是把
  /// 脆弱重连推入楔死的最后一击(OpenZCine audit 根因;verify-on-HW)。
  final Duration settleDelay;

  final Random _random;

  int _normalFailures = 0;
  int _busyStreak = 0;
  int _absentAttempts = 0;
  final List<DateTime> _drops = [];
  bool _stormPaused = false;

  /// 风暴保护已触发(粘住,直到 [resetLedger])。
  bool get stormPaused => _stormPaused;

  /// 连续 busy 拍数(宿主 ≥2 时换「相机被占用」文案)。
  int get busyStreak => _busyStreak;

  /// 拨号失败后取下一拍延迟;null = 预算耗尽(终态)。
  Duration? nextDelay(ReconnectFailureKind kind) {
    switch (kind) {
      case ReconnectFailureKind.normal:
        _busyStreak = 0;
        _absentAttempts = 0;
        if (_normalFailures >= maxAttempts) return null;
        final delay = _normalFailures == 0
            ? Duration.zero // 多数断线是一次抖动:立即重试
            : _jittered(_scaled(_normalFailures));
        _normalFailures++;
        return delay;
      case ReconnectFailureKind.busy:
        _busyStreak++;
        return busyRetryDelay; // 不耗预算:外部占用,等就是了
      case ReconnectFailureKind.cameraAbsent:
        _busyStreak = 0;
        if (_absentAttempts >= absentMaxAttempts) return null;
        _absentAttempts++;
        // 拔插等待期按退避节拍照走(不 jitter:无风暴风险,拍数可预算)。
        return _scaled(_absentAttempts);
    }
  }

  Duration _scaled(int attempt) {
    final ms = baseDelay.inMilliseconds * (1 << (attempt - 1));
    final capped =
        ms < maxDelay.inMilliseconds ? ms : maxDelay.inMilliseconds;
    return Duration(milliseconds: capped);
  }

  Duration _jittered(Duration d) {
    if (d == Duration.zero || jitterRatio <= 0) return d;
    final spread = (_random.nextDouble() * 2 - 1) * jitterRatio;
    final jittered = (d.inMilliseconds * (1 + spread)).round();
    return Duration(
        milliseconds: jittered.clamp(0, maxDelay.inMilliseconds));
  }

  /// DROP 记账(仅「恢复循环建立的连接再次断链」时调用)。
  void noteDrop(DateTime now) {
    _drops.add(now);
    _drops.removeWhere((t) => now.difference(t) > stormWindow);
    if (_drops.length >= stormDrops) _stormPaused = true;
  }

  /// 操作员动作(手动 connect/disconnect)清零账本;重连成功不清。
  void resetLedger() {
    _normalFailures = 0;
    _busyStreak = 0;
    _absentAttempts = 0;
    _drops.clear();
    _stormPaused = false;
  }
}

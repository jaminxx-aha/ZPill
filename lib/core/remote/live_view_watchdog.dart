/// 取景流看门狗(纯值类,2026-10-10 自动重连 + 看门狗功能)。
///
/// 只管一个新故障域:**事务成功但内容冻结** —— 楔死的机身会持续应答
/// GetLiveViewImageEx 并返回同一张缓存 JPEG,每帧都解码成功、链路读数
/// 一切正常,操作员看着冻结画面直到永远(OpenZCine #283)。活传感器因
/// 噪声永不发出相同字节两次,同一 payload 持续 > [repeatTimeout] 是
/// 重放的确凿证据。
///
/// 「链路静默」与「坏帧连击」**不在本域**:引擎既有失败退避
/// (连续 5 帧失败转 failed,~5s 收口)已覆盖,重复实现反而抢语义。
///
/// 判死后的分级(对相机温柔,OpenZCine 口径):
/// - 冻结时先**探测命令通道**(宿主发 0x90C8 DeviceReady,无副作用):
///   机身忙(写卡/下载后 flush 中)→ **BUSY 保持,不重启** —— 重启
///   取景会把机身菜单摔回拍摄屏,反复重启 = 反复摔操作员的机身菜单
///   (#297);有界窗口([busyHoldTimeout])保证真楔死仍能自愈(#283)。
/// - 不忙 → **重启礼让**:冻结未满 [restartGraceTimeout] 不动用重启 ——
///   操作员进机身菜单/回放同样表现为冻结且命令通道不忙(2026-10-10
///   Zf 实证:4s 即被摁回拍摄屏,菜单浏览不可用),礼让窗内按
///   [busyProbeInterval] 复查,新帧到达即自我纠错;满窗仍冻结才重启
///   取景(0x9202 尽力 + 自愈梯 0x9201)。重启前查 [restartBudgetExhausted],
///   预算耗尽 → 升级整链重连(宿主回调,连接层接管),避免无限重启风暴。
///
/// 健康度从**最后好帧时刻**起算,不是墙钟;自我纠错:真新 payload 到达
/// 即清零重复计数(楔住后自己恢复的机身不会被旧判决压住)。pause 期间
/// 无 inspect 自然豁免。时钟注入:单测零真实挂钟。
library;

import 'package:flutter/foundation.dart' show Uint8List;

/// 看门狗输出的动作信号([LiveViewWatchdog.inspect] 返回 null = 无动作)。
enum LiveViewWatchdogSignal {
  /// 检测到冻结:宿主探测命令通道(0x90C8),结果回填
  /// [LiveViewWatchdog.noteProbeResult]。
  probe,

  /// 命令通道忙:BUSY 保持(不重启),继续取帧等自我恢复。
  busyHold,

  /// BUSY 保持超窗([busyHoldTimeout]):真楔死,重启取景。
  busyHoldExpired,

  /// 命令通道不忙且冻结已满 [LiveViewWatchdog.restartGraceTimeout]:
  /// 重启取景(先查 [LiveViewWatchdog.restartBudgetExhausted])。
  restart,
}

/// 帧签名:FNV-1a,先折叠长度,再均匀采样([sampleCount] 个字节)。
///
/// 采样而非全量哈希:每帧成本恒定(2MB JPEG 与 40KB 同价);不同帧签名
/// 碰撞理论上可能,但需**不间断**碰撞数秒才触发判死,传感器噪声使其
/// 概率趋零。
int liveViewFrameSignature(Uint8List jpeg, {int sampleCount = 512}) {
  var hash = 0x811c9dc5;
  void mix(int byte) {
    hash ^= byte & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }

  mix(jpeg.length);
  mix(jpeg.length >> 8);
  mix(jpeg.length >> 16);
  mix(jpeg.length >> 24);
  final step = jpeg.length < sampleCount ? 1 : jpeg.length ~/ sampleCount;
  for (var i = 0; i < jpeg.length; i += step) {
    mix(jpeg[i]);
  }
  return hash;
}

final class LiveViewWatchdog {
  LiveViewWatchdog({
    this.repeatTimeout = const Duration(seconds: 4),
    this.busyHoldTimeout = const Duration(seconds: 60),
    this.busyProbeInterval = const Duration(seconds: 2),
    this.restartGraceTimeout = const Duration(seconds: 30),
    this.maxRestarts = 3,
    this.restartWindow = const Duration(minutes: 5),
    int Function(Uint8List)? signature,
  }) : _signature = signature ?? liveViewFrameSignature;

  /// 同一 payload 持续超过此时长 = 冻结(重放)(verify-on-HW)。
  final Duration repeatTimeout;

  /// BUSY 保持的有界窗口:超窗按真楔死重启(verify-on-HW)。
  final Duration busyHoldTimeout;

  /// 忙保持期间的探测复查节流(verify-on-HW)。
  final Duration busyProbeInterval;

  /// 重启礼让窗:命令通道不忙的冻结,持续满此时长才动用重启 —— 操作员
  /// 进机身菜单/回放即冻结且不忙,重启会把机身摁回拍摄屏打断操作;
  /// 真楔死晚些自愈无损失(画面反正已停)。verify-on-HW:30s 起步。
  final Duration restartGraceTimeout;

  final int maxRestarts;
  final Duration restartWindow;

  final int Function(Uint8List) _signature;

  bool _probing = false;
  int? _lastSignature;
  DateTime? _signatureFirstSeen;
  DateTime? _busySince;
  DateTime? _lastProbeAt;
  final List<DateTime> _restarts = [];

  /// 每成功帧调用:新签名 → 清零返回 null(self-heal);同签名持续
  /// > [repeatTimeout] → 按内部阶段返回动作信号。
  LiveViewWatchdogSignal? inspect(Uint8List jpeg, DateTime now) {
    final sig = _signature(jpeg);
    if (sig != _lastSignature) {
      // 真新 payload:一切清零(自我纠错)。
      _lastSignature = sig;
      _signatureFirstSeen = now;
      _probing = false;
      _busySince = null;
      _lastProbeAt = null;
      return null;
    }
    // 同签名:从**首次见到该签名**的时刻起算冻结时长。
    final firstSeen = _signatureFirstSeen ??= now;
    final frozenFor = now.difference(firstSeen);
    if (_probing) return null; // 探测在途,宿主回填结果
    if (frozenFor < repeatTimeout) return null;
    if (_busySince != null &&
        frozenFor >= repeatTimeout + busyHoldTimeout) {
      // 忙保持超窗:仍忙也按真楔死收口。
      _busySince = null;
      _lastSignature = null; // 重启后帧必然重新评估
      return LiveViewWatchdogSignal.busyHoldExpired;
    }
    // 探测节拍(忙保持复查与不忙礼让共用):距上次发出探测不足
    // busyProbeInterval 不再发。
    final last = _lastProbeAt;
    if (last != null && now.difference(last) < busyProbeInterval) return null;
    _lastProbeAt = now;
    _probing = true;
    return LiveViewWatchdogSignal.probe;
  }

  /// 当前是否处于冻结态(同一签名持续 ≥ [repeatTimeout];含探测在途/
  /// 忙保持/礼让期)。宿主在新帧到达时据此维护展示态:非冻结的新内容 =
  /// BUSY 保持的自我恢复,横幅就该撤了。
  bool frozen(DateTime now) {
    final firstSeen = _signatureFirstSeen;
    return _lastSignature != null &&
        firstSeen != null &&
        now.difference(firstSeen) >= repeatTimeout;
  }

  /// 宿主把命令通道探测结果回填(busy = DeviceReady 回忙/异常),返回
  /// 下一动作:忙 → [LiveViewWatchdogSignal.busyHold](保持不重启);
  /// 不忙且冻结已满 [restartGraceTimeout] → [LiveViewWatchdogSignal.restart];
  /// 不忙但未满礼让窗 → null(礼让等待:多为操作员在机身菜单/回放,
  /// 下一帧按节拍复查,新帧到达即自我纠错)。
  LiveViewWatchdogSignal? noteProbeResult(
      {required bool busy, required DateTime now}) {
    _probing = false;
    if (busy) {
      _busySince ??= now;
      return LiveViewWatchdogSignal.busyHold;
    }
    final firstSeen = _signatureFirstSeen;
    if (firstSeen == null ||
        now.difference(firstSeen) >= restartGraceTimeout) {
      _lastSignature = null; // 重启后帧必然重新评估
      return LiveViewWatchdogSignal.restart;
    }
    return null; // 礼让等待,不动用重启
  }

  /// 宿主完成一次取景流重启后调用:预算记账。
  void noteRestarted(DateTime now) {
    _restarts.add(now);
    _restarts.removeWhere((t) => now.difference(t) > restartWindow);
  }

  /// 重启预算耗尽([restartWindow] 内已重启 [maxRestarts] 次):
  /// 宿主收到 restart/busyHoldExpired 信号时先查本方法,耗尽则不再
  /// 重启、升级整链重连(避免无限重启风暴)。
  bool get restartBudgetExhausted => _restarts.length >= maxRestarts;

  /// stop/start/新连接/升级后全清。
  void reset() {
    _probing = false;
    _lastSignature = null;
    _signatureFirstSeen = null;
    _busySince = null;
    _lastProbeAt = null;
    _restarts.clear();
  }
}

/// 实例心跳看门狗(2026-10-21):升级安装时 iOS 27 beta 不终止运行中
/// 的旧实例(实测一日累积 4 个僵尸 —— 互相扫描踩台、抢相机,面板发现
/// 全废),而 App 间/devicectl 均无杀进程通道。解法 = 心跳仲裁:各实例
/// 在盘上写 {token, startedAtMs, beatMs},读到**新鲜**他者心跳且自身
/// startedAt 更旧的一方 exit(0) 自我了断(新实例胜出 —— 僵尸必是旧代
/// 码旧实例);beat 过期(他者已死/后台冻结无活动)则覆盖接管。
/// 纯 Dart 文件 IO(platform 层;core 零 IO 约定不破)。存量僵尸跑旧
/// 代码不认识协议,需一次重启清场,此后升级安装自愈。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 仲裁判定(纯函数,可测):他者心跳新鲜且**启动比我晚** → 我是旧实
/// 例(僵尸),该退。同 token(自己写的)/beat 过期(他者已死/后台冻
/// 结无活动)/他者启动更早(他才是该退的旧实例,他自己会退)→ 不退。
bool instanceShouldExit({
  required String myToken,
  required int myStartedAtMs,
  required String? otherJson,
  required int nowMs,
  int freshWindowMs = 10000,
}) {
  if (otherJson == null || otherJson.isEmpty) return false;
  final Map<String, Object?> other;
  try {
    other = jsonDecode(otherJson) as Map<String, Object?>;
  } on FormatException {
    return false; // 损坏行当无他者
  }
  final otherToken = other['token'];
  final otherStarted = other['startedAtMs'];
  final otherBeat = other['beatMs'];
  if (otherToken is! String || otherToken == myToken) return false;
  if (otherStarted is! int || otherBeat is! int) return false;
  if (nowMs - otherBeat > freshWindowMs) return false; // 他者已死/冻结
  return otherStarted > myStartedAtMs; // 他者更新 → 我是旧实例 → 我退
}

/// 心跳记录序列化(单行 JSON,防损坏按FormatException当无他者)。
String instanceHeartbeatJson({
  required String token,
  required int startedAtMs,
  required int beatMs,
}) =>
    jsonEncode(
        {'token': token, 'startedAtMs': startedAtMs, 'beatMs': beatMs});

/// 看门狗运行体:周期写心跳 + 每拍仲裁。退出动作经 [onExit] 注入
/// (生产 = AppLog 留痕 + exit(0);测试注入记录器)。
final class InstanceWatch {
  InstanceWatch({
    required File lockFile,
    this.period = const Duration(seconds: 3),
    this.freshWindowMs = 10000,
    int Function()? now,
    void Function(String reason)? onExit,
  })  : _lockFile = lockFile,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _onExit = onExit;

  final File _lockFile;
  final Duration period;
  final int freshWindowMs;
  final int Function() _now;
  final void Function(String reason)? _onExit;
  late final String _token =
      '${DateTime.now().microsecondsSinceEpoch}-${_now()}'; // 启动期生成,进程内恒定
  late final int _startedAtMs = _now();
  Timer? _timer;
  bool _armed = false;

  /// 自身心跳(启动时刻):迟到仲裁的基准。
  int get startedAtMs => _startedAtMs;

  void start() {
    if (_armed) return;
    _armed = true;
    _beat();
    _timer = Timer.periodic(period, (_) => _beat());
  }

  /// 停拍(驱动停沿):Timer 取消 —— 测试的「无 pending Timer」断言不炸。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _armed = false;
  }

  void _beat() {
    final nowMs = _now();
    try {
      final shouldExit = instanceShouldExit(
        myToken: _token,
        myStartedAtMs: _startedAtMs,
        otherJson: _lockFile.existsSync() ? _lockFile.readAsStringSync() : null,
        nowMs: nowMs,
        freshWindowMs: freshWindowMs,
      );
      if (shouldExit) {
        _onExit?.call('发现更新实例在跑(fresh heartbeat),本实例退出让位');
        exit(0);
      }
      _lockFile.writeAsStringSync(
          instanceHeartbeatJson(
              token: _token, startedAtMs: _startedAtMs, beatMs: nowMs),
          flush: true);
    } on Exception {
      // 盘满/IO 异常:跳过一拍(仲裁失效的最坏结果 = 僵尸回潮,可容忍)
    }
  }
}

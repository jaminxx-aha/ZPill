/// 心跳保活(TODO.md §二 P2 / 实现注意事项 3)。
///
/// 铁律:心跳必须**真实收发** —— ProbeRequest(13) 发出后,
/// 必须收到 ProbeResponse(14) 才清零失败计数;
/// "只计数不清零"的心跳等于定时断线。
///
/// 实现为 delay 注入的串行循环(非 Timer.periodic):间隔从上一次
/// ping 落定时刻起算,测试注入 [delay] 即可全程驱动,不留真实挂钟定时器。
library;

import 'dart:async';

final class ProbeKeepalive {
  ProbeKeepalive({
    required this.ping,
    required this.onDead,
    this.interval = const Duration(seconds: 15),
    this.maxMissed = 3,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  /// 发送 ProbeRequest 并等待 ProbeResponse;真实收到返回 true。
  /// 实现方必须自带超时(链路死时不得永久挂起)。
  final Future<bool> Function() ping;

  /// 连续 [maxMissed] 次未收到响应时回调(触发断开清理)。
  /// 只回调一次,之后循环停止。
  final void Function() onDead;

  final Duration interval;

  /// 连续未响应上限,达到即判死链。
  final int maxMissed;

  final Future<void> Function(Duration) _delay;

  /// 循环世代:stop() 递增并清 _running,迟到的旧迭代在下一个检查点退出。
  int _runId = 0;
  bool _running = false;
  int _missed = 0;

  bool get isRunning => _running;

  /// 启动心跳(幂等):立即返回,循环在后台自转。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _missed = 0;
    final run = ++_runId;
    while (_running && run == _runId) {
      await _delay(interval);
      if (!_running || run != _runId) return;
      var ok = false;
      try {
        ok = await ping();
      } on Object {
        ok = false; // ping 抛异常视同无响应
      }
      if (!_running || run != _runId) return;
      if (ok) {
        _missed = 0;
      } else if (++_missed >= maxMissed) {
        _running = false;
        onDead();
        return;
      }
    }
  }

  /// 停止心跳(幂等):在途 ping 的结果不再计数。
  void stop() {
    _running = false;
    _runId++;
  }
}

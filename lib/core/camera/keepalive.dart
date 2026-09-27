/// 心跳保活(TODO.md §二 P2 / 实现注意事项 3)。
///
/// 铁律:心跳必须**真实收发** —— ProbeRequest(13) 发出后,
/// 必须收到 ProbeResponse(14) 才清零失败计数;
/// "只计数不清零"的心跳等于定时断线。
library;

final class ProbeKeepalive {
  ProbeKeepalive({
    required this.ping,
    required this.onDead,
    this.interval = const Duration(seconds: 15),
    this.maxMissed = 3,
  });

  /// 发送 ProbeRequest 并等待 ProbeResponse;真实收到返回 true。
  final Future<bool> Function() ping;

  /// 连续 [maxMissed] 次未收到响应时回调(触发断开清理)。
  final void Function() onDead;

  final Duration interval;
  final int maxMissed;

  /// TODO(P2): start/stop —— Timer 周期调 [ping];
  /// 成功清零未响应计数,失败自增,达 [maxMissed] 调 [onDead] 并 stop。
  void start() => throw UnimplementedError();

  void stop() => throw UnimplementedError();
}

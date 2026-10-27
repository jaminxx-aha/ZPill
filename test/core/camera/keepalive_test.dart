import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/camera/keepalive.dart';

/// 手动泵:每次 call 记一个 Completer,pump 按序解决,驱动串行循环。
final class FakeDelay {
  final pending = <Completer<void>>[];
  final requested = <Duration>[];

  Future<void> call(Duration d) {
    requested.add(d);
    final c = Completer<void>();
    pending.add(c);
    return c.future;
  }

  Future<void> pump() async {
    expect(pending, isNotEmpty, reason: '循环未在等待 delay(已停?)');
    pending.removeAt(0).complete();
    await Future<void>.value();
    await Future<void>.value();
  }

  /// stop 后循环可能仍挂在最后一个未完成 delay 上:逐个排空让它退出。
  Future<void> drain() async {
    while (pending.isNotEmpty) {
      await pump();
    }
  }
}

void main() {
  test('成功清零:交替失败不误判,连续达上限才死', () async {
    final delay = FakeDelay();
    final results = <bool>[false, false, true, false, false];
    var calls = 0;
    var dead = 0;
    final k = ProbeKeepalive(
      ping: () async => results[calls++],
      onDead: () => dead++,
      interval: const Duration(seconds: 15),
      maxMissed: 3,
      delay: delay.call,
    );
    final running = k.start();
    for (var i = 0; i < results.length; i++) {
      await delay.pump();
    }
    expect(calls, 5);
    expect(dead, 0, reason: '未连续 3 次失败不应判死');
    expect(k.isRunning, isTrue);
    k.stop();
    await delay.drain();
    await running;
    expect(dead, 0);
  });

  test('连续 maxMissed 次无响应 → onDead 恰一次并停转', () async {
    final delay = FakeDelay();
    var calls = 0;
    var dead = 0;
    final k = ProbeKeepalive(
      ping: () async {
        calls++;
        return false;
      },
      onDead: () => dead++,
      maxMissed: 3,
      delay: delay.call,
    );
    final running = k.start();
    await delay.pump();
    await delay.pump();
    await delay.pump();
    expect(calls, 3);
    expect(dead, 1);
    expect(k.isRunning, isFalse);
    expect(delay.pending, isEmpty, reason: '判死后不得再排队下一拍');
    await running;
    expect(dead, 1, reason: 'onDead 只回调一次');
  });

  test('ping 抛异常按无响应计', () async {
    final delay = FakeDelay();
    var dead = 0;
    final k = ProbeKeepalive(
      ping: () async => throw TimeoutException('链路死'),
      onDead: () => dead++,
      maxMissed: 2,
      delay: delay.call,
    );
    final running = k.start();
    await delay.pump();
    await delay.pump();
    expect(dead, 1);
    k.stop();
    await running;
  });

  test('stop 后循环退出,迟到泵不触发 ping', () async {
    final delay = FakeDelay();
    var calls = 0;
    final k = ProbeKeepalive(
      ping: () async {
        calls++;
        return true;
      },
      onDead: () => fail('stop 不应判死'),
      delay: delay.call,
    );
    final running = k.start();
    await delay.pump(); // ping 1
    expect(calls, 1);
    k.stop();
    // 循环在下一个 delay 处排队后停止:该次 delay 的迟到完成不得再 ping
    await delay.drain();
    expect(calls, 1, reason: 'stop 后不得再 ping');
    expect(k.isRunning, isFalse);
    await running;
  });

  test('start 幂等:重复 start 不另起循环', () async {
    final delay = FakeDelay();
    var calls = 0;
    final k = ProbeKeepalive(
      ping: () async {
        calls++;
        return true;
      },
      onDead: () => fail('不应判死'),
      delay: delay.call,
    );
    final running = k.start();
    unawaited(k.start()); // 幂等:直接返回
    await delay.pump();
    expect(calls, 1, reason: '一拍只 ping 一次');
    k.stop();
    await delay.drain();
    await running;
  });

  test('stop 后可重启:新循环照常运转', () async {
    final delay = FakeDelay();
    var calls = 0;
    final k = ProbeKeepalive(
      ping: () async {
        calls++;
        return true;
      },
      onDead: () => fail('不应判死'),
      delay: delay.call,
    );
    var running = k.start();
    await delay.pump();
    expect(calls, 1);
    k.stop();
    await delay.drain();
    await running;

    running = k.start();
    await delay.pump();
    expect(calls, 2, reason: '重启后恢复心跳');
    k.stop();
    await delay.drain();
    await running;
  });
}

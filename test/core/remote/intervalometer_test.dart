import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/remote/intervalometer.dart';

/// 假时钟:记录每次等待时长,手动放行(同 controller 测试 _GatedDelay
/// 口径;被停止竞速废掉的门无副作用,release 照常走)。
final class _FakeDelay {
  final waits = <Duration>[];
  final _gates = Queue<Completer<void>>();

  Future<void> call(Duration d) {
    waits.add(d);
    final c = Completer<void>();
    _gates.add(c);
    return c.future;
  }

  void release() => _gates.removeFirst().complete();

  void releaseAll() {
    while (_gates.isNotEmpty) {
      _gates.removeFirst().complete();
    }
  }

  int get pending => _gates.length;
}

void main() {
  late _FakeDelay delay;
  var probeResults = <bool>[];
  var probeThrows = false;
  var probeCalls = 0;
  var shootOk = true;
  var shootCalls = 0;
  String? shootDetail;

  late Intervalometer iv;

  /// 就绪探测脚本:耗尽后恒取末值(脚本短于预算时)。
  Future<bool> probe() async {
    probeCalls++;
    if (probeThrows) throw Exception('探针异常');
    if (probeResults.isEmpty) return true;
    if (probeResults.length == 1) return probeResults.first;
    return probeResults.length > probeCalls - 1
        ? probeResults[probeCalls - 1]
        : probeResults.last;
  }

  setUp(() {
    delay = _FakeDelay();
    probeResults = [];
    probeThrows = false;
    probeCalls = 0;
    shootOk = true;
    shootCalls = 0;
    shootDetail = null;
    iv = Intervalometer(
      delay: delay.call,
      probeReady: probe,
      shoot: () async {
        shootCalls++;
        return (shootOk, shootDetail);
      },
    )..readyPolls = 2; // 拨小:忙超时场景脚本短
  });

  test('正常 N 拍:到点即拍,末拍后不再等间隔,reason=completed', () async {
    iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 3));
    await pumpEventQueue();
    expect(iv.status, IntervalometerStatus.running);
    expect(iv.attempted, 1, reason: '首轮无首拍延迟,探就绪即拍');
    expect(delay.pending, 1, reason: '拍后进入 5s 间隔等待');

    delay.release(); // 第 2 拍到点
    await pumpEventQueue();
    expect(iv.attempted, 2);

    delay.release(); // 第 3 拍到点
    await pumpEventQueue();
    expect(iv.attempted, 3);

    await iv.done;
    expect(iv.status, IntervalometerStatus.stopped);
    expect(iv.stopReason, IntervalStopReason.completed);
    expect(iv.taken, 3);
    expect(iv.failed, 0);
    expect(delay.waits, const [Duration(seconds: 5), Duration(seconds: 5)],
        reason: 'N 拍只有 N-1 次间隔等待');
    expect(shootCalls, 3);
  });

  test('忙超时跳拍:探测预算耗尽不发快门,记账后继续轮(下一拍成功)',
      () async {
    // readyPolls=2:第 1 拍两次探测均忙 → 跳拍;第 2 拍首次探测即就绪
    probeResults = [false, false, true];
    iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 2));
    await pumpEventQueue();
    // readyPolls=2:探 2 次、中间等 1 拍 → 忙超时记账
    delay.release(); // 300ms 探测节拍
    await pumpEventQueue();
    expect(iv.lastShot?.outcome, IntervalShotOutcome.busyTimeout);
    expect(shootCalls, 0, reason: '忙超时未发快门');
    expect(iv.attempted, 1);

    delay.release(); // 间隔到点 → 第 2 拍
    await pumpEventQueue();
    expect(shootCalls, 1);
    await iv.done;
    expect(iv.stopReason, IntervalStopReason.completed);
    expect(iv.taken, 1);
    expect(iv.failed, 1);
    expect(iv.shots.map((s) => s.outcome), [
      IntervalShotOutcome.busyTimeout,
      IntervalShotOutcome.success,
    ]);
  });

  test('失败跳拍:单拍失败不炸整轮,成功清连续计数', () async {
    shootOk = false;
    shootDetail = '快门释放失败:被拒';
    iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 3));
    await pumpEventQueue();
    expect(iv.lastShot?.outcome, IntervalShotOutcome.failure);
    expect(iv.lastShot?.detail, '快门释放失败:被拒');
    expect(iv.consecutiveFailures, 1);

    shootOk = true; // 第 2 拍起恢复
    delay.release(); // 第 2 拍
    await pumpEventQueue();
    expect(iv.consecutiveFailures, 0, reason: '成功清零连续失败');

    delay.release(); // 第 3 拍
    await pumpEventQueue();
    await iv.done;
    expect(iv.stopReason, IntervalStopReason.completed);
    expect(iv.taken, 2);
    expect(iv.failed, 1);
  });

  test('连续失败自停:默认 3 拍不成即停,reason=autoStopped', () async {
    shootOk = false;
    final started = iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 10));
    expect(started, isTrue);
    await pumpEventQueue();
    delay.release(); // 第 2 拍
    await pumpEventQueue();
    delay.release(); // 第 3 拍
    await pumpEventQueue();
    await iv.done;
    expect(iv.status, IntervalometerStatus.stopped);
    expect(iv.stopReason, IntervalStopReason.autoStopped);
    expect(iv.attempted, 3, reason: '第 3 次连续失败即停,不再等间隔');
    expect(iv.taken, 0);
    expect(delay.pending, 0, reason: '自停后无在途等待');
  });

  test('停止即时:间隔等待在途(门未放行)即停,不再发快门', () async {
    iv.start(IntervalConfig(interval: const Duration(minutes: 10)));
    await pumpEventQueue();
    expect(iv.attempted, 1);
    expect(delay.pending, 1, reason: '10 分钟间隔等待中');

    iv.stop(); // 门未放行 —— 停止信号竞速胜出
    await iv.done;
    expect(iv.status, IntervalometerStatus.stopped);
    expect(iv.stopReason, IntervalStopReason.stopped);
    expect(shootCalls, 1, reason: '停后再无快门');
    expect(delay.pending, 1, reason: '假时钟门保持未放行(证明不等睡眠)');
  });

  test('暂停/恢复:间隔等待即时挂起,恢复后间隔重新起算;暂停期零快门',
      () async {
    iv.start(IntervalConfig(interval: const Duration(seconds: 5)));
    await pumpEventQueue();
    expect(iv.attempted, 1);

    iv.pause();
    await pumpEventQueue();
    expect(iv.status, IntervalometerStatus.paused);
    expect(delay.pending, 1, reason: '被暂停打断的等待门仍挂(已废)');
    expect(iv.attempted, 1, reason: '暂停期不拍');

    iv.resume();
    await pumpEventQueue();
    expect(iv.status, IntervalometerStatus.running);
    expect(delay.waits.last, const Duration(seconds: 5),
        reason: '恢复后重新起算 5s 间隔');

    delay.releaseAll(); // 废门 + 新间隔门一起放行
    await pumpEventQueue();
    expect(iv.attempted, 2, reason: '恢复满一个间隔后拍第 2 张');
    iv.stop();
    await iv.done;
    expect(shootCalls, 2);
  });

  test('暂停中停止:暂停门即时解挂收口', () async {
    iv.start(IntervalConfig(interval: const Duration(seconds: 5)));
    await pumpEventQueue();
    iv.pause();
    await pumpEventQueue();
    iv.stop(); // 暂停门挂着 —— 停止信号解挂
    await iv.done;
    expect(iv.status, IntervalometerStatus.stopped);
    expect(iv.attempted, 1);
  });

  test('首拍延迟:先等延迟再拍', () async {
    iv.start(IntervalConfig(
      interval: const Duration(seconds: 5),
      shotCount: 1,
      firstShotDelay: const Duration(seconds: 3),
    ));
    await pumpEventQueue();
    expect(iv.attempted, 0, reason: '首拍延迟中,未拍');
    expect(delay.waits, const [Duration(seconds: 3)]);
    delay.release();
    await pumpEventQueue();
    await iv.done;
    expect(iv.taken, 1);
    expect(iv.stopReason, IntervalStopReason.completed);
  });

  test('无限张数:null 拍到停止为止', () async {
    iv.start(IntervalConfig(interval: const Duration(seconds: 1)));
    await pumpEventQueue();
    for (var i = 2; i <= 4; i++) {
      delay.release();
      await pumpEventQueue();
      expect(iv.attempted, i);
    }
    iv.stop();
    await iv.done;
    expect(iv.taken, 4);
    expect(iv.stopReason, IntervalStopReason.stopped);
  });

  test('探针异常:放行去拍(快门事务自证),不按忙超时记账', () async {
    probeThrows = true;
    iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 1));
    await pumpEventQueue();
    await iv.done;
    expect(shootCalls, 1);
    expect(iv.taken, 1, reason: '探针异常不是快门失败');
  });

  test('参数钳制:间隔 1s..1h;张数 <1 记 1,null 保持无限', () {
    final low = IntervalConfig(interval: Duration.zero, shotCount: 0);
    expect(low.interval, const Duration(seconds: 1));
    expect(low.shotCount, 1);
    final high = IntervalConfig(interval: const Duration(hours: 2));
    expect(high.interval, const Duration(hours: 1));
    expect(high.shotCount, isNull);
    final neg = IntervalConfig(
        interval: const Duration(seconds: 5),
        firstShotDelay: const Duration(seconds: -3));
    expect(neg.firstShotDelay, Duration.zero);
  });

  test('启动/停止状态机:运行中拒绝再启;停止后重开计数重置', () async {
    iv.start(IntervalConfig(interval: const Duration(seconds: 5)));
    await pumpEventQueue();
    expect(
        iv.start(IntervalConfig(interval: const Duration(seconds: 1))),
        isFalse,
        reason: '运行中拒绝再启');
    iv.pause();
    expect(iv.start(IntervalConfig(interval: const Duration(seconds: 1))),
        isFalse,
        reason: '暂停中也拒绝');
    iv.stop();
    await iv.done;
    expect(iv.status, IntervalometerStatus.stopped);

    // 重开:上一轮计数清零
    delay.releaseAll();
    final ok = iv.start(IntervalConfig(
        interval: const Duration(seconds: 5), shotCount: 1));
    expect(ok, isTrue);
    await pumpEventQueue();
    await iv.done;
    expect(iv.attempted, 1);
    expect(iv.taken, 1);
  });

  test('停止落在单拍事务中:本拍照常记账后收口', () async {
    final slowShoot = Completer<void>();
    final iv2 = Intervalometer(
      delay: delay.call,
      probeReady: probe,
      shoot: () async {
        await slowShoot.future;
        return (true, null);
      },
    );
    iv2.start(IntervalConfig(interval: const Duration(seconds: 5)));
    await pumpEventQueue();
    expect(iv2.status, IntervalometerStatus.running);
    iv2.stop(); // 单拍在途停止
    slowShoot.complete(); // 事务落地
    await iv2.done;
    expect(iv2.status, IntervalometerStatus.stopped);
    expect(iv2.taken, 1, reason: '在途快门已发,落账不弃');
    expect(iv2.stopReason, IntervalStopReason.stopped);
  });

  test('就绪探测中暂停:恢复后重探再拍', () async {
    probeResults = [false, false]; // 恒忙 → 拨小预算下会忙超时
    iv.start(IntervalConfig(interval: const Duration(seconds: 5)));
    await pumpEventQueue();
    // 探测节拍等待中暂停
    iv.pause();
    await pumpEventQueue();
    expect(iv.status, IntervalometerStatus.paused);
    expect(iv.attempted, 0, reason: '尚未记账(探测被暂停打断)');
    probeResults = [true]; // 恢复后探就绪
    iv.resume();
    delay.releaseAll(); // 探测节拍门 + 废门
    await pumpEventQueue();
    expect(iv.attempted, 1);
    iv.stop();
    await iv.done;
  });
}

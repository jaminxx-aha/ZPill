/// 后台保活协调器与通道调度(持有式申请契约,2026-10-15):
/// 纯 Dart 协调器的并集/换装/最后释放/幂等/失效重申决策 +
/// MethodChannel 层的通道调用序列与降级(契约见
/// lib/platform/background_transfer.dart)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/platform/background_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundLeaseCoordinator(纯 Dart):', () {
    test('无→申请:首个持有者产出 apply', () {
      final c = BackgroundLeaseCoordinator();
      expect(c.isHolding, isFalse);
      final plan =
          c.hold('transfer', const {BgMode.dataTransfer});
      expect(plan.action, BackgroundTaskAction.apply);
      expect(plan.modes, {BgMode.dataTransfer});
      expect(c.isHolding, isTrue);
      expect(c.effectiveModes, {BgMode.dataTransfer});
    });

    test('重复申请幂等:同集再 hold 不过通道', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      expect(
          c.hold('transfer', const {BgMode.dataTransfer}).action,
          BackgroundTaskAction.none);
      // 换 tag 同集:并集未变,同样幂等
      expect(
          c.hold('other', const {BgMode.dataTransfer}).action,
          BackgroundTaskAction.none);
    });

    test('并集 + 集变→换装:新持有者并入新模式', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      final plan = c.hold(
          'ble', const {BgMode.bluetoothInteraction, BgMode.location});
      expect(plan.action, BackgroundTaskAction.apply);
      expect(plan.modes, {
        BgMode.dataTransfer,
        BgMode.bluetoothInteraction,
        BgMode.location,
      });
    });

    test('部分释放→换装(缩集),不误发 stop', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      c.hold('ble', const {BgMode.bluetoothInteraction});
      final plan = c.release('transfer');
      expect(plan.action, BackgroundTaskAction.apply);
      expect(plan.modes, {BgMode.bluetoothInteraction});
      expect(c.isHolding, isTrue);
    });

    test('最后释放→stop', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('ble', const {BgMode.bluetoothInteraction});
      final plan = c.release('ble');
      expect(plan.action, BackgroundTaskAction.stop);
      expect(plan.modes, isEmpty);
      expect(c.isHolding, isFalse);
      expect(c.effectiveModes, isEmpty);
    });

    test('释放未持有者:幂等 none', () {
      final c = BackgroundLeaseCoordinator();
      expect(c.release('ghost').action, BackgroundTaskAction.none);
      c.hold('transfer', const {BgMode.dataTransfer});
      expect(c.release('ghost').action, BackgroundTaskAction.none);
      expect(c.isHolding, isTrue);
    });

    test('空集 hold 等价释放', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      expect(c.hold('transfer', const <BgMode>{}).action,
          BackgroundTaskAction.stop);
      expect(c.isHolding, isFalse);
    });

    test('stop 后再 hold:重新申请', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      c.release('transfer');
      final plan = c.hold('ble', const {BgMode.bluetoothInteraction});
      expect(plan.action, BackgroundTaskAction.apply);
      expect(plan.modes, {BgMode.bluetoothInteraction});
    });

    test('invalidate 后 reconcile:仍持有的申请重发(前台重申路)', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      c.hold('ble', const {BgMode.bluetoothInteraction});
      c.invalidate();
      expect(c.isHolding, isFalse);
      final plan = c.reconcile();
      expect(plan.action, BackgroundTaskAction.apply);
      expect(plan.modes,
          {BgMode.dataTransfer, BgMode.bluetoothInteraction});
    });

    test('invalidate 后无持有者:reconcile 静默', () {
      final c = BackgroundLeaseCoordinator();
      c.hold('transfer', const {BgMode.dataTransfer});
      c.release('transfer');
      c.invalidate();
      expect(c.reconcile().action, BackgroundTaskAction.none);
    });
  });

  group('MethodChannelBackgroundScheduler(nikonpill/bg):', () {
    late List<MethodCall> calls;
    late MethodChannelBackgroundScheduler scheduler;

    void mockChannel({bool missing = false}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              MethodChannelBackgroundScheduler.channel, (call) async {
        if (missing) {
          throw MissingPluginException();
        }
        calls.add(call);
        return null;
      });
    }

    setUp(() {
      calls = [];
      scheduler = MethodChannelBackgroundScheduler();
      mockChannel();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              MethodChannelBackgroundScheduler.channel, null);
    });

    test('首个持有:ensureRunning 携 modes 数组', () async {
      await scheduler.ensureRunning(
          'transfer', const {BgMode.dataTransfer});
      expect(calls, hasLength(1));
      expect(calls.single.method, 'ensureRunning');
      expect(
          (calls.single.arguments
              as Map<Object?, Object?>)['modes'] as List<Object?>,
          ['dataTransfer']);
    });

    test('并集换装:第二持有者触发一次携并集的 ensureRunning', () async {
      await scheduler.ensureRunning(
          'transfer', const {BgMode.dataTransfer});
      await scheduler.ensureRunning(
          'ble', const {BgMode.bluetoothInteraction, BgMode.location});
      expect(calls, hasLength(2));
      final second =
          (calls[1].arguments as Map<Object?, Object?>)['modes'] as List<Object?>;
      expect(second, unorderedEquals(['dataTransfer', 'bluetoothInteraction', 'location']));
    });

    test('重复申请不过通道;部分释放换装;最后释放才 stop', () async {
      await scheduler.ensureRunning(
          'transfer', const {BgMode.dataTransfer});
      await scheduler.ensureRunning(
          'ble', const {BgMode.bluetoothInteraction});
      expect(calls, hasLength(2));
      // 同集重复:无通道动作
      await scheduler.ensureRunning(
          'transfer', const {BgMode.dataTransfer});
      // 未持有者释放:无通道动作
      await scheduler.stop('ghost');
      expect(calls, hasLength(2));
      // 部分释放:换装为 ble 模式(不是 stop)
      await scheduler.stop('transfer');
      expect(calls, hasLength(3));
      expect(calls[2].method, 'ensureRunning');
      expect(
          (calls[2].arguments
              as Map<Object?, Object?>)['modes'] as List<Object?>,
          ['bluetoothInteraction']);
      // 最后释放:stop
      await scheduler.stop('ble');
      expect(calls, hasLength(4));
      expect(calls.last.method, 'stop');
      expect(calls.last.arguments, isNull);
    });

    test('reassert:仍持有时按并集重发(静默吊销重申请路)', () async {
      await scheduler.ensureRunning(
          'ble', const {BgMode.bluetoothInteraction, BgMode.location});
      expect(calls, hasLength(1));
      await scheduler.reassert();
      expect(calls, hasLength(2));
      expect(calls[1].method, 'ensureRunning');
      expect(
          (calls[1].arguments
              as Map<Object?, Object?>)['modes'] as List<Object?>,
          unorderedEquals(['bluetoothInteraction', 'location']));
    });

    test('reassert:无持有时静默', () async {
      await scheduler.reassert();
      expect(calls, isEmpty);
    });

    test('旧端 MissingPluginException:ensure/stop/reassert 均不炸', () async {
      mockChannel(missing: true);
      await scheduler.ensureRunning(
          'transfer', const {BgMode.dataTransfer});
      await scheduler.stop('transfer');
      await scheduler.reassert();
      // 不抛即通过;stop 后 reassert 无持有者,本就静默
    });
  });
}

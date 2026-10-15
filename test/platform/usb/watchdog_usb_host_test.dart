import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/platform/usb/usb_host.dart';
import 'package:nikon_pill/platform/usb/watchdog_usb_host.dart';

const _dev = UsbDeviceHandle(
  vendorId: 0x04B0,
  productId: 0x0453,
  identifier: '1-2',
);

/// 可编排的内层通道:读/写可挂起、可抛错,设备表可变(拔出轮询用)。
final class _FakeInner implements UsbHostChannel {
  _FakeInner();

  List<UsbDeviceHandle> cameras = [_dev];
  int openCalls = 0;
  int closeCalls = 0;

  /// bulkRead 行为:null=正常返回;否则为抛出的异常(挂起用 never-complete)。
  Future<Uint8List> Function(int maxLen)? bulkReadImpl;
  Future<void> Function(Uint8List bytes)? bulkOutImpl;

  /// drainIn 调用计数;drainImpl=null 正常返回,否则执行注入行为
  /// (挂起用 never-complete)。
  int drainCalls = 0;
  Future<void> Function()? drainImpl;

  @override
  Future<List<UsbDeviceHandle>> listCameras() async => cameras;

  @override
  Future<void> open(UsbDeviceHandle device) async => openCalls++;

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> bulkOut(Uint8List bytes) =>
      bulkOutImpl?.call(bytes) ?? Future.value();

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) =>
      bulkReadImpl?.call(maxLen) ?? Future.value(Uint8List(4));

  @override
  Future<void> drainIn() {
    drainCalls++;
    return drainImpl?.call() ?? Future.value();
  }

  @override
  Stream<Uint8List> get interruptEvents => const Stream.empty();

  @override
  Stream<String> get breakages => const Stream.empty();
}

WatchdogUsbHostChannel _watchdog(_FakeInner inner) => WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      drainWatchdogMs: 30,
      detachPollInterval: null,
    );

void main() {
  test('bulkRead 挂起:宽限期后 TimeoutException + breakages 广播', () async {
    final inner = _FakeInner();
    inner.bulkReadImpl = (_) => Completer<Uint8List>().future;
    final wd = _watchdog(inner);
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await expectLater(
      wd.bulkRead(512, timeoutMs: 15),
      throwsA(isA<TimeoutException>()),
    );
    // 广播流事件派发是微任务(见 memory:thumbnail 测试同坑),泵完再断言
    await pumpEventQueue();
    expect(reasons, hasLength(1));
    expect(reasons.single, contains('相机已拔出或无响应'));
  });

  test('断链毒化:后续收发秒抛且不再等超时;open() 解除', () async {
    final inner = _FakeInner();
    inner.bulkReadImpl = (_) => Completer<Uint8List>().future;
    final wd = _watchdog(inner);

    await expectLater(
        wd.bulkRead(512, timeoutMs: 15), throwsA(isA<TimeoutException>()));
    // 秒抛:0ms 超时也会立刻失败,不再挂一遍宽限。
    final sw = Stopwatch()..start();
    await expectLater(
        wd.bulkRead(512, timeoutMs: 15000), throwsA(isA<TimeoutException>()));
    expect(sw.elapsedMilliseconds < 30, isTrue);
    await expectLater(
        wd.bulkOut(Uint8List(4)), throwsA(isA<TimeoutException>()));

    // 恢复透传:撤销挂起行为后再验
    inner.bulkReadImpl = null;
    inner.bulkOutImpl = null;
    // 重开链路:解除毒化,收发恢复透传。
    await wd.open(_dev);
    expect(await wd.bulkRead(512, timeoutMs: 15), hasLength(4));
    await wd.bulkOut(Uint8List(4));
  });

  test('native 窗口超时原样透传,不断链', () async {
    final inner = _FakeInner();
    inner.bulkReadImpl = (_) =>
        throw TimeoutException('bulkRead 15000ms 内未收到数据');
    final wd = _watchdog(inner);
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await expectLater(
        wd.bulkRead(512, timeoutMs: 15), throwsA(isA<TimeoutException>()));
    expect(reasons, isEmpty);
    // 未毒化:撤销异常行为,后续调用照常透传
    inner.bulkReadImpl = null;
    expect(await wd.bulkRead(512, timeoutMs: 15), hasLength(4));
  });

  test('bulkOut 挂起:兜底超时 + 断链', () async {
    final inner = _FakeInner();
    inner.bulkOutImpl = (_) => Completer<void>().future;
    final wd = _watchdog(inner);
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await expectLater(wd.bulkOut(Uint8List(4)), throwsA(isA<TimeoutException>()));
    await pumpEventQueue();
    expect(reasons, hasLength(1));
  });

  test('拔出轮询:设备消失即广播断链;close() 停轮询', () async {
    final inner = _FakeInner();
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, isEmpty); // 设备在,不误报

    inner.cameras = [];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, ['相机已断开(USB 连接消失)']);

    // 断链已停轮询:把设备插回去也不再广播(只广播一次,等 open 重建)
    inner.cameras = [_dev];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, hasLength(1));

    // close() 后轮询停:设备表再变也不广播
    await wd.open(_dev); // 解除断链 + 重启轮询
    await wd.close();
    inner.cameras = [];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, hasLength(1));
  });

  // ── 链路探测(幽灵设备防线)──────────────────────────────────
  // 背景:usb_service 删除记录失败后 getDevices() 一直返回已拔出的设备,
  // 枚举判定被骗;探测用真实事务复核(见看门狗头注释)。

  test('幽灵设备:枚举一直在但探测挂死 → 断链', () async {
    final inner = _FakeInner();
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(milliseconds: 5),
      // 模拟链路看门狗超时上抛(幽灵管道上真实事务挂死的表现)
      probe: () async => throw TimeoutException('bulk IN 无数据'),
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, hasLength(1));
    expect(reasons.single, contains('链路探测超时'));
    // 断链后轮询停:不会再有第二次广播
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reasons, hasLength(1));
  });

  test('幽灵设备:探测快速失败连续 2 次断链', () async {
    final inner = _FakeInner();
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(milliseconds: 5),
      probe: () async => throw StateError('usb -202'),
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, hasLength(1));
    expect(reasons.single, contains('连续 2 次失败'));
  });

  test('探测瞬时失败一次后恢复:不断链', () async {
    final inner = _FakeInner();
    var calls = 0;
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(milliseconds: 5),
      probe: () => ++calls == 1
          ? Future<Object?>.error(StateError('usb -202'))
          : Future<Object?>.value(null),
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, greaterThan(2)); // 失败后探测仍在继续
    expect(reasons, isEmpty);
  });

  test('探测间隔:probeInterval 未到不重复探测', () async {
    final inner = _FakeInner();
    var calls = 0;
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(seconds: 10),
      probe: () async => calls++,
    );

    await wd.open(_dev);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, 1); // 只有开场第一枚,间隔内不再发
  });

  test('枚举已判消失时不再发探测', () async {
    final inner = _FakeInner();
    var calls = 0;
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(milliseconds: 5),
      probe: () async => calls++,
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    inner.cameras = []; // 第一枚轮询前就拔(干净移除路径)
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, ['相机已断开(USB 连接消失)']);
    expect(calls, 0);
  });

  test('旧链路的迟到探测失败不毒化重开后的新链路', () async {
    final inner = _FakeInner();
    final firstProbe = Completer<Object?>();
    var calls = 0;
    final wd = WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
      detachPollInterval: const Duration(milliseconds: 5),
      probeInterval: const Duration(milliseconds: 5),
      probe: () => ++calls == 1
          ? firstProbe.future
          : Future<Object?>.value(null),
    );
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.open(_dev);
    await Future<void>.delayed(
        const Duration(milliseconds: 10)); // 第一枚探测已挂起
    await wd.open(_dev); // 重开新链路(世代轮换)
    firstProbe.completeError(StateError('旧链路死')); // 旧探测迟到失败
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reasons, isEmpty); // 新链路未被毒化,探测照常成功
    expect(calls, greaterThan(2));
  });

  test('旧链路挂死的收发看门狗迟到引爆不毒化重开后的新链路', () async {
    final inner = _FakeInner();
    inner.bulkOutImpl = (_) => Completer<void>().future;
    final wd = _watchdog(inner);
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    final stale = wd.bulkOut(Uint8List(4)); // 将在 30ms 后超时
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await wd.open(_dev); // 超时引爆前重开新链路
    await expectLater(stale, throwsA(isA<TimeoutException>()));
    await pumpEventQueue();
    expect(reasons, isEmpty); // 迟到引爆只抛给原调用者,不断新链路

    inner.bulkOutImpl = null;
    await wd.bulkOut(Uint8List(4)); // 新链路收发正常,不秒抛
  });

  // ── drainIn(中止后排空,nico 三件套之三)──────────────────────

  test('drainIn 转发内层', () async {
    final inner = _FakeInner();
    final wd = _watchdog(inner);
    await wd.drainIn();
    expect(inner.drainCalls, 1);
  });

  test('drainIn 挂死:兜底超时静默返回,不广播断链、不毒化', () async {
    final inner = _FakeInner();
    inner.drainImpl = () => Completer<void>().future;
    final wd = _watchdog(inner);
    final reasons = <String>[];
    wd.breakages.listen(reasons.add);

    await wd.drainIn(); // 30ms 兜底到点,静默完成(不抛)
    await pumpEventQueue();
    expect(reasons, isEmpty); // 排空失败不是链路活性证据,不判死
    // 未毒化:后续收发照常透传
    expect(await wd.bulkRead(512, timeoutMs: 15), hasLength(4));
    await wd.bulkOut(Uint8List(4));
  });

  test('断链后 drainIn 秒抛(链路已死无从排空)', () async {
    final inner = _FakeInner();
    inner.bulkReadImpl = (_) => Completer<Uint8List>().future;
    final wd = _watchdog(inner);
    await expectLater(
        wd.bulkRead(512, timeoutMs: 15), throwsA(isA<TimeoutException>()));
    await expectLater(wd.drainIn(), throwsA(isA<TimeoutException>()));
    // 调用方(UsbPtpTransport._drainAfterAbort)按 best-effort 静默
  });
}

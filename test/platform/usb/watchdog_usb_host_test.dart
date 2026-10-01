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
  Stream<Uint8List> get interruptEvents => const Stream.empty();

  @override
  Stream<String> get breakages => const Stream.empty();
}

WatchdogUsbHostChannel _watchdog(_FakeInner inner) => WatchdogUsbHostChannel(
      inner: inner,
      readGraceMs: 30,
      bulkOutWatchdogMs: 30,
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
}

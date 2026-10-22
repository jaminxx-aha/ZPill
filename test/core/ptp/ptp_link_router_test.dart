import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptp/ptp_link_router.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';

/// 可脚本化的假传输层:execute 由队列供结果;事件流可随时推。
final class FakeTransport implements PtpTransport {
  FakeTransport({this.failWith});

  /// 非空:execute 直接以该异常失败(不进队列)。
  final Object? failWith;

  final requests = <PtpRequest>[];
  final _replies = <Completer<PtpResult>>[];
  int closeCalls = 0;
  final _eventsCtrl = StreamController<PtpEvent>.broadcast();

  @override
  Stream<PtpEvent> get events => _eventsCtrl.stream;

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) {
    requests.add(request);
    final failure = failWith;
    if (failure != null) {
      return Future.error(failure);
    }
    final completer = Completer<PtpResult>();
    _replies.add(completer);
    return completer.future;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  /// 测试脚本:回一个结果(按 FIFO)。
  void reply(PtpResult result) {
    _replies.removeAt(0).complete(result);
  }

  void emitEvent(int code) =>
      _eventsCtrl.add(PtpEvent(code: code, transactionId: 0xFFFFFFFF));
}

PtpResult _ok() => const PtpResult(responseCode: 0x2001);

/// 可取消假内层(Cancel-Drain 转发测试用):cancelInFlight 计数并返回
/// [cancelResult];transport 面只是 attach 的形参要求,不被调用。
final class CancelCapableFakeTransport implements PtpTransport, PtpCancelCapable {
  CancelCapableFakeTransport({this.cancelResult = true});

  final bool cancelResult;
  var cancelCalls = 0;

  @override
  Future<bool> cancelInFlight() async {
    cancelCalls++;
    return cancelResult;
  }

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    throw UnimplementedError();
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

void main() {
  test('attach → execute 转发内层,请求原样送达', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    router.attach(usb);

    final future = router.execute(const PtpRequest(opcode: 0x1007, params: [1]));
    await pumpEventQueue();
    expect(usb.requests.single.opcode, 0x1007);
    usb.reply(_ok());
    expect((await future).responseCode, 0x2001);
  });

  test('detach 后旧链事件不进广播,新链事件接上', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    final wifi = FakeTransport();
    router.attach(usb);
    final events = <PtpEvent>[];
    router.events.listen(events.add);

    usb.emitEvent(0x4002);
    await pumpEventQueue();
    expect(events.map((e) => e.code), [0x4002]);

    router.detach();
    usb.emitEvent(0x4003); // 旧链迟到事件:不得再进广播
    wifi.emitEvent(0x4004); // 尚未挂载,同样不该进
    await pumpEventQueue();
    expect(events.map((e) => e.code), [0x4002]);

    router.attach(wifi);
    wifi.emitEvent(0x400D);
    await pumpEventQueue();
    expect(events.map((e) => e.code), [0x4002, 0x400D]);
  });

  test('连续 attach:替换内层,旧内层不被关闭', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    final wifi = FakeTransport();
    router.attach(usb);
    router.attach(wifi); // USB → 无线切换

    await pumpEventQueue();
    final future = router.execute(const PtpRequest(opcode: 0x1001));
    await pumpEventQueue();
    expect(wifi.requests, hasLength(1));
    expect(usb.requests, isEmpty); // 新请求不再走旧链
    expect(usb.closeCalls, 0); // 旧内层原封不动
    wifi.reply(_ok());
    expect((await future).responseCode, 0x2001);
  });

  test('detach 时 in-flight:以旧链自己的结果完成(不被取消)', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    router.attach(usb);

    final future = router.execute(const PtpRequest(opcode: 0x1009));
    await pumpEventQueue();
    router.detach(); // 在途事务仍挂在 usb 上
    await pumpEventQueue();
    usb.reply(_ok());
    expect((await future).responseCode, 0x2001);
  });

  test('detach 时 in-flight:以旧链自己的异常失败(不被替换)', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    final wifi = FakeTransport();
    router.attach(usb);
    final future = router.execute(const PtpRequest(opcode: 0x1009));
    await pumpEventQueue();

    router.detach();
    router.attach(wifi);
    usb.reply(const PtpResult(responseCode: 0x2002));
    expect((await future).responseCode, 0x2002); // 旧链结果,不是新链
  });

  test('未挂载 execute:PtpLinkDetachedException(isA<Exception>)', () async {
    final router = PtpLinkRouter();
    await expectLater(
      router.execute(const PtpRequest(opcode: 0x1001)),
      throwsA(isA<PtpLinkDetachedException>()),
    );
    expect(const PtpLinkDetachedException('x'), isA<Exception>());
  });

  test('close:在途以 Exception 失败 + 永不 close 内层 + 后续 execute 秒败',
      () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    router.attach(usb);

    final future = router.execute(const PtpRequest(opcode: 0x1009));
    await pumpEventQueue();

    final expectFailed =
        expectLater(future, throwsA(isA<PtpLinkDetachedException>()));
    await router.close();
    await expectFailed;

    expect(usb.closeCalls, 0); // 核心断言:内层 USB 单例不可被毒化
    await expectLater(
      router.execute(const PtpRequest(opcode: 0x1001)),
      throwsA(isA<PtpLinkDetachedException>()),
    );
    expect(() => router.attach(FakeTransport()), throwsStateError);
    await router.close(); // 幂等
  });

  test('close 前已 detach 的在途事务同样被收尾', () async {
    final router = PtpLinkRouter();
    final usb = FakeTransport();
    router.attach(usb);
    final future = router.execute(const PtpRequest(opcode: 0x1009));
    await pumpEventQueue();
    router.detach();

    final expectFailed =
        expectLater(future, throwsA(isA<PtpLinkDetachedException>()));
    await router.close();
    await expectFailed;
  });

  test('内层 execute 失败原样透传(异常类型与栈不吞)', () async {
    final router = PtpLinkRouter();
    final broken = FakeTransport(failWith: TimeoutException('链路死'));
    router.attach(broken);
    await expectLater(
        router.execute(const PtpRequest(opcode: 0x1001)),
        throwsA(isA<TimeoutException>()));
    expect(broken.closeCalls, 0);
  });

  group('取消-排水转发', () {
    test('内层具备能力 → 透传(计数 + 返回值原样)', () async {
      final router = PtpLinkRouter();
      final wifi = CancelCapableFakeTransport();
      router.attach(wifi);
      expect(await router.cancelInFlight(), isTrue);
      expect(wifi.cancelCalls, 1);
      expect(await router.cancelInFlight(), isTrue);
      expect(wifi.cancelCalls, 2);
    });

    test('内层为 USB(无能力)/ 未挂载 / 已 close → false no-op', () async {
      final router = PtpLinkRouter();
      expect(await router.cancelInFlight(), isFalse); // 未挂载

      final usb = FakeTransport(); // 不实现 PtpCancelCapable
      router.attach(usb);
      expect(await router.cancelInFlight(), isFalse);

      await router.close();
      expect(await router.cancelInFlight(), isFalse);
    });
  });
}

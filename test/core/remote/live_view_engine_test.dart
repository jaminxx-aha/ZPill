import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';

/// 按序回放的假传输层(与 ptp_session_test 同构,精简版)。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) => script.add(
      PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void fail(Object e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)}');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventCtrl.stream;

  @override
  Future<void> close() async {}

  int get liveViewFetches =>
      requests.where((r) => r.opcode == NikonOperationCode.getLiveViewImage).length;
}

/// 手动放行的 delay:记录时长并挂门,测试逐个 release 控制循环节拍。
final class _GatedDelay {
  final durations = <Duration>[];
  final _gates = Queue<Completer<void>>();

  Future<void> call(Duration d) {
    durations.add(d);
    final c = Completer<void>();
    _gates.add(c);
    return c.future;
  }

  void release() => _gates.removeFirst().complete();
}

Uint8List _frame(int marker) =>
    Uint8List.fromList([0xFF, 0xD8, marker, 0xFF, 0xD9]);

void main() {
  test('帧序列发布:StartLiveView → 逐帧 → stop 转 idle,迟到帧不发布', () async {
    final transport = _ScriptTransport()
      ..ok() // startLiveView
      ..ok(data: _frame(1))
      ..ok(data: _frame(2))
      ..ok(data: _frame(3));
    final delay = _GatedDelay();
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: delay.call,
    );

    final frames = <int>[];
    engine.frame.addListener(() => frames.add(engine.frame.value![2]));

    await engine.start();
    expect(engine.status.value, LiveViewStatus.running);
    await pumpEventQueue();
    expect(frames, [1]); // 首帧后挂在 interval 门上

    delay.release();
    await pumpEventQueue();
    expect(frames, [1, 2]);

    delay.release();
    await pumpEventQueue();
    expect(frames, [1, 2, 3]);

    // 停止:循环在门上等待;放行后 runId 已废,不再取帧
    await engine.stop();
    expect(engine.status.value, LiveViewStatus.idle);
    delay.release();
    await pumpEventQueue();
    expect(engine.frame.value![2], 3); // 末帧保留
    expect(transport.liveViewFetches, 3);
  });

  test('失败退避:间隔 ×2 封顶 2s,连续 5 次转 failed', () async {
    final transport = _ScriptTransport()
      ..ok() // startLiveView
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.getLiveViewImage, responseCode: 0x2002))
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.getLiveViewImage, responseCode: 0x2002))
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.getLiveViewImage, responseCode: 0x2002))
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.getLiveViewImage, responseCode: 0x2002))
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.getLiveViewImage, responseCode: 0x2002));
    final delay = _GatedDelay();
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: delay.call,
    );

    await engine.start();
    await pumpEventQueue(); // 首次取帧失败 → 退避门 1(200ms)
    // 逐门放行:门 i 放行 → 第 i+2 次失败 → 新退避门。前 4 次失败均应
    // 保持 running,第 5 次失败(已无新门)直接转 failed。
    for (var i = 0; i < 3; i++) {
      expect(engine.status.value, LiveViewStatus.running,
          reason: '第 ${i + 1} 次失败后仍应退避重试');
      delay.release();
      await pumpEventQueue();
    }
    expect(engine.status.value, LiveViewStatus.running,
        reason: '第 4 次失败后仍应退避重试');
    delay.release(); // → 第 5 次失败
    await pumpEventQueue();
    expect(engine.status.value, LiveViewStatus.failed);
    expect(engine.lastError, contains('取景中断'));
    // 退避序列:200 → 400 → 800 → 1600(第 5 次失败不再等待)
    expect(delay.durations,
        [const Duration(milliseconds: 200), const Duration(milliseconds: 400),
         const Duration(milliseconds: 800), const Duration(milliseconds: 1600)]);
    expect(transport.liveViewFetches, 5);
  });

  test('pause 挂起取帧、resume 恢复(不发 Start/End)', () async {
    final transport = _ScriptTransport()
      ..ok() // startLiveView
      ..ok(data: _frame(1))
      ..ok(data: _frame(2));
    final delay = _GatedDelay();
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: delay.call,
    );

    await engine.start();
    await pumpEventQueue();
    expect(transport.liveViewFetches, 1);
    expect(engine.frame.value![2], 1);

    engine.pause();
    delay.release(); // 放行 interval 门 → 循环进入 paused 等待
    await pumpEventQueue();
    delay.release(); // 放行 pausedTick → 仍挂起,不取帧
    await pumpEventQueue();
    expect(transport.liveViewFetches, 1, reason: 'pause 期间不得取帧');

    engine.resume();
    delay.release(); // 放行下一个 pausedTick → 恢复取帧
    await pumpEventQueue();
    expect(transport.liveViewFetches, 2);
    expect(engine.frame.value![2], 2);
  });

  test('StartLiveView 失败:直接转 failed 不进轮询', () async {
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView, responseCode: 0x2005));
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.failed);
    expect(engine.lastError, contains('取景开启失败'));
    expect(transport.requests.map((r) => r.opcode),
        [NikonOperationCode.startLiveView]);
  });
}

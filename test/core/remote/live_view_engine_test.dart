import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/log/app_log.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/remote/live_view_engine.dart';
import 'package:z_pill/core/remote/live_view_header.dart';
import 'package:z_pill/core/remote/live_view_watchdog.dart';

/// 按序回放的假传输层(与 ptp_session_test 同构,精简版)。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) => script.add(
      PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void fail(Object e) => script.add(e);
  void reject(int code) =>
      script.add(PtpResult(responseCode: code));

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

  int get liveViewFetches => requests
      .where((r) =>
          r.opcode == NikonOperationCode.getLiveViewImageEx ||
          r.opcode == NikonOperationCode.getLiveViewImage)
      .length;
}

/// 事务耗时注入的假传输:取帧事务前推进注入时钟(模拟链路耗时),
/// 供「节拍从帧起步计」的睡眠断言 —— 引擎的 [clock] 时钟即此钟。
/// 只推进取帧码:startLiveView/探测等命令事务不计入节拍窗。
final class _SlowTxnTransport extends _ScriptTransport {
  _SlowTxnTransport(this.clock, this.advance);

  final _TestClock clock;
  final Duration advance;

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    if (request.opcode == NikonOperationCode.getLiveViewImageEx ||
        request.opcode == NikonOperationCode.getLiveViewImage) {
      clock.advance(advance);
    }
    return super.execute(request, onData: onData);
  }
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

/// 合成时钟:引擎喂看门狗用(阈值 4s 是生产默认,重放帧前推进 5s)。
final class _TestClock {
  DateTime value = DateTime(2026, 10, 10, 12);
  DateTime call() => value;
  void advance(Duration d) => value = value.add(d);
}

Uint8List _frame(int marker) =>
    Uint8List.fromList([0xFF, 0xD8, marker, 0xFF, 0xD9]);

/// 1024B display-info 头(坐标系 6048×3400、一框、@828 录制中)+ SOI 尾。
Uint8List _headerFrame() {
  final b = Uint8List(1024 + 8);
  void be16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  be16(16, 6048);
  be16(18, 3400);
  b[42] = 2; // 合焦
  b[44] = 1; // areaCount
  be16(48, 240);
  be16(50, 240);
  be16(52, 3024);
  be16(54, 1700);
  b[828] = 1; // 机身正在录制
  b[1024] = 0xFF;
  b[1025] = 0xD8;
  b[1026] = 0xFF;
  return b;
}

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
    expect(engine.lastError?.key, startsWith('live.interrupted'));
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

  test('头+JPEG 帧:header 与剥离 JPEG 同步发布;裸 JPEG → header 置 null',
      () async {
    final raw = _headerFrame();
    final transport = _ScriptTransport()
      ..ok() // startLiveView
      ..ok(data: raw)
      ..ok(data: _frame(9)); // 裸 JPEG(无头)
    final delay = _GatedDelay();
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: delay.call,
    );

    await engine.start();
    await pumpEventQueue();
    final h = engine.header.value!;
    expect(h.coordinateWidth, 6048);
    expect(h.focusResult, LiveViewFocusResult.focused);
    expect(h.recording, isTrue);
    expect(h.boxes.single.width, 240);
    // JPEG 从 1024 处剥离,不带头
    expect(engine.frame.value![0], 0xFF);
    expect(engine.frame.value![1], 0xD8);
    expect(engine.frame.value!.length, 8);

    delay.release();
    await pumpEventQueue();
    expect(engine.header.value, isNull); // 裸帧覆盖头状态
    expect(engine.frame.value![2], 9);
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
    expect(engine.lastError?.key, startsWith('live.startFail'));
    expect(transport.requests.map((r) => r.opcode),
        [NikonOperationCode.startLiveView]);
  });

  test('身份门自愈:0x9201 首拍 0xA004 → 0x90C2(1) 开闩 → 重试通,'
      '配对 0x90C2(0) 还身(闩单向,流照跑)', () async {
    // Zf USB 实证(2026-10-07 v8/v9):上传优先门是单向闩,0x90C2(1)
    // = 唯一实证开闩钥匙(0x9435 是假钥匙);remote 持有态才是机身停
    // 「已连接到计算机」屏的元凶 —— 故自愈进过 remote 必配对退出,
    // 退不关闩(背靠背 1→0 后 0x9201 照通、帧照流)。
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus))
      ..reject(PtpResponseCode.operationNotSupported) // 0x9202 关被拒(取景本没开)
      ..ok() // 0x90C2(1) 开闩进 remote
      ..ok() // 0x9201 重试通
      ..ok() // 0x90C2(0) 配对还身
      ..ok(data: _frame(7)); // 首帧
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.running);
    await pumpEventQueue();
    expect(engine.frame.value![2], 7);
    expect(transport.requests.map((r) => r.opcode), [
      NikonOperationCode.startLiveView,
      NikonOperationCode.endLiveView,
      NikonOperationCode.changeCameraMode,
      NikonOperationCode.startLiveView,
      NikonOperationCode.changeCameraMode,
      NikonOperationCode.getLiveViewImageEx,
    ]);
    expect(transport.requests[2].params, [1]);
    expect(transport.requests[4].params, [0], reason: '开闩即还身');
    expect(engine.session.remoteModeActive, isFalse,
        reason: '配对退出后 remote 不再持有(机身回自己的取景屏)');

    // 自愈路径照常置 _viewOn:stop 发 0x9202(不开则不发)。
    await engine.stop();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(2),
        reason: '自愈梯楔死钥匙 0x9202 一笔(被拒)+ stop 收尾一笔');
  });

  test('usbfs 形态自愈:0x90C2 被拒 → 写 0xD406 身份 → 重试通', () async {
    // 直连 USB 主机(usbfs/libusb 类)上 initiator 残留出厂 MTP 串时
    // 0x9201 恒 0xA004,写非 MTP 身份串即通;老机身 0x90C2 op 缺席
    // → 落到第二把钥匙(有屏显人设副作用,只作末级兜底)。
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus))
      ..reject(PtpResponseCode.operationNotSupported) // 0x9202 关被拒
      ..reject(PtpResponseCode.operationNotSupported) // 0x90C2(1) op 缺席
      ..ok() // 0xD406 身份写
      ..ok() // 0x9201 重试通
      ..ok(data: _frame(5)); // 首帧
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.running);
    await pumpEventQueue();
    expect(engine.frame.value![2], 5);
    expect(transport.requests.map((r) => r.opcode), [
      NikonOperationCode.startLiveView,
      NikonOperationCode.endLiveView,
      NikonOperationCode.changeCameraMode,
      PtpOperationCode.setDevicePropValue,
      NikonOperationCode.startLiveView,
      NikonOperationCode.getLiveViewImageEx,
    ]);
    expect(transport.requests[3].params,
        [PtpDevicePropCode.sessionInitiatorInfo]);

    // 自愈路径照常置 _viewOn:stop 发 0x9202(不开则不发)。
    await engine.stop();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(2),
        reason: '自愈梯楔死钥匙 0x9202 一笔(被拒)+ stop 收尾一笔');
  });

  test('身份门自愈失败:0x9202/remote 模式/身份写全被拒 → failed 带原 0xA004',
      () async {
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus))
      ..reject(PtpResponseCode.operationNotSupported) // 0x9202 关被拒
      ..reject(PtpResponseCode.operationNotSupported) // 0x90C2(1) 被拒
      ..reject(PtpResponseCode.operationNotSupported); // 0xD406 写也被拒
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.failed);
    expect(engine.lastError?.key, 'live.startFailLadder');
    expect(engine.lastError?.args?['e'], contains('A004'),
        reason: '自愈段全败上抛原始 0xA004,不遮原语义');
    // 连接梯随失败浮出(真机定案仪器:哪一级被拒一眼可读,l 参承载)。
    expect(engine.lastError?.args?['l'], isNotEmpty);
    expect(engine.session.connectLadder, [
      '9201:0xA004',
      '9202:拒',
      '90C2:拒',
      'D406:拒',
    ], reason: '钥匙失败不重试 0x9201,直接换下一把(9202 关被拒同样跳过)');
    expect(transport.requests.map((r) => r.opcode), [
      NikonOperationCode.startLiveView,
      NikonOperationCode.endLiveView,
      NikonOperationCode.changeCameraMode,
      PtpOperationCode.setDevicePropValue,
    ]);
    await engine.stop();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(1),
        reason: '仅自愈梯的 0x9202 一笔;stop 不再加发(从未开启成功)');
  });

  test('remote 进了但重试仍 0xA004 → 身份写兜底 → 重试通,末尾配对还身', () async {
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus))
      ..reject(PtpResponseCode.operationNotSupported) // 0x9202 关被拒
      ..ok() // 0x90C2(1) 开闩进 remote
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus)) // remote 后仍拒
      ..ok() // 0xD406 身份写
      ..ok() // 0x9201 重试通
      ..ok() // 0x90C2(0) 配对还身(remoteEntered)
      ..ok(data: _frame(8)); // 首帧
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.running);
    await pumpEventQueue();
    expect(engine.frame.value![2], 8);
    expect(transport.requests.map((r) => r.opcode), [
      NikonOperationCode.startLiveView,
      NikonOperationCode.endLiveView,
      NikonOperationCode.changeCameraMode,
      NikonOperationCode.startLiveView,
      PtpOperationCode.setDevicePropValue,
      NikonOperationCode.startLiveView,
      NikonOperationCode.changeCameraMode,
      NikonOperationCode.getLiveViewImageEx,
    ]);
    expect(engine.session.remoteModeActive, isFalse);
  });

  test('双段自愈后仍 0xA004:各重试一次,failed 上抛,仍配对还身', () async {
    final transport = _ScriptTransport()
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus))
      ..reject(PtpResponseCode.operationNotSupported) // 0x9202 关被拒
      ..ok() // 0x90C2(1) 开闩进 remote
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus)) // remote 重试仍拒
      ..ok() // 0xD406 身份写通
      ..fail(const PtpResponseException(
          opcode: NikonOperationCode.startLiveView,
          responseCode: NikonResponseCode.invalidStatus)) // 最后重试仍拒
      ..ok(); // 0x90C2(0) 配对还身(finally 路径)
    final engine = LiveViewEngine(
      session: PtpSession(transport: transport),
      delay: _GatedDelay().call,
    );

    await engine.start();
    expect(engine.status.value, LiveViewStatus.failed);
    expect(engine.lastError?.key, 'live.startFailLadder');
    expect(engine.lastError?.args?['e'], contains('A004'));
    expect(engine.lastError?.args?['l'], isNotEmpty);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView)
            .length,
        3,
        reason: '初拍 + remote 重试 + 身份重试,各一次不无限打');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
            .last
            .params,
        [0],
        reason: '进过 remote 必配对退出:失败路径也要还机身自由');
  });

  group('接管持有期的 0xA004(2026-10-11 Zf 实证:模式写后瞬态忙,'
      '自愈梯不得碰 0x90C2 —— 会杀仅持有期保值的会话写入)', () {
    test('remoteHeld:首拍 0xA004 → 400ms 忙退避重试通,零 0x90C2', () async {
      final transport = _ScriptTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus))
        ..ok() // 0x9201 忙重试通
        ..ok(data: _frame(9)); // 首帧
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      )..remoteHeld = true;

      final starting = engine.start();
      await pumpEventQueue(); // 首拍 0xA004 落定,挂上 400ms 退避门
      delay.release();
      await starting;
      expect(engine.status.value, LiveViewStatus.running);
      await pumpEventQueue();
      expect(engine.frame.value![2], 9);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode),
          isEmpty,
          reason: '接管持有中不碰 0x90C2(配对退闩会杀模式覆写等会话写入)');
      expect(delay.durations.first, const Duration(milliseconds: 400));
      expect(engine.session.connectLadder, contains('9201:OK(忙重试)'));
    });

    test('remoteHeld:0x2019 忙同样进退避;两轮重试+0x9202 后两轮仍 0xA004 → '
        '上抛原语义', () async {
      final transport = _ScriptTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus))
        ..reject(PtpResponseCode.deviceBusy) // 重试 1:忙
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)) // 重试 2:仍拒
        ..ok() // 0x9202 先关再开(楔死候选钥匙)
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)) // 重试 3:仍拒
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)); // 重试 4:仍拒
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      )..remoteHeld = true;

      final starting = engine.start();
      await pumpEventQueue(); // 首拍 0xA004 → 挂上第 1 个退避门
      delay.release();
      await pumpEventQueue(); // 重试 1:0x2019 忙 → 挂上第 2 个退避门
      delay.release();
      await pumpEventQueue(); // 重试 2:仍拒 → 0x9202 → 挂上第 3 个退避门
      delay.release();
      await pumpEventQueue(); // 重试 3:仍拒 → 挂上第 4 个退避门
      delay.release();
      await starting;
      expect(engine.status.value, LiveViewStatus.failed);
      expect(engine.lastError?.key, startsWith('live.startFail'));
      expect(engine.lastError?.args?['e'], contains('A004'),
          reason: '上抛原始语义');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.startLiveView)
              .length,
          5,
          reason: '初拍 + 两轮忙退避 + 0x9202 后两轮,不无限打');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.endLiveView)
              .length,
          1,
          reason: '楔死候选钥匙只打一次');
      expect(engine.session.connectLadder, contains('9202:OK'));
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode),
          isEmpty);
    });

    test('remoteHeld:楔死(机身侧取景残留)→ 0x9202 先关再开 → 重试通', () async {
      final transport = _ScriptTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus))
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)) // 重试 1:仍拒
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)) // 重试 2:仍拒
        ..ok() // 0x9202 先关(残留取景收尾)
        ..ok() // 0x9201 重试通(9202 后)
        ..ok(data: _frame(11)); // 首帧
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      )..remoteHeld = true;

      final starting = engine.start();
      await pumpEventQueue();
      delay.release();
      await pumpEventQueue(); // 重试 1 仍拒 → 挂上重试 2 的门
      delay.release();
      await pumpEventQueue(); // 重试 2 仍拒 → 0x9202 → 挂上 9202 后重试的门
      delay.release();
      await starting;
      expect(engine.status.value, LiveViewStatus.running);
      await pumpEventQueue();
      expect(engine.frame.value![2], 11);
      expect(
          transport.requests.map((r) => r.opcode), [
        NikonOperationCode.startLiveView,
        NikonOperationCode.startLiveView,
        NikonOperationCode.startLiveView,
        NikonOperationCode.endLiveView,
        NikonOperationCode.startLiveView,
        NikonOperationCode.getLiveViewImageEx,
      ]);
      expect(engine.session.connectLadder, contains('9202:OK'));
      expect(engine.session.connectLadder, contains('9201:OK(9202 后重试)'));
    });

    test('remoteHeld:非 0xA004/0x2019 的拒绝立即上抛,不重试', () async {
      final transport = _ScriptTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.notLiveView));
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: _GatedDelay().call,
      )..remoteHeld = true;

      await engine.start();
      expect(engine.status.value, LiveViewStatus.failed);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.startLiveView)
              .length,
          1,
          reason: '0xA00B 不属瞬态忙,不打第二轮');
    });
  });

  group('帧签名看门狗(冻结检测,2026-10-10)', () {
    LiveViewEngine wireEngine(
      _ScriptTransport transport,
      _GatedDelay delay,
      _TestClock clock, {
      int maxRestarts = 3,
      void Function()? onEscalate,
    }) =>
        LiveViewEngine(
          session: PtpSession(transport: transport),
          watchdog: LiveViewWatchdog(maxRestarts: maxRestarts),
          delay: delay.call,
          clock: clock.call,
          onEscalateToLinkRecovery: onEscalate,
        );

    test('同帧重放 >4s → 探测忙(0x2019)→ BUSY 保持:health=busy 不发 0x9202,'
        '新帧到达自我恢复 → health 回 ok', () async {
      final transport = _ScriptTransport()
        ..ok() // 0x9201
        ..ok(data: _frame(1)) // 取帧 1:新签名
        ..ok(data: _frame(1)) // 取帧 2:同签名重放 5s → 探测
        ..reject(PtpResponseCode.deviceBusy) // 0x90C8 → 忙(false)
        ..ok(data: _frame(2)); // 取帧 3:真新内容 → 横幅撤下
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock);

      await engine.start();
      await pumpEventQueue(); // 取帧 1 发布,挂在 interval 门 1
      expect(engine.health.value, LiveViewHealth.ok);

      clock.advance(const Duration(seconds: 5)); // 重放 > 4s 判冻结
      delay.release(); // → 取帧 2(重放)→ 探测在途,循环挂 interval 门 2
      await pumpEventQueue();

      expect(engine.health.value, LiveViewHealth.busy,
          reason: '机身忙(写卡/下载 flush):保持不重启');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.endLiveView),
          isEmpty,
          reason: 'BUSY 保持不发 0x9202(重启会把机身菜单摔回拍摄屏)');
      expect(transport.requests.last.opcode, NikonOperationCode.deviceReady);

      clock.advance(const Duration(milliseconds: 100));
      delay.release(); // → 取帧 3(新内容):冻结解除,横幅撤下
      await pumpEventQueue();
      expect(engine.health.value, LiveViewHealth.ok);
      expect(engine.frame.value![2], 2);
      expect(engine.status.value, LiveViewStatus.running);
      expect(transport.liveViewFetches, 3);
    });

    test('探测不忙 → 礼让(不忙但未满 30s 不重启)→ 满窗重启取景:'
        '0x9202(尽力)+ 自愈梯 0x9201 → 记账、health 回 ok、取帧续跑', () async {
      final transport = _ScriptTransport()
        ..ok() // 0x9201(初始)
        ..ok(data: _frame(1)) // 取帧 1
        ..ok(data: _frame(1)) // 取帧 2:重放 5s → 探测不忙 → 礼让(不重启)
        ..ok() // 0x90C8 → 不忙(true)
        ..ok(data: _frame(1)) // 取帧 3:重放 31s → 复查不忙 → 满礼让窗重启
        ..ok() // 0x90C8 → 不忙
        ..ok() // 0x9202 EndLiveView(尽力)
        ..ok() // 0x9201 重启(自愈梯直过)
        ..ok(data: _frame(2)); // 取帧 4:重启后的新帧
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock);

      await engine.start();
      await pumpEventQueue(); // 取帧 1,interval 门 1
      clock.advance(const Duration(seconds: 5));
      delay.release(); // → 取帧 2(重放)→ 探测不忙 → 礼让,interval 门 2
      await pumpEventQueue();
      expect(engine.health.value, LiveViewHealth.ok,
          reason: '礼让期不打摁机身:菜单浏览场景无横幅无重启');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.endLiveView),
          isEmpty,
          reason: '礼让窗内不重启(重启会把机身菜单摔回拍摄屏)');

      clock.advance(const Duration(seconds: 26)); // 冻结满 31s ≥ 礼让窗 30s
      delay.release(); // → 取帧 3(重放)→ 复查不忙 → 重启序列,interval 门 3
      await pumpEventQueue(); // 处置器(探测/重启)全在门上完成

      expect(engine.health.value, LiveViewHealth.ok, reason: '重启成功回 ok');
      expect(engine.status.value, LiveViewStatus.running);
      expect(transport.requests.map((r) => r.opcode), [
        NikonOperationCode.startLiveView,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.deviceReady,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.deviceReady,
        NikonOperationCode.endLiveView,
        NikonOperationCode.startLiveView,
      ], reason: '礼让期复查探测 → 满窗重启 = EndLiveView + 自愈梯');

      clock.advance(const Duration(milliseconds: 100));
      delay.release(); // → 取帧 4:重启后取景续跑
      await pumpEventQueue();
      expect(engine.frame.value![2], 2);
      expect(transport.liveViewFetches, 4);
    });

    test('探测异常(链路类)→ 按不忙走礼让,满窗重启,不让异常吞掉冻结判决',
        () async {
      final transport = _ScriptTransport()
        ..ok() // 0x9201(初始)
        ..ok(data: _frame(1)) // 取帧 1
        ..ok(data: _frame(1)) // 取帧 2:重放 5s → 探测异常 → 视不忙 → 礼让
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.deviceReady,
            responseCode: 0x2002)) // 探测抛错 → 视不忙
        ..ok(data: _frame(1)) // 取帧 3:重放 31s → 复查再异常 → 满窗重启
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.deviceReady,
            responseCode: 0x2002)) // 复查抛错 → 视不忙
        ..ok() // 0x9202
        ..ok() // 0x9201 重启
        ..ok(data: _frame(2)); // 取帧 4
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock);

      await engine.start();
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 5));
      delay.release(); // → 重放帧 → 探测异常 → 礼让
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 26)); // 满礼让窗
      delay.release(); // → 重放帧 → 复查异常 → 重启序列
      await pumpEventQueue();

      expect(engine.health.value, LiveViewHealth.ok);
      expect(transport.requests.map((r) => r.opcode), [
        NikonOperationCode.startLiveView,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.deviceReady,
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.deviceReady,
        NikonOperationCode.endLiveView,
        NikonOperationCode.startLiveView,
      ]);
    });

    test('重启预算耗尽(maxRestarts:1)→ 升级整链重连恰一次:'
        'status 回 idle、不再发 0x9202、循环即废', () async {
      var escalations = 0;
      final transport = _ScriptTransport()
        ..ok() // 0x9201(初始)
        ..ok(data: _frame(1)) // 取帧 1
        ..ok(data: _frame(1)) // 取帧 2:重放 5s → 探测不忙 → 礼让
        ..ok() // 0x90C8 不忙
        ..ok(data: _frame(1)) // 取帧 3:重放 31s → 复查不忙 → 满窗重启 #1
        ..ok() // 0x90C8 不忙
        ..ok() // 0x9202
        ..ok() // 0x9201(重启 #1,预算记满 1/1)
        ..ok(data: _frame(2)) // 取帧 4:重启后的新帧
        ..ok(data: _frame(2)) // 取帧 5:重放 5s → 探测不忙 → 礼让
        ..ok() // 0x90C8 不忙
        ..ok(data: _frame(2)) // 取帧 6:重放 31s → 复查不忙 → 预算耗尽
        ..ok(); // 0x90C8 不忙
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock,
          maxRestarts: 1, onEscalate: () => escalations++);

      await engine.start();
      await pumpEventQueue(); // 取帧 1
      clock.advance(const Duration(seconds: 5));
      delay.release(); // → 取帧 2 → 探测不忙 → 礼让
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 26)); // 满礼让窗
      delay.release(); // → 取帧 3 → 复查不忙 → 重启 #1(记账 1/1)
      await pumpEventQueue();
      expect(engine.health.value, LiveViewHealth.ok);

      clock.advance(const Duration(milliseconds: 100));
      delay.release(); // → 取帧 4(新帧)
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 5));
      delay.release(); // → 取帧 5(再次重放)→ 探测不忙 → 礼让
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 26)); // 再满礼让窗
      delay.release(); // → 取帧 6(重放)→ 复查不忙 → 预算耗尽 → 升级
      await pumpEventQueue();

      expect(escalations, 1, reason: '升级回调恰一次');
      expect(engine.status.value, LiveViewStatus.idle,
          reason: '回 idle 待重连成功后 autoLiveViewOnConnect 重新起景');
      expect(engine.health.value, LiveViewHealth.ok);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.endLiveView),
          hasLength(1),
          reason: '只有重启 #1 发过 0x9202;升级路径拆链是连接层的事');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.startLiveView)
              .length,
          2,
          reason: '初始 + 重启 #1 各一次;升级路径不再重启取景');

      delay.release(); // 放行最后的 interval 门:循环世代已废,不得再取帧
      await pumpEventQueue();
      expect(transport.liveViewFetches, 6);
    });

    test('冻结重启被拒(自愈梯全败)→ failed 带梯,取景中断文案可辨', () async {
      final transport = _ScriptTransport()
        ..ok() // 0x9201(初始)
        ..ok(data: _frame(1)) // 取帧 1
        ..ok(data: _frame(1)) // 取帧 2:重放 5s → 探测不忙 → 礼让
        ..ok() // 0x90C8 不忙
        ..ok(data: _frame(1)) // 取帧 3:重放 31s → 复查不忙 → 满窗重启
        ..ok() // 0x90C8 不忙
        ..ok() // 0x9202(尽力)
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.startLiveView,
            responseCode: NikonResponseCode.invalidStatus)) // 重启被拒
        ..reject(PtpResponseCode.operationNotSupported) // 0x90C2 钥匙缺
        ..reject(PtpResponseCode.operationNotSupported); // 0xD406 钥匙缺
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock);

      await engine.start();
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 5));
      delay.release(); // → 重放帧 → 探测不忙 → 礼让
      await pumpEventQueue();
      clock.advance(const Duration(seconds: 26)); // 满礼让窗
      delay.release(); // → 重放帧 → 复查不忙 → 重启序列全败
      await pumpEventQueue();

      expect(engine.status.value, LiveViewStatus.failed);
      expect(engine.lastError?.key, 'live.freezeRestartFailLadder');
      expect(engine.lastError?.args?['l'], isNotEmpty,
          reason: '连接梯浮出:真机定案仪器');
    });

    test('pause 期不判冻结:看门狗纯帧驱动,挂起期时钟流逝不触发探测/重启',
        () async {
      final transport = _ScriptTransport()
        ..ok() // 0x9201
        ..ok(data: _frame(1)) // 取帧 1
        ..ok(data: _frame(2)); // 取帧 2(resume 后的新帧)
      final delay = _GatedDelay();
      final clock = _TestClock();
      final engine = wireEngine(transport, delay, clock);

      await engine.start();
      await pumpEventQueue(); // 取帧 1 发布,挂 interval 门 1
      expect(engine.frame.value![2], 1);

      engine.pause();
      delay.release(); // 放行门 1 → 循环进 paused tick(50ms 门 2)
      await pumpEventQueue();

      // 挂起期时钟流逝 10 分钟:看门狗无帧输入,不发探测/重启
      clock.advance(const Duration(minutes: 10));
      await pumpEventQueue();
      expect(
          transport.requests
              .where((r) =>
                  r.opcode == NikonOperationCode.deviceReady ||
                  r.opcode == NikonOperationCode.endLiveView),
          isEmpty,
          reason: '看门狗纯帧驱动:pause 期无输入即无判决');
      expect(engine.health.value, LiveViewHealth.ok);
      expect(engine.status.value, LiveViewStatus.running);
      expect(engine.frame.value![2], 1, reason: '末帧保留不闪黑');

      engine.resume();
      delay.release(); // 放行 paused tick 门 2 → 恢复取帧 2(新签名)
      await pumpEventQueue();
      expect(engine.frame.value![2], 2);
      expect(engine.health.value, LiveViewHealth.ok,
          reason: '恢复后新帧到达,无冻结误报');
      expect(transport.liveViewFetches, 2);
    });
  });

  group('帧起步节拍(2026-10-25:睡眠 = 节拍 − 上帧事务耗时,钳 0)', () {
    test('纯函数钳位:事务快补差额、事务吃满零睡', () {
      expect(
          liveViewPaceSleep(
              txn: Duration.zero,
              interval: const Duration(milliseconds: 50)),
          const Duration(milliseconds: 50),
          reason: '零耗时(测试假传输常态)保持旧 50ms 睡眠,老用例不搅');
      expect(
          liveViewPaceSleep(
              txn: const Duration(milliseconds: 30),
              interval: const Duration(milliseconds: 50)),
          const Duration(milliseconds: 20));
      expect(
          liveViewPaceSleep(
              txn: const Duration(milliseconds: 80),
              interval: const Duration(milliseconds: 50)),
          Duration.zero,
          reason: '事务慢于节拍:零睡直取下一拍,不吃死时间');
    });

    test('慢事务链路(事务 80ms ≥ 节拍 50ms)→ 睡眠钳 0', () async {
      final clock = _TestClock();
      final transport = _SlowTxnTransport(clock, const Duration(milliseconds: 80))
        ..ok() // startLiveView
        ..ok(data: _frame(1))
        ..ok(data: _frame(2));
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
        clock: clock.call,
      );

      await engine.start();
      await pumpEventQueue(); // 首帧:事务 80ms(时钟推进)→ 睡眠门 0
      expect(delay.durations, [Duration.zero],
          reason: '节拍从帧起步计:事务已吃满节拍,零睡直取下一拍');

      delay.release();
      await pumpEventQueue();
      expect(engine.frame.value![2], 2);
      expect(delay.durations, [Duration.zero, Duration.zero]);
      expect(transport.liveViewFetches, 2);
    });

    test('节拍账:满 100 帧经 AppLog(live) 报 fps/事务/睡眠/零睡并清账', () async {
      final lines = <String>[];
      AppLog.mirror = lines.add;
      addTearDown(() => AppLog.mirror = null);
      final clock = _TestClock();
      // 每帧事务 40ms → 账窗 100×40ms = 4s,fps=25.0;睡眠 50−40=10ms。
      final transport = _SlowTxnTransport(clock, const Duration(milliseconds: 40))
        ..ok(); // startLiveView
      for (var i = 1; i <= 100; i++) {
        transport.ok(data: _frame(i)); // 逐帧换签名,不触发看门狗冻结
      }
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
        clock: clock.call,
      );

      await engine.start();
      await pumpEventQueue(); // 第 1 帧入账
      for (var i = 2; i <= 99; i++) {
        delay.release();
        await pumpEventQueue();
      }
      expect(lines.where((l) => l.contains('节拍账')), isEmpty,
          reason: '未满窗不报');

      delay.release(); // 第 100 帧 → 满窗报账
      await pumpEventQueue();
      final report = lines.singleWhere((l) => l.contains('节拍账'));
      expect(report, contains('[I/${AppLog.live}]'));
      expect(report, contains('n=100'));
      expect(report, contains('fps=25.0'));
      expect(report, contains('事务avg=40.0/max=40.0ms'));
      expect(report, contains('睡眠avg=10.0ms'));
      expect(report, contains('零睡=0'));

      delay.release(); // 第 101 帧:清账后重新起窗,不产生第二条
      await pumpEventQueue();
      expect(lines.where((l) => l.contains('节拍账')), hasLength(1));
      expect(transport.liveViewFetches, 101);
    });

    test('framesFlowing:running 且未挂起为真;pause/stop 即假(下载钳块闸口径)',
        () async {
      final transport = _ScriptTransport()
        ..ok() // startLiveView
        ..ok(data: _frame(1));
      final delay = _GatedDelay();
      final engine = LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      );
      expect(engine.framesFlowing, isFalse, reason: 'idle 未在轮询');

      await engine.start();
      await pumpEventQueue();
      expect(engine.framesFlowing, isTrue, reason: 'running 帧在流');

      engine.pause();
      expect(engine.framesFlowing, isFalse,
          reason: '挂起窗(拍照/对焦)帧不流,闸放下载全速');
      engine.resume();
      expect(engine.framesFlowing, isTrue);

      await engine.stop();
      expect(engine.framesFlowing, isFalse, reason: '停轮回 idle');
    });
  });
}

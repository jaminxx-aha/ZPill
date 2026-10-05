import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';

final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void reply(int responseCode) =>
      script.add(PtpResult(responseCode: responseCode));
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

  int count(int opcode) => requests.where((r) => r.opcode == opcode).length;
}

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  String? get error => null;

  @override
  String? get deviceName => null;

  @override
  bool get isWireless => false;

  @override
  String? get pairingCode => null;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {}

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}

  @override
  Future<void> disconnect() async {}
}

/// 手动放行的 delay(capture 的 DeviceReady 轮询节拍)。
final class _GatedDelay {
  final _gates = Queue<Completer<void>>();

  Future<void> call(Duration d) {
    final c = Completer<void>();
    _gates.add(c);
    return c.future;
  }

  void release() => _gates.removeFirst().complete();
}

/// PropDesc 数据集(u16 code + u16 type + u8 getSet + 当前值 + FORM)。
Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, List<int>? enums}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
  type.write(w, current);
  if (enums != null) {
    w
      ..u8(0x02) // FORM=0x02 枚举域
      ..u16(enums.length);
    for (final v in enums) {
      type.write(w, v);
    }
  } else {
    w.u8(0x00); // 无 FORM
  }
  return w.takeBytes();
}

/// 三次曝光属性 PropDesc 应答(f/2.8 · 1/100s · ISO 200,均可写)。
void _scriptExposure(_ScriptTransport t) {
  t
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.fNumber, PtpDataType.uint16, 28,
        enums: [28, 32, 40]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureTime, PtpDataType.uint32, 10000))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
        enums: [100, 200, 400, 800]));
}

void main() {
  late _ScriptTransport transport;
  late _FakeConnection conn;
  late _GatedDelay delay;
  late RemoteController controller;

  setUp(() {
    transport = _ScriptTransport();
    conn = _FakeConnection();
    delay = _GatedDelay();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      ),
      delay: delay.call,
    );
  });

  tearDown(() async {
    controller.dispose();
  });

  test('连接成功 → 曝光自动刷新(0x5007/0x500D/0x500F)', () async {
    _scriptExposure(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 28);
    expect(controller.exposure?.shutterUs, 10000);
    expect(controller.exposure?.iso, 200);
    expect(controller.linkUp, isTrue);
  });

  test('capture:CaptureComplete 事件先到 → 提前收口,轮询不到 10 次', () async {
    transport.ok(); // initiateCapture
    transport.reply(PtpResponseCode.deviceBusy); // 第 1 轮 DeviceReady:忙
    transport.reply(PtpResponseCode.deviceBusy); // 第 2 轮 DeviceReady:忙
    final capture = controller.capture();
    await pumpEventQueue();
    expect(controller.capturing, isTrue);

    delay.release(); // 第 1 轮 300ms 到点 → DeviceReady 忙(false)
    await pumpEventQueue();
    delay.release(); // 第 2 轮
    await pumpEventQueue();
    expect(
        transport.count(NikonOperationCode.deviceReady), 2,
        reason: '前两轮均在等待,尚未收口');

    // 事件到达 → 下一轮 Future.any 命中事件分支
    transport.eventCtrl.add(const PtpEvent(code: PtpEventCode.captureComplete, transactionId: 0xFFFFFFFF));
    await capture;
    expect(controller.capturing, isFalse);
    expect(controller.error, isNull);
    expect(transport.count(NikonOperationCode.deviceReady), 2,
        reason: '事件收口后不再轮询');
  });

  test('capture:无事件 → DeviceReady 兜底收口', () async {
    transport.ok(); // initiateCapture
    transport.ok(); // deviceReady → true
    final capture = controller.capture();
    await pumpEventQueue();
    delay.release();
    await capture;
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 1);
  });

  test('capture:DeviceReady 非忙错误 → 放弃兜底不算失败(命令已被接受)',
      () async {
    transport.ok(); // initiateCapture
    transport.reply(PtpResponseCode.operationNotSupported); // deviceReady 抛
    final capture = controller.capture();
    await pumpEventQueue();
    delay.release();
    await capture;
    expect(controller.capturing, isFalse);
    expect(controller.error, isNull);
  });

  test('capture:快门 0x2019 忙 → 报错且不轮询', () async {
    transport.reply(PtpResponseCode.deviceBusy); // initiateCapture 忙
    await controller.capture();
    expect(controller.error, contains('快门释放失败'));
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 0,
        reason: '忙不是换码信号,不得回退');
  });

  test('capture:0x100E 被 0x2002 拒(Zf 真机实证)→ 回退 0x9207,后续直发',
      () async {
    transport
      ..reply(PtpResponseCode.generalError) // 0x100E:Zf 回 GeneralError
      ..ok() // 0x9207 回退成功
      ..ok(); // deviceReady → true
    final first = controller.capture();
    await pumpEventQueue();
    delay.release(); // 第 1 轮 DeviceReady
    await first;
    expect(controller.error, isNull);
    expect(transport.count(PtpOperationCode.initiateCapture), 1);
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);

    // 第二次:直发缓存码 0x9207,不再重试标准码
    transport
      ..ok() // 0x9207 直发
      ..ok(); // deviceReady → true
    final second = controller.capture();
    await pumpEventQueue();
    delay.release(); // 第 1 轮 DeviceReady
    await second;
    expect(controller.error, isNull);
    expect(transport.count(PtpOperationCode.initiateCapture), 1,
        reason: '缓存码后不再重试标准码');
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 2);
  });

  test('capture:两码皆拒 → 报后码异常,不轮询', () async {
    transport
      ..reply(PtpResponseCode.generalError) // 0x100E 拒
      ..reply(PtpResponseCode.operationNotSupported); // 0x9207 也拒
    await controller.capture();
    expect(controller.error, contains('快门释放失败'));
    expect(controller.error, contains('0x9207'), reason: '后码(尼康)失败更可诊断');
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
  });

  test('ObjectAdded → 「已拍摄」提示 + 曝光刷新;断连后迟到事件丢弃', () async {
    _scriptExposure(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.iso, 200);

    _scriptExposure(transport); // ObjectAdded 触发的刷新
    transport.eventCtrl
        .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x1234]));
    await pumpEventQueue();
    expect(controller.notice, '已拍摄');

    // 断连:_invalidate 清态
    conn.statesCtrl.add(CameraLinkState.failed);
    await pumpEventQueue();
    expect(controller.linkUp, isFalse);
    expect(controller.notice, isNull);
    expect(controller.exposure, isNull);

    // 断连后的迟到事件:notice 不得回屏
    transport.eventCtrl
        .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x5678]));
    await pumpEventQueue();
    expect(controller.notice, isNull);
  });

  test('未连接 capture:直接提示,不发操作', () async {
    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    await controller.capture();
    expect(controller.error, '未连接相机');
    expect(transport.requests, isEmpty);
  });

  test('PropDesc 驱动:desc 域入状态(枚举值/可写性可见)', () async {
    _scriptExposure(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    final f = controller.exposureProps[PtpDevicePropCode.fNumber]!;
    expect(f.value, 28);
    expect(f.desc?.enumValues, [28, 32, 40]);
    expect(f.desc?.getSet, isTrue);
    expect(controller.exposure?.shutterUs, 10000);
  });

  test('PropDesc 不可用退回裸值 0x1015(域未知但值可用)', () async {
    transport
      ..reply(PtpResponseCode.operationNotSupported) // fNumber 0x1014 拒
      ..ok(data: Uint8List.fromList([28, 0]))
      ..reply(PtpResponseCode.operationNotSupported) // exposureTime
      ..ok(data: Uint8List.fromList([16, 39, 0, 0]))
      ..reply(PtpResponseCode.operationNotSupported) // exposureIndex
      ..ok(data: Uint8List.fromList([200, 0]));
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 28);
    expect(controller.exposure?.shutterUs, 10000);
    expect(controller.exposure?.iso, 200);
    expect(controller.exposureProps[PtpDevicePropCode.fNumber]?.desc, isNull,
        reason: 'PropDesc 拒答后不得残留旧 desc');
  });

  test('门禁关(生产默认):setExposureProp 直接拒绝,零流量', () async {
    await controller.setExposureProp(PtpDevicePropCode.fNumber, 32);
    expect(controller.error, contains('曝光调节未启用'));
    expect(transport.requests, isEmpty);
    expect(controller.writing, isFalse);
  });

  test('门禁开:0x1016 裸值写出 + 回读刷新(相机 clamp 以回读为准)', () async {
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
    addTearDown(() => PtpSession.kSetPropEnabled = false);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    _scriptExposure(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.canAdjustExposure, isTrue);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue);

    transport
      ..ok() // 0x1016 写 fNumber=32
      ..ok(data: _propDescDataset( // 回读:相机 clamp 到 40
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 40,
          enums: [28, 32, 40]));
    await controller.setExposureProp(PtpDevicePropCode.fNumber, 32);

    final write = transport.requests
        .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.fNumber]);
    expect(write.dataOut, Uint8List.fromList([32, 0])); // u16 裸值
    expect(controller.exposure?.fNumber, 40, reason: '屏显以回读为准');
    expect(controller.error, isNull);
    expect(controller.writing, isFalse);
  });

  test('门禁开:相机上报只读(getSet=false)→ 拒写', () async {
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    transport
      ..ok(data: _propDescDataset( // fNumber 只读
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 28,
          getSet: false))
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.exposureTime, PtpDataType.uint32, 10000))
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200));
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    await controller.setExposureProp(PtpDevicePropCode.fNumber, 32);
    expect(controller.error, contains('只读'));
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isFalse);
  });

  test('门禁开:写失败(0x2019 忙)→ 报错,值不漂移', () async {
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
    addTearDown(() => PtpSession.kSetPropEnabled = false);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    _scriptExposure(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    transport.reply(PtpResponseCode.deviceBusy); // 0x1016 忙
    await controller.setExposureProp(PtpDevicePropCode.fNumber, 32);
    expect(controller.error, contains('曝光调节失败'));
    expect(controller.exposure?.fNumber, 28, reason: '失败后原值不动');
    expect(controller.writing, isFalse);
  });
}

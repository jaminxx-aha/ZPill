import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/connection/camera_overview_controller.dart';

/// 按序回放的假传输层(session 方法测试模板,见 ptp_session_test)。
final class FakePtpTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventsCtrl = StreamController<PtpEvent>.broadcast();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)} 的响应');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventsCtrl.stream;

  @override
  Future<void> close() async {}
}

/// 手搓 GetDeviceInfo 数据集(布局独立于被测代码;操作码表与属性表
/// 均可覆盖 —— 能力门禁测试的正反两组件)。
Uint8List buildDataset(
    {List<int> operations = const [0x1001, 0x1007, 0x1009],
    List<int> deviceProps = const [0x5001, 0x5007]}) {
  final w = ByteWriter()
    ..u16(0x0100)
    ..u32(0x0000000A)
    ..u16(0x0064);
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str('Nikon');
  w.u16(0x0000);
  w.u32(operations.length);
  for (final op in operations) {
    w.u16(op);
  }
  w.u32(1); // events
  w.u16(0x4002);
  w.u32(deviceProps.length);
  for (final p in deviceProps) {
    w.u16(p);
  }
  w
    ..u32(0) // captureFormats
    ..u32(2) // imageFormats
    ..u16(0x3000)
    ..u16(0x3801);
  str('Nikon Corp');
  str('TestModel');
  str('V1.00');
  str('012345678901');
  return w.takeBytes();
}

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  /// 可变当前态(放行门用例模拟放行时点与「等窗里翻篇」;其余用例不触
  /// 碰,恒 disconnected 与旧口径同形)。
  @override
  CameraLinkState state = CameraLinkState.disconnected;

  @override
  String? get error => null;

  @override
  String? get deviceName => null;

  @override
  bool get isWireless => false;

  @override
  String? get pairingCode => null;

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {}

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}

  @override
  Future<void> disconnect() async {}
}

/// 镜头规格五连读(0xD0E0 + 0xD0E3-E6,连接沿/换镜沿各一轮;Zf 实证
/// 不在声明表但应答,40 SE 回 25/4000/4000/200/200)。默认 ID 99 不在
/// [kLensIdNames] 映射表 —— 不影响走规格描述路的既有用例。
void _scriptLensSpec(FakePtpTransport transport,
    {int lensId = 99,
    int focalMin = 4000,
    int focalMax = 4000,
    int apWide = 200,
    int apTele = 200}) {
  void u32(int v) => transport.reply(PtpResult(
      responseCode: PtpResponseCode.ok,
      data: Uint8List.fromList(
          [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])));
  void u16(int v) => transport.reply(PtpResult(
      responseCode: PtpResponseCode.ok,
      data: Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF])));
  u16(lensId);
  u32(focalMin);
  u32(focalMax);
  u16(apWide);
  u16(apTele);
}

void _emitPropChanged(FakePtpTransport transport, int code) {
  transport.eventsCtrl.add(PtpEvent(
      code: PtpEventCode.devicePropChanged,
      transactionId: 0,
      params: [code]));
}

void main() {
  test('属性在册才读:电池/焦距/光圈逐码 0x1015,裸值解码', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(
            deviceProps: const [0x5001, 0x5008, 0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 u8
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 焦距 u32 = 4000(0.01mm)→ 40mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // 光圈 u16 LE = 280(ƒ/2.8)
    _scriptLensSpec(transport); // 规格五连读(0xD0E0 + 0xD0E3-E6)

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.deviceInfo?.model, 'TestModel');
    expect(controller.batteryPercent, 80);
    expect(controller.focalLengthMm, 40); // 4000(0.01mm)÷100
    expect(controller.fNumber, 280);
    // 请求序:GetDeviceInfo + 三次属性(声明表外的码不发)+ 规格五连读
    // (0xD0E0/0xD0E3-E6 声明表外但应答,2026-10-12 探针)
    expect(
        transport.requests.map((r) => r.opcode),
        [
          0x1001,
          ...List.filled(8, 0x1015),
        ]);
    expect(transport.requests.skip(1).map((r) => r.params.single), [
      0x5001,
      0x5008,
      0x5007,
      PtpDevicePropCode.lensId,
      PtpDevicePropCode.lensFocalLengthMin,
      PtpDevicePropCode.lensFocalLengthMax,
      PtpDevicePropCode.lensMaxApertureWide,
      PtpDevicePropCode.lensMaxApertureTele,
    ]);
  });

  test('连接沿放行门:门挂住概览零请求,放行即上路', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final gate = Completer<void>();
    CameraOverviewController(
        session: session,
        connection: conn,
        connectRefreshGate: () => gate.future);

    // 放行后整链可排空的应答(GetDeviceInfo + 电池/焦距/光圈 + 规格五连读)
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5001, 0x5008, 0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 u8
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 焦距 u32
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // 光圈 u16
    _scriptLensSpec(transport);

    conn.state = CameraLinkState.connected;
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(transport.requests, isEmpty, reason: '门挂住:起景段未落定,概览不抢锁');

    gate.complete();
    await pumpEventQueue();
    expect(transport.requests.first.opcode, 0x1001, reason: '门放行即上路');
  });

  test('连接沿放行门:等窗里翻篇(断开),放行后不追', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final gate = Completer<void>();
    CameraOverviewController(
        session: session,
        connection: conn,
        connectRefreshGate: () => gate.future);

    conn.statesCtrl.add(CameraLinkState.connected);
    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    gate.complete(); // 放行时已是断开态
    await pumpEventQueue();
    expect(transport.requests, isEmpty, reason: '翻篇不追:重连沿有自己的新定时');
  });

  test('渐进刷新:数据点赋值沿即 notify,不等整链跑完', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(
            deviceProps: const [0x5001, 0x5008, 0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 u8
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 焦距 40mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // 光圈 ƒ/2.8
    _scriptLensSpec(transport);

    var notifies = 0;
    controller.addListener(() => notifies++);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    // 机身组 + 电池/焦距/光圈逐点 + 镜头规格 = 5 次沿通知(旧实现整链
    // 只在尾部 notify 一次,电池/镜头卡要陪跑完全部 8 事务才可见)。
    expect(notifies, 5);
  });

  test('裸值方言偏离回 string:安全取整退 null,整链照走不中断', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5001])));
    // 电池应答 5 字节 string 布局(标准 u8 宽度失配 → 嗅探按 string):
    // 硬转型 `as int?` 在此抛 TypeError 逃 on Exception 收口 —— 整链
    // 静默中断、镜头规格永远不读;安全取整退 null = 该行缺省,链照走。
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([2, 0x41, 0, 0x42, 0]))); // PTP string 'AB'
    _scriptLensSpec(transport);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.batteryPercent, isNull);
    expect(controller.lensSpec, isNotNull, reason: '链未被坏值中断');
    expect(transport.requests, hasLength(7)); // GetDeviceInfo + 电池 + 规格五连读
  });

  test('标准属性全不在册:只发 GetDeviceInfo,规格五连读绕声明表照发', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    _scriptLensSpec(transport); // 0xD0E0/0xD0E3-E6 不在声明表但应答(探针定案)

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.deviceInfo?.model, 'TestModel');
    expect(controller.batteryPercent, isNull);
    expect(controller.focalLengthMm, isNull);
    expect(controller.fNumber, isNull);
    // GetDeviceInfo + 规格五连读(0xD0E0 + 0xD0E3-E6)
    expect(transport.requests, hasLength(6));
    expect(controller.lensSpec?.description, '40mm ƒ/2');
  });

  test('断连清态;门闩挡住迟到的属性事件(不再发请求)', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5001, 0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 80%
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // ƒ/2.8
    _scriptLensSpec(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.deviceInfo, isNotNull);
    expect(controller.lensSpec, isNotNull);

    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    expect(controller.deviceInfo, isNull);
    expect(controller.batteryPercent, isNull);
    expect(controller.fNumber, isNull);
    expect(controller.lensSpec, isNull); // 规格随断连清态
    expect(controller.lensId, isNull);
    expect(controller.lensDisplay, isNull);

    // 迟到的属性事件:_linkUp 门闩,静默丢弃
    _emitPropChanged(transport, PtpDevicePropCode.fNumber);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();
    expect(controller.fNumber, isNull);
    // GetDeviceInfo + 电池 + 光圈 + 规格五连读,断连后零新增
    expect(transport.requests, hasLength(8));
  });

  test('镜头规格直读:0xD0E0 + 0xD0E3-E6 拼装,无 EXIF 时镜头行回规格描述',
      () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    _scriptLensSpec(transport,
        focalMin: 2400, focalMax: 12000, apWide: 400, apTele: 630);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    final spec = controller.lensSpec;
    expect(spec, isNotNull);
    expect(spec!.focalMinMm, 24);
    expect(spec.focalMaxMm, 120);
    expect(spec.maxApertureWide, 400);
    expect(spec.maxApertureTele, 630);
    expect(spec.containsFocal(85), isTrue);
    expect(spec.containsFocal(200), isFalse);
    expect(spec.description, '24-120mm ƒ/4-6.3');
    // 不拍照即知:ID 未收录映射表,lensDisplay 退规格描述
    expect(controller.lensId, 99);
    expect(controller.lensDisplay, '24-120mm ƒ/4-6.3');
    // 五码次序 D0E0 打头 → D0E6,直读不走声明表门禁
    expect(transport.requests.skip(1).map((r) => r.params.single), const [
      PtpDevicePropCode.lensId,
      PtpDevicePropCode.lensFocalLengthMin,
      PtpDevicePropCode.lensFocalLengthMax,
      PtpDevicePropCode.lensMaxApertureWide,
      PtpDevicePropCode.lensMaxApertureTele,
    ]);
  });

  test('规格拒答降级:lensSpec 保持 null,镜头行回 --', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    // ID 打头拒答(降级容忍)+ 首个规格码拒答(规格循环短路)
    transport.fail(const PtpResponseException(
        opcode: 0x1015, responseCode: PtpResponseCode.generalError));
    transport.fail(const PtpResponseException(
        opcode: 0x1015, responseCode: PtpResponseCode.generalError));

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.lensId, isNull);
    expect(controller.lensSpec, isNull);
    expect(controller.lensDisplay, isNull);
  });

  test('0x4006 实时追平:拨轮改光圈行即变(不拍照),同窗事件去抖收敛', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // 连接沿:0x5007 在册先读
    _scriptLensSpec(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    // 拨轮连转两下:同窗去抖,一轮读值
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x18, 0x01]))); // ƒ/2.8
    _emitPropChanged(transport, PtpDevicePropCode.fNumber);
    _emitPropChanged(transport, PtpDevicePropCode.fNumber);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(controller.fNumber, 280);
    expect(controller.focalLengthMm, isNull);
    // GetDeviceInfo + 连接沿 0x5007 + 规格五连读 + 事件一轮 0x5007
    expect(transport.requests, hasLength(8));
    expect(transport.requests.last.params.single, PtpDevicePropCode.fNumber);
  });

  test('0x4006 焦距在规格区间内(变焦):行即变,规格不重读', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5008])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x60, 0x09, 0x00, 0x00]))); // 连接沿:24mm
    _scriptLensSpec(transport,
        focalMin: 2400, focalMax: 12000, apWide: 400, apTele: 630);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.focalLengthMm, 24);
    expect(controller.lensSpec?.description, '24-120mm ƒ/4-6.3');

    // 变焦到 85mm(区间内)
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x34, 0x21, 0x00, 0x00]))); // 8500 → 85mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([99, 0]))); // 换镜哨:ID 同值(99),非换镜
    _emitPropChanged(transport, PtpDevicePropCode.focalLength);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(controller.focalLengthMm, 85);
    expect(controller.lensSpec?.description, '24-120mm ƒ/4-6.3',
        reason: '区间内变焦 + ID 同值:规格原样,零重读');
    // GetDeviceInfo + 连接沿 0x5008 + 规格五连读 + 事件一轮 0x5008+哨
    expect(transport.requests, hasLength(9));
  });

  test('0x4006 焦距挪出规格区间 = 换镜信号:ID 对比实锤,规格五连读 + 光圈对表',
      () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5007, 0x5008])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 连接沿:40mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xC8, 0x00]))); // 连接沿:ƒ/2
    _scriptLensSpec(transport); // 挂 40 SE:40-40mm ƒ/2
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.focalLengthMm, 40);
    expect(controller.lensSpec?.description, '40mm ƒ/2');

    // 热换 24-120:焦距 40 → 24(出 40-40 区间),ID 99 → 31 实锤
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x60, 0x09, 0x00, 0x00]))); // 2400 → 24mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([31, 0]))); // 换镜哨:ID 变了
    _scriptLensSpec(transport,
        lensId: 31, focalMin: 2400, focalMax: 12000, apWide: 400, apTele: 400);
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x90, 0x01]))); // 新镜头 ƒ/4
    _emitPropChanged(transport, PtpDevicePropCode.focalLength);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(controller.focalLengthMm, 24);
    expect(controller.lensSpec?.description, '24-120mm ƒ/4');
    expect(controller.fNumber, 400);
    expect(controller.lensId, 31);
    // GetDeviceInfo + 连接沿两读 + 规格五连读 + 0x5008+哨 + 新规格五连读
    // + 0x5007
    expect(transport.requests, hasLength(16));
  });

  test('0x4006 能力门禁:焦距/光圈不在声明表,事件零动作', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    _scriptLensSpec(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    _emitPropChanged(transport, PtpDevicePropCode.fNumber);
    _emitPropChanged(transport, PtpDevicePropCode.focalLength);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(controller.fNumber, isNull);
    expect(controller.focalLengthMm, isNull);
    expect(transport.requests, hasLength(6), reason: 'GetDeviceInfo + 规格五连读');
  });

  test('LensID 映射命中:不拍照出营销名全称,换镜即跟新名', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5008])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 连接沿:40mm
    _scriptLensSpec(transport, lensId: 25); // 挂 40 SE(ID 25)

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.lensDisplay, 'NIKKOR Z 40mm f/2 SE',
        reason: 'ID 表命中 = 挂机镜头权威名(规格描述给不出 SE 后缀)');

    // 热换 24-120(焦距 40 → 24 出区间,ID 25 → 31 实锤,双信号都触发)
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x60, 0x09, 0x00, 0x00]))); // 24mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([31, 0]))); // 换镜哨
    _scriptLensSpec(transport,
        lensId: 31,
        focalMin: 2400,
        focalMax: 12000,
        apWide: 400,
        apTele: 400);
    _emitPropChanged(transport, PtpDevicePropCode.focalLength);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();
    expect(controller.lensId, 31);
    expect(controller.lensDisplay, 'NIKKOR Z 24-120mm f/4 S',
        reason: '换镜后映射名即跟');
    // GetDeviceInfo + 连接沿 0x5008 + 规格五连读 + 0x5008+哨 + 新规格五连读
    expect(transport.requests, hasLength(14));
  });

  test('同区间换镜盲区修复:焦距停在 24 不挪,ID 31→25 变化照样触发规格重读',
      () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn,
        propResyncDebounce: const Duration(milliseconds: 20));

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [0x5007, 0x5008])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x60, 0x09, 0x00, 0x00]))); // 连接沿:24mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x90, 0x01]))); // 连接沿:ƒ/4
    _scriptLensSpec(transport,
        lensId: 31,
        focalMin: 2400,
        focalMax: 12000,
        apWide: 400,
        apTele: 400); // 挂 24-120 ƒ/4 S
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.lensSpec?.description, '24-120mm ƒ/4');

    // 热换 40 SE 并把变焦停在 24mm:焦距不动(区间内),出区间启发式哑火
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x60, 0x09, 0x00, 0x00]))); // 仍 24mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([25, 0]))); // 换镜哨:ID 31 → 25
    _scriptLensSpec(transport, lensId: 25); // 新规格 40-40mm ƒ/2
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xC8, 0x00]))); // 顺带对表:ƒ/2
    _emitPropChanged(transport, PtpDevicePropCode.focalLength);
    await Future.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(controller.focalLengthMm, 24);
    expect(controller.lensId, 25);
    expect(controller.lensSpec?.description, '40mm ƒ/2');
    expect(controller.lensDisplay, 'NIKKOR Z 40mm f/2 SE');
    expect(controller.fNumber, 200);
    // GetDeviceInfo + 连接沿两读 + 规格五连读 + 0x5008+哨 + 新规格五连读
    // + 0x5007
    expect(transport.requests, hasLength(16));
  });

  test('未挂镜:lensId 回 0,规格值官方明说不固定,一个都不读', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0, 0]))); // 0xD0E0 = 0(未挂)

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.lensId, isNull);
    expect(controller.lensSpec, isNull);
    expect(controller.lensDisplay, isNull);
    // GetDeviceInfo + 0xD0E0(规格四码因未挂被门禁,脚本耗尽即失败)
    expect(transport.requests, hasLength(2));
  });

  test('0xD0E0 拒答降级:ID 路放弃,规格四码照读(兼容只有规格码的机身)',
      () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    transport.fail(const PtpResponseException(
        opcode: 0x1015, responseCode: PtpResponseCode.generalError));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 40mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 40mm
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xC8, 0x00]))); // ƒ/2
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0xC8, 0x00]))); // ƒ/2

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.lensId, isNull);
    expect(controller.lensSpec?.description, '40mm ƒ/2',
        reason: 'ID 拒答不拖累规格路');
    expect(controller.lensDisplay, '40mm ƒ/2');
  });
}

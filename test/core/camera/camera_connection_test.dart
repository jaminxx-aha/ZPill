import 'dart:async';
import 'dart:io' show FileSystemException, SocketException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/core/camera/camera_info.dart';
import 'package:z_pill/core/camera/reconnect_policy.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_link_router.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/ptpip/channels.dart';
import 'package:z_pill/core/ptpip/codec.dart';
import 'package:z_pill/core/ptpip/packet.dart';
import 'package:z_pill/core/ptpip/transport.dart';
import 'package:z_pill/data/paired_cameras_store.dart';
import 'package:z_pill/platform/usb/usb_host.dart';

import '../ptp/ptp_session_test.dart'
    show FakePtpTransport, buildDeviceInfoDataset;
import '../ptpip/transport_test.dart' show FakePtpIpChannel;

/// 假 USB 主机通道:记录生命周期调用,字节管道不参与(传输层已另行单测)。
final class FakeUsbHostChannel implements UsbHostChannel {
  FakeUsbHostChannel(this.devices);

  final List<UsbDeviceHandle> devices;
  final List<String> openedIdentifiers = [];
  int closeCalls = 0;
  final StreamController<Uint8List> _eventCtrl =
      StreamController<Uint8List>.broadcast();

  /// 测试注入断链事件(生产由 WatchdogUsbHostChannel 发出)。
  final StreamController<String> breakageCtrl =
      StreamController<String>.broadcast();

  @override
  Stream<String> get breakages => breakageCtrl.stream;

  @override
  Future<List<UsbDeviceHandle>> listCameras() async => devices;

  @override
  Future<void> open(UsbDeviceHandle device) async =>
      openedIdentifiers.add(device.identifier);

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> bulkOut(Uint8List bytes) async {}

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async =>
      Uint8List(0);

  @override
  Future<void> drainIn() async {}

  @override
  Stream<Uint8List> get interruptEvents => _eventCtrl.stream;
}

const _zf = UsbDeviceHandle(
  vendorId: 0x04B0,
  productId: 0x0453,
  identifier: '1-2',
);

PtpResult _ok({Uint8List? data}) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

/// USB 线装配:fake 传输层同时充当路由器内层(生产拓扑:usbTransport
/// 即 router 的 inner,connect 时由连接层 attach)。[reconnectPolicy]/
/// [delay] 注入恢复循环(断链测试停摆/零时延用)。
(CameraConnectionImpl, PtpLinkRouter, PtpSession) wireUsb(
    FakeUsbHostChannel usb, FakePtpTransport fake,
    {ReconnectPolicy? reconnectPolicy,
    Future<void> Function(Duration)? delay}) {
  final link = PtpLinkRouter()..attach(fake);
  final session = PtpSession(transport: link);
  return (
    CameraConnectionImpl(
        usb: usb,
        usbTransport: fake,
        link: link,
        session: session,
        reconnectPolicy: reconnectPolicy,
        delay: delay),
    link,
    session,
  );
}

final _codec = PtpIpCodecImpl();

/// 包 → 线上帧形态(模拟相机推包)。
PtpIpFrame _frameOf(PtpIpPacket packet) {
  final bytes = _codec.encode(packet);
  return PtpIpFrame(
    type: packet.type,
    body: Uint8List.sublistView(bytes, kPtpIpHeaderLength),
  );
}

/// 无线路径装配:真 PtpIpTransport 骑在双假通道上(每连接新建实例,
/// 同生产语义),经 createIpTransport 注入连接层。
(CameraConnectionImpl, PtpLinkRouter, PtpSession, FakePtpIpChannel,
        FakePtpIpChannel, PtpIpTransport)
    wireWireless(FakeUsbHostChannel usb,
        {Duration? connectBudget,
        ReconnectPolicy? reconnectPolicy,
        Future<void> Function(Duration)? delay}) {
  final command = FakePtpIpChannel();
  final event = FakePtpIpChannel();
  final channels = <PtpIpChannel>[command, event];
  final ip = PtpIpTransport(
    createChannel: () => channels.removeAt(0),
    transactionTimeout: const Duration(milliseconds: 500),
  );
  final link = PtpLinkRouter();
  final session = PtpSession(transport: link);
  return (
    CameraConnectionImpl(
      usb: usb,
      usbTransport: FakePtpTransport(),
      link: link,
      session: session,
      createIpTransport: () async => ip,
      wirelessConnectBudget: connectBudget,
      reconnectPolicy: reconnectPolicy,
      delay: delay,
    ),
    link,
    session,
    command,
    event,
    ip,
  );
}

/// 脚本化:双通道握手 + GetDeviceInfo(StartData+EndData 全量携带,
/// Zf 真机小数据集形态)+ OpenSession。配对流程在 OpenSession 后还有
/// 后续(0x952B),故收尾 await 由调用方决定(见 [scriptWirelessConnect])。
///
/// [deviceInfoOperations] 覆写 GetDeviceInfo 的 op 表(默认全量;
/// STA 模式真机只报 9 项的小表人设用它模拟)。
Future<void> scriptHandshakeAndOpen(
  FakePtpIpChannel command,
  FakePtpIpChannel event, {
  List<int>? deviceInfoOperations,
}) async {
  await pumpEventQueue();
  command.emit(_frameOf(InitCommandResponsePacket(
    connectionNumber: 0xC0DE,
    cameraGuid: Uint8List(16),
    cameraName: 'NIKON Z f',
    protocolVersion: kPtpIpProtocolVersion,
  )));
  await pumpEventQueue();
  event.emit(_frameOf(const InitEventResponsePacket()));
  await pumpEventQueue();

  final dataset = deviceInfoOperations == null
      ? buildDeviceInfoDataset()
      : buildDeviceInfoDataset(operations: deviceInfoOperations);
  final gid = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(gid.opcode, PtpOperationCode.getDeviceInfo);
  command.emit(_frameOf(StartDataPacket(
      transactionId: gid.transactionId, totalLength: dataset.length)));
  command.emit(
      _frameOf(EndDataPacket(transactionId: gid.transactionId, payload: dataset)));
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: gid.transactionId)));
  await pumpEventQueue();

  final os = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(os.opcode, PtpOperationCode.openSession);
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: os.transactionId)));
}

/// 把 [connecting] 推到 connected(免配对相):脚本化连接全流程。
Future<void> scriptWirelessConnect(
  FakePtpIpChannel command,
  FakePtpIpChannel event,
  Future<void> connecting, {
  List<int>? deviceInfoOperations,
}) async {
  await scriptHandshakeAndOpen(command, event,
      deviceInfoOperations: deviceInfoOperations);
  await scriptAppMode(command); // 连接转正前切应用模式
  await connecting;
}

/// 脚本化 0x952B 取码应答(count=4,05 00 07 07 → "5077",NiConn 抓包
/// 形态)并断言请求形态(dp=3 数据入、无参数)。
Future<void> scriptPairingCode(FakePtpIpChannel command) async {
  await pumpEventQueue();
  final req = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(req.opcode, NikonOperationCode.getPtpIpPairingCode);
  expect(req.params, isEmpty);
  expect(req.dataPhaseInfo, 3, reason: '0x952B 是数据入操作');
  final payload =
      Uint8List.fromList([4, 0, 0, 0, 0x05, 0x00, 0x07, 0x07]); // → "5077"
  command.emit(_frameOf(StartDataPacket(
      transactionId: req.transactionId, totalLength: payload.length)));
  command.emit(_frameOf(
      EndDataPacket(transactionId: req.transactionId, payload: payload)));
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
  await pumpEventQueue(); // 帧异步投递:泵到 state → pairing 才返回
}

/// 脚本化 0x935A 配对确认应答并断言请求形态(param 0x2001)。
Future<void> scriptCompletePairing(FakePtpIpChannel command) async {
  await pumpEventQueue();
  final req = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(req.opcode, NikonOperationCode.completePairing);
  expect(req.params, [0x2001]);
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
  await pumpEventQueue(); // 泵到 0x935A 应答送达、配对后续(落账/重连)启动
}

/// 脚本化 0x9435 切应用模式应答 + 0x90C2 遥控闩括号(1→0)应答(连接
/// 转正前的最后一步)并断言请求形态。2026-10-15 起无线连接流与 USB
/// 同款:0x9435 无论成败都直取 0x90C2(1) 开闩 + (0) 还身(AP 真机:
/// 0x9435 OK 也是假钥匙,不发闩则取景/对焦全坏)。
Future<void> scriptAppMode(FakePtpIpChannel command) async {
  await pumpEventQueue();
  final req = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(req.opcode, NikonOperationCode.changeApplicationMode);
  expect(req.params, [1]);
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
  await pumpEventQueue();
  for (final latch in const [1, 0]) {
    final latchReq =
        _codec.decode(command.sent.last) as OperationRequestPacket;
    expect(latchReq.opcode, NikonOperationCode.changeCameraMode);
    expect(latchReq.params, [latch], reason: '0x90C2($latch) 括号');
    command.emit(_frameOf(OperationResponsePacket(
        responseCode: PtpResponseCode.ok,
        transactionId: latchReq.transactionId)));
    await pumpEventQueue();
  }
}

/// 配对测试装配:每次无线连接新建传输实例(同生产语义),通道从池里
/// 顺序出队 —— 连接 1 用 command[0]/event[0],配对后重连(连接 2)用
/// command[1]/event[1]。[connects] 为预置连接数。
(CameraConnectionImpl, PtpLinkRouter, PtpSession, List<FakePtpIpChannel>,
        List<FakePtpIpChannel>)
    wirePairing(
  FakeUsbHostChannel usb, {
  required PairedCamerasStore paired,
  int connects = 2,
  List<Duration> retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
}) {
  final command = List.generate(connects, (_) => FakePtpIpChannel());
  final event = List.generate(connects, (_) => FakePtpIpChannel());
  final pool = <PtpIpChannel>[
    for (var i = 0; i < connects; i++) ...[command[i], event[i]],
  ];
  final link = PtpLinkRouter();
  final session = PtpSession(transport: link);
  return (
    CameraConnectionImpl(
      usb: usb,
      usbTransport: FakePtpTransport(),
      link: link,
      session: session,
      pairedCameras: paired,
      postPairingRetryDelays: retryDelays,
      createIpTransport: () async => PtpIpTransport(
        createChannel: () => pool.removeAt(0),
        transactionTimeout: const Duration(milliseconds: 500),
      ),
    ),
    link,
    session,
    command,
    event,
  );
}

/// 恢复循环装配(2026-10-10 自动重连):每拍拨号新建传输实例(同生产
/// 语义),通道池顺序出队 —— 连接 1 用 command[0]/event[0],恢复拨号
/// 依次取 [connects] 内的后续组;拨号拍数超过 [connects] 后池尾是
/// [RefusingChannel](SocketException → normal 分类)—— 通道池越界会抛
/// RangeError(Error)逃逸恢复循环的 on Exception 收口,拒连尾巴兜住。
(CameraConnectionImpl, PtpLinkRouter, PtpSession, List<FakePtpIpChannel>,
        List<FakePtpIpChannel>)
    wireRecovery(
  FakeUsbHostChannel usb, {
  PairedCamerasStore? paired,
  ReconnectPolicy? reconnectPolicy,
  Future<void> Function(Duration)? delay,
  int connects = 2,
}) {
  final command = List.generate(connects, (_) => FakePtpIpChannel());
  final event = List.generate(connects, (_) => FakePtpIpChannel());
  final pool = <PtpIpChannel>[
    for (var i = 0; i < connects; i++) ...[command[i], event[i]],
    ...List.filled(8, RefusingChannel()),
  ];
  final link = PtpLinkRouter();
  final session = PtpSession(transport: link);
  return (
    CameraConnectionImpl(
      usb: usb,
      usbTransport: FakePtpTransport(),
      link: link,
      session: session,
      pairedCameras: paired,
      postPairingRetryDelays: const [Duration(milliseconds: 10)],
      createIpTransport: () async => PtpIpTransport(
        createChannel: () => pool.removeAt(0),
        transactionTimeout: const Duration(milliseconds: 500),
      ),
      reconnectPolicy: reconnectPolicy,
      delay: delay,
    ),
    link,
    session,
    command,
    event,
  );
}

/// connect 即拒绝的通道(SocketException → 上层转热点/本地网络指引)。
final class RefusingChannel implements PtpIpChannel {
  @override
  Future<void> connect(String host, int port) async =>
      throw const SocketException('Connection refused');

  @override
  bool get isOpen => false;

  @override
  Stream<PtpIpFrame> get frames => const Stream.empty();

  @override
  Future<void> sendFrame(PtpIpFrame frame) async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('connect:listCameras → open → GetDeviceInfo → OpenSession → connected',
      () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);
    final states = <CameraLinkState>[];
    conn.states.listen(states.add);

    fake.reply(_ok(data: buildDeviceInfoDataset())); // GetDeviceInfo
    fake.reply(_ok()); // OpenSession

    await conn.connect();

    expect(conn.state, CameraLinkState.connected);
    expect(conn.deviceName, 'TestModel_12345678901',
        reason: 'USB 无实例名:型号_序列号答「哪一台」(2026-10-16 定案)');
    expect(conn.deviceModel, 'TestModel',
        reason: '型号单列:拍摄页胶囊只答机型不答哪一台(2026-10-17 定案)');
    expect(conn.error, isNull);
    expect(conn.isWireless, isFalse);
    expect(usb.openedIdentifiers, ['1-2']);
    // 状态序:connecting → connected(detecting 属 WiFi 线,跳过)
    await Future<void>.delayed(Duration.zero);
    expect(states, [
      CameraLinkState.connecting,
      CameraLinkState.connected,
    ]);
  });

  test('无相机:failed + 插线/解锁引导,不动 USB 会话', () async {
    final usb = FakeUsbHostChannel(const []);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);

    await conn.connect();

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error?.key, 'conn.errNoUsbCamera');
    expect(usb.openedIdentifiers, isEmpty);
    expect(fake.requests, isEmpty);
  });

  test('0x201E 残留会话:自动 CloseSession 后重开仍连上', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);

    fake.reply(_ok(data: buildDeviceInfoDataset())); // GetDeviceInfo
    fake.reply(const PtpResult(
        responseCode: PtpResponseCode.sessionAlreadyOpen)); // OpenSession ①
    fake.reply(_ok()); // CloseSession(残留)
    fake.reply(_ok()); // OpenSession ②
    fake.reply(_ok()); // 0x9435 切应用模式
    fake.reply(_ok()); // 0x90C2(1) 开闩(0x9435 OK 也照发,假钥匙防短路)
    fake.reply(_ok()); // 0x90C2(0) 开闩即还身(连接括号)

    await conn.connect();

    expect(conn.state, CameraLinkState.connected);
    expect(
      fake.requests.map((r) => r.opcode),
      [
        PtpOperationCode.getDeviceInfo,
        PtpOperationCode.openSession,
        PtpOperationCode.closeSession,
        PtpOperationCode.openSession,
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ],
    );
  });

  test('disconnect:连接括号已退 remote → teardown 无 remote 可退,'
      'detach 挡住 CloseSession,状态回 disconnected', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, session) = wireUsb(usb, fake);

    fake.reply(_ok(data: buildDeviceInfoDataset()));
    fake.reply(_ok()); // OpenSession
    fake.reply(_ok()); // 0x9435 切应用模式
    fake.reply(_ok()); // 0x90C2(1) 开闩
    fake.reply(_ok()); // 0x90C2(0) 开闩即还身(连接括号)
    await conn.connect();

    await conn.disconnect();

    expect(conn.state, CameraLinkState.disconnected);
    expect(conn.deviceName, isNull);
    expect(session.isSessionOpen, isFalse);
    expect(usb.closeCalls, 1);
    // 连接括号(1→0)已还身:remoteModeActive=false,teardown 无 remote
    // 可退(用户「接管」开启的 remote 才走退步,见控制器测试);detach
    // 先行挡住 CloseSession(相机侧残留由 0x201E 自愈处理)。
    expect(fake.requests.map((r) => r.opcode), [
      PtpOperationCode.getDeviceInfo,
      PtpOperationCode.openSession,
      NikonOperationCode.changeApplicationMode,
      NikonOperationCode.changeCameraMode, // 0x90C2(1) 开闩
      NikonOperationCode.changeCameraMode, // 0x90C2(0) 连接括号还身
    ]);
    expect(fake.requests[3].params, [1]);
    expect(fake.requests[4].params, [0]);
  });

  test('OpenSession 被拒:failed + 清理(close 会话与 USB)', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);

    fake.reply(_ok(data: buildDeviceInfoDataset()));
    // 拒绝码用表内在册的 generalError:本测试验证传播与清理,不针对特定码。
    fake.reply(const PtpResult(responseCode: PtpResponseCode.generalError));

    await conn.connect();

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error, isNotNull);
    expect(usb.closeCalls, 1);
  });

  test('受限画像(op 表缺 GetObject):failed + 关机重启指引,不开会话',
      () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);

    // 2026-10-01 真机受限态:元数据/属性/事件在册,数据操作全缺。
    fake.reply(_ok(data: buildDeviceInfoDataset(
        operations: [0x1001, 0x1007, 0x9431]))); // GetDeviceInfo

    await conn.connect();

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error?.key, 'conn.errRestricted');
    // 拦在 OpenSession 之前(会话都开不了,浏览无意义)
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo]);
    expect(usb.closeCalls, 1);

    // 相机重启翻回全量画像后重连:force 刷新不吃受限缓存,正常连上。
    fake.reply(_ok(data: buildDeviceInfoDataset())); // GetDeviceInfo(force)
    fake.reply(_ok()); // OpenSession
    fake.reply(_ok()); // 0x9435 切应用模式
    fake.reply(_ok()); // 0x90C2(1) 进 remote
    await conn.connect();
    expect(conn.state, CameraLinkState.connected);
    expect(conn.deviceName, 'TestModel_12345678901');
  });

  test('断链事件(breakages):connected → reconnecting(自动恢复),清理会话与 USB',
      () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final park = Completer<void>();
    final (conn, _, session) = wireUsb(usb, fake,
        reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
        delay: (_) => park.future); // settle 即停摆:恢复循环不再前进
    final states = <CameraLinkState>[];
    conn.states.listen(states.add);

    fake.reply(_ok(data: buildDeviceInfoDataset()));
    fake.reply(_ok()); // OpenSession
    fake.reply(_ok()); // 0x9435 切应用模式
    fake.reply(_ok()); // 0x90C2(1) 开闩
    fake.reply(_ok()); // 0x90C2(0) 连接括号还身
    await conn.connect();
    expect(conn.state, CameraLinkState.connected);

    usb.breakageCtrl.add('相机已断开(USB 连接消失)');
    await pumpEventQueue();

    // 2026-10-10 自动重连:connected 断链按 _lastGood 档案转恢复期
    //(不再直接 failed;预算耗尽/未归位超限才终态,见恢复循环 group)
    expect(conn.state, CameraLinkState.reconnecting);
    expect(conn.error?.key, 'conn.recoverStatus');
    expect(conn.error?.args?['e'], '相机已断开(USB 连接消失)',
        reason: '断链原因作 {e} 参数,headline 恒为键');
    expect(session.isSessionOpen, isFalse);
    expect(usb.closeCalls, 1);
    // 断链清理:连接括号已退 remote(无 remote 可退)→ 不下 CloseSession
    // (detach 先行)
    expect(fake.requests.map((r) => r.opcode), [
      PtpOperationCode.getDeviceInfo,
      PtpOperationCode.openSession,
      NikonOperationCode.changeApplicationMode,
      NikonOperationCode.changeCameraMode, // 0x90C2(1) 开闩
      NikonOperationCode.changeCameraMode, // 0x90C2(0) 连接括号还身
    ]);
    expect(states, [
      CameraLinkState.connecting,
      CameraLinkState.connected,
      CameraLinkState.reconnecting,
    ]);
  });

  test('connecting 期间 disconnect:迟到的失败不得把 disconnected 覆盖成 failed',
      () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, _) = wireUsb(usb, fake);

    final gate = Completer<void>();
    fake.failAfter(
        gate.future,
        const PtpResponseException(
            opcode: PtpOperationCode.getDeviceInfo,
            responseCode: PtpResponseCode.generalError)); // GetDeviceInfo 延迟失败
    final connecting = conn.connect();
    await pumpEventQueue();
    expect(conn.state, CameraLinkState.connecting);

    await conn.disconnect(); // 竞态:先断开(disconnected)
    gate.complete(); // 迟到的失败这才送达

    await connecting;
    expect(conn.state, CameraLinkState.disconnected); // 不被覆盖
    expect(conn.error, isNull); // disconnect() 已清空
  });

  group('无线(PTP-IP)', () {
    test('握手 → GetDeviceInfo → OpenSession → connected(USB 全程不动)',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, session, command, event, _) = wireWireless(usb);
      final states = <CameraLinkState>[];
      conn.states.listen(states.add);

      await scriptWirelessConnect(
          command, event, conn.connect(ip: '192.168.1.1'));

      expect(conn.state, CameraLinkState.connected);
      expect(conn.isWireless, isTrue);
      expect(conn.deviceName, 'TestModel_12345678901',
          reason: '无线无实例名(手动 IP):同 USB 口径拼型号_序列号');
      expect(conn.error, isNull);
      expect(session.isSessionOpen, isTrue);
      expect(command.host, '192.168.1.1');
      expect(command.port, 15740);
      expect(usb.openedIdentifiers, isEmpty); // 无线路径不碰 USB
      expect(usb.closeCalls, 0); // 连接保持,无 teardown
      await Future<void>.delayed(Duration.zero);
      expect(states, [
        CameraLinkState.connecting,
        CameraLinkState.connected,
      ]);
    });

    test('设备名取 mDNS 实例名(型号_序列号;手动 IP 无实例名同款拼装,'
        '序列号缺失才退纯型号)', () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, session, command, event, _) = wireWireless(usb);

      await scriptWirelessConnect(command, event,
          conn.connect(ip: '192.168.1.1', instanceName: 'Z_f_8014411'));

      expect(conn.state, CameraLinkState.connected);
      expect(conn.isWireless, isTrue);
      expect(conn.deviceName, 'Z_f_8014411');
      expect(conn.deviceModel, 'TestModel',
          reason: '型号与实例名分列:胶囊用型号,相机页设备行用实例名');
      expect(session.isSessionOpen, isTrue);
    });

    test('STA 小 op 表人设(op 表缺 GetObject):照常 connected —— 按表拒连是误杀',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, session, command, event, _) = wireWireless(usb);

      // 2026-10-04 真机:STA 模式(关机重启后依旧)GetDeviceInfo 只报
      // 9 项 —— 0x1001/0x1002/0x1003 + 6 个 0x9xxx 厂商码,连
      // GetObjectHandles/GetObjectInfo 都不在表;但照片级 GetThumb/
      // GetObject 照常 0x2001。受限画像拦截仅对 USB 生效(那里是真拒绝)。
      await scriptWirelessConnect(
        command,
        event,
        conn.connect(ip: '192.168.0.104'),
        deviceInfoOperations: const [
          0x1001, 0x1002, 0x1003,
          0x935A, 0x9439, 0x9440, 0x9441, 0x9442, 0x952B,
        ],
      );

      expect(conn.state, CameraLinkState.connected);
      expect(conn.isWireless, isTrue);
      expect(conn.deviceName, 'TestModel_12345678901',
          reason: '手动 IP 无实例名:型号_序列号拼装(非纯型号)');
      expect(session.isSessionOpen, isTrue);
    });

    test('断链(command 通道被关):connected → reconnecting(自动恢复),'
        '实例/USB/路由全收口', () async {
      final usb = FakeUsbHostChannel(const []);
      final park = Completer<void>();
      final (conn, link, session, command, event, ip) = wireWireless(usb,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
          delay: (_) => park.future); // settle 即停摆:恢复循环不再前进

      await scriptWirelessConnect(
          command, event, conn.connect(ip: '192.168.1.1'));
      expect(conn.state, CameraLinkState.connected);

      command.emitClosed();
      await pumpEventQueue();

      // 2026-10-10 自动重连:断链转恢复期,链路全量收口语义不变
      expect(conn.state, CameraLinkState.reconnecting);
      expect(conn.error?.key, 'conn.recoverStatus');
      expect(conn.error?.args?['e'], contains('command 通道'),
          reason: '断链取证串作 {e} 参数');
      expect(session.isSessionOpen, isFalse);
      expect(command.closed, isTrue);
      expect(event.closed, isTrue);
      expect(usb.closeCalls, 1); // 无线 teardown 同样收口 USB
      // 无线实例报废(重连必须新建实例):execute 秒败
      await expectLater(
          ip.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<Exception>()));
      // 路由器已卸链
      await expectLater(
          link.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkDetachedException>()));
    });

    test('握手被拒(InitFail):failed + 通道关闭 + 路由器卸链', () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, link, session, command, event, ip) = wireWireless(usb);

      final connecting = conn.connect(ip: '192.168.1.1');
      await pumpEventQueue();
      command.emit(_frameOf(const InitFailPacket(reason: 0x1234)));
      await connecting; // _failConnect 内部收口,connect 不抛

      expect(conn.state, CameraLinkState.failed);
      // 2026-10-04 真机:InitFail(0x1)= 单连接槽位被 SnapBridge 占用,
      // 文案给出占用指引而非裸异常串。
      expect(conn.error?.key, 'conn.errInitRejected');
      expect(conn.error?.args?['r'], '1234', reason: 'reason 十六进制随行');
      expect(session.isSessionOpen, isFalse);
      expect(command.closed, isTrue); // 握手失败即关通道
      expect(event.closed, isTrue);
      expect(usb.closeCalls, 1);
      await expectLater(
          ip.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<Exception>()));
      await expectLater(
          link.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkDetachedException>()));
    });

    test('SocketException → 热点/本地网络指引文案', () async {
      final usb = FakeUsbHostChannel(const []);
      final channels = <PtpIpChannel>[RefusingChannel(), RefusingChannel()];
      final link = PtpLinkRouter();
      final conn = CameraConnectionImpl(
        usb: usb,
        usbTransport: FakePtpTransport(),
        link: link,
        session: PtpSession(transport: link),
        createIpTransport: () async =>
            PtpIpTransport(createChannel: () => channels.removeAt(0)),
      );

      await conn.connect(ip: '192.168.1.1');

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.errUnreachable');
      expect(conn.error?.args?['ip'], '192.168.1.1', reason: '地址随行');
      expect(usb.closeCalls, 1);
      await expectLater(
          link.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkDetachedException>()));
    });

    test('半哑相机(TCP 通但握手不答):总预算一次收口,不逐级等分步超时',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final command = FakePtpIpChannel();
      final event = FakePtpIpChannel();
      final pool = <PtpIpChannel>[command, event];
      final link = PtpLinkRouter();
      final conn = CameraConnectionImpl(
        usb: usb,
        usbTransport: FakePtpTransport(),
        link: link,
        session: PtpSession(transport: link),
        createIpTransport: () async => PtpIpTransport(
          createChannel: () => pool.removeAt(0),
          // 分步超时 500ms > 总预算 30ms:证明收口来自总预算而非分步
          transactionTimeout: const Duration(milliseconds: 500),
        ),
        wirelessConnectBudget: const Duration(milliseconds: 30),
      );

      // 不脚本化任何握手响应:TCP 即接、Init 之后死寂(真机人设:IP 可
      // 达但相机 PTP-IP 栈不答 —— 分步超时逐级叠加单次尝试能拖 30s+,
      // 2026-10-08 用户反馈「上次」连接很久才失败)
      await conn.connect(ip: '192.168.1.1');

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.errTimeout');
      expect(conn.error?.args?['ip'], '192.168.1.1');
      expect(conn.isWireless, isFalse); // 预算收口时链路未立成
      expect(usb.closeCalls, 1);

      // 僵尸续体(在途握手仍等自己的分步超时)稍后自行收口关双通道,
      // 不留泄漏的 TCP
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(command.closed, isTrue);
      expect(event.closed, isTrue);
    });

    test('半哑相机之二(收下会话但 op 死寂):切应用模式同计总预算,'
        '不挂满 15s 后带毒转 connected', () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, session, command, event, _) = wireWireless(usb,
          connectBudget: const Duration(milliseconds: 30));

      final connecting = conn.connect(ip: '192.168.1.1');
      // 握手 + GetDeviceInfo + OpenSession 全应答(相机收得下会话),
      // 之后 0x9435 一去不回 —— 真机人设:停在有线界面的相机对无线
      // Init 不拒也不答 op
      await scriptHandshakeAndOpen(command, event);
      await connecting;

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.errTimeout');
      // 确实走到了切应用模式这一步(不是握手期就死了)
      final ladderOp = _codec.decode(command.sent.last);
      expect(ladderOp, isA<OperationRequestPacket>()
          .having((p) => p.opcode, 'opcode', NikonOperationCode.changeApplicationMode));
      expect(session.isSessionOpen, isFalse); // teardown 已收口
      expect(command.closed, isTrue); // 会话已立成,close 即刻关双通道
      expect(event.closed, isTrue);
      expect(usb.closeCalls, 1);
    });
  });

  group('无线配对(0x952B → 0x935A,相机记录本设备)', () {
    test('未配对:取码 → pairing 等确认 → 确认 → 相机收线不算断链 → '
        'teardown 重连 → connected + 配对档案落账', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, session, command, event) =
          wirePairing(usb, paired: paired);
      final states = <CameraLinkState>[];
      conn.states.listen(states.add);

      // 连接 1:握手 → GetDeviceInfo → OpenSession → 取码 → pairing 态
      final connecting =
          conn.connect(ip: '192.168.0.104', instanceName: 'Z_f_8014411');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      expect(conn.state, CameraLinkState.pairing);
      expect(conn.pairingCode, '5077');

      // 用户确认 → 0x935A → 相机 OK 后自行收线(NiConn 抓包:单连接
      // 服务器释放槽位),不得按「等待配对确认期间断链」误报
      await conn.confirmPairing();
      await scriptCompletePairing(command[0]);
      command[0].emitClosed();
      await pumpEventQueue();

      // teardown + 重连(连接 2):档案已落账,免配对相直连
      await scriptWirelessConnect(command[1], event[1], connecting);

      expect(conn.state, CameraLinkState.connected);
      expect(conn.pairingCode, isNull);
      expect(conn.error, isNull);
      expect(session.isSessionOpen, isTrue);
      expect(command[1].host, '192.168.0.104');
      // 档案:键 = GetDeviceInfo 序列号,展示名 = mDNS 实例名
      final saved = await paired.list();
      expect(saved, hasLength(1));
      expect(saved.single.id, '12345678901');
      expect(saved.single.name, 'Z_f_8014411');
      expect(saved.single.model, 'TestModel');
      expect(saved.single.lastIp, '192.168.0.104');
      expect(saved.single.lastConnectedAt, isNotNull);
      // 状态序:connecting → pairing → connecting(重连)→ connected
      expect(states, [
        CameraLinkState.connecting,
        CameraLinkState.pairing,
        CameraLinkState.connecting,
        CameraLinkState.connected,
      ]);
    });

    test('配对后重连:首连被拒(机身等按 OK)→ 整窗保持 connecting 安静重试 '
        '→ connected', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, session, command, event) = wirePairing(usb,
          paired: paired,
          connects: 3,
          retryDelays: const [Duration(milliseconds: 30)]);
      final states = <CameraLinkState>[];
      conn.states.listen(states.add);

      final connecting =
          conn.connect(ip: '192.168.0.104', instanceName: 'Z_f_8014411');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      await conn.confirmPairing();
      await scriptCompletePairing(command[0]);
      command[0].emitClosed();
      await pumpEventQueue();

      // 重连 1:等它拨号到 command[1],按「机身确认前槽位不可用」拒之
      // (2026-10-06 Zf 真机形态:相机弹「配对完成」等按 OK)
      for (var i = 0; command[1].sent.isEmpty && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(command[1].sent, isNotEmpty, reason: '配对后重连已拨号');
      command[1].emit(_frameOf(const InitFailPacket(reason: 0x1)));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // silent 拍:失败不上报状态,等待机身按 OK 期间不闪失败横幅
      expect(conn.state, CameraLinkState.connecting,
          reason: '被拒不转 failed,整窗保持 connecting');

      // 退避(30ms)后重连 2:全流程成功
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await scriptWirelessConnect(command[2], event[2], connecting);
      expect(conn.state, CameraLinkState.connected);
      expect(conn.error, isNull);
      expect(session.isSessionOpen, isTrue);
      final saved = await paired.list();
      expect(saved.single.wirelessPaired, isTrue);
      // 状态序:connecting → pairing → connecting(等按 OK,含被拒的静默
      // 重试拍)→ connected —— 无 failed 闪断
      expect(states, [
        CameraLinkState.connecting,
        CameraLinkState.pairing,
        CameraLinkState.connecting,
        CameraLinkState.connected,
      ]);
    });

    test('配对后重连:整个等待窗全被拒 → failed + 机身按 OK 指引'
        '(档案已落账,下次免配对)', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      // 两拍退避 → 1+2 = 3 次重试(连接 1=配对,2/3/4=重试拍)
      final (conn, _, _, command, event) = wirePairing(usb,
          paired: paired,
          connects: 4,
          retryDelays: const [
            Duration(milliseconds: 30),
            Duration(milliseconds: 30)
          ]);
      final connecting =
          conn.connect(ip: '192.168.0.104', instanceName: 'Z_f_8014411');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      await conn.confirmPairing();
      await scriptCompletePairing(command[0]);
      command[0].emitClosed();
      await pumpEventQueue();

      // 三拍重试全按「槽位不可用」拒
      for (var i = 1; i <= 3; i++) {
        for (var k = 0; command[i].sent.isEmpty && k < 100; k++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(command[i].sent, isNotEmpty, reason: '重连拍 $i 已拨号');
        command[i].emit(_frameOf(const InitFailPacket(reason: 0x1)));
      }
      for (var k = 0; conn.state != CameraLinkState.failed && k < 200; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await connecting;

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.pairGiveUp', reason: '配对后重连窗耗尽');
      // 配对已成功落账(wirelessPaired=true):用户按完 OK 手动重点连接
      // 即免配对直连,不再重走配对相
      final saved = await paired.list();
      expect(saved.single.wirelessPaired, isTrue);
    });

    test('配对后重连:等待期间用户断开 → 即止,不再拨号', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      // 长退避(200ms)给断开留窗口;connects=3 供第 2 拍(若误重试则
      // command[2] 会收到拨号,断言捕获)
      final (conn, _, _, command, event) = wirePairing(usb,
          paired: paired,
          connects: 3,
          retryDelays: const [Duration(milliseconds: 200)]);
      final connecting =
          conn.connect(ip: '192.168.0.104', instanceName: 'Z_f_8014411');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      await conn.confirmPairing();
      await scriptCompletePairing(command[0]);
      command[0].emitClosed();
      await pumpEventQueue();

      // 重连拍 1 被拒 → 进入 200ms 退避
      for (var i = 0; command[1].sent.isEmpty && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      command[1].emit(_frameOf(const InitFailPacket(reason: 0x1)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(conn.state, CameraLinkState.connecting);

      // 退避期间用户主动断开 → 循环止步,不再有新拨号
      await conn.disconnect();
      await connecting;
      expect(conn.state, CameraLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(command[2].sent, isEmpty, reason: '断开后不再重试');
    });

    test('已配对(档案在册):不问配对直连,链路上无 0x952B/0x935A', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      await paired.save(const CameraInfo(
        id: '12345678901',
        name: 'Z_f_8014411',
        model: 'TestModel',
        lastIp: '192.168.0.104',
        wirelessPaired: true,
      ));
      final (conn, _, _, command, event) = wirePairing(usb, paired: paired);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.0.104'));

      expect(conn.state, CameraLinkState.connected);
      final ops = command[0].sent
          .map(_codec.decode)
          .whereType<OperationRequestPacket>()
          .map((p) => p.opcode)
          .toList();
      expect(ops, [
        PtpOperationCode.getDeviceInfo,
        PtpOperationCode.openSession,
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode, // 0x90C2(1) 开闩
        NikonOperationCode.changeCameraMode, // 0x90C2(0) 还身(连接括号)
      ]);
    });

    test('取码被拒(裸错误响应):当前会话照常转正,不落档案(下次再问)',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, _, command, event) = wirePairing(usb, paired: paired);

      final connecting = conn.connect(ip: '192.168.1.1');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await pumpEventQueue();
      final req = _codec.decode(command[0].sent.last) as OperationRequestPacket;
      expect(req.opcode, NikonOperationCode.getPtpIpPairingCode);
      command[0].emit(_frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.generalError,
          transactionId: req.transactionId)));
      await scriptAppMode(command[0]); // 会话照常转正的最后一拍
      await connecting;

      expect(conn.state, CameraLinkState.connected);
      expect(conn.pairingCode, isNull);
      expect(command[1].connected, isFalse); // 未发生重连
      // STA「连接至计算机」形态:0x952B 拒答也要落连接档案(快速重连
      // 可用),但 wirelessPaired=false —— 下次连接仍问配对,不误记。
      final saved = await paired.list();
      expect(saved, hasLength(1));
      expect(saved.single.id, '12345678901');
      expect(saved.single.lastIp, '192.168.1.1');
      expect(saved.single.wirelessPaired, isFalse);

      // 重连:配对未完成(旗标 false)→ 再问 0x952B(再拒)→ 转正
      await conn.disconnect();
      final reconnect = conn.connect(ip: '192.168.1.1');
      await scriptHandshakeAndOpen(command[1], event[1]);
      await pumpEventQueue();
      final req2 =
          _codec.decode(command[1].sent.last) as OperationRequestPacket;
      expect(req2.opcode, NikonOperationCode.getPtpIpPairingCode);
      command[1].emit(_frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.generalError,
          transactionId: req2.transactionId)));
      await scriptAppMode(command[1]);
      await reconnect;
      expect(conn.state, CameraLinkState.connected);
    });

    test('跳过配对:当前会话转正,相机不记录,无重连', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, _, command, event) = wirePairing(usb, paired: paired);

      final connecting =
          conn.connect(ip: '192.168.1.1', instanceName: 'Z_f_8014411');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      expect(conn.state, CameraLinkState.pairing);

      await conn.cancelPairing();
      await scriptAppMode(command[0]); // 转正前切应用模式
      await connecting;

      expect(conn.state, CameraLinkState.connected);
      // 用户跳过:连接档案照落(应用侧记住),但相机侧未记录 → 旗标
      // false,下次连接再问配对。
      final saved = await paired.list();
      expect(saved, hasLength(1));
      expect(saved.single.wirelessPaired, isFalse);
      expect(command[1].connected, isFalse);
      // 0x935A 未发出:链路上只有 GetDeviceInfo/OpenSession/取码
      final ops = command[0].sent
          .map(_codec.decode)
          .whereType<OperationRequestPacket>()
          .map((p) => p.opcode)
          .toList();
      expect(ops, [
        PtpOperationCode.getDeviceInfo,
        PtpOperationCode.openSession,
        NikonOperationCode.getPtpIpPairingCode,
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode, // 0x90C2(1) 开闩
        NikonOperationCode.changeCameraMode, // 0x90C2(0) 还身(连接括号)
      ]);
    });

    test('等待确认期间断链:failed 收口,配对门不悬死', () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, session, command, event) =
          wirePairing(usb, paired: paired);

      final connecting = conn.connect(ip: '192.168.1.1');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      expect(conn.state, CameraLinkState.pairing);

      command[0].emitClosed();
      await pumpEventQueue();

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.pairWaitBroken');
      expect(conn.pairingCode, isNull);
      expect(session.isSessionOpen, isFalse);
      expect(await paired.list(), isEmpty);
      await connecting; // aborted 出口:connect() 正常返回,可立即重连
    });

    test('CompletePairing 被拒(非 OK,链路仍活):按跳过处理,下次再问',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final paired = InMemoryPairedCamerasStore();
      final (conn, _, _, command, event) = wirePairing(usb, paired: paired);

      final connecting = conn.connect(ip: '192.168.1.1');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      await conn.confirmPairing();
      await pumpEventQueue();
      final req = _codec.decode(command[0].sent.last) as OperationRequestPacket;
      expect(req.opcode, NikonOperationCode.completePairing);
      command[0].emit(_frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.generalError,
          transactionId: req.transactionId)));
      await scriptAppMode(command[0]); // 按跳过处理后的转正一拍
      await connecting;

      expect(conn.state, CameraLinkState.connected);
      // 拒答按跳过处理:档案落账但旗标 false,下次再问。
      final saved = await paired.list();
      expect(saved, hasLength(1));
      expect(saved.single.wirelessPaired, isFalse);
      expect(command[1].connected, isFalse);
    });

    test('配对档案写盘失败:failed 收口,不卡死 pairing(守卫补洞)', () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, _, command, event) =
          wirePairing(usb, paired: const _SaveFailingStore());

      final connecting = conn.connect(ip: '192.168.1.1');
      await scriptHandshakeAndOpen(command[0], event[0]);
      await scriptPairingCode(command[0]);
      await conn.confirmPairing();
      await scriptCompletePairing(command[0]);
      await connecting;

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.errWireless');
      expect(conn.pairingCode, isNull);
    });
  });

  group('自动重连(断链恢复循环,2026-10-10)', () {
    test('断链 → reconnecting → 完整重拨成功 → connected(恢复建立的连接)',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final delays = <Duration>[];
      final (conn, _, session, command, event) = wireRecovery(usb,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
          delay: (d) async => delays.add(d), // 全零时延:settle/退避即过
          connects: 2);
      final states = <CameraLinkState>[];
      conn.states.listen(states.add);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.0.104'));
      expect(conn.state, CameraLinkState.connected);

      command[0].emitClosed();
      await pumpEventQueue();

      expect(conn.state, CameraLinkState.reconnecting);
      expect(conn.error?.key, 'conn.recoverStatus');
      expect(conn.error?.args?['e'], contains('command 通道'));
      expect(session.isSessionOpen, isFalse);

      // settle 静置已过(注入零时延):恢复拨号即刻发出(新传输实例新通道)
      await scriptHandshakeAndOpen(command[1], event[1]);
      await scriptAppMode(command[1]);
      for (var k = 0; conn.state != CameraLinkState.connected && k < 100; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(conn.state, CameraLinkState.connected);
      expect(conn.error, isNull);
      expect(session.isSessionOpen, isTrue);
      expect(command[1].host, '192.168.0.104');
      expect(delays, [
        const Duration(milliseconds: 1200), // settle:相机拆会话槽需要时间
      ], reason: '首拨成功,无退避拍');
      expect(states, [
        CameraLinkState.connecting,
        CameraLinkState.connected,
        CameraLinkState.reconnecting,
        CameraLinkState.connected,
      ]);
    });

    test('busy 慢拍:InitFail 0x1 恒 5s 不耗预算(maxAttempts:0 也不终态);'
        '连拍 ≥2 换「相机被占用」文案', () async {
      final usb = FakeUsbHostChannel(const []);
      final delays = <Duration>[];
      var beat = 0;
      final park = Completer<void>();
      final (conn, _, _, command, event) = wireRecovery(usb,
          // normal 预算 0:busy 若误耗预算,首拍即 null → failed(断言捕获)
          reconnectPolicy: ReconnectPolicy(maxAttempts: 0, jitterRatio: 0),
          delay: (d) async {
            delays.add(d);
            beat++;
            if (beat >= 3) await park.future; // settle + busy 拍 1 放行,其后停摆
          },
          connects: 3);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.1.1'));
      command[0].emitClosed();
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting);

      // 拨号 1:InitFail 0x1(单连接槽位被 SnapBridge 占用)→ busy 拍 5s
      for (var i = 0; command[1].sent.isEmpty && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      command[1].emit(_frameOf(const InitFailPacket(reason: 0x1)));
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting,
          reason: 'busy 不耗预算:maxAttempts=0 下误耗即 null → failed');

      // 拨号 2:再拒 → busyStreak≥2 → 换占用文案(不再闪裸异常串)
      for (var i = 0; command[2].sent.isEmpty && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      command[2].emit(_frameOf(const InitFailPacket(reason: 0x1)));
      await pumpEventQueue();

      expect(conn.state, CameraLinkState.reconnecting,
          reason: 'busy 恒 5s 慢拍,永不终态(理论;停摆防真跑 5s)');
      expect(conn.error?.key, 'conn.errBusy');
        expect(delays, [
        const Duration(milliseconds: 1200), // settle
        const Duration(seconds: 5), // busy 拍 1
        const Duration(seconds: 5), // busy 拍 2(其后停摆)
      ]);
    });

    test('恢复拨号连续失败:预算耗尽 → failed + 「已试 N 次」指引', () async {
      final usb = FakeUsbHostChannel(const []);
      // connects=1:恢复拨号全部走池尾拒连通道(SocketException → normal 分类)
      final (conn, _, session, command, event) = wireRecovery(usb,
          reconnectPolicy: ReconnectPolicy(maxAttempts: 2, jitterRatio: 0),
          delay: (d) async {}, // 全零时延:退避拍即过
          connects: 1);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.1.1'));
      expect(conn.state, CameraLinkState.connected);

      command[0].emitClosed();
      for (var k = 0; conn.state != CameraLinkState.failed && k < 200; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      // maxAttempts=2 → 拨 3 次(第 0 拍零延迟立即重试)后预算耗尽
      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.recoverGiveUpNormal');
      expect(conn.error?.args?['n'], 3, reason: '已试 maxAttempts+1 次');
      expect(conn.error?.args?['e'], isNotNull, reason: '异常细节随行');
      expect(session.isSessionOpen, isFalse);
    });

    test('USB 断链未归位:cameraAbsent 慢拍(不耗预算);插回即拨成 connected',
        () async {
      final usb = FakeUsbHostChannel([_zf]); // 非 const:要 clear/add
      final fake = FakePtpTransport();
      var beat = 0;
      final park = Completer<void>();
      final (conn, _, session) = wireUsb(usb, fake,
          // normal 预算 0:cameraAbsent 若误耗预算,首拍即 null → failed
          reconnectPolicy: ReconnectPolicy(maxAttempts: 0, jitterRatio: 0),
          delay: (d) async {
            beat++;
            if (beat >= 2) await park.future; // settle 放行;cameraAbsent 首拍停摆
          });

      fake.reply(_ok(data: buildDeviceInfoDataset()));
      fake.reply(_ok()); // OpenSession
      fake.reply(_ok()); // 0x9435
      fake.reply(_ok()); // 0x90C2(1)
      fake.reply(_ok()); // 0x90C2(0)
      await conn.connect();
      expect(conn.state, CameraLinkState.connected);

      // 拔出:listCameras 空 → cameraAbsent(不是 normal:预算/文案都不同)
      usb.devices.clear();
      usb.breakageCtrl.add('相机已断开(USB 连接消失)');
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting);
      expect(conn.error?.key, 'conn.waitingUsb');
      expect(usb.openedIdentifiers, ['1-2'], reason: '未归位拍不重复 open');

      // 插回 + 预置完整拨号脚本,放行停摆拍 → 下一拨即成
      usb.devices.add(_zf);
      fake.reply(_ok(data: buildDeviceInfoDataset()));
      fake.reply(_ok()); // OpenSession
      fake.reply(_ok()); // 0x9435
      fake.reply(_ok()); // 0x90C2(1)
      fake.reply(_ok()); // 0x90C2(0)
      park.complete();
      for (var k = 0; conn.state != CameraLinkState.connected && k < 200; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(conn.state, CameraLinkState.connected);
      expect(conn.error, isNull);
      expect(session.isSessionOpen, isTrue);
      expect(usb.openedIdentifiers, ['1-2', '1-2'], reason: '恢复拨号重新 open');
    });

    test('USB 未归位超限(absentMaxAttempts):failed + 重新插线指引终态',
        () async {
      final usb = FakeUsbHostChannel([_zf]);
      final fake = FakePtpTransport();
      final (conn, _, _) = wireUsb(usb, fake,
          reconnectPolicy: ReconnectPolicy(
              maxAttempts: 0, jitterRatio: 0, absentMaxAttempts: 2),
          delay: (d) async {}); // 全零时延:未归位退避拍即过

      fake.reply(_ok(data: buildDeviceInfoDataset()));
      fake.reply(_ok()); // OpenSession
      fake.reply(_ok()); // 0x9435
      fake.reply(_ok()); // 0x90C2(1)
      fake.reply(_ok()); // 0x90C2(0)
      await conn.connect();
      expect(conn.state, CameraLinkState.connected);

      usb.devices.clear();
      usb.breakageCtrl.add('相机已断开(USB 连接消失)');
      for (var k = 0; conn.state != CameraLinkState.failed && k < 200; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.recoverGiveUpUsb');
      expect(conn.error?.args?['e'], isNotNull, reason: '异常细节随行');
    });

    test('退避中 disconnect 即止(世代护栏);reconnecting 态 connect() 不抢拨号',
        () async {
      final usb = FakeUsbHostChannel(const []);
      var beat = 0;
      final park = Completer<void>();
      final (conn, _, _, command, event) = wireRecovery(usb,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
          delay: (d) async {
            beat++;
            if (beat >= 2) await park.future; // settle 放行;首拍退避停摆
          },
          connects: 1); // 恢复拨号走池尾拒连通道(normal 分类)

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.1.1'));
      expect(conn.state, CameraLinkState.connected);

      command[0].emitClosed();
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting);
      expect(conn.error?.key, 'conn.recoverStatus',
          reason: '首拍退避期(ScriptException→normal)的动态文案');

      // 护栏:reconnecting 态 connect() 立即返回,不抢拨号
      //(用户路径 = 页面「取消重连」→ disconnect → 手动连)
      await conn.connect(ip: '192.168.1.1');
      expect(conn.state, CameraLinkState.reconnecting, reason: '不抢拨号');
      expect(conn.error?.key, 'conn.recoverStatus', reason: '未被 connect() 覆盖');

      // 退避停摆期用户主动断开 → 即止
      await conn.disconnect();
      expect(conn.state, CameraLinkState.disconnected);

      // 放行停摆的退避拍:世代护栏让旧循环退出,不再有拨号/teardown
      final closeCalls = usb.closeCalls;
      park.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(usb.closeCalls, closeCalls, reason: '旧恢复循环不再拨号');
    });

    test('requestRecovery(取景看门狗升级入口):仅 connected 生效', () async {
      final usb = FakeUsbHostChannel(const [_zf]);
      final fake = FakePtpTransport();
      final park = Completer<void>();
      final (conn, _, session) = wireUsb(usb, fake,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
          delay: (_) => park.future); // settle 即停摆:恢复循环不前进

      // 非 connected:disconnected 态 no-op(不清理、不转态)
      conn.requestRecovery('取景流多次重启未恢复');
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.disconnected);
      expect(usb.closeCalls, 0);

      fake.reply(_ok(data: buildDeviceInfoDataset()));
      fake.reply(_ok()); // OpenSession
      fake.reply(_ok()); // 0x9435
      fake.reply(_ok()); // 0x90C2(1)
      fake.reply(_ok()); // 0x90C2(0)
      await conn.connect();
      expect(conn.state, CameraLinkState.connected);

      // connected:升级进恢复路(与断链同一条);生产传入的是键
      //(app_services:conn.errStreamRestart),随 {e} 参数走
      conn.requestRecovery('conn.errStreamRestart');
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting);
      expect(conn.error?.key, 'conn.recoverStatus');
      expect(conn.error?.args?['e'], 'conn.errStreamRestart');
      expect(session.isSessionOpen, isFalse);
      expect(usb.closeCalls, 1);
    });

    test('DROP 风暴:恢复建立的连接 3 次断链(120s 窗)→ 粘住暂停 failed', () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, _, _, command, event) = wireRecovery(usb,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0), // 风暴默认 120s/3 次
          delay: (d) async {}, // 全零时延:每轮恢复即拨即成
          connects: 4);
      final states = <CameraLinkState>[];
      conn.states.listen(states.add);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.1.1'));

      // 首断不是 DROP(本次运行从未由恢复建立过):进恢复,拨 1 成 → 断(DROP 1)
      for (var round = 1; round <= 3; round++) {
        command[round - 1].emitClosed();
        await pumpEventQueue();
        expect(conn.state, CameraLinkState.reconnecting,
            reason: '第 $round 轮断链进恢复期');
        await scriptHandshakeAndOpen(command[round], event[round]);
        await scriptAppMode(command[round]);
        for (var k = 0;
            conn.state != CameraLinkState.connected && k < 100;
            k++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(conn.state, CameraLinkState.connected, reason: '第 $round 轮拨成');
      }

      // 第 3 次 DROP:恢复建立的连接再断 → 120s 窗内 3 次 → 风暴粘住
      command[3].emitClosed();
      await pumpEventQueue();

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error?.key, 'conn.errReconnectPaused');
        expect(states.where((s) => s == CameraLinkState.reconnecting),
          hasLength(3), reason: '首断 + DROP 1/2 进恢复期;DROP 3 直接 failed(风暴)');
    });

    test('迟到转正守卫:恢复拨号成功在途被 disconnect → 不得覆盖 disconnected',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final store = _GatedPairedStore(const [
        CameraInfo(
          id: '12345678901',
          name: 'Z_f_8014411',
          model: 'TestModel',
          lastIp: '192.168.0.104',
          wirelessPaired: true,
        ),
      ]);
      final (conn, _, _, command, event) = wireRecovery(usb,
          paired: store,
          reconnectPolicy: ReconnectPolicy(jitterRatio: 0),
          delay: (d) async {},
          connects: 2);

      await scriptWirelessConnect(
          command[0], event[0], conn.connect(ip: '192.168.0.104'));
      expect(conn.state, CameraLinkState.connected);

      command[0].emitClosed();
      await pumpEventQueue();
      expect(conn.state, CameraLinkState.reconnecting);

      // 恢复拨号走完握手/会话/切模式 → 落账 save(转正前最后一步)停摆
      await scriptHandshakeAndOpen(command[1], event[1]);
      await scriptAppMode(command[1]);
      for (var k = 0; store.saves < 2 && k < 100; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(store.saves, 2, reason: '恢复拨号已走到转正前的落账步');

      // 停摆期内用户主动断开
      await conn.disconnect();
      expect(conn.state, CameraLinkState.disconnected);

      // 放行迟到的落账 → 守卫生效:不转 connected
      store.releaseSecondSave();
      for (var k = 0; k < 50; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(conn.state, CameraLinkState.disconnected,
          reason: '迟到续体不得把已收口的 disconnected 覆盖成 connected');
    });
  });
}

/// save 必炸的档案库(模拟写盘失败):list 正常,save 抛 FileSystemException。
final class _SaveFailingStore implements PairedCamerasStore {
  const _SaveFailingStore();

  @override
  Future<List<CameraInfo>> list() async => const [];

  @override
  Future<void> save(CameraInfo camera) async =>
      throw const FileSystemException('disk full');

  @override
  Future<void> remove(String id) async {}
}

/// 第 2 次 save(恢复拨号转正前的落账)停摆的档案库:制造「拨号成功
/// 在途、转正前一刻被外部收口」的竞态窗口。
final class _GatedPairedStore implements PairedCamerasStore {
  _GatedPairedStore(List<CameraInfo> seed) : records = [...seed];

  final List<CameraInfo> records;
  final Completer<void> _secondSaveGate = Completer<void>();
  int saves = 0;

  void releaseSecondSave() => _secondSaveGate.complete();

  @override
  Future<List<CameraInfo>> list() async => List.unmodifiable(records);

  @override
  Future<void> save(CameraInfo camera) async {
    records.removeWhere((c) => c.id == camera.id);
    records.add(camera);
    saves++;
    if (saves == 2) await _secondSaveGate.future;
  }

  @override
  Future<void> remove(String id) async {}
}

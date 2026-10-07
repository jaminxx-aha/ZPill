import 'dart:async';
import 'dart:io' show FileSystemException, SocketException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/camera/camera_info.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_link_router.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/channels.dart';
import 'package:nikon_pill/core/ptpip/codec.dart';
import 'package:nikon_pill/core/ptpip/packet.dart';
import 'package:nikon_pill/core/ptpip/transport.dart';
import 'package:nikon_pill/data/paired_cameras_store.dart';
import 'package:nikon_pill/platform/usb/usb_host.dart';

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
/// 即 router 的 inner,connect 时由连接层 attach)。
(CameraConnectionImpl, PtpLinkRouter, PtpSession) wireUsb(
    FakeUsbHostChannel usb, FakePtpTransport fake) {
  final link = PtpLinkRouter()..attach(fake);
  final session = PtpSession(transport: link);
  return (
    CameraConnectionImpl(
        usb: usb, usbTransport: fake, link: link, session: session),
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
    wireWireless(FakeUsbHostChannel usb) {
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

/// 脚本化 0x9435 切应用模式应答(连接转正前的最后一步)并断言请求
/// 形态(p1=1)。配对相走完后的直连路径同样会发它。
Future<void> scriptAppMode(FakePtpIpChannel command) async {
  await pumpEventQueue();
  final req = _codec.decode(command.sent.last) as OperationRequestPacket;
  expect(req.opcode, NikonOperationCode.changeApplicationMode);
  expect(req.params, [1]);
  command.emit(_frameOf(OperationResponsePacket(
      responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
  await pumpEventQueue();
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
    expect(conn.deviceName, 'TestModel');
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
    expect(conn.error, contains('未发现尼康相机'));
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
    expect(conn.error, contains('受限连接状态'));
    expect(conn.error, contains('重新开机'));
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
    expect(conn.deviceName, 'TestModel');
  });

  test('断链事件(breakages):connected → failed,清理会话与 USB', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final (conn, _, session) = wireUsb(usb, fake);
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

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error, '相机已断开(USB 连接消失)');
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
      CameraLinkState.failed,
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
      expect(conn.deviceName, 'TestModel');
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
      expect(conn.deviceName, 'TestModel');
      expect(session.isSessionOpen, isTrue);
    });

    test('断链(command 通道被关):connected → failed,实例/USB/路由全收口',
        () async {
      final usb = FakeUsbHostChannel(const []);
      final (conn, link, session, command, event, ip) = wireWireless(usb);

      await scriptWirelessConnect(
          command, event, conn.connect(ip: '192.168.1.1'));
      expect(conn.state, CameraLinkState.connected);

      command.emitClosed();
      await pumpEventQueue();

      expect(conn.state, CameraLinkState.failed);
      expect(conn.error, contains('command 通道'));
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
      expect(conn.error, contains('相机拒绝了连接'));
      expect(conn.error, contains('InitFail'));
      expect(conn.error, contains('SnapBridge'));
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
      expect(conn.error, contains('连不上 192.168.1.1'));
      expect(conn.error, contains('相机热点'));
      expect(conn.error, contains('允许访问本地网络'));
      expect(usb.closeCalls, 1);
      await expectLater(
          link.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkDetachedException>()));
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
      expect(saved.single.id, '012345678901');
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
      expect(conn.error, contains('按「OK」完成配对'));
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
        id: '012345678901',
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
      expect(saved.single.id, '012345678901');
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
      expect(conn.error, contains('等待配对确认期间连接断开'));
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
      expect(conn.error, contains('无线连接失败'));
      expect(conn.pairingCode, isNull);
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

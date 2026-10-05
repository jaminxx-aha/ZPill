import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/camera/camera_discovery.dart';
import 'package:nikon_pill/core/camera/camera_info.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/paired_cameras_store.dart';
import 'package:nikon_pill/features/connection/camera_overview_controller.dart';
import 'package:nikon_pill/features/connection/connection_page.dart';
import 'package:nikon_pill/platform/nsd_scanner.dart';

/// 记账假连接:connect/disconnect/配对确认落账,states 流由测试驱动。
final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  String? connectIp;
  String? connectInstanceName;
  int disconnectCalls = 0;
  bool wireless = false;
  String? code;
  int confirmCalls = 0;
  int cancelCalls = 0;

  @override
  String? deviceName;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  String? get error => null;

  @override
  bool get isWireless => wireless;

  @override
  String? get pairingCode => code;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {
    connectIp = ip;
    connectInstanceName = instanceName;
  }

  @override
  Future<void> confirmPairing() async => confirmCalls++;

  @override
  Future<void> cancelPairing() async => cancelCalls++;

  @override
  Future<void> disconnect() async => disconnectCalls++;
}

/// 记账假扫描器:事件流由测试驱动。
final class _FakeScanner implements NsdScanner {
  final eventsCtrl = StreamController<NsdEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<NsdEvent> get events => eventsCtrl.stream;

  @override
  Future<void> startBrowsing() async => startCalls++;

  @override
  Future<void> stopBrowsing() async => stopCalls++;
}

/// start 必炸的扫描器(ohos/Android 未装配 → MissingPluginException)。
final class _FailingScanner implements NsdScanner {
  @override
  Stream<NsdEvent> get events => const Stream.empty();

  @override
  Future<void> startBrowsing() async => throw MissingPluginException();

  @override
  Future<void> stopBrowsing() async {}
}

/// 按序回放的假传输层(只够 GetDeviceInfo / GetDevicePropValue 走通,
/// 已连接信息卡用)。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<PtpResult> script = Queue();

  void reply(PtpResult result) => script.add(result);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)} 的响应');
    }
    return script.removeFirst();
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

/// 手搓 GetDeviceInfo 数据集(布局独立于被测代码;deviceProps 可覆盖)。
Uint8List _deviceInfoDataset({List<int> deviceProps = const [0x5001, 0x5007]}) {
  final w = ByteWriter()
    ..u16(0x0100) // StandardVersion
    ..u32(0x0000000A) // VendorExtensionId(尼康)
    ..u16(0x0064); // VendorExtensionVersion
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str('Nikon'); // VendorExtensionDesc
  w.u16(0x0000); // FunctionalMode 标准
  w.u32(2); // operations
  w
    ..u16(0x1001)
    ..u16(0x1009);
  w.u32(1); // events
  w.u16(0x4002);
  w.u32(deviceProps.length); // deviceProps
  for (final p in deviceProps) {
    w.u16(p);
  }
  w
    ..u32(0) // captureFormats
    ..u32(2) // imageFormats
    ..u16(0x3000)
    ..u16(0x3801);
  str('Nikon Corp'); // manufacturer
  str('TestModel'); // model
  str('V1.00'); // deviceVersion
  str('012345678901'); // serialNumber
  return w.takeBytes();
}

const _zfCamera = DiscoveredIpCamera(
    name: 'Z_f_8014411', host: '192.168.0.104', port: 15740);

void main() {
  group('ConnectionController', () {
    test('connectWireless:IP 透传(去空白);空输入回落默认网关', () async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);

      controller.ipController.text = ' 10.0.0.5 ';
      await controller.connectWireless();
      expect(conn.connectIp, '10.0.0.5');

      controller.ipController.clear();
      await controller.connectWireless();
      expect(conn.connectIp, kDefaultCameraIp);
    });

    test('hint:connected 无提示(信息视图自释);pairing/failed 保留', () async {
      final conn = _FakeConnection()..deviceName = 'NIKON ZF';
      final controller = ConnectionController(connection: conn);

      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();
      expect(controller.state, CameraLinkState.connected);
      expect(controller.hint, isNull);

      conn.statesCtrl.add(CameraLinkState.pairing);
      await pumpEventQueue();
      expect(controller.hint, '相机请求配对确认(见弹窗)');

      conn.statesCtrl.add(CameraLinkState.failed);
      await pumpEventQueue();
      expect(controller.hint, '连接失败'); // error null → 兜底文案
    });

    test('activeIp:各连接方式落账(USB null / 发现 / 档案 / 手动)', () async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);

      await controller.connect(); // USB:无 IP
      expect(conn.connectIp, isNull);
      expect(controller.activeIp, isNull);

      await controller.connectDiscovered(_zfCamera);
      expect(controller.activeIp, '192.168.0.104');

      final store = InMemoryPairedCamerasStore();
      await store.save(CameraInfo(
          id: 'a',
          name: 'A',
          lastIp: '9.9.9.9',
          lastConnectedAt: DateTime(2026, 1, 1)));
      final controller2 = ConnectionController(
          connection: conn, pairedCameras: store);
      await controller2.loadSaved();
      await controller2.connectSaved(controller2.savedCameras.single);
      expect(controller2.activeIp, '9.9.9.9');

      controller2.ipController.text = ' 10.0.0.5 ';
      await controller2.connectWireless();
      expect(controller2.activeIp, '10.0.0.5');
      controller2.ipController.clear();
      await controller2.connectWireless();
      expect(controller2.activeIp, kDefaultCameraIp);
    });

    test('扫描:found/lost 驱动列表;无 IP 不上榜;点选连接 = IP + 实例名 + 停扫',
        () async {
      final conn = _FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);

      await controller.startScan();
      expect(scanner.startCalls, 1);
      expect(controller.scanning, isTrue);

      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await pumpEventQueue();
      expect(controller.cameras.single, _zfCamera);

      // 解析失败(无 IP)不上榜
      scanner.eventsCtrl.add(const NsdCameraFound(
          DiscoveredIpCamera(name: 'broken', host: '', port: 15740)));
      await pumpEventQueue();
      expect(controller.cameras, hasLength(1));

      // 同名再发现 = 去重更新,不重复上榜
      scanner.eventsCtrl.add(const NsdCameraFound(DiscoveredIpCamera(
          name: 'Z_f_8014411', host: '192.168.9.9', port: 15740)));
      await pumpEventQueue();
      expect(controller.cameras, hasLength(1));
      expect(controller.cameras.single.host, '192.168.9.9');

      // 消失事件移除
      scanner.eventsCtrl.add(const NsdCameraLost('Z_f_8014411'));
      await pumpEventQueue();
      expect(controller.cameras, isEmpty);

      // 再发现后点选连接:IP + 实例名透传,扫描停止
      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await pumpEventQueue();
      await controller.connectDiscovered(controller.cameras.single);
      expect(conn.connectIp, '192.168.0.104');
      expect(conn.connectInstanceName, 'Z_f_8014411');
      expect(scanner.stopCalls, 1);
      expect(controller.scanning, isFalse);
    });

    test('扫描未装配平台(start 抛 MissingPluginException):静默降级回手动',
        () async {
      final controller = ConnectionController(
          connection: _FakeConnection(), scanner: _FailingScanner());

      await controller.startScan();

      expect(controller.scanning, isFalse);
    });

    test('selectMethod:离开 STA 自动停扫;同方式空转不多发', () async {
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: _FakeConnection(), scanner: scanner);

      await controller.startScan();
      expect(controller.scanning, isTrue);

      // 扫描中切走 STA:结果不再可见,扫描顺手停掉
      controller.selectMethod(ConnectionMethod.ap);
      await pumpEventQueue();
      expect(controller.method, ConnectionMethod.ap);
      expect(controller.scanning, isFalse);
      expect(scanner.stopCalls, 1);

      // 非扫描态切方式:不触发多余的 stopBrowsing
      controller.selectMethod(ConnectionMethod.sta);
      controller.selectMethod(ConnectionMethod.usb);
      await pumpEventQueue();
      expect(scanner.stopCalls, 1);
      expect(controller.method, ConnectionMethod.usb);
    });

    test('loadSaved:配对档案进列表(最近优先);connectSaved 透传 IP + 实例名',
        () async {
      final store = InMemoryPairedCamerasStore();
      await store.save(CameraInfo(
          id: 'a',
          name: 'A',
          lastIp: '1.1.1.1',
          lastConnectedAt: DateTime(2026, 1, 1)));
      await store.save(CameraInfo(
          id: 'b',
          name: 'B',
          lastIp: '2.2.2.2',
          lastConnectedAt: DateTime(2026, 2, 1)));
      final conn = _FakeConnection();
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);

      await controller.loadSaved();
      expect(controller.savedCameras.map((c) => c.id), ['b', 'a']); // 2月 > 1月

      await controller.connectSaved(controller.savedCameras.first);
      expect(conn.connectIp, '2.2.2.2');
      expect(conn.connectInstanceName, 'B');
    });
  });

  group('ConnectionPage', () {
    testWidgets('AP 卡:分段切入;默认 IP 预填,点「AP 连接」按输入连接,空回落默认',
        (WidgetTester tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      // 默认有线;切到 AP 热点分段出 AP 卡
      expect(find.text('USB 连接'), findsOneWidget);
      await tester.tap(find.text('AP 热点'));
      await tester.pump();
      expect(find.text('AP 连接(相机当热点)'), findsOneWidget);
      expect(controller.ipController.text, kDefaultCameraIp);

      // 预填默认 IP:直接透传
      await tester.tap(find.widgetWithText(FilledButton, 'AP 连接'));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);

      // 清空输入:回落默认
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.widgetWithText(FilledButton, 'AP 连接'));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);

      // 自定义 IP:原样透传
      await tester.enterText(find.byType(TextField), '10.0.0.5');
      await tester.tap(find.widgetWithText(FilledButton, 'AP 连接'));
      await tester.pump();
      expect(conn.connectIp, '10.0.0.5');
    });

    testWidgets('扫描 UI:切到 STA 分段,点「扫描相机」→ 发现列表 → 点相机连接',
        (tester) async {
      final conn = _FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);
      await tester
          .pumpWidget(MaterialApp(home: ConnectionPage(controller: controller)));

      await tester.tap(find.text('同一 Wi-Fi'));
      await tester.pump();
      expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);

      await tester.tap(find.text('扫描相机'));
      await tester.pump();
      expect(scanner.startCalls, 1);
      expect(find.text('扫描中…(点按停止)'), findsOneWidget);

      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await tester.pump();
      expect(find.text('Z_f_8014411'), findsOneWidget);
      expect(find.text('192.168.0.104'), findsOneWidget);

      await tester.tap(find.text('Z_f_8014411'));
      await tester.pump();
      expect(conn.connectIp, '192.168.0.104');
      expect(conn.connectInstanceName, 'Z_f_8014411');
      expect(scanner.stopCalls, 1);
    });

    testWidgets('配对弹窗:展示验证码;确认 → confirmPairing,关窗', (tester) async {
      final conn = _FakeConnection()..code = '5077';
      final controller = ConnectionController(connection: conn);
      await tester
          .pumpWidget(MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      await tester.pumpAndSettle();
      expect(find.text('配对确认'), findsOneWidget);
      expect(find.text('5077'), findsOneWidget);

      await tester.tap(find.text('确认配对'));
      await tester.pumpAndSettle();
      expect(conn.confirmCalls, 1);
      expect(find.text('配对确认'), findsNothing); // 弹窗已关
    });

    testWidgets('配对弹窗:跳过 → cancelPairing(相机不记录,下次再问)',
        (tester) async {
      final conn = _FakeConnection()..code = '5077';
      final controller = ConnectionController(connection: conn);
      await tester
          .pumpWidget(MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      await tester.pumpAndSettle();

      await tester.tap(find.text('跳过配对'));
      await tester.pumpAndSettle();
      expect(conn.cancelCalls, 1);
      expect(conn.confirmCalls, 0);
      expect(find.text('配对确认'), findsNothing);
    });

    testWidgets('配对弹窗:等待期间断链(状态离开 pairing)自动关窗', (tester) async {
      final conn = _FakeConnection()..code = '5077';
      final controller = ConnectionController(connection: conn);
      await tester
          .pumpWidget(MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      await tester.pumpAndSettle();
      expect(find.text('配对确认'), findsOneWidget);

      // 断链:连接层已把状态收口为 failed,弹窗必须自己关掉
      conn.statesCtrl.add(CameraLinkState.failed);
      await tester.pumpAndSettle();
      expect(find.text('配对确认'), findsNothing);
    });

    testWidgets('connecting:分段切换禁用,各方式卡按钮禁用', (WidgetTester tester) async {
      final conn = _FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      // 分段切换本身禁用(连接进行中不可换方式)
      expect(
        tester
            .widget<SegmentedButton<ConnectionMethod>>(
                find.byType(SegmentedButton<ConnectionMethod>))
            .onSelectionChanged,
        isNull,
      );
      // 当前方式(有线)主按钮禁用
      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'USB 连接'))
            .onPressed,
        isNull,
      );
      // 另两方式:切过去(经控制器)按钮同样禁用
      controller.selectMethod(ConnectionMethod.ap);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'AP 连接'))
            .onPressed,
        isNull,
      );
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '扫描相机'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('已连接视图:信息卡组(链路/机身/镜头)+ 相册 + 断开连接',
        (WidgetTester tester) async {
      // 加高视口:信息卡组较长,断开按钮在折线下(点空)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = _FakeConnection()..deviceName = 'NIKON ZF';
      final transport = _ScriptTransport();
      final session = PtpSession(transport: transport);
      // refresh() 脚本:GetDeviceInfo + 电池/焦距/光圈(全在册)。
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _deviceInfoDataset(
              deviceProps: const [0x5001, 0x5008, 0x5007])));
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([80]))); // 电池 80%
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x90, 0x01]))); // 焦距 400(u16 LE)
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x18, 0x01]))); // 光圈 ƒ/2.8(280)
      final overview =
          CameraOverviewController(session: session, connection: conn);
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller, overview: overview),
      ));

      conn.statesCtrl.add(CameraLinkState.connected);
      await tester.pumpAndSettle();

      // 连接卡:USB 链路 + 设备名
      expect(find.text('USB 数据线'), findsOneWidget);
      expect(find.text('NIKON ZF'), findsOneWidget);
      // 机身卡:GetDeviceInfo + 电池(属性门禁读到)
      expect(find.text('TestModel'), findsOneWidget);
      expect(find.text('V1.00'), findsOneWidget);
      expect(find.text('012345678901'), findsOneWidget);
      expect(find.text('80%'), findsOneWidget);
      // 镜头卡:无照片/无 EXIF → 型号缺读,属性在册读到
      expect(find.text('400mm'), findsOneWidget);
      expect(find.text('ƒ/2.8'), findsOneWidget);
      // 动作:相册入口 + 断开
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('断开连接'), findsOneWidget);

      await tester.tap(find.text('断开连接'));
      await tester.pump();
      expect(conn.disconnectCalls, 1);
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/camera/camera_discovery.dart';
import 'package:nikon_pill/core/camera/camera_info.dart';
import 'package:nikon_pill/data/paired_cameras_store.dart';
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

    test('hint:connected 文案按链路区分(USB / Wi-Fi)', () async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);

      conn.deviceName = 'NIKON ZF';
      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();

      conn.wireless = false;
      expect(controller.hint, 'USB 已连接:NIKON ZF。到「浏览」页查看照片');

      conn.wireless = true;
      expect(controller.hint, 'Wi-Fi 已连接:NIKON ZF。到「浏览」页查看照片');
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
    testWidgets('无线卡:默认 IP 预填,点「手动连接」按输入连接,空回落默认',
        (WidgetTester tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      expect(find.text('无线连接(Wi-Fi)'), findsOneWidget);
      expect(controller.ipController.text, kDefaultCameraIp);

      // 预填默认 IP:直接透传
      await tester.tap(find.text('手动连接'));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);

      // 清空输入:回落默认
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('手动连接'));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);

      // 自定义 IP:原样透传
      await tester.enterText(find.byType(TextField), '10.0.0.5');
      await tester.tap(find.text('手动连接'));
      await tester.pump();
      expect(conn.connectIp, '10.0.0.5');
    });

    testWidgets('扫描 UI:点「扫描相机」→ 发现列表 → 点相机连接', (tester) async {
      final conn = _FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);
      await tester
          .pumpWidget(MaterialApp(home: ConnectionPage(controller: controller)));

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

    testWidgets('connecting / connected:无线按钮与 USB 按钮双双禁用',
        (WidgetTester tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '手动连接'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      conn.statesCtrl.add(CameraLinkState.connected);
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '手动连接'))
            .onPressed,
        isNull,
      );
      // USB 主按钮变「断开」(connected 态唯一可用动作)
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        controller.disconnect,
      );
    });
  });
}

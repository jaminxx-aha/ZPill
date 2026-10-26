import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app_services.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/camera/camera_discovery.dart';
import 'package:nikon_pill/core/camera/camera_info.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/probe.dart';
import 'package:nikon_pill/core/ptpip/subnet_scan.dart';
import 'package:nikon_pill/core/ble/ble_camera_session.dart';
import 'package:nikon_pill/core/ble/gatt_uuids.dart';
import 'package:nikon_pill/core/ble/pairing_message.dart';
import 'package:nikon_pill/core/ble/wifi_credentials.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/ble_identity_store.dart';
import 'package:nikon_pill/data/paired_cameras_store.dart';
import 'package:nikon_pill/data/settings_store.dart';
import 'package:nikon_pill/design/app_colors.dart';
import 'package:nikon_pill/features/connection/camera_overview_controller.dart';
import 'package:nikon_pill/features/connection/connection_controller.dart';
import 'package:nikon_pill/features/connection/connection_page.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/remote_page.dart';
import 'package:nikon_pill/features/settings/settings_page.dart';
import 'package:nikon_pill/l10n/l10n.dart';
import 'package:nikon_pill/platform/ble_scanner.dart';
import 'package:nikon_pill/platform/network_monitor.dart';
import 'package:nikon_pill/platform/nsd_scanner.dart';

import '../../core/ble/ble_camera_session_test.dart'
    show FakeBleHost, buildStage2, buildStage4;
import '../../core/ble/wifi_credentials_test.dart' show craftBlob;
import '../../helpers/fake_connection.dart';

/// 内存设置库(落账 update;流直推)—— 蓝牙 GPS 注入开关落库断言用。
class _FakeSettingsStore implements SettingsStore {
  final ctrl = StreamController<AppSettings>.broadcast();
  AppSettings value = const AppSettings();
  int updateCalls = 0;

  @override
  Stream<AppSettings> get settings => ctrl.stream;

  @override
  Future<AppSettings> current() async => value;

  @override
  Future<void> update(AppSettings settings) async {
    value = settings;
    updateCalls++;
    ctrl.add(settings);
  }
}

/// 记账假 joiner:join 落账可编程返回(SSID/密码/安全字节断言用,
/// gateway 模拟 native 读到的 DHCP 网关),release 计数(断连沿释放
/// 进程路由)。
final class _FakeWifiJoiner implements WifiJoiner {
  _FakeWifiJoiner({this.ok = true, this.reason, this.gateway});

  bool ok;
  String? reason;
  String? gateway;
  String? joinedSsid;
  String? joinedPassword;
  int? joinedSecurity;
  int releaseCalls = 0;

  @override
  Future<WifiJoinResult> join({
    required String ssid,
    required String password,
    required int security,
  }) async {
    joinedSsid = ssid;
    joinedPassword = password;
    joinedSecurity = security;
    return WifiJoinResult(ok: ok, reason: reason, gateway: gateway);
  }

  @override
  Future<void> release() async => releaseCalls++;

  @override
  Future<List<WifiApScan>> scanAps() async => const [];
}

/// 记账假连接:connect/disconnect/配对确认落账,states 流由测试驱动。


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

/// 挂起的 delay(永不完成):遥控页引擎帧轮询/AE 轮询在测试里驻停。
Future<void> _parkedDelay(Duration _) => Completer<void>().future;

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

const _zfCamera =
    DiscoveredIpCamera(name: 'Z_f_8014411', host: '192.168.0.104', port: 15740);

void main() {
  group('ConnectionController', () {
    test('connectWireless:候选序 mDNS 发现 > join 网关 > 默认 192.168.1.1', () async {
      final conn = FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);

      // 无发现无网关:回落默认
      await controller.connectWireless();
      expect(conn.connectIp, kDefaultCameraIp);

      // mDNS 发现最优先
      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await pumpEventQueue();
      await controller.connectWireless();
      expect(conn.connectIp, '192.168.0.104');

      // mDNS 清空(AP 方式切换沿清旧网结果)后网关次之
      controller.selectMethod(ConnectionMethod.ap);
      controller.apGateway = '192.168.100.1';
      await controller.connectWireless();
      expect(conn.connectIp, '192.168.100.1');
    });

    test('apCameraIp 候选序:mDNS 发现 > join 网关 > 默认', () {
      // mDNS 发现压网关
      expect(
          apCameraIp(discovered: const [_zfCamera], gateway: '192.168.100.1'),
          '192.168.0.104');
      // 网关压默认:相机热点网段因机型而异,网关比硬编码 192.168.1.1 普适
      expect(apCameraIp(discovered: const [], gateway: '192.168.100.1'),
          '192.168.100.1');
      // 网关缺席(native 拿不到不带键 / 空白串)回落默认 192.168.1.1
      expect(apCameraIp(discovered: const []), kDefaultCameraIp);
      expect(apCameraIp(discovered: const [], gateway: '  '), kDefaultCameraIp);
    });

    test('joinCameraAp ok 带网关:自动连接直达网关 IP(不再硬编码默认)', () async {
      final conn = FakeConnection();
      final joiner = _FakeWifiJoiner(gateway: '192.168.100.1');
      final controller =
          ConnectionController(connection: conn, wifiJoiner: joiner)
            ..cameraApCredentials = const WifiCredentials(
                ssid: 'Zf_80114411',
                password: 'wpa2pass99',
                security: 0x02,
                keySource: 'test');
      final outcome = await controller.joinCameraAp();
      expect(outcome, ApJoinOutcome.joined);
      expect(controller.apGateway, '192.168.100.1');
      expect(controller.method, ConnectionMethod.ap);
      await pumpEventQueue(); // connectWireless 是发射不等待,排微任务落地
      expect(conn.connectIp, '192.168.100.1');
    });

    test('joinCameraAp ok 无网关:回落默认 192.168.1.1(现状不变)', () async {
      final conn = FakeConnection();
      final controller =
          ConnectionController(connection: conn, wifiJoiner: _FakeWifiJoiner())
            ..cameraApCredentials = const WifiCredentials(
                ssid: 'Zf_80114411',
                password: 'wpa2pass99',
                security: 0x02,
                keySource: 'test');
      final outcome = await controller.joinCameraAp();
      expect(outcome, ApJoinOutcome.joined);
      expect(controller.apGateway, isNull);
      await pumpEventQueue();
      expect(conn.connectIp, kDefaultCameraIp);
    });

    test('STA 路不吃网关:apGateway 在手,connectManualIp 仍只认手填(空不动作)', () async {
      final conn = FakeConnection();
      final controller = ConnectionController(connection: conn)
        ..apGateway = '192.168.100.1';
      // 空输入不动作 —— STA 网关是路由器,绝不让 AP 网关顶上
      await controller.connectManualIp();
      expect(conn.connectIp, isNull);
      controller.manualIpController.text = ' 192.168.0.5 ';
      await controller.connectManualIp();
      expect(conn.connectIp, '192.168.0.5');
    });

    test('selectMethod 切进 AP 清 mDNS 旧网结果(旧网段发现连相机热点只会超时)', () async {
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: FakeConnection(), scanner: scanner);
      await controller.startScan();
      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await pumpEventQueue();
      expect(controller.cameras, isNotEmpty);

      controller.selectMethod(ConnectionMethod.ap);
      await pumpEventQueue();
      expect(controller.cameras, isEmpty,
          reason: 'AP 方式在相机热点网段,STA 扫描的旧结果跨网段,作废');
    });

    group('连接方式记忆(上次选中经 AppSettings 持久化)', () {
      test('冷启恢复:设置里存的方式装载沿回填', () async {
        final settingsStore = _FakeSettingsStore()
          ..value = const AppSettings().copyWith(connectionMethod: 'sta');
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          connection: FakeConnection(),
          settingsController: settings,
        );
        expect(controller.method, ConnectionMethod.usb, reason: '装载沿前保持默认有线');
        await pumpEventQueue();
        expect(controller.method, ConnectionMethod.sta);
      });

      test('表外持久化名不回填(保持默认有线)', () async {
        final settingsStore = _FakeSettingsStore()
          ..value = const AppSettings().copyWith(connectionMethod: 'bogus');
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          connection: FakeConnection(),
          settingsController: settings,
        );
        await pumpEventQueue();
        expect(controller.method, ConnectionMethod.usb);
      });

      test('选中即落库(写侧走 SettingsController 同一条 AppSettings 路)', () async {
        final settingsStore = _FakeSettingsStore();
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          connection: FakeConnection(),
          settingsController: settings,
        );
        await pumpEventQueue(); // 先让装载沿走完(默认档不动作)
        controller.selectMethod(ConnectionMethod.ap);
        await pumpEventQueue();
        expect(settingsStore.value.connectionMethod, 'ap');
        expect(settingsStore.updateCalls, 1);
        expect(controller.method, ConnectionMethod.ap);
      });

      test('会话内已选过:装载沿不再回填(用户选择不被旧档覆盖)', () async {
        final settingsStore = _FakeSettingsStore()
          ..value = const AppSettings().copyWith(connectionMethod: 'ap');
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          connection: FakeConnection(),
          settingsController: settings,
        );
        // 装载在途(构造沿已发起)用户先选:落库且随后到货的旧档不覆盖。
        controller.selectMethod(ConnectionMethod.sta);
        await pumpEventQueue();
        expect(controller.method, ConnectionMethod.sta);
        expect(settingsStore.value.connectionMethod, 'sta');
      });
    });

    test('hint:connected 无提示(信息视图自释);pairing/failed 保留', () async {
      final conn = FakeConnection()..deviceName = 'NIKON ZF';
      final controller = ConnectionController(connection: conn);

      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();
      expect(controller.state, CameraLinkState.connected);
      expect(controller.hint, isNull);

      conn.statesCtrl.add(CameraLinkState.pairing);
      await pumpEventQueue();
      expect(controller.hint?.key, 'conn.pairingAuto');

      conn.statesCtrl.add(CameraLinkState.failed);
      await pumpEventQueue();
      expect(controller.hint?.key, 'conn.failed'); // error null → 兜底键,渲染层落 zh
    });

    test(
        'hint:reconnecting 读连接层动态文案(恢复循环逐拍更新),'
        'error 缺席回落「正在自动重连…」', () async {
      final conn = FakeConnection()..error = (key: '正在等待相机重新接入 USB(重新插好数据线后自动续连)', args: null);
      final controller = ConnectionController(connection: conn);

      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      expect(controller.state, CameraLinkState.reconnecting);
      expect(controller.hint?.key, '正在等待相机重新接入 USB(重新插好数据线后自动续连)');

      conn.error = null;
      conn.statesCtrl.add(CameraLinkState.reconnecting); // 重复 notify 重读
      await pumpEventQueue();
      expect(controller.hint?.key, 'conn.reconnectAuto');
    });

    testWidgets('EN 环境:连接层失败消息(key+args)按英文词表渲染,'
        '异常细节原样随行(2026-10-20 用户报告:英文界面提示仍是中文)',
        (tester) async {
      final conn = FakeConnection()
        ..error = (
          key: 'conn.recoverGiveUpNormal',
          args: {'n': 9, 'e': 'SocketException: Connection timed out'}
        );
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(L10nScope(
        code: 'en',
        child: MaterialApp(home: ConnectionPage(controller: controller)),
      ));

      conn.statesCtrl.add(CameraLinkState.failed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Auto-reconnect failed (9 attempts'),
          findsOneWidget,
          reason: '模板走 en 词表,{n} 占位落地');
      expect(find.textContaining('SocketException: Connection timed out'),
          findsOneWidget,
          reason: '技术细节经 {e} 原样随行');
      expect(find.textContaining('自动重连未成功'), findsNothing,
          reason: '不再漏中文模板');
    });

    test('activeIp:各连接方式落账(USB null / 发现 / 档案 / 手动)', () async {
      final conn = FakeConnection();
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
      final controller2 =
          ConnectionController(connection: conn, pairedCameras: store);
      await controller2.loadSaved();
      await controller2.connectSaved(controller2.savedCameras.single);
      expect(controller2.activeIp, '9.9.9.9');

      // AP:候选序落账(无发现无网关 → 默认)
      final controller3 = ConnectionController(connection: conn);
      await controller3.connectWireless();
      expect(controller3.activeIp, kDefaultCameraIp);
    });

    test('扫描:found/lost 驱动列表;无 IP 不上榜;点选连接 = IP + 实例名 + 停扫', () async {
      final conn = FakeConnection();
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

    test('扫描未装配平台(start 抛 MissingPluginException):静默降级回手动', () async {
      final controller = ConnectionController(
          connection: FakeConnection(), scanner: _FailingScanner());

      await controller.startScan();

      expect(controller.scanning, isFalse);
    });

    test('rescanIfScanning:扫描中停→起重启浏览;未扫描时不动', () async {
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: FakeConnection(), scanner: scanner);

      // 未在扫描:后台恢复不触发浏览
      await controller.rescanIfScanning();
      expect(scanner.startCalls, 0);
      expect(scanner.stopCalls, 0);

      await controller.startScan();
      expect(scanner.startCalls, 1);

      // 扫描中后台恢复:重启一轮(挂起期间系统可能停掉 mDNS 查询)
      await controller.rescanIfScanning();
      expect(scanner.stopCalls, 1);
      expect(scanner.startCalls, 2);
      expect(controller.scanning, isTrue);
    });

    test('selectMethod:离开 STA 自动停扫;同方式空转不多发', () async {
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: FakeConnection(), scanner: scanner);

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

    test('loadSaved:配对档案进列表(最近优先);connectSaved 透传 IP + 实例名', () async {
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
      final conn = FakeConnection();
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);

      await controller.loadSaved();
      expect(controller.savedCameras.map((c) => c.id), ['b', 'a']); // 2月 > 1月

      await controller.connectSaved(controller.savedCameras.first);
      expect(conn.connectIp, '2.2.2.2');
      expect(conn.connectInstanceName, 'B');
    });

    group('scanSubnet(/24 网段扫描兜底,2026-10-15)', () {
      test('门禁:mDNS 已有结果 / 会话活跃时不扫,闲置态放行全网段', () async {
        var connectCalls = 0;
        final subnet = SubnetCameraScanner(
          interfaceIps: () async => ['192.168.0.5'],
          connectCheck: (host, port, timeout) async {
            connectCalls++;
            return false;
          },
        );
        final nsd = _FakeScanner();
        final conn = FakeConnection();
        final controller = ConnectionController(
            connection: conn, scanner: nsd, subnetScanner: subnet);

        // ① mDNS 有结果:探测连接是对单连接槽位的无谓打扰
        nsd.eventsCtrl.add(const NsdCameraFound(_zfCamera));
        await pumpEventQueue();
        await controller.scanSubnet();
        expect(connectCalls, 0, reason: 'mDNS 已发现,不扫(硬约束①)');
        nsd.eventsCtrl.add(const NsdCameraLost('Z_f_8014411'));
        await pumpEventQueue();

        // ② 会话活跃(连接中/已连接):探测 socket 可能占配对槽
        conn.statesCtrl.add(CameraLinkState.connecting);
        await pumpEventQueue();
        await controller.scanSubnet();
        conn.statesCtrl.add(CameraLinkState.connected);
        await pumpEventQueue();
        await controller.scanSubnet();
        expect(connectCalls, 0, reason: '会话活跃,禁止探测(硬约束②)');

        // 闲置(disconnected):放行,全网段 253 候选逐个检查
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        await controller.scanSubnet();
        expect(connectCalls, 253);
        expect(controller.subnetScanCompleted, isTrue);
      });

      test('门禁③:扫描在途重入被挡(不并发双探测),收口后旗标复位', () async {
        final gate = Completer<void>();
        var connectCalls = 0;
        final subnet = SubnetCameraScanner(
          interfaceIps: () async => ['192.168.0.5'],
          concurrency: 2,
          connectCheck: (host, port, timeout) {
            connectCalls++;
            return gate.future.then((_) => false);
          },
        );
        final controller = ConnectionController(
            connection: FakeConnection(), subnetScanner: subnet);
        final first = controller.scanSubnet();
        await pumpEventQueue();
        expect(controller.scanningSubnet, isTrue);
        expect(connectCalls, 2); // 池 2 个 worker 各挂一个
        await controller.scanSubnet(); // 重入:被门挡下
        expect(connectCalls, 2, reason: '未发起新一轮(硬约束③)');
        gate.complete();
        await first;
        expect(controller.scanningSubnet, isFalse);
        expect(controller.subnetScanCompleted, isTrue);
        expect(controller.subnetCameras, isEmpty);
      });

      test('结果落账 + connectProbed:名字透传实例名;被拒相机 IP 展示', () async {
        final conn = FakeConnection();
        final subnet = SubnetCameraScanner(
          interfaceIps: () async => ['192.168.0.5'],
          connectCheck: (host, port, timeout) async =>
              host == '192.168.0.2' || host == '192.168.0.9',
          probe: (host) async => host == '192.168.0.2'
              ? ProbedCamera(
                  host: host, name: 'NIKON Z f', cameraGuid: Uint8List(16))
              : ProbedCamera(
                  host: host,
                  name: '',
                  cameraGuid: Uint8List(0),
                  initFailReason: 0x1),
        );
        final controller =
            ConnectionController(connection: conn, subnetScanner: subnet);
        await controller.scanSubnet();
        expect(controller.subnetCameras, hasLength(2));
        expect(controller.subnetCameras.first.name, 'NIKON Z f');
        expect(controller.subnetCameras.last.rejected, isTrue,
            reason: 'InitFail 相机照样入榜(name 空,UI 以 IP 展示)');

        await controller.connectProbed(controller.subnetCameras.first);
        expect(conn.connectIp, '192.168.0.2');
        expect(conn.connectInstanceName, 'NIKON Z f');
        expect(controller.activeIp, '192.168.0.2');

        await controller.connectProbed(controller.subnetCameras.last);
        expect(conn.connectIp, '192.168.0.9');
        expect(conn.connectInstanceName, isNull,
            reason: '被拒相机无名,实例名留空(连接档案退型号)');
      });

      test('切到 AP 方式清空网段扫描结果(旧网段发现不作数)', () async {
        final subnet = SubnetCameraScanner(
          interfaceIps: () async => ['192.168.0.5'],
          connectCheck: (host, port, timeout) async => host == '192.168.0.2',
          probe: (host) async => ProbedCamera(
              host: host, name: 'NIKON Z f', cameraGuid: Uint8List(16)),
        );
        final controller = ConnectionController(
            connection: FakeConnection(), subnetScanner: subnet);
        await controller.scanSubnet();
        expect(controller.subnetCameras, hasLength(1));

        controller.selectMethod(ConnectionMethod.ap);
        expect(controller.subnetCameras, isEmpty);
        expect(controller.subnetScanCompleted, isFalse);
      });
    });
  });

  group('ConnectionPage', () {
    testWidgets('未连接主视图:方式行 + hero 点按直连;说明收进方式行 ⓘ', (WidgetTester tester) async {
      final conn = FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      // 默认有线:AppBar 三分(六~七轮)——「相机」挪左、方式位(图标+
      // 标题+ⓘ)居中、右上统一连接图标(Icons.link);中央「连接相机」
      // 钮退役(五轮:点图标连接),说明默认隐藏。usb 图标两处:方式位+hero。
      expect(find.text('有线'), findsOneWidget, reason: 'AppBar 方式位(六轮)');
      expect(find.byIcon(Icons.link), findsOneWidget,
          reason: '右上角统一连接图标(七轮,方法无关)');
      expect(find.text('连接相机'), findsNothing,
          reason: '中央连接钮退役(五轮:点图标连接)');
      expect(find.text('当前方式:有线'), findsNothing, reason: '「当前方式」字样整删');
      expect(find.byIcon(Icons.usb), findsNWidgets(2),
          reason: '方式位 + hero(六轮:右上钮换统一「连接」文字)');
      expect(find.textContaining('C-to-C 数据线直连'), findsNothing,
          reason: '说明默认隐藏(点方式行 ⓘ 弹说明弹窗)');
      expect(find.textContaining('app 将自动接管相机'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('conn_method_info')));
      await tester.pumpAndSettle();
      expect(find.textContaining('C-to-C 数据线直连'), findsOneWidget,
          reason: '点方式行 ⓘ 弹说明弹窗(五轮:入口自 hero 迁此)');
      await tester.tapAt(const Offset(400, 20)); // 点弹层外收起
      await tester.pumpAndSettle();
      expect(find.textContaining('C-to-C 数据线直连'), findsNothing);

      // 点 hero = 发起 USB 连接(无 IP;五轮图标即连接钮)
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.connectIp, isNull, reason: 'USB 连接无 IP');

      // 切 AP 方式(经控制器;弹层路径由下测覆盖):接管预告收进 ⓘ 弹窗
      //(默认隐藏),点 hero 走候选序(无发现无网关 → 默认)
      controller.selectMethod(ConnectionMethod.ap);
      await tester.pump();
      expect(find.text('AP 模式'), findsOneWidget, reason: '方式位随方式切换');
      expect(find.byIcon(Icons.wifi_tethering), findsNWidgets(2),
          reason: '方式位 + hero');
      expect(find.textContaining('app 将自动接管相机'), findsNothing,
          reason: '接管预告藏 ⓘ 弹窗后才出');
      await tester.tap(find.byKey(const ValueKey('conn_method_info')));
      await tester.pumpAndSettle();
      expect(find.textContaining('app 将自动接管相机'), findsOneWidget);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);
    });

    testWidgets('右上角模式选择弹层:方式条目 + 当前打勾;选中仅切换不连接', (tester) async {
      final conn = FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      expect(find.text('选择连接方式'), findsOneWidget);
      expect(find.text('有线'), findsNWidgets(2),
          reason: 'AppBar 方式位 + 弹层条目(六轮)');
      expect(find.text('AP 模式'), findsOneWidget);
      expect(find.text('STA 模式'), findsOneWidget);
      expect(find.text('蓝牙'), findsNothing, reason: 'BLE 未装配不出蓝牙条目');

      await tester.tap(find.text('AP 模式'));
      await tester.pumpAndSettle();
      expect(controller.method, ConnectionMethod.ap);
      expect(find.text('选择连接方式'), findsNothing, reason: '点选后收弹层');
      expect(conn.connectIp, isNull,
          reason: '选中仅切换视图,不发起连接(2026-10-19 用户定稿)');
      expect(find.text('AP 模式'), findsOneWidget,
          reason: '方式位随选中切换(弹层已收,仅页面一处)');
      expect(find.text('当前方式:AP 模式'), findsNothing, reason: '「当前方式」字样整删');
    });

    testWidgets('AP 凭据卡(EN):标签列自适应,Password 不折行不省略;'
        '整卡两行共用一宽列对齐', (tester) async {
      // EN + 测试字体(Ahem 宽度夸张)下 AP 视图在默认 600 高视口本就
      // 垂直溢出(与标签列无关的既有形态,真机字体紧凑不触)—— 加高
      // 视口让页面放得下,聚焦标签列本身。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = ConnectionController(connection: FakeConnection());
      await tester.pumpWidget(L10nScope(
        code: 'en',
        child: MaterialApp(home: ConnectionPage(controller: controller)),
      ));
      await tester.pumpAndSettle();
      controller.selectMethod(ConnectionMethod.ap);
      controller.cameraApCredentials = const WifiCredentials(
          ssid: 'Zf_80114411',
          password: 'wpa2pass99',
          security: 0x02,
          keySource: kWifiKeyFixed);
      await tester.pumpAndSettle();

      // EN 长词根治(旧 44 钉宽下 Password 折行):标签列按最长标签
      // 实测放行 —— 渲染宽 ≥ 自然宽即单行全显(不折行也不省略)。
      expect(tester.takeException(), isNull);
      final element = tester.element(find.text('Password'));
      final natural = TextPainter(
        text: TextSpan(
            text: 'Password', style: DefaultTextStyle.of(element).style),
        textScaler: MediaQuery.textScalerOf(element),
        textDirection: TextDirection.ltr,
      )..layout();
      final naturalWidth = natural.width;
      natural.dispose();
      expect(tester.getSize(find.text('Password')).width,
          greaterThanOrEqualTo(naturalWidth),
          reason: '标签列 ≥ 标签自然宽 → 单行全显');
      expect(tester.getSize(find.text('SSID')).width,
          tester.getSize(find.text('Password')).width,
          reason: '卡内 SSID/密码两行标签列同宽(整卡列对齐)');
      expect(find.text('wpa2pass99'), findsOneWidget);
    });

    testWidgets('STA 视图:进页自动扫描(静默),两段列表点行连接', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      // 原地替换(无路由):起扫挪帧尾,一帧后到位。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // 进页自动扫描;静默 —— 无扫描钮、无「扫描中」指示。
      expect(scanner.startCalls, 1);
      expect(find.text('扫描中…(点按停止)'), findsNothing, reason: '扫描静默');
      expect(find.text('扫描相机'), findsNothing, reason: '扫描钮退役');
      expect(find.text('已配对'), findsOneWidget, reason: '两段列表段名');
      expect(find.text('其它设备'), findsOneWidget);
      expect(find.text('暂无已配对设备'), findsOneWidget);
      expect(find.text('未发现设备'), findsOneWidget);

      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await tester.pump();
      await tester.pump();
      expect(find.text('Z_f_8014411'), findsOneWidget);
      expect(find.text('192.168.0.104'), findsOneWidget);

      // 点行连接(无面板可收,原地连接)
      await tester.tap(find.text('Z_f_8014411'));
      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 过渡走完
      expect(conn.connectIp, '192.168.0.104');
      expect(conn.connectInstanceName, 'Z_f_8014411');
      expect(scanner.stopCalls, 1, reason: 'connectDiscovered 自带停扫');
    });

    testWidgets('断开后快速重连列表刷新(connected → disconnected 沿上重拉档案)', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection();
      final store = InMemoryPairedCamerasStore();
      await store.save(const CameraInfo(
          id: '012345678901', name: 'Z_f_8014411', lastIp: '192.168.1.4'));
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      await tester.pump();

      // 首帧档案:STA 视图「已配对」组可见(原地替换,无面板),点行直连
      expect(find.text('Z_f_8014411'), findsOneWidget);
      await tester.tap(find.text('Z_f_8014411'));
      await tester.pump();
      expect(conn.connectIp, '192.168.1.4');
      expect(conn.connectInstanceName, 'Z_f_8014411');

      // 连接期间档案新增(另一台);断开的沿上要重拉到
      await store.save(
          const CameraInfo(id: '99', name: 'Z_8_ABC', lastIp: '192.168.1.9'));
      conn.statesCtrl.add(CameraLinkState.connected);
      await tester.pump();
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await tester.pumpAndSettle();

      // 断开沿重拉的档案原地刷新(无面板可收)
      expect(find.text('Z_8_ABC'), findsOneWidget, reason: '断开沿上重拉连接档案');
      expect(find.text('Z_f_8014411'), findsOneWidget);
    });

    testWidgets('STA hero 点按连最近(八轮):首条「最近」徽,在途点按取消', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection();
      final store = InMemoryPairedCamerasStore();
      await store.save(CameraInfo(
          id: '012345678901',
          name: 'Z_f_8014411',
          lastIp: '192.168.1.4',
          lastConnectedAt: DateTime(2026, 10, 1)));
      await store.save(CameraInfo(
          id: '99',
          name: 'Z_8_ABC',
          lastIp: '192.168.1.9',
          lastConnectedAt: DateTime(2026, 10, 18)));
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      await tester.pump();

      // 首条 = 档案最近优先(Z_8_ABC 10-18 > Z_f 10-1):唯一「最近」徽。
      expect(find.text('Z_8_ABC'), findsOneWidget);
      expect(find.text('Z_f_8014411'), findsOneWidget);
      expect(find.text('最近'), findsOneWidget,
          reason: '最近连接条目名后绿底「最近」徽(八轮,仅首条)');

      // hero 点按 = 连最近(与列表行同路 connectSaved:首条 IP/实例名)。
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.connectIp, '192.168.1.9', reason: 'hero 连最近 = 档案首条');
      expect(conn.connectInstanceName, 'Z_8_ABC');

      // 在途再点 hero = 取消(与 USB/AP hero 同语义)。
      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      expect(find.text('取消连接'), findsNothing,
          reason: '九轮:STA 连接中底部取消按钮退役(取消 = 再点 hero)');
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.disconnectCalls, 1, reason: '在途点按 = 取消连接');
    });

    testWidgets('connecting 态:点图标取消连接;方式选择禁用', (tester) async {
      final conn = FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();

      // 中央按钮退役(五轮):取消 = 再点图标,页面不再出按钮
      expect(find.text('取消连接'), findsNothing, reason: '中央按钮退役(五轮)');
      expect(find.text('连接相机'), findsNothing);
      // 右上角连接图标钮禁用(连接进行中不可换方式;七轮统一图标)
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('conn_mode_picker')))
            .onPressed,
        isNull,
      );

      // 在途点 hero = 取消连接(五轮:图标即连接钮)
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.disconnectCalls, 1, reason: '在途点图标 = 取消连接');
    });

    testWidgets(
        'reconnecting 态:状态行「正在重连…」+ 错误位动态文案 + '
        '点图标取消', (tester) async {
      final conn = FakeConnection()
        ..error = (key: '相机被占用(可能被 SnapBridge/尼享连接),每 5 秒慢速重试,可点「取消」', args: null);
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.reconnecting);
      // 状态行尾槽 spinner(不定进度)永不 settle —— pump 走帧即可。
      await tester.pump();

      expect(find.text('正在重连…'), findsOneWidget, reason: '状态行 label');
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'busy 尾槽 spinner(重连进行中)');
      expect(find.text('相机被占用(可能被 SnapBridge/尼享连接),每 5 秒慢速重试,可点「取消」'),
          findsOneWidget,
          reason: '固定错误位读连接层动态文案(busy 慢拍分类)');
      // 中央按钮退役(五轮):取消 = 点图标
      expect(find.text('取消重连'), findsNothing, reason: '中央按钮退役(五轮)');
      expect(find.text('取消连接'), findsNothing);

      // 右上角连接图标钮禁用(恢复期不可换方式;七轮统一图标)
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('conn_mode_picker')))
            .onPressed,
        isNull,
      );

      // 在途点 hero = 取消重连(五轮:图标即连接钮)
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.disconnectCalls, 1,
          reason: '在途点图标 = 取消重连(disconnect,恢复循环即止)');
    });

    testWidgets('无感配对:进 pairing 态自动确认,全程不弹窗', (tester) async {
      final conn = FakeConnection()..pairingCode = '5077';
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      // pairing 态状态卡尾槽是 spinner(不定进度),pumpAndSettle 永不
      // settle —— 用 pump 走帧即可。
      await tester.pump();
      // 验证码不回传相机(0x935A 参数与码无关),自动确认与手动等价;
      // 多次 notify 只确认一次(哨兵)。
      expect(conn.confirmCalls, 1);
      expect(find.text('配对确认'), findsNothing);
      conn.statesCtrl.add(CameraLinkState.pairing); // 状态未离开的重复 notify
      await tester.pump();
      expect(conn.confirmCalls, 1);
    });

    testWidgets('无感配对:等待期间断链 → 状态收口,无弹窗可滞留', (tester) async {
      final conn = FakeConnection()..pairingCode = '5077';
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      await tester.pump();
      expect(conn.confirmCalls, 1);
      conn.statesCtrl.add(CameraLinkState.failed);
      await tester.pumpAndSettle();
      expect(find.text('正在配对(自动确认)'), findsNothing);
    });

    testWidgets('配对后等待机身确认:专属状态卡/提示 + 可取消;耗尽转失败撤下', (tester) async {
      final conn = FakeConnection()..pairingCode = '5077';
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.pairing);
      await tester.pump();
      expect(conn.confirmCalls, 1);

      // pairing → connecting 沿 = 机身确认等待窗(真机 2026-10-06:相机
      // 弹「配对完成」等按 OK,应用整窗静默重试不闪失败)
      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      expect(controller.awaitingCameraConfirm, isTrue);
      expect(find.text('等待相机上确认配对…'), findsOneWidget);
      expect(find.text('连接中…'), findsNothing);
      expect(controller.hint?.key, contains('conn.pairingSent'));
      expect(find.textContaining('配对信息已发送'), findsOneWidget,
          reason: '等待指引落在固定错误位');
      // 等待窗取消 = 点图标(五轮中央按钮退役)
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      expect(conn.disconnectCalls, 1, reason: '等待窗点图标 = 取消');

      // 窗口耗尽转 failed:等待文案撤下,回到真实错误
      conn.statesCtrl.add(CameraLinkState.failed);
      await tester.pumpAndSettle();
      expect(controller.awaitingCameraConfirm, isFalse);
      expect(find.text('等待相机上确认配对…'), findsNothing);
      expect(controller.hint?.key, 'conn.failed');
    });

    testWidgets('删除已保存相机:确认 → 清档案,列表即消(无感重配语义)', (tester) async {
      // 加高视口:「忘记这台相机」tooltip 在面板折线下(同上)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection();
      final store = InMemoryPairedCamerasStore();
      await store.save(const CameraInfo(
          id: '012345678901',
          name: 'Z_f_8014411',
          lastIp: '192.168.1.4',
          wirelessPaired: true));
      // identityStore 不注入:regenerate 的真文件 IO 在 FakeAsync 域
      // 不上浮,换新身份语义由 client_identity_store 单测覆盖。
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Z_f_8014411'), findsOneWidget);

      await tester.tap(find.byTooltip('忘记这台相机'));
      await tester.pumpAndSettle();
      expect(find.text('忘记这台相机?'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(await store.list(), isEmpty);
      expect(find.text('Z_f_8014411'), findsNothing);
    });

    testWidgets(
        '已连接视图:bento 卡 v24(状态行/机身/镜头信息/存储)+ 底部双钮'
        '+ 型号弹层(详情)+ 点状态词断开', (WidgetTester tester) async {
      // 加高视口:卡片网格较长,底部双钮在折线下(点空)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection()..deviceName = 'NIKON ZF';
      final transport = _ScriptTransport();
      final session = PtpSession(transport: transport);
      // refresh() 脚本:GetDeviceInfo + 镜头 ID(早读,名先亮)+ 电池/
      // 焦距/光圈(全在册)。
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data:
              _deviceInfoDataset(deviceProps: const [0x5001, 0x5008, 0x5007])));
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([99, 0]))); // 镜头 ID u16(不在映射表)
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([80]))); // 电池 80%
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList(
              [0xA0, 0x0F, 0x00, 0x00]))); // 焦距 u32 = 4000(0.01mm)→ 40mm
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x18, 0x01]))); // 光圈 ƒ/2.8(280)
      // 镜头规格四连读(0xD0E3-E6,不在声明表但应答,链尾):
      // 40-40mm ƒ/2-ƒ/2。
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 焦距下限 u32
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xA0, 0x0F, 0x00, 0x00]))); // 焦距上限 u32
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xC8, 0x00]))); // 广角端最大光圈 u16
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xC8, 0x00]))); // 远摄端最大光圈 u16
      final overview =
          CameraOverviewController(session: session, connection: conn);
      final controller = ConnectionController(connection: conn);
      // 「进入拍摄」push 的遥控控制器:connection 置空(不接状态流)。
      // 2026-10-10 取景默认打开:进页自动起景发 0x9201 → 预置失败应答
      // (引擎转 failed 收口,不发帧请求不转圈;本测只验路由进出,
      // 取景/参数由 remote 系测试覆盖)。
      final remoteTransport = _ScriptTransport();
      remoteTransport.reply(
          PtpResult(responseCode: PtpResponseCode.generalError)); // 0x9201
      final remote = RemoteController(
          session: PtpSession(transport: remoteTransport),
          engine: LiveViewEngine(
              session: PtpSession(transport: remoteTransport),
              delay: _parkedDelay),
          delay: _parkedDelay,
          aeDelay: _parkedDelay);
      addTearDown(remote.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(
            controller: controller,
            overview: overview,
            remoteController: remote),
      ));

      conn.statesCtrl.add(CameraLinkState.connected);
      await tester.pumpAndSettle();

      // 状态行:绿点 + 已连接 + 电池壳(电量数字嵌壳内);设备名/链路串收进弹层,pill 只留图标。
      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('80'), findsOneWidget,
          reason: '电池壳内嵌电量数字,无百分号(v26)');
      expect(find.text('USB 数据线'), findsNothing,
          reason: '链路 pill 只留图标,详情在弹层');
      expect(find.text('NIKON ZF'), findsNothing, reason: '设备名移入弹层');
      // 机身卡:型号 pill + 固件/序列号裸值(标签字删,原图标扛语义)。
      expect(find.text('TestModel'), findsOneWidget);
      expect(find.text('V1.00'), findsOneWidget);
      // 序列号:Zf 定宽 32 左补零方言在解析层剥前导零
      expect(find.text('12345678901'), findsOneWidget);
      // 镜头信息卡:名 + 焦距 + 光圈(ID 未收录映射表 → 型号回规格描述)。
      expect(find.textContaining('40mm ƒ/2'), findsOneWidget);
      expect(find.text('40mm'), findsOneWidget);
      expect(find.text('ƒ/2.8'), findsOneWidget);
      expect(find.textContaining('· '), findsNothing,
          reason: '出处小标注(· 规格 等)已整删');
      // 底部双钮:左相册右进入拍摄;断开连接不在主页面(状态词点按)。
      expect(find.text('进入拍摄'), findsOneWidget);
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('断开连接'), findsNothing,
          reason: '断开收状态词点按,全程无断开按钮');

      // 进入拍摄:全屏 push 遥控监看页;信息胶囊带返回钮,pop 即回。
      await tester.tap(find.text('进入拍摄'));
      await tester.pumpAndSettle();
      expect(find.byType(RemotePage), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(RemotePage),
              matching: find.byIcon(Icons.arrow_back)),
          findsOneWidget,
          reason: '路由态信息胶囊带返回钮');
      await tester.tap(find.descendant(
          of: find.byType(RemotePage),
          matching: find.byIcon(Icons.arrow_back)));
      await tester.pumpAndSettle();
      expect(find.byType(RemotePage), findsNothing, reason: '返回即回相机页');
      expect(find.text('进入拍摄'), findsOneWidget);

      // 型号 pill 点按 → 详情弹层:四行读数,纯信息(无断开钮 ——
      // 断开走状态词点按,2026-10-23 拆散)。
      await tester.tap(find.text('TestModel'));
      await tester.pumpAndSettle();
      expect(find.text('设备名'), findsOneWidget);
      expect(find.text('NIKON ZF'), findsOneWidget);
      expect(find.text('型号'), findsOneWidget);
      expect(find.text('TestModel'), findsNWidgets(2),
          reason: '机身卡 pill + 弹层值各一');
      expect(find.text('链路'), findsOneWidget);
      expect(find.text('USB 数据线'), findsOneWidget, reason: '详情收进弹层');
      expect(find.text('电池'), findsNothing,
          reason: '电池行已删(电量只在状态行电池壳)');
      expect(find.text('断开连接'), findsNothing,
          reason: '弹层纯信息,断开收状态词点按');
      // 弹层无按钮可点:点屏障收层。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('设备名'), findsNothing, reason: '屏障点按收层');

      // 行尾电池壳/链路 pill 点空不响应(不弹层不断开)—— 只有
      // 「已连接」状态词可点(2026-10-23 定稿)。
      await tester.tap(find.text('80'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.usb));
      await tester.pumpAndSettle();
      expect(conn.disconnectCalls, 0);
      expect(find.text('设备名'), findsNothing, reason: '行尾点按不开弹层');

      // 点「已连接」状态词 → 确认弹框;取消 = 不断开(2026-10-23
      // 裁定:直断补确认)。
      await tester.tap(find.text('已连接'));
      await tester.pumpAndSettle();
      expect(find.text('断开连接?'), findsOneWidget);
      expect(find.text('断开连接'), findsOneWidget,
          reason: '确认钮红底 = 旧弹层红色断开的视觉');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(conn.disconnectCalls, 0);
      expect(find.text('断开连接?'), findsNothing, reason: '取消即收框');

      // 再点状态词 → 确认「断开连接」= 断开。
      await tester.tap(find.text('已连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开连接'));
      await tester.pumpAndSettle();
      expect(conn.disconnectCalls, 1);
    });

    testWidgets('拍摄模式跟随走 0x4006 事件通道(页内无轮询,节拍内零事务)',
        (WidgetTester tester) async {
      // 2026-10-22 撤页内 2s 单读 0xD1A6 轮询:AppServices 级事件轮询器
      // (GetEventEx 0x941C)把 0x4006(0xD1A6)并入 session.events →
      // RemoteController 定向重读 → notifyListeners → 页面 merge 监听
      // (_connectedView)重建。emitPolledEvents 即轮询器的注入口,注入
      // 一枚事件验证全链;再推进假时钟越过旧 2s 节拍两拍,确认 0xD1A6
      // 读事务只有事件触发的这一笔(页内不再自读)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = FakeConnection();
      final controller = ConnectionController(connection: conn);
      // overview 不接 conn:已连接视图渲染用(读数占位),免整链脚本。
      final overview = CameraOverviewController(
          session: PtpSession(transport: _ScriptTransport()),
          connection: FakeConnection());
      // remote 同款不接 connection:无连接沿初读链,模式只随事件走
      // (连接沿初读归 _onConnectedChain,remote 系测试覆盖)。
      final remoteTransport = _ScriptTransport();
      final remoteSession = PtpSession(transport: remoteTransport);
      final remote = RemoteController(
          session: remoteSession,
          engine: LiveViewEngine(session: remoteSession, delay: _parkedDelay),
          delay: _parkedDelay,
          aeDelay: _parkedDelay);
      addTearDown(remote.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(
            controller: controller,
            overview: overview,
            remoteController: remote),
      ));

      conn.statesCtrl.add(CameraLinkState.connected);
      await tester.pumpAndSettle();
      expect(remote.cameraMode, isNull, reason: '未发事件前模式未知');

      // 拨杆拨到视频档:0x4006(0xD1A6)→ 定向重读(u8=1 视频)→ 跟随。
      remoteTransport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([1])));
      remoteSession.emitPolledEvents(const [
        PtpEvent(
            code: PtpEventCode.devicePropChanged,
            transactionId: 0xFFFFFFFF,
            params: [PtpDevicePropCode.liveViewSelector]),
      ]);
      await tester.pumpAndSettle();
      expect(remote.cameraMode, CaptureMode.video);

      // 页内零轮询:推进 5s(旧 2s 节拍已越两拍),0xD1A6 读事务仅此一笔
      //(轮询若在,脚本早已耗尽抛 StateError,读数也翻倍)。
      await tester.pump(const Duration(seconds: 5));
      expect(
          remoteTransport.requests.where((r) =>
              r.opcode == PtpOperationCode.getDevicePropValue &&
              r.params.first == PtpDevicePropCode.liveViewSelector),
          hasLength(1));
    });
  });

  group('ConnectionPage 蓝牙工具通道:', () {
    Future<BleIdentityStore> tempIdentityStore() async {
      final dir = await Directory.systemTemp.createTemp('nikonpill_ble_test');
      return BleIdentityStore(dataDir: () async => dir.path);
    }

    Future<void> pumpEvents() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// 完整就绪夹具:host + session + 身份存储 + 设置控制器 + 刷新计数。
    Future<
        ({
          FakeBleHost host,
          BleCameraSession session,
          BleIdentityStore identityStore,
          SettingsController settings,
          _FakeSettingsStore settingsStore,
          ConnectionController controller,
        })> readyFixture({
      FakeConnection? connection,
      _FakeWifiJoiner? joiner,
    }) async {
      final host = FakeBleHost();
      final session = BleCameraSession(host: host);
      final identityStore = await tempIdentityStore();
      final settingsStore = _FakeSettingsStore();
      final settings = SettingsController(store: settingsStore);
      final controller = ConnectionController(
        connection: connection,
        bleSession: session,
        bleIdentityStore: identityStore,
        wifiJoiner: joiner,
        settingsController: settings,
      );
      // 预存身份(卡片「已配对」态;设备侧无关紧要,真身在新配对沿写)。
      await identityStore.save(BlePairedIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223344,
        nonce: 0x55667788,
        serial: '1641397',
        controllerName: 'NikonPill',
        pairedAt: DateTime(2026, 10, 14),
      ));
      await controller.loadBleIdentity();
      // 驱动握手到 ready(连接 → stage1 → stage2 → stage4)。
      final done = session
          .pair(const BleDevice(name: 'Z f_8014411', uuid: 'P1', rssi: -50));
      await pumpEvents();
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await pumpEvents();
      final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
      await pumpEvents();
      host.emit(
          BleNotified(uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pumpEvents();
      await done;
      return (
        host: host,
        session: session,
        identityStore: identityStore,
        settings: settings,
        settingsStore: settingsStore,
        controller: controller,
      );
    }

    /// 进蓝牙视图:右上角方式弹层选蓝牙(选中仅切换,body 原地替换)。
    /// 顺带加高视口:hero 正中改版后(弹性区上下分栏),默认 600 高
    /// 视口把唤醒钮/红卡按钮压到折线下,tap 打不中 —— 与 STA 用例同款。
    Future<void> openBleTools(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('蓝牙'));
      await tester.pumpAndSettle();
    }

    testWidgets('未装配 BLE:方式弹层无蓝牙条目,默认有线主视图照常', (tester) async {
      final conn = FakeConnection();
      await tester.pumpWidget(MaterialApp(
          home: ConnectionPage(
              controller: ConnectionController(connection: conn))));
      await tester.pump();
      // 五轮:中央连接钮退役(点图标连接);方式行在场。
      expect(find.text('有线'), findsOneWidget, reason: '方式行在场');
      expect(find.text('连接相机'), findsNothing);
      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      expect(find.text('选择连接方式'), findsOneWidget);
      expect(find.text('蓝牙'), findsNothing);
    });

    testWidgets(
        '已配对未连(idle):打开不回链(页内全手动),连接钮在场待点;'
        '两段列表 + PTP 状态行不出(工具通道不混链路态)', (tester) async {
      // 夹具有真文件 IO(临时目录/身份存档),testWidgets 的
      // fake-async zone 吃不到 —— 必须 runAsync 放行。此态只建夹具不
      // 驱动握手(会话停在 idle)。
      final f = (await tester.runAsync(() async {
        final host = FakeBleHost();
        final session = BleCameraSession(host: host);
        final identityStore = await tempIdentityStore();
        final settingsStore = _FakeSettingsStore();
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          bleSession: session,
          bleIdentityStore: identityStore,
          settingsController: settings,
        );
        await identityStore.save(BlePairedIdentity(
          peripheralUuid: 'P1',
          deviceId: 0x11223344,
          nonce: 0x55667788,
          serial: '1641397',
          controllerName: 'NikonPill',
          pairedAt: DateTime(2026, 10, 14),
        ));
        await controller.loadBleIdentity();
        return (host: host, controller: controller);
      }))!;
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);
      expect(find.text('蓝牙连接'), findsNothing, reason: '标题行删除:方式由图标表达');
      expect(find.text('未连接'), findsNothing, reason: 'PTP 状态行在蓝牙视图下隐藏');
      expect(find.text('已配对,未连接'), findsOneWidget);
      // 打开沿不自动回链(2026-10-19 定稿:进入页面不主动连接)——
      // 连接钮在场待点,无连接进行态。
      expect(find.text('连接中…'), findsNothing);
      // 右上钮是图标(七轮),页面唯一「连接」TextButton = 面板行。
      final connectBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, '连接').first);
      expect(connectBtn.onPressed, isNotNull, reason: '显式点按才发起');
      // 两段列表段名(有档案:已配对组非空;其它设备组空态)
      expect(find.text('已配对'), findsOneWidget);
      expect(find.text('其它设备'), findsOneWidget);
      expect(find.text('暂无已配对设备'), findsNothing);
      expect(find.text('最近'), findsOneWidget,
          reason: '配对档案行 = 最近连接条目,名后绿底「最近」徽(八轮)');
      // WiFi 动作组就绪才挂(2026-10-19 定稿:关闭钮整个退役):未
      // 连接整组退场,远程连接相机/关闭都不出。
      expect(find.text('远程连接相机'), findsNothing);
      expect(find.text('关闭'), findsNothing);
      // GPS 注入开关已迁设置页(2026-10-18),蓝牙页不再有开关。
      expect(find.byType(SwitchListTile), findsNothing);
      // 收尾:无在途重连(打开沿不回链),直接拆树。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('点方式行 ⓘ 弹说明:工具通道长文案收进弹窗,正文不常驻', (tester) async {
      // 夹具同 idle 用例(真文件 IO 须 runAsync;面板硬绑 AppServices
      // 单例,自动化照常跑,与本用例断言无关)。
      final controller = (await tester.runAsync(() async {
        final session = BleCameraSession(host: FakeBleHost());
        final identityStore = await tempIdentityStore();
        final controller = ConnectionController(
          bleSession: session,
          bleIdentityStore: identityStore,
          settingsController: SettingsController(store: _FakeSettingsStore()),
        );
        await identityStore.save(BlePairedIdentity(
          peripheralUuid: 'P1',
          deviceId: 0x11223344,
          nonce: 0x55667788,
          serial: '1641397',
          controllerName: 'NikonPill',
          pairedAt: DateTime(2026, 10, 14),
        ));
        await controller.loadBleIdentity();
        return controller;
      }))!;
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      // 正文不再常驻长文案(说明收进方式行 ⓘ 点开的弹窗,五轮入口迁此)。
      expect(find.textContaining('不建立相机连接'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('conn_method_info')));
      await tester.pumpAndSettle();
      expect(find.textContaining('不建立相机连接'), findsOneWidget,
          reason: '点方式行 ⓘ 弹说明弹窗(五轮:入口自 hero 迁此)');
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(find.textContaining('不建立相机连接'), findsNothing);
      // hero 点按不再承担说明(五轮让位给连接;八轮 = 连最近:面板
      // 「连接」同一条手动重连路)—— 说明弹窗不开;重连循环在场
      //(本夹具会话未注身份,首轮即未命中进退避)。
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('不建立相机连接'), findsNothing,
          reason: 'hero 点按 = 连最近(八轮),不开说明弹窗');
      expect(find.text('连接中…'), findsWidgets,
          reason: '八轮:hero 连最近 = 面板「连接」同路,重连循环在跑'
              '(按钮位同文案;十轮:名下副文退役;十三轮:改文案「连接中…」)');
      // 收尾:拆树(面板在途扫描/重连循环随树拆废 —— 世代号即刻止步)。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('蓝牙 hero 连最近/在途取消(八/九轮):面板同路,涟漪跟面板循环',
        (tester) async {
      // 十二轮起面板跟页面控制器会话(生产 = AppServices 驱动同一只):
      // 夹具 FakeBleHost 会话直接可测 —— 重连循环真发 scanForDeviceId
      // 走 FakeBleHost 计数,不再借道 AppServices 单例 + 通道 mock。
      final f = (await tester.runAsync(() async {
        final host = FakeBleHost();
        final session = BleCameraSession(host: host);
        final identityStore = await tempIdentityStore();
        final controller = ConnectionController(
          bleSession: session,
          bleIdentityStore: identityStore,
          settingsController: SettingsController(store: _FakeSettingsStore()),
        );
        await identityStore.save(BlePairedIdentity(
          peripheralUuid: 'P1',
          deviceId: 0x11223344,
          nonce: 0x55667788,
          serial: '1641397',
          controllerName: 'NikonPill',
          pairedAt: DateTime(2026, 10, 14),
        ));
        await controller.loadBleIdentity();
        return (host: host, session: session, controller: controller);
      }))!;

      AppServices.instance.bleManualOff = true;
      addTearDown(() => AppServices.instance.bleManualOff = false);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);
      // 会话注身份(重连轮真走到 scanForDeviceId;FakeBleHost 无命中
      // 配置 → 无命中轮,会话态停在 idle —— 涟漪只能跟面板循环)。
      f.session.identity = BleIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223344,
        nonce: 0x55667788,
        serial: '1641397',
        name: 'NikonPill',
      );

      // 涟漪环 = 圆形容器且有描边无填充(hero 外圈有填充、状态行圆点
      // 无描边,均不计数)。闲态无环(会话 idle,涟漪未起)。
      final rings = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).border != null &&
          (w.decoration as BoxDecoration).color == null);
      expect(rings, findsNothing, reason: '闲态无涟漪');

      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      await tester.pump();
      expect(AppServices.instance.bleManualOff, isFalse,
          reason: 'hero 连最近 = 显式连接意图,解除手动断开压制');
      expect(f.host.scanIdCalls, greaterThanOrEqualTo(1),
          reason: '走面板「连接」同一条重连路(scanForDeviceId 已发)');
      expect(rings, findsNWidgets(3),
          reason: '九轮:蓝牙连接中出涟漪 —— 无命中轮会话态停在 idle,'
              '涟漪跟面板重连循环走(onRetryingChanged 上抛)');
      expect(find.text('连接中…'), findsOneWidget,
          reason: '重连反馈只在按钮位(十轮名下副文退役;十三轮'
              'ble.reconnecting 改名「连接中…」)');

      // 九轮:在途再点 hero = 取消 —— 与面板「断开」钮同语义(manualOff
      // 复压 + 废循环 + 断链),行副文/按钮回「连接」,涟漪即停。
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      await tester.pump();
      expect(AppServices.instance.bleManualOff, isTrue,
          reason: '取消 = 显式断开意图(压离页后驱动自动回链)');
      expect(find.text('连接中…'), findsNothing, reason: '重连循环已废');
      expect(find.text('连接'), findsOneWidget, reason: '面板行回到「连接」');
      expect(rings, findsNothing, reason: '取消后涟漪即停');

      // 收尾:拆树(面板循环随世代号废;夹具会话非单例,无驱动 Timer
      // 须清)。
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('等待系统配对红卡:黄点状态词 + 引导卡 + 手动按钮(不点不跳)',
        (tester) async {
      final f = (await tester.runAsync(() async {
        final host = FakeBleHost();
        final session = BleCameraSession(host: host);
        final identityStore = await tempIdentityStore();
        final controller = ConnectionController(
          bleSession: session,
          bleIdentityStore: identityStore,
          settingsController: SettingsController(store: _FakeSettingsStore()),
        );
        await identityStore.save(BlePairedIdentity(
          peripheralUuid: 'P1',
          deviceId: 0x11223344,
          nonce: 0x55667788,
          serial: '1641397',
          controllerName: 'NikonPill',
          pairedAt: DateTime(2026, 10, 14),
        ));
        await controller.loadBleIdentity();
        return (host: host, controller: controller);
      }))!;
      // iOS 首配握手落档沿(面板 onSystemBondNeeded → 控制器;测试直调
      // 同一入口 —— iOS 分支被 Platform 门挡在测试宿主外)。
      f.controller.markAwaitSystemBond();
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      expect(find.text('等待系统配对'), findsOneWidget, reason: '状态词(黄点)');
      expect(find.text('蓝牙验证完成,请到系统蓝牙完成配对'), findsOneWidget,
          reason: '红色引导卡(自动跳系统蓝牙已删,2026-10-19 裁定)');
      expect(find.textContaining('断开手机蓝牙'), findsOneWidget);
      expect(find.text('打开系统蓝牙设置'), findsOneWidget,
          reason: '手动按钮保留(裁定②):点了才跳,不点不跳');

      // 手动钮:先断本机 BLE 再深链(测试环境深链 MissingPlugin 静默,
      // 只验不炸)。
      await tester.tap(find.text('打开系统蓝牙设置'));
      await tester.pump();
      // 收尾:拆树。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets(
        'ready 后:唤醒写 0x2005;唤醒沿断链(相机等 BLE 释放才开热点)',
        (tester) async {
      // 夹具有真文件 IO(临时目录/身份存档),testWidgets 的
      // fake-async zone 吃不到 —— 必须 runAsync 放行。
      final f = (await tester.runAsync(readyFixture))!;
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);
      expect(find.text('已连接'), findsNWidgets(2),
          reason: '状态行 + 十二轮就绪段名(配对面板组头不再「已配对」)');
      expect(find.text('已配对'), findsNothing,
          reason: '十二轮:就绪沿段名让位「已连接」');
      expect(find.text('最近'), findsNothing,
          reason: '十二轮:就绪行不带「最近」徽(已连接时无意义)');
      // (hero 就绪配色断言在十一轮专项用例:实底统一黄 + 点按断开。)

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(f.host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x01]));
      expect(f.session.state, BleSessionState.idle,
          reason: '写成功即断链:相机等 BLE 释放才真正开热点');
      // 十七轮:凭据未解出不弹 SnackBar(下方文字提醒撤),置
      // wifiAwakePending → 错误位出红字「去系统连 Wi-Fi」固定提醒。
      expect(find.byType(SnackBar), findsNothing,
          reason: '十七轮:凭据未解出撤 SnackBar');
      expect(f.controller.wifiAwakePending, isTrue);
      expect(find.text('相机 Wi-Fi 已开启,请在系统 Wi-Fi 中连接相机热点(密码看相机屏幕);传图完点「重连」恢复蓝牙'),
          findsOneWidget,
          reason: '十七轮:错误位红字固定提醒(打开 Wi-Fi 且未直连)');
      expect(find.textContaining('0x2004 空'), findsNothing,
          reason: '十七轮:会话杂错让位红字提醒(错误位不显「AP 凭据」失败细节)');
      // 收尾:拆树(无 joiner:红卡不出,凭据未解出走红字提醒路)。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('蓝牙就绪 hero 实底统一黄,点按 = 断开(十一轮)', (tester) async {
      // 夹具(真文件 IO)驱动页面控制器会话到 ready —— ready 定 hero
      // 实底。十二轮起面板跟控制器会话,hero 断开(cancelResume)落在
      // 夹具会话上 → 断言 manualOff 旗标 + 夹具会话态直接可读。
      final f = (await tester.runAsync(readyFixture))!;
      addTearDown(() => AppServices.instance.bleManualOff = false);

      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      // 十一轮:就绪 hero = 实底统一黄(与按钮实底同深,十轮淡绿被否)
      // + onBrandYellow 深字图标 + 黄描边。
      final heroKey = find.byKey(const ValueKey('conn_method_hero'));
      final heroBox = tester
          .widget<AnimatedContainer>(find.descendant(
              of: heroKey, matching: find.byType(AnimatedContainer)))
          .decoration as BoxDecoration;
      expect(heroBox.color, AppColors.accentYellow,
          reason: '十一轮:就绪实底统一黄(闲态为 45% 次级黄)');
      expect(heroBox.border?.top.color, AppColors.accentYellow,
          reason: '就绪黄描边(在途同款)');
      final heroIcon = tester.widget<Icon>(
          find.descendant(of: heroKey, matching: find.byIcon(Icons.bluetooth)));
      expect(heroIcon.color, AppColors.onBrandYellow,
          reason: '十一轮:黄底深字(App 按钮实底同款配对)');

      // 就绪点按 = 断开(面板「断开」同路:manualOff 压驱动回链 + 断链)。
      await tester.tap(heroKey);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(AppServices.instance.bleManualOff, isTrue,
          reason: '十一轮:就绪 hero 点按 = 显式断开意图');
      expect(f.session.state, BleSessionState.idle,
          reason: '断链沿收口回 idle(夹具会话即面板会话,十二轮)');
      // 收尾:拆树(夹具会话非单例,无驱动 Timer 须清)。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('蓝牙连接中:状态词可点取消 + hero 停止重连(十三/十四轮)', (tester) async {
      // 场景:断链后驱动自动重连 —— 会话停在 reconnecting(状态行
      // 「连接中…」,hero 涟漪)。驱动路径用 reconnectDirect 模拟:
      // 60s 直连握手窗内恒 pairing,超时沿置 reconnecting(FakeBleHost
      // 无事件喂,握手永不完成)。
      final f = (await tester.runAsync(() async {
        final host = FakeBleHost();
        final session = BleCameraSession(host: host);
        final identityStore = await tempIdentityStore();
        final controller = ConnectionController(
          bleSession: session,
          bleIdentityStore: identityStore,
          settingsController: SettingsController(store: _FakeSettingsStore()),
        );
        await identityStore.save(BlePairedIdentity(
          peripheralUuid: 'P1',
          deviceId: 0x11223344,
          nonce: 0x55667788,
          serial: '1641397',
          controllerName: 'NikonPill',
          pairedAt: DateTime(2026, 10, 14),
        ));
        await controller.loadBleIdentity();
        return (host: host, session: session, controller: controller);
      }))!;
      AppServices.instance.bleManualOff = false;
      addTearDown(() => AppServices.instance.bleManualOff = false);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);
      f.session.identity = BleIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223344,
        nonce: 0x55667788,
        serial: '1641397',
        name: 'NikonPill',
      );
      unawaited(f.session.reconnectDirect());
      await tester.pump();
      await tester.pump();

      // 握手窗(pairing):状态行 + 行尾同词「握手中…」(十四轮:行内
      // 只出状态词,「断开」钮被否);解除配对隐。
      expect(find.text('握手中…'), findsNWidgets(2),
          reason: '握手期:状态行 + 档案行尾(十轮)');
      expect(find.text('断开'), findsNothing,
          reason: '十四轮:握手期行内「断开」钮被否(取消走 hero 再点)');
      expect(find.byIcon(Icons.link_off), findsNothing,
          reason: '解除配对在握手期隐(十轮)');

      // 超时 → reconnecting(连接中):状态行 + 行尾同词,**常驻自动
      // 重试即刻起**(十五轮:面板就是页面开着时的重连执行者 —— 状态
      // 沿入 reconnecting 自动起循环,相机就绪即连上),解除配对隐。
      await tester.pump(const Duration(seconds: 61));
      expect(f.controller.bleState, BleSessionState.reconnecting,
          reason: '直连窗 60s 超时 → 停在 reconnecting(驱动重连档)');
      expect(find.text('连接中…'), findsNWidgets(2),
          reason: '十三轮:连接中如实报态(状态行 + 行尾)');
      expect(find.text('连接'), findsNothing,
          reason: '十五轮:连接中不与「连接」钮并存 —— 重连由常驻自动'
              '循环承担,行内只报态与给取消(点状态词)');
      expect(find.byIcon(Icons.link_off), findsNothing,
          reason: '十三轮:连接中解除配对隐');
      final rings = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).border != null &&
          (w.decoration as BoxDecoration).color == null);
      expect(rings, findsNWidgets(3),
          reason: '连接中(busy)涟漪在跑');
      expect(f.host.scanIdCalls, greaterThanOrEqualTo(1),
          reason: '十五轮:常驻自动循环真在重试(scanForDeviceId 已发)');

      // 十四轮:点行尾「连接中…」状态词 = 取消(manualOff + 断链回
      // idle,与 hero 再点同语义);自动循环随取消废。
      await tester.tap(find.text('连接中…').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(AppServices.instance.bleManualOff, isTrue,
          reason: '十四轮:点状态词 = 显式断开意图(压驱动自动回链)');
      expect(f.session.state, BleSessionState.idle,
          reason: '断链沿收口回 idle');
      expect(find.text('连接中…'), findsNothing, reason: '重连已停');
      expect(find.text('连接'), findsOneWidget, reason: '面板行回到「连接」');
      expect(find.byIcon(Icons.link_off), findsOneWidget,
          reason: '解除配对回归(闲态)');
      expect(rings, findsNothing, reason: '停止后涟漪即停');

      // 闲态显式连接 = 面板循环(单发,manualResume 绕闸):按钮位报
      // 「连接中…」,再点 hero = 取消(九轮)。
      AppServices.instance.bleManualOff = false;
      await tester.tap(find.text('连接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('连接中…'), findsOneWidget,
          reason: '面板循环在跑:按钮位报「连接中…」');
      expect(rings, findsNWidgets(3), reason: '面板循环涟漪在跑');
      await tester.tap(find.byKey(const ValueKey('conn_method_hero')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(AppServices.instance.bleManualOff, isTrue,
          reason: '九轮:在途(hero)再点 = 取消');
      expect(find.text('连接中…'), findsNothing, reason: '面板循环已废');
      expect(rings, findsNothing, reason: '取消后涟漪即停');

      // 收尾:拆树(reconnectDirect 已收口,无在途 Timer)。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('ready 沿旧档相机名回填:档案补 cameraName,展示名随更',
        (tester) async {
      // 真文件 IO 须 runAsync 放行。直调回填(AppServices 常驻监听
      // ready 沿同参)。
      final f = (await tester.runAsync(readyFixture))!;
      expect(f.controller.bleIdentity!.displayName, 'NikonPill');
      // 跨相机残留名不回填:档案 deviceId ≠ 会话现役身份 → 短路。
      f.session.lastMatchName = 'Z f_8014411';
      await tester.runAsync(() => f.controller.healCameraName());
      expect(f.controller.bleIdentity!.cameraName, isEmpty);
      // 档案对齐会话现役身份(旧档真实形态:档自 session.identity 落
      // 盘)→ 回填 + 展示名随更。
      final id = f.session.identity!;
      await tester.runAsync(() => f.identityStore.save(BlePairedIdentity(
            peripheralUuid: id.peripheralUuid,
            deviceId: id.deviceId,
            nonce: id.nonce,
            serial: id.serial,
            controllerName: 'NikonPill',
            pairedAt: DateTime(2026, 10, 14),
          )));
      await tester.runAsync(() => f.controller.loadBleIdentity());
      await tester.runAsync(() => f.controller.healCameraName());
      expect(f.controller.bleIdentity!.cameraName, 'Z f_8014411');
      expect(f.controller.bleIdentity!.displayName, 'Z f_8014411');
      // 幂等:同沿再跑不变形。
      await tester.runAsync(() => f.controller.healCameraName());
      expect(f.controller.bleIdentity!.cameraName, 'Z f_8014411');
    });

    testWidgets('未就绪时 WiFi 动作如实失败(controller 门禁)', (tester) async {
      final host = FakeBleHost();
      final session = BleCameraSession(host: host);
      expect(await session.wakeCameraWifi(), isFalse);
      expect(host.writes, isEmpty);
      expect(session.lastError?.key, 'ble.notConnectedOp');
      expect(session.lastError?.args?['label'], 'ble.wakeWifi');
    });

    testWidgets('唤醒沿自动读凭据:0x2004 解出 → 无 joiner 弹手动入网红卡,主钮切 AP 发射连接',
        (tester) async {
      final f = (await tester.runAsync(readyFixture))!;
      f.host.reads[kNikonCharConfig] =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: false);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(f.host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x01]));
      expect(f.controller.cameraApCredentials, isNotNull);
      expect(f.controller.cameraApCredentials!.ssid, 'Zf_80114411');
      expect(f.session.state, BleSessionState.idle,
          reason: '唤醒沿断链(相机等 BLE 释放才开热点),凭据已先落控制器');
      // 手动入网红卡留在本页(测试宿主无 joiner,= iOS/ohos 情形;
      // 2026-10-19 裁定③④:App 不主动跳 Wi-Fi,不弹 SnackBar 指引)。
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('相机 Wi-Fi 已开启,请手动入网'), findsOneWidget);
      expect(find.textContaining('加入热点「Zf_80114411」'), findsOneWidget);
      expect(find.text('wpa2pass99'), findsOneWidget);
      expect(find.text('已加入热点,开始连接'), findsOneWidget);

      // 主钮 = 显式用户意图:切 AP 方式并发射连接,红卡即撤。
      await tester.tap(find.text('已加入热点,开始连接'));
      await tester.pump();
      expect(f.controller.method, ConnectionMethod.ap);
      expect(f.controller.wifiAwakePending, isFalse, reason: '显式连接沿撤卡');
      await tester.pumpAndSettle();
      // AP 视图凭据卡照旧(SSID/密码/安全 + 复制)
      expect(find.text('相机热点凭据(蓝牙通道解出)'), findsOneWidget);
      expect(find.text('wpa2pass99'), findsOneWidget);
      expect(find.text('SSID'), findsOneWidget);
      expect(find.textContaining('WPA2'), findsOneWidget);
    });

    testWidgets('唤醒但凭据未解出:错误位红字提醒去系统连 Wi-Fi,提示条撤(十七轮)',
        (tester) async {
      final f = (await tester.runAsync(readyFixture))!;
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(f.controller.cameraApCredentials, isNull);
      expect(f.session.state, BleSessionState.idle,
          reason: '凭据未解出也断链:相机开热点不依赖凭据解出');
      expect(find.byType(SnackBar), findsNothing,
          reason: '十七轮:下方 SnackBar 提醒撤');
      expect(find.text('相机 Wi-Fi 已开启,请在系统 Wi-Fi 中连接相机热点(密码看相机屏幕);传图完点「重连」恢复蓝牙'),
          findsOneWidget,
          reason: '十七轮:错误位红字固定提醒(打开 Wi-Fi 且未直连)');
      expect(find.textContaining('0x2004 空'), findsNothing,
          reason: '十七轮:会话杂错让位红字提醒');

      // 切 AP 模式方式:主视图不出凭据卡
      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AP 模式'));
      await tester.pumpAndSettle();
      expect(find.text('相机热点凭据(蓝牙通道解出)'), findsNothing);
    });

    testWidgets('唤醒沿 joiner ok:自动加入热点 + 发射 AP 连接(连接层收到 connect)',
        (tester) async {
      final conn = FakeConnection();
      final joiner = _FakeWifiJoiner();
      final f = (await tester
          .runAsync(() => readyFixture(connection: conn, joiner: joiner)))!;
      f.host.reads[kNikonCharConfig] =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: false);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(f.host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x01]));
      expect(f.session.state, BleSessionState.idle, reason: '交接沿断链');
      expect(joiner.joinedSsid, 'Zf_80114411');
      expect(joiner.joinedPassword, 'wpa2pass99');
      expect(joiner.joinedSecurity, 0x02, reason: '0x2004 安全字节原样透传');
      expect(conn.connectIp, '192.168.1.1',
          reason: 'join 成功沿自动发射 AP 连接(SnapBridge 全程)');
      expect(f.controller.method, ConnectionMethod.ap, reason: '自动切到 AP 方式');
      expect(find.textContaining('已加入相机热点'), findsOneWidget);
    });

    testWidgets('唤醒沿 joiner fail:不发射连接,终态含手动指引与原因', (tester) async {
      final conn = FakeConnection();
      final joiner = _FakeWifiJoiner(ok: false, reason: 'unavailable');
      final f = (await tester
          .runAsync(() => readyFixture(connection: conn, joiner: joiner)))!;
      f.host.reads[kNikonCharConfig] =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: false);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(joiner.joinedSsid, 'Zf_80114411', reason: '凭据在手仍尝试加入,失败才回落');
      expect(conn.connectIp, isNull, reason: 'join 失败不发射连接');
      expect(find.textContaining('自动加入热点失败'), findsOneWidget);
      expect(find.textContaining('unavailable'), findsOneWidget);
      // 收尾:拆树。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('lastError 沿实时刷新:错误落库即 notifyListeners,同值不发', (tester) async {
      final f = (await tester.runAsync(readyFixture))!;
      var notifications = 0;
      f.controller.addListener(() => notifications++);
      f.session.lastError = const (key: '注入失败:x', args: null);
      await tester.pump();
      final afterErr = notifications;
      expect(afterErr, greaterThan(0), reason: '错误沿即时刷新,不等状态跃迁');
      f.session.lastError = const (key: '注入失败:x', args: null); // 同值去重
      await tester.pump();
      expect(notifications, afterErr);
      f.session.lastError = const (key: '注入失败:y', args: null);
      await tester.pump();
      expect(notifications, greaterThan(afterErr));
    });
  });
}

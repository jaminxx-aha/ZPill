import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
import 'package:nikon_pill/features/connection/camera_overview_controller.dart';
import 'package:nikon_pill/features/connection/connection_page.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/remote_page.dart';
import 'package:nikon_pill/features/settings/settings_page.dart';
import 'package:nikon_pill/platform/ble_scanner.dart';
import 'package:nikon_pill/platform/network_monitor.dart';
import 'package:nikon_pill/platform/nsd_scanner.dart';

import '../../core/ble/ble_camera_session_test.dart'
    show FakeBleHost, buildStage2, buildStage4;
import '../../core/ble/wifi_credentials_test.dart' show craftBlob;

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
}

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

  /// 连接层动态文案(reconnecting 期恢复循环逐拍更新;failed 的终态)。
  String? err;

  @override
  String? deviceName;

  @override
  String? deviceModel;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  String? get error => err;

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
      final conn = _FakeConnection();
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
      final conn = _FakeConnection();
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
      final conn = _FakeConnection();
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
      final conn = _FakeConnection();
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
          ConnectionController(connection: _FakeConnection(), scanner: scanner);
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
          connection: _FakeConnection(),
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
          connection: _FakeConnection(),
          settingsController: settings,
        );
        await pumpEventQueue();
        expect(controller.method, ConnectionMethod.usb);
      });

      test('选中即落库(写侧走 SettingsController 同一条 AppSettings 路)', () async {
        final settingsStore = _FakeSettingsStore();
        final settings = SettingsController(store: settingsStore);
        final controller = ConnectionController(
          connection: _FakeConnection(),
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
          connection: _FakeConnection(),
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
      final conn = _FakeConnection()..deviceName = 'NIKON ZF';
      final controller = ConnectionController(connection: conn);

      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();
      expect(controller.state, CameraLinkState.connected);
      expect(controller.hint, isNull);

      conn.statesCtrl.add(CameraLinkState.pairing);
      await pumpEventQueue();
      expect(controller.hint, 'conn.pairingAuto');

      conn.statesCtrl.add(CameraLinkState.failed);
      await pumpEventQueue();
      expect(controller.hint, 'conn.failed'); // error null → 兜底键,渲染层落 zh
    });

    test(
        'hint:reconnecting 读连接层动态文案(恢复循环逐拍更新),'
        'error 缺席回落「正在自动重连…」', () async {
      final conn = _FakeConnection()..err = '正在等待相机重新接入 USB(重新插好数据线后自动续连)';
      final controller = ConnectionController(connection: conn);

      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      expect(controller.state, CameraLinkState.reconnecting);
      expect(controller.hint, '正在等待相机重新接入 USB(重新插好数据线后自动续连)');

      conn.err = null;
      conn.statesCtrl.add(CameraLinkState.reconnecting); // 重复 notify 重读
      await pumpEventQueue();
      expect(controller.hint, 'conn.reconnectAuto');
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

    test('扫描未装配平台(start 抛 MissingPluginException):静默降级回手动', () async {
      final controller = ConnectionController(
          connection: _FakeConnection(), scanner: _FailingScanner());

      await controller.startScan();

      expect(controller.scanning, isFalse);
    });

    test('rescanIfScanning:扫描中停→起重启浏览;未扫描时不动', () async {
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: _FakeConnection(), scanner: scanner);

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
      final conn = _FakeConnection();
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
        final conn = _FakeConnection();
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
            connection: _FakeConnection(), subnetScanner: subnet);
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
        final conn = _FakeConnection();
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
            connection: _FakeConnection(), subnetScanner: subnet);
        await controller.scanSubnet();
        expect(controller.subnetCameras, hasLength(1));

        controller.selectMethod(ConnectionMethod.ap);
        expect(controller.subnetCameras, isEmpty);
        expect(controller.subnetScanCompleted, isFalse);
      });
    });
  });

  group('ConnectionPage', () {
    testWidgets('未连接主视图:居中「连接相机」,有线直连;AP 方式候选序直连', (WidgetTester tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionPage(controller: controller),
      ));

      // 默认有线:右上角 = 当前方式图标;居中「连接相机」直接发起 USB 连接
      expect(find.text('连接相机'), findsOneWidget);
      expect(find.text('当前方式:有线'), findsOneWidget);
      expect(find.byIcon(Icons.usb), findsOneWidget);
      expect(find.textContaining('app 将自动接管相机'), findsNothing);
      await tester.tap(find.text('连接相机'));
      await tester.pump();
      expect(conn.connectIp, isNull, reason: 'USB 连接无 IP');

      // 切 AP 方式(经控制器;弹层路径由下测覆盖):接管预告在场,
      // 点「连接相机」走候选序(无发现无网关 → 默认)
      controller.selectMethod(ConnectionMethod.ap);
      await tester.pump();
      expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
      expect(find.textContaining('点「连接相机」后 app 将自动接管相机'), findsOneWidget);
      await tester.tap(find.text('连接相机'));
      await tester.pump();
      expect(conn.connectIp, kDefaultCameraIp);
    });

    testWidgets('右上角模式选择弹层:方式条目 + 当前打勾;点选即切换并收层', (tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      await tester.tap(find.byIcon(Icons.usb));
      await tester.pumpAndSettle();
      expect(find.text('选择连接方式'), findsOneWidget);
      expect(find.text('有线'), findsOneWidget);
      expect(find.text('AP 模式'), findsOneWidget);
      expect(find.text('STA 模式'), findsOneWidget);
      expect(find.text('蓝牙'), findsNothing, reason: 'BLE 未装配不出蓝牙条目');

      await tester.tap(find.text('AP 模式'));
      await tester.pumpAndSettle();
      expect(controller.method, ConnectionMethod.ap);
      expect(find.text('选择连接方式'), findsNothing, reason: '点选后收弹层');
      expect(find.text('当前方式:AP 模式'), findsOneWidget);
    });

    testWidgets('STA 扫描面板:打开沿自动扫描,发现列表点选连接并收面板', (tester) async {
      // 加高视口:底部面板 85% 高,内容(发现列表/手填/已存相机)在
      // 默认 600 高下折线外,点按落空。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = _FakeConnection();
      final scanner = _FakeScanner();
      final controller =
          ConnectionController(connection: conn, scanner: scanner);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      // 原地替换(2026-10-18):选 STA 即本视图,无中央按钮;
      // 起扫挪帧尾,一帧后到位(spinner 永不定,pumpAndSettle 不适用)。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);
      // 打开沿自动扫描(mDNS 发现是慢活,转圈才有进度感)
      expect(scanner.startCalls, 1);
      expect(find.text('扫描中…(点按停止)'), findsOneWidget);

      scanner.eventsCtrl.add(const NsdCameraFound(_zfCamera));
      await tester.pump();
      expect(find.text('Z_f_8014411'), findsOneWidget);
      expect(find.text('192.168.0.104'), findsOneWidget);

      // 点选相机 → 连接沿(页面监听 connecting 自动返回,进度/取消
      // 在主视图状态卡)
      final tile = tester.widget<ListTile>(find.ancestor(
          of: find.text('Z_f_8014411'), matching: find.byType(ListTile)).first);
      // ignore: avoid_print
      print('DBG tile onTap=${tile.onTap != null} busy=${controller.state}');
      await tester.tap(find.text('Z_f_8014411'));
      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 页面退场动画走完
      expect(conn.connectIp, '192.168.0.104');
      expect(conn.connectInstanceName, 'Z_f_8014411');
      expect(scanner.stopCalls, 1, reason: 'connectDiscovered 自带停扫');
      // ignore: avoid_print
      print('DBG probes: scaffolds=${find.byType(Scaffold).evaluate().length}');
      final tctx = tester.element(find.text('STA 连接(同一 Wi-Fi)').first);
      // ignore: avoid_print
      print('DBG route=${ModalRoute.of(tctx)?.runtimeType} isCurrent=${ModalRoute.of(tctx)?.isCurrent} canPop=${Navigator.of(tctx).canPop()} navigators=${find.byType(Navigator).evaluate().length}');
    });

    
    
    testWidgets('断开后快速重连列表刷新(connected → disconnected 沿上重拉档案)', (tester) async {
      // 加高视口:「上次」列表在面板折线下(同上)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = _FakeConnection();
      final store = InMemoryPairedCamerasStore();
      await store.save(const CameraInfo(
          id: '012345678901', name: 'Z_f_8014411', lastIp: '192.168.1.4'));
      final controller =
          ConnectionController(connection: conn, pairedCameras: store);
      controller.selectMethod(ConnectionMethod.sta);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));
      await tester.pump();

      // 首帧档案:STA 视图「上次」列表可见(原地替换,无面板),点选直连
      expect(find.text('上次:Z_f_8014411'), findsOneWidget);
      await tester.tap(find.text('上次:Z_f_8014411'));
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
      expect(find.text('上次:Z_8_ABC'), findsOneWidget, reason: '断开沿上重拉连接档案');
      expect(find.text('上次:Z_f_8014411'), findsOneWidget);
    });

    
    testWidgets('connecting 态:中央按钮/方式选择禁用,可取消(逃生口)', (tester) async {
      final conn = _FakeConnection();
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.connecting);
      await tester.pump();

      expect(find.text('取消连接'), findsOneWidget);
      // 中央连接按钮禁用(busy 锁发起新连接)
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '连接相机'))
            .onPressed,
        isNull,
      );
      // 右上角方式选择禁用(连接进行中不可换方式)
      expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byIcon(Icons.usb), matching: find.byType(IconButton)))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('取消连接'));
      await tester.pump();
      expect(conn.disconnectCalls, 1);
    });

    testWidgets(
        'reconnecting 态:状态卡「正在重连…」+ hint 动态文案 + '
        '取消重连逃生口 + 主操作禁用(2026-10-10)', (tester) async {
      final conn = _FakeConnection()
        ..err = '相机被占用(可能被 SnapBridge/尼享连接),每 5 秒慢速重试,可点「取消」';
      final controller = ConnectionController(connection: conn);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: controller)));

      conn.statesCtrl.add(CameraLinkState.reconnecting);
      // 状态卡尾槽 spinner(不定进度)永不 settle —— pump 走帧即可。
      await tester.pump();

      expect(find.text('正在重连…'), findsOneWidget, reason: '状态卡 label');
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'busy 尾槽 spinner(重连进行中)');
      expect(find.text('相机被占用(可能被 SnapBridge/尼享连接),每 5 秒慢速重试,可点「取消」'),
          findsOneWidget,
          reason: 'hint 读连接层动态文案(busy 慢拍分类)');
      expect(find.text('取消重连'), findsOneWidget, reason: '重连中逃生口');
      expect(find.text('取消连接'), findsNothing, reason: '文案按态区分');

      // busy:中央按钮与方式选择禁用(恢复期不可换方式/发起连接)
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '连接相机'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byIcon(Icons.usb), matching: find.byType(IconButton)))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('取消重连'));
      await tester.pump();
      expect(conn.disconnectCalls, 1, reason: '取消重连 = disconnect(恢复循环即止)');
    });

    testWidgets('无感配对:进 pairing 态自动确认,全程不弹窗', (tester) async {
      final conn = _FakeConnection()..code = '5077';
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
      final conn = _FakeConnection()..code = '5077';
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
      final conn = _FakeConnection()..code = '5077';
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
      expect(controller.hint, contains('conn.pairingSent'));
      expect(find.text('取消连接'), findsOneWidget, reason: '等待窗保留取消逃生口');

      // 窗口耗尽转 failed:等待文案撤下,回到真实错误
      conn.statesCtrl.add(CameraLinkState.failed);
      await tester.pumpAndSettle();
      expect(controller.awaitingCameraConfirm, isFalse);
      expect(find.text('等待相机上确认配对…'), findsNothing);
      expect(controller.hint, 'conn.failed');
    });

    testWidgets('删除已保存相机:确认 → 清档案,列表即消(无感重配语义)', (tester) async {
      // 加高视口:「忘记这台相机」tooltip 在面板折线下(同上)。
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final conn = _FakeConnection();
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
      expect(find.text('上次:Z_f_8014411'), findsOneWidget);

      await tester.tap(find.byTooltip('忘记这台相机'));
      await tester.pumpAndSettle();
      expect(find.text('忘记这台相机?'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(await store.list(), isEmpty);
      expect(find.text('上次:Z_f_8014411'), findsNothing);
    });

    testWidgets(
        '已连接视图:bento 卡 v24(状态行/机身/镜头信息/存储)+ 底部双钮'
        '+ 状态行弹层(详情/断开)', (WidgetTester tester) async {
      // 加高视口:卡片网格较长,底部双钮在折线下(点空)。
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
          data:
              _deviceInfoDataset(deviceProps: const [0x5001, 0x5008, 0x5007])));
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
      // 镜头规格五连读(0xD0E0 + 0xD0E3-E6,不在声明表但应答):
      // ID 99(不在映射表)+ 40-40mm ƒ/2-ƒ/2。
      transport.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([99, 0]))); // 镜头 ID u16
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
      // 底部双钮:左相册右进入拍摄;断开连接不在主页面(弹层里)。
      expect(find.text('进入拍摄'), findsOneWidget);
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('断开连接'), findsNothing,
          reason: '断开连接移入状态行弹层');

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

      // 状态行点按 → 详情弹层:四行读数 + 红色断开连接。
      await tester.tap(find.text('已连接'));
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

      await tester.tap(find.text('断开连接'));
      await tester.pumpAndSettle();
      expect(conn.disconnectCalls, 1);
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
      _FakeConnection? connection,
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

    /// 进蓝牙工具面板:右上角方式弹层选蓝牙 → 点「连接相机」。
    Future<void> openBleTools(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.usb));
      await tester.pumpAndSettle();
      // 选中即进流程:蓝牙条目点下直接弹工具面板(不再回落点连接)。
      await tester.tap(find.text('蓝牙'));
      await tester.pumpAndSettle();
    }

    testWidgets('未装配 BLE:方式弹层无蓝牙条目,默认有线主视图照常', (tester) async {
      final conn = _FakeConnection();
      await tester.pumpWidget(MaterialApp(
          home: ConnectionPage(
              controller: ConnectionController(connection: conn))));
      await tester.pump();
      expect(find.text('连接相机'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.usb));
      await tester.pumpAndSettle();
      expect(find.text('选择连接方式'), findsOneWidget);
      expect(find.text('蓝牙'), findsNothing);
    });

    testWidgets(
        '已配对未连(idle):重连钮在场,WiFi 钮禁用;'
        'PTP 状态卡不出(工具通道不混链路态)', (tester) async {
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
      expect(find.text('蓝牙连接'), findsOneWidget);
      expect(find.text('未连接'), findsNothing, reason: 'PTP 状态卡在蓝牙分段下隐藏');
      expect(find.text('已配对,未连接'), findsOneWidget);
      // 打开沿自动重连已在跑(面板硬绑 AppServices 单例;本用例页面显示
      // 夹具自建会话,状态行不动,但面板钮同位转进行态 —— 自动化可见面)。
      final retryBtn = tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('重连中…'), matching: find.byType(OutlinedButton)));
      expect(retryBtn.onPressed, isNotNull,
          reason: '点按即唤醒(2026-10-18):重连进行中可点,打断受闸循环绕闸直连');
      final wake = tester.widget<FilledButton>(find.ancestor(
          of: find.text('远程连接相机'), matching: find.byType(FilledButton)));
      expect(wake.onPressed, isNull, reason: 'WiFi 动作门禁 = 会话就绪');
      // GPS 注入开关已迁设置页(2026-10-18),蓝牙页不再有开关。
      expect(find.byType(SwitchListTile), findsNothing);
      // 收尾:关弹层 → 面板 dispose 废在途自动重连(退避 Timer 随取消
      // 释放;不关则挂到用例尾判「Timer still pending」)。
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
    });

    testWidgets(
        'ready 后:关闭/唤醒写 0x2005;唤醒沿断链(相机等 BLE 释放才开热点)',
        (tester) async {
      // 夹具有真文件 IO(临时目录/身份存档),testWidgets 的
      // fake-async zone 吃不到 —— 必须 runAsync 放行。
      final f = (await tester.runAsync(readyFixture))!;
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);
      expect(find.text('已连接'), findsOneWidget);

      // 关闭先测(须 ready 态;唤醒沿会断链,0x80 不断链)。
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(f.host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x80]));
      expect(f.session.state, BleSessionState.ready);

      await tester.tap(find.text('远程连接相机'));
      await tester.pumpAndSettle();
      expect(f.host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x01]));
      expect(f.session.state, BleSessionState.idle,
          reason: '写成功即断链:相机等 BLE 释放才真正开热点');
      expect(find.byType(SnackBar), findsOneWidget);
      // 收尾:关弹层废在途自动重连(退避 Timer 随取消释放)。
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
    });

    testWidgets('未就绪时 WiFi 动作如实失败(controller 门禁)', (tester) async {
      final host = FakeBleHost();
      final session = BleCameraSession(host: host);
      expect(await session.wakeCameraWifi(), isFalse);
      expect(host.writes, isEmpty);
      expect(session.lastError, contains('BLE 未连接'));
    });

    testWidgets('唤醒沿自动读凭据:0x2004 解出 → AP 卡凭据块照实显示', (tester) async {
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

      // 原地替换(无页可退):直接经方式弹层切 AP 模式,凭据卡在本视图
      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AP 模式'));
      await tester.pumpAndSettle();
      expect(find.text('相机热点凭据(蓝牙通道解出)'), findsOneWidget);
      expect(find.text('wpa2pass99'), findsOneWidget);
      expect(find.text('SSID'), findsOneWidget);
      expect(find.textContaining('WPA2'), findsOneWidget);
    });

    testWidgets('唤醒但凭据未解出:AP 方式不出凭据卡,提示如实', (tester) async {
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
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('凭据未解出'), findsOneWidget);

      // 切 AP 模式方式:主视图不出凭据卡
      await tester.tap(find.byTooltip('选择连接方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AP 模式'));
      await tester.pumpAndSettle();
      expect(find.text('相机热点凭据(蓝牙通道解出)'), findsNothing);
    });

    testWidgets('唤醒沿 joiner ok:自动加入热点 + 发射 AP 连接(连接层收到 connect)',
        (tester) async {
      final conn = _FakeConnection();
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
      final conn = _FakeConnection();
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
      // 收尾:关弹层废在途自动重连(joiner 失败不触发自动收层)。
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
    });

    /// 真异步排微任务(握手事件沿各排一轮;普通 test 无 fake-async 痛)。
    Future<void> drainMicrotasks() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('关闭 Wi-Fi(BLE 断态):先补链再写 0x80,链路保持 —— 控制器层', () async {
      // 握手舞步靠事件沿驱动,widget 测试的 fake-async zone 排不动
      // 这条微任务链 —— 下放到控制器层普通 test(真异步)。
      final host = FakeBleHost();
      final session = BleCameraSession(host: host);
      final identityStore = await tempIdentityStore();
      final controller = ConnectionController(
        bleSession: session,
        bleIdentityStore: identityStore,
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
      // 先到 ready(完整握手),再断到 idle —— 传图后常态。
      final done = session
          .pair(const BleDevice(name: 'Z f_8014411', uuid: 'P1', rssi: -50));
      await drainMicrotasks();
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await drainMicrotasks();
      final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
      await drainMicrotasks();
      host.emit(
          BleNotified(uuid: kNikonCharPairing, data: buildStage4().encode()));
      await drainMicrotasks();
      await done;
      expect(session.state, BleSessionState.ready);
      await session.disconnect();
      await drainMicrotasks(); // 控制器 bleState 镜像(流异步投递)跟到 idle
      expect(session.state, BleSessionState.idle);

      // 补链关 Wi-Fi:重连命中 → 复用握手 → 写 0x80 → 链路保持。
      // reconnectDeviceId 用会话现役身份的 deviceId(pair 沿 stage4
      // 派生,与 store 存档值无关 —— 会话层测试同款口径)。
      host.reconnectDeviceId = session.identity!.deviceId;
      final closeFut = controller.closeCameraWifi();
      await drainMicrotasks();
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await drainMicrotasks();
      final stage1r = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1r).encode()));
      await drainMicrotasks();
      host.emit(
          BleNotified(uuid: kNikonCharPairing, data: buildStage4().encode()));
      expect(await closeFut, isTrue);
      expect(host.lastWrite(kNikonCharWifi), Uint8List.fromList([0x80]));
      expect(session.state, BleSessionState.ready,
          reason: '关 Wi-Fi 后无线单元空出,BLE 保持连接(注入续上)');
    });

    testWidgets('关闭 Wi-Fi(补链无命中):如实失败,态回落可重试', (tester) async {
      final f = (await tester.runAsync(readyFixture))!;
      await f.session.disconnect(); // BLE 断;host 未预置重连命中
      await tester.pumpWidget(
          MaterialApp(home: ConnectionPage(controller: f.controller)));
      await tester.pumpAndSettle();
      await openBleTools(tester);

      await tester.ensureVisible(find.text('关闭')); // 断态卡多一行,钮可能折出视口
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle(); // 第 1 轮扫描无命中 → 退避定时器挂起
      await tester.pump(const Duration(seconds: 2)); // 退避(1s 档)到点
      await tester.pumpAndSettle(); // 第 2 轮无命中 → 两轮尽 → 如实失败
      expect(f.host.countWrite(kNikonCharWifi), 0, reason: '两轮无命中:不该有 0x80 写入');
      expect(f.session.state, BleSessionState.idle, reason: '无命中不进连接尝试,态不翻转');
      expect(find.textContaining('重连无命中'), findsExactly(2),
          reason: 'SnackBar(操作失败)+ 弹层错误行(lastError 实时上屏,2026-10-17 A2)各一处');
      // 收尾:关弹层废在途自动重连(退避 Timer 随取消释放)。
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
    });

    testWidgets('lastError 沿实时刷新:错误落库即 notifyListeners,同值不发', (tester) async {
      final f = (await tester.runAsync(readyFixture))!;
      var notifications = 0;
      f.controller.addListener(() => notifications++);
      f.session.lastError = '注入失败:x';
      await tester.pump();
      final afterErr = notifications;
      expect(afterErr, greaterThan(0), reason: '错误沿即时刷新,不等状态跃迁');
      f.session.lastError = '注入失败:x'; // 同值去重
      await tester.pump();
      expect(notifications, afterErr);
      f.session.lastError = '注入失败:y';
      await tester.pump();
      expect(notifications, greaterThan(afterErr));
    });
  });
}

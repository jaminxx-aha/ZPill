import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/ble_camera_session.dart';
import 'package:z_pill/core/ble/geo_payload.dart';
import 'package:z_pill/platform/ble_scanner.dart';
import 'package:z_pill/platform/background_transfer.dart';
import 'package:z_pill/platform/ble_driver.dart';
import 'package:z_pill/platform/location_host.dart';

/// 最小桩:驱动本身不触 host(只有会话触),驱动门面用例保持会话
/// idle 即可,未触面一律 UnimplementedError。
final class _StubBleHost implements BleHost {
  // 会话构造沿即订阅 events(其余面保持未触,驱动用例不走到)。
  @override
  Stream<BleEvent> get events => const Stream<BleEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _RecordingBackground implements BackgroundTransferScheduler {
  final ensureCalls = <(String, Set<BgMode>)>[];
  final stops = <String>[];
  var reassertCalls = 0;

  @override
  Future<void> ensureRunning(String tag, Set<BgMode> modes) async {
    ensureCalls.add((tag, modes));
  }

  @override
  Future<void> stop(String tag) async => stops.add(tag);

  @override
  Future<void> reassert() async => reassertCalls++;
}

final class _StubLocationStream implements LocationStreamHost {
  var started = 0;
  var stopped = 0;

  @override
  Future<void> startStream() async => started++;

  @override
  Stream<LocationSample> stream() => const Stream<LocationSample>.empty();

  @override
  Future<void> stopStream() async => stopped++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 可注入定位点的记录流(PTP 注入用例)。只实现流/起停三面,授权面
/// 保持未触。
final class _RecordingLocationStream implements LocationStreamHost {
  final ctrl = StreamController<LocationSample>.broadcast();
  var started = 0;
  var stopped = 0;

  @override
  Future<void> startStream() async => started++;

  @override
  Stream<LocationSample> stream() => ctrl.stream;

  @override
  Future<void> stopStream() async => stopped++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _identity = BleIdentity(
  peripheralUuid: 'AA-BB',
  deviceId: 7,
  nonce: 12345678,
  serial: '30012345',
  name: 'Z fc',
);

void main() {
  late BleCameraSession session;
  late _RecordingBackground background;
  late _StubLocationStream location;
  late BleDriver driver;
  var gpsOn = false;

  setUp(() {
    session = BleCameraSession(host: _StubBleHost());
    background = _RecordingBackground();
    location = _StubLocationStream();
    gpsOn = false;
    driver = BleDriver(
      session: session,
      gpsInjectEnabled: () => gpsOn,
      locationStream: location,
      background: background,
      dataDir: () async => '', // 实例看门狗缺席(测试无 pending Timer)
    );
  });

  tearDown(() {
    // 收驱动循环:周期 tick/重试 Timer 全取消,测试无 pending Timer。
    driver.manualOff = true;
  });

  test('有身份 refresh:链路层起跑;idle 会话沿释放后台持有(ready 才持)',
      () async {
    session.identity = _identity;
    driver.refresh();
    expect(driver.running, isTrue);
    await pumpEventQueue();
    // 持有语义:bluetoothInteraction 只在会话 ready 沿申请(状态沿由
    // 装配层监听驱动 syncBackgroundHold);idle 沿一律释放。
    expect(background.ensureCalls, isEmpty);
    expect(background.stops, ['ble']);
  });

  test('GPS 开:注入层挂定位流订阅(会话 idle 不起平台流)', () async {
    session.identity = _identity;
    gpsOn = true;
    driver.refresh();
    await pumpEventQueue();
    expect(driver.running, isTrue);
    expect(location.started, 0); // idle 会话:平台流等 ready 沿
  });

  test('suspend 有身份:跳过挂起(回链优先,回链定稿 2026-10-21)',
      () async {
    session.identity = _identity;
    driver.refresh();
    driver.suspend();
    expect(driver.running, isTrue);
  });

  test('suspend 无身份(真首配):驱动停,后台持有释放', () async {
    driver.refresh(); // 无身份:wantLink false,本就不跑
    session.identity = _identity;
    driver.refresh();
    expect(driver.running, isTrue);
    session.identity = null;
    driver.suspend();
    await pumpEventQueue();
    expect(driver.running, isFalse);
    expect(background.stops, ['ble', 'ble']); // 身份沿 + 挂起沿各一释放
  });

  test('manualOff 翻面:链路层收(有身份不拆链),清除沿恢复守候', () async {
    session.identity = _identity;
    driver.refresh();
    expect(driver.running, isTrue);
    driver.manualOff = true;
    await pumpEventQueue();
    expect(driver.running, isFalse);
    driver.manualOff = false;
    await pumpEventQueue();
    expect(driver.running, isTrue); // 显式连接/重配对沿清除后守候恢复
  });

  test('PTP 注入:无 BLE 身份也起定位流,优先 0x9523 且 30s 内同点不重写',
      () async {
    final loc = _RecordingLocationStream();
    final writes = <GeoFix>[];
    var ptpReady = true;
    var gpsOn = true;
    final d = BleDriver(
      session: session,
      gpsInjectEnabled: () => gpsOn,
      locationStream: loc,
      background: background,
      dataDir: () async => '',
      ptpGpsAvailable: () => ptpReady,
      ptpGpsWrite: (fix) async {
        writes.add(fix);
        return true;
      },
    );
    addTearDown(() async {
      gpsOn = false;
      d.refresh();
      await pumpEventQueue();
      await loc.ctrl.close();
    });

    d.refresh();
    await pumpEventQueue();
    expect(loc.started, 1, reason: 'PTP-only 也要起平台定位流');

    const sample =
        LocationSample(latitude: 35.5, longitude: 139.7, altitude: 40);
    loc.ctrl.add(sample);
    await pumpEventQueue();
    expect(writes, hasLength(1));
    expect(writes.single.latitude, 35.5);
    expect(writes.single.altitude, 40);

    loc.ctrl.add(sample); // 同点、30s 内:不重写
    await pumpEventQueue();
    expect(writes, hasLength(1));

    // PTP 掉线:注入层收口,不再写 PTP
    ptpReady = false;
    d.refresh();
    await pumpEventQueue();
    loc.ctrl.add(const LocationSample(
        latitude: 35.5001, longitude: 139.7, altitude: 40));
    await pumpEventQueue();
    expect(writes, hasLength(1));
  });
}

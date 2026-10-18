import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/ble_camera_session.dart';
import 'package:nikon_pill/core/ble/blowfish_hasher.dart';
import 'package:nikon_pill/core/ble/gatt_uuids.dart';
import 'package:nikon_pill/core/ble/geo_payload.dart';
import 'package:nikon_pill/core/ble/pairing_engine.dart';
import 'package:nikon_pill/core/ble/pairing_message.dart';
import 'package:nikon_pill/platform/ble_scanner.dart';

import 'wifi_credentials_test.dart' show craftBlob;

/// BleHost 假体:写序记录 + 事件注入 + 可编程失败。
final class FakeBleHost implements BleHost {
  final eventCtrl = StreamController<BleEvent>.broadcast();
  final writes = <(String, Uint8List)>[];
  final notifies = <String>[];
  final reads = <String, Uint8List?>{};
  Object? writeError;
  Object? readError;
  int? reconnectDeviceId;
  Uint8List? reconnectMfg;
  final connects = <String>[];

  void emit(BleEvent event) => eventCtrl.add(event);

  Uint8List lastWrite(String uuid) =>
      writes.reversed.firstWhere((w) => w.$1 == uuid).$2;

  int countWrite(String uuid) => writes.where((w) => w.$1 == uuid).length;

  @override
  Stream<BleEvent> get events => eventCtrl.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<BleDevice>> scan(
          {Duration timeout = const Duration(seconds: 10)}) async =>
      const [];

  @override
  Future<void> stopScan() async {}

  @override
  Future<List<BleDevice>> scanForDeviceId(int deviceId,
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (reconnectDeviceId == deviceId) {
      return [
        BleDevice(
            name: 'Z f_x', uuid: 'P1', rssi: -50, mfgData: reconnectMfg)
      ];
    }
    return const [];
  }

  @override
  Future<void> connectPaired(String peripheralUuid) async {
    connects.add(peripheralUuid);
  }

  @override
  Future<void> setNotify(String characteristicUuid) async {
    notifies.add(characteristicUuid);
  }

  @override
  Future<Uint8List?> read(String characteristicUuid) async {
    final error = readError;
    if (error != null) {
      throw error;
    }
    return reads[characteristicUuid];
  }

  @override
  Future<void> write(String characteristicUuid, Uint8List data,
      {bool withoutResponse = false}) async {
    // 失败也记账:先记录再抛,失败写同样是一次写尝试。
    writes.add((characteristicUuid, data));
    final error = writeError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> disconnect() async {}
}

Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

int _reverseU32(int value) {
  final v = value & 0xFFFFFFFF;
  return ((v & 0x000000FF) << 24) |
      ((v & 0x0000FF00) << 8) |
      ((v & 0x00FF0000) >>> 8) |
      ((v & 0xFF000000) >>> 24);
}

/// 按 salt[0] 构造相机 stage2 挑战(与引擎 _findSalt 同构)。
PairingMessage buildStage2(PairingMessage stage1,
    {int camTs = 0xb9943d5e8026fa29}) {
  final hasher = BlowfishHasher();
  final salt = NikonPairingEngine.salts[0];
  final (h0, h1) = hasher.hash(<int>[
    salt[0],
    salt[1],
    _reverseU32(camTs & 0xFFFFFFFF),
    _reverseU32((camTs >>> 32) & 0xFFFFFFFF),
    _reverseU32(stage1.timestamp & 0xFFFFFFFF),
    _reverseU32((stage1.timestamp >>> 32) & 0xFFFFFFFF),
  ]);
  return PairingMessage(
    stage: 0x02,
    timestamp: camTs,
    device: _reverseU32(h0),
    nonce: _reverseU32(h1),
  );
}

/// stage4:字节 9-16 = 序列号 ASCII(device/nonce 小端拼出)。
PairingMessage buildStage4() => const PairingMessage(
      stage: 0x04,
      timestamp: 0,
      device: 0x33323142, // LE = 'B123'
      nonce: 0x00363534, // LE = '456\0'
    );

void main() {
  late FakeBleHost host;
  late DateTime now;
  late BleCameraSession session;
  const device = BleDevice(name: 'Z f_8014411', uuid: 'P1', rssi: -50);

  setUp(() {
    host = FakeBleHost();
    now = DateTime.utc(2026, 10, 13, 8, 0, 0);
    session = BleCameraSession(host: host, now: () => now);
    // 拆链弃写:Ready 沿自驱首写是真实 2.5s 延迟,tearDown 断链让守卫
    // 弃写,防迟发写漏进下一测试的时序。
    addTearDown(() => session.disconnect());
  });

  GeoFix fixAt(double lat,
          {double lon = 139.0, double alt = 10, int sats = 8}) =>
      GeoFix(
        latitude: lat,
        longitude: lon,
        altitude: alt,
        satellites: sats,
        utcTime: now,
      );

  /// 驱动完整握手:连接 → stage1 → stage2 → stage4 → NOT1。
  Future<void> runHandshake(
      {bool resume = false,
      BleCameraSession? target,
      bool? gateStandby}) async {
    final s = target ?? session;
    Object? ok;
    final done = resume
        ? s.retryReconnect(gateStandby: gateStandby ?? true).then((v) => ok = v)
        : s.pair(device);
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    final stage1 =
        PairingMessage.decode(host.lastWrite(kNikonCharPairing));
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
    await pump();
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage4().encode()));
    await pump();
    host.emit(BleNotified(
        uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
    await pump();
    if (resume) {
      expect(ok, isTrue);
    } else {
      await done;
    }
  }

  test('配对全链:订阅 → stage1 → stage3 → 序列号 → 控制器名 → ready', () async {
    await runHandshake();
    expect(session.state, BleSessionState.ready);
    expect(host.notifies, [
      kNikonCharPairing,
      kNikonCharNot1,
      kNikonCharNot2,
      kNikonCharStatusForControl,
      kNikonCharControlPoint,
    ]);
    expect(session.identity, isNotNull);
    expect(session.identity!.peripheralUuid, 'P1');
    expect(session.identity!.deviceId & 0xFF, 0x01);
    expect(session.identity!.serial, 'B123456');
    expect(session.identity!.name, 'NikonPill');
    final name = host.lastWrite(kNikonCharName);
    expect(name.length, 32);
    expect(String.fromCharCodes(name.take(9)), 'NikonPill');
    expect(name.skip(9).every((b) => b == 0), isTrue);
  });

  test('lastError 变化沿 errors 流实时发(同值不发,清空发 null)', () async {
    final seen = <String?>[];
    final sub = session.errors.listen(seen.add);
    session.lastError = '旧错';
    session.lastError = '旧错'; // 同值去重,不重复上屏
    session.lastError = '新错';
    await pump();
    session.lastError = null;
    await pump();
    await sub.cancel();
    expect(seen, ['旧错', '新错', null]);
  });

  test('ready 沿清陈旧错误(重连几轮失败后终成,错误行不残留)', () async {
    session.lastError = '第 1 轮无命中';
    final done = session.pair(device);
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
    await pump();
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage4().encode()));
    await pump();
    expect(session.state, BleSessionState.ready);
    expect(session.lastError, isNull);
    await done;
  });

  test('stage4+名字写 → 即刻 ready(NOT1 非闸门,真机 2026-10-13)', () async {
    final done = expectLater(session.pair(device), completes);
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
    await pump();
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage4().encode()));
    await pump();
    expect(session.state, BleSessionState.ready); // 名字落定即收口
    expect(host.countWrite(kNikonCharName), 1);
    // 迟到 NOT1 纯信息,状态不动
    host.emit(BleNotified(
        uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
    await pump();
    expect(session.state, BleSessionState.ready);
    await done;
  });

  test('握手无应答超时 → pair 抛 BlePairingException 回 idle', () async {
    final short = BleCameraSession(
        host: host,
        now: () => now,
        handshakeTimeout: const Duration(milliseconds: 60));
    // expectLater 急切挂接(同 salt-miss 例)。
    final done = expectLater(
        short.pair(device), throwsA(isA<BlePairingException>()));
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    // stage1 已发出但相机不应答:超时弃局回 idle。
    await done;
    expect(short.state, BleSessionState.idle);
  });

  test('stage2 无 salt 命中 → pair 抛 BlePairingException,回 idle', () async {
    // expectLater 急切挂接,避免 pair 抛错先落成 unhandled async error。
    final done = expectLater(
        session.pair(device), throwsA(isA<BlePairingException>()));
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    final stage1 =
        PairingMessage.decode(host.lastWrite(kNikonCharPairing));
    final bad = buildStage2(stage1);
    host.emit(BleNotified(
        uuid: kNikonCharPairing,
        data: PairingMessage(
          stage: 0x02,
          timestamp: bad.timestamp,
          device: bad.device ^ 0x01,
          nonce: bad.nonce,
        ).encode()));
    await pump();
    await done;
    expect(session.state, BleSessionState.idle);
  });

  test('握手期间断连 → pair 抛错回 idle', () async {
    final done = expectLater(
        session.pair(device), throwsA(isA<BlePairingException>()));
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    host.emit(const BleDisconnected('P1'));
    await pump();
    await done;
    expect(session.state, BleSessionState.idle);
  });

  test('GEO 去重门:首点过闸发;<3s 且 <1.1m 跳;位移 ≥1.1m 发;≥3s 发', () async {
    await runHandshake();
    int geoCount() => host.countWrite(kNikonCharGeo);
    // 首写门内(Ready+2.5s)onFix 缓存不写,过闸 tick 回补。
    session.onFix(fixAt(35.5));
    await pump();
    expect(geoCount(), 0);
    now = now.add(const Duration(seconds: 3));
    await session.tick();
    expect(geoCount(), 1); // 回补首点
    expect(host.countWrite(kNikonCharTime), 1); // 同拍首笔 TIME(校时)

    session.onFix(fixAt(35.500009)); // ~1.0m <1.1m 且 <3s → 跳
    await pump();
    expect(geoCount(), 1);

    session.onFix(fixAt(35.50001)); // ~1.11m ≥1.1m → 发(仍 <3s)
    await pump();
    expect(geoCount(), 2);

    now = now.add(const Duration(seconds: 3));
    session.onFix(fixAt(35.50001)); // 未动但距上次成功 ≥3s → 发
    await pump();
    expect(geoCount(), 3);
  });

  test('GEO 写失败入缓存:过闸 tick 重发,失败重进闸,成功后恢复', () async {
    await runHandshake();
    host.writeError = Exception('GATT 错误(唤醒窗)');
    session.onFix(fixAt(35.5)); // 首写门内:缓存不写
    await pump();
    expect(host.countWrite(kNikonCharGeo), 0);
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // 过闸回补 → 写失败(失败也记账 1)→ 重进闸
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(session.state, BleSessionState.ready); // 不炸会话
    expect(host.countWrite(kNikonCharTime), 0); // 重进闸:TIME 让位

    host.writeError = null;
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // 过重闸:回补成功 + 首笔 TIME
    expect(host.countWrite(kNikonCharGeo), 2);
    expect(host.countWrite(kNikonCharTime), 1);
  });

  test('保鲜与保活:30s 无成功注入重发 GEO;TIME 45s 档到点写', () async {
    await runHandshake();
    session.onFix(fixAt(35.5));
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // 首笔回补 GEO + TIME
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(host.countWrite(kNikonCharTime), 1);

    now = now.add(const Duration(seconds: 20));
    await session.tick(); // 20s:GEO 未到 30s、TIME 未到 45s → 静默
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(host.countWrite(kNikonCharTime), 1);

    now = now.add(const Duration(seconds: 12)); // 累计 32s
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 2); // GEO 保鲜重发
    expect(host.countWrite(kNikonCharTime), 1); // 32s < 45s 仍未到点

    now = now.add(const Duration(seconds: 14)); // 距上次 TIME 46s
    await session.tick();
    expect(host.countWrite(kNikonCharTime), 2); // 45s 档到点
    expect(host.countWrite(kNikonCharGeo), 2); // 距保鲜成功 14s → 不重发
  });

  test('ready 断连 → reconnecting;重连复用身份(deviceId/nonce 不变)', () async {
    await runHandshake();
    final saved = session.identity!;
    host.emit(const BleDisconnected('P1'));
    await pump();
    expect(session.state, BleSessionState.reconnecting);
    expect(session.nextRetryDelay, const Duration(seconds: 1));

    host.reconnectDeviceId = saved.deviceId;
    now = now.add(const Duration(seconds: 1));
    await runHandshake(resume: true);
    expect(session.state, BleSessionState.ready);
    expect(session.identity!.deviceId, saved.deviceId);
    expect(session.identity!.nonce, saved.nonce);
    expect(session.nextRetryDelay, const Duration(seconds: 1)); // 归零
  });

  test('重连无命中推进退避;nextRetryDelay 封顶 60s', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = null; // 扫不到
    for (final expected in const [2, 4, 8, 16, 30, 60, 60]) {
      final ok = await session.retryReconnect();
      expect(ok, isFalse);
      expect(session.nextRetryDelay, Duration(seconds: expected));
    }
  });

  test('深睡闸门:自动重连扫到待机广播(bit0=1)不连,退避冻结 2s', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = session.identity!.deviceId;
    // Zf 真机 2026-10-17:待机 0x1F(bit0=1;字节布局 99 03 + deviceId + 状态)。
    host.reconnectMfg =
        Uint8List.fromList([0x99, 0x03, 0x44, 0x5d, 0x4b, 0x24, 0x1f]);
    host.connects.clear(); // 首配的连接记账清掉,只看闸门期
    for (var i = 0; i < 3; i++) {
      expect(await session.retryReconnect(), isFalse);
    }
    expect(session.state, BleSessionState.reconnecting);
    expect(session.nextRetryDelay, const Duration(seconds: 2)); // 冻结不推进
    expect(session.lastRetryGated, isTrue); // 上层日志据此区分「被闸/无命中」
    expect(host.connects, isEmpty); // 一次连接都没发起
  });

  test('深睡闸门放行:广播转就绪(bit0=0)即连,复用握手到 ready', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = session.identity!.deviceId;
    host.reconnectMfg =
        Uint8List.fromList([0x99, 0x03, 0x44, 0x5d, 0x4b, 0x24, 0x1e]);
    host.connects.clear();
    await runHandshake(resume: true); // 默认闸门开:0x1E 非待机 → 放行
    expect(session.state, BleSessionState.ready);
    expect(session.lastRetryGated, isFalse);
    expect(host.connects, ['P1']);
  });

  test('手动重连绕闸:待机广播 + gateStandby:false 照连', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = session.identity!.deviceId;
    host.reconnectMfg =
        Uint8List.fromList([0x99, 0x03, 0x44, 0x5d, 0x4b, 0x24, 0x1f]);
    host.connects.clear();
    await runHandshake(resume: true, gateStandby: false);
    expect(session.state, BleSessionState.ready);
    expect(host.connects, ['P1']);
    expect(session.lastMatchName, 'Z f_x',
        reason: '重连命中沿记录广播名(ready 沿旧档相机名回填消费)');
  });

  test('重连后写闸:2.5s 内不写,过闸恢复 GEO/TIME;首写门重连同套', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = session.identity!.deviceId;
    now = now.add(const Duration(seconds: 1));
    await runHandshake(resume: true);
    final geoBefore = host.countWrite(kNikonCharGeo);
    final timeBefore = host.countWrite(kNikonCharTime);

    session.onFix(fixAt(35.5)); // 闸内:onFix 缓存不写 GEO
    await pump();
    expect(host.countWrite(kNikonCharGeo), geoBefore);

    await session.tick(); // 闸内:TIME 也不写
    expect(host.countWrite(kNikonCharTime), timeBefore);

    now = now.add(const Duration(seconds: 3));
    session.onFix(fixAt(35.5)); // 过闸直发(无上次成功 → 过去重门)
    await pump();
    expect(host.countWrite(kNikonCharGeo), geoBefore + 1);
    await session.tick(); // 过闸:缓存已被直发取代,TIME 补上
    expect(host.countWrite(kNikonCharTime), timeBefore + 1);
  });

  test('Ready 延迟首写:2.5s 内零 GEO/TIME,恰过闸首拍双落', () async {
    await runHandshake();
    await pump();
    // 收口校时不再 Ready 沿即刻发(相机 GPS 会话未醒减灾)。
    expect(host.countWrite(kNikonCharTime), 0);
    expect(host.countWrite(kNikonCharGeo), 0);

    session.onFix(fixAt(35.5));
    await pump();
    expect(host.countWrite(kNikonCharGeo), 0); // 闸内缓存

    await session.tick();
    expect(host.countWrite(kNikonCharTime), 0);

    now = now.add(const Duration(milliseconds: 2500)); // 恰过闸
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 1); // 缓存回补
    expect(host.countWrite(kNikonCharTime), 1); // 首笔 TIME(校时)
  });

  test('首写自驱:writeGate=0 时 Ready 沿自发校时,不依赖驱动 tick(配对页挂起场景)',
      () async {
    final s = BleCameraSession(
        host: host, now: () => now, writeGate: Duration.zero);
    await runHandshake(target: s);
    await pump(); // 一次性延迟(0)沉淀
    expect(host.countWrite(kNikonCharTime), 1); // 自驱收口校时
    expect(s.state, BleSessionState.ready);
    expect(s.lastError, isNull);
  });

  test('TIME 保活档位:前台 45s 到点;切后台 90s;回前台按 45s', () async {
    await runHandshake();
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // 首笔 TIME(校时)
    expect(host.countWrite(kNikonCharTime), 1);

    now = now.add(const Duration(seconds: 44));
    await session.tick(); // 44s < 45s → 未到点
    expect(host.countWrite(kNikonCharTime), 1);

    now = now.add(const Duration(seconds: 1)); // 恰 45s
    await session.tick();
    expect(host.countWrite(kNikonCharTime), 2);

    session.setForeground(false); // 切后台档
    now = now.add(const Duration(seconds: 44));
    await session.tick(); // 44s < 90s → 未到点
    expect(host.countWrite(kNikonCharTime), 2);

    now = now.add(const Duration(seconds: 46)); // 90s 到点
    await session.tick();
    expect(host.countWrite(kNikonCharTime), 3);

    session.setForeground(true); // 回前台档:距上次 50s ≥ 45s → 到点
    now = now.add(const Duration(seconds: 50));
    await session.tick();
    expect(host.countWrite(kNikonCharTime), 4);
  });

  test('断链 ticker 停:非 ready 态到点也不写', () async {
    await runHandshake();
    now = now.add(const Duration(seconds: 3));
    await session.tick();
    final timeBefore = host.countWrite(kNikonCharTime);

    host.emit(const BleDisconnected('P1'));
    await pump();
    expect(session.state, BleSessionState.reconnecting);

    now = now.add(const Duration(seconds: 100));
    await session.tick(); // 到点也不写:ticker 随断链停
    expect(host.countWrite(kNikonCharTime), timeBefore);
  });

  test('TIME 写失败不炸会话:lastError 带因,下一拍重试同载荷', () async {
    await runHandshake();
    now = now.add(const Duration(seconds: 3));
    host.writeError = Exception('GATT 错误(唤醒窗)');
    await session.tick(); // 首笔 TIME 失败
    expect(session.state, BleSessionState.ready);
    expect(session.lastError, contains('TIME 写失败'));
    expect(host.countWrite(kNikonCharTime), 1); // 失败也记账

    host.writeError = null;
    await session.tick(); // 保活锚未落 → 立即重试
    expect(host.countWrite(kNikonCharTime), 2);
  });

  group('readWifiCredentials(0x2004,BLE→WiFi 二期)', () {
    test('ready 态读 0x2004 → 解密出凭据;blob 落 trace', () async {
      await runHandshake();
      final traces = <String>[];
      session.onTrace = traces.add;
      host.reads[kNikonCharConfig] =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: false);
      final creds = await session.readWifiCredentials();
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Zf_80114411');
      expect(creds.password, 'wpa2pass99');
      expect(creds.security, 0x02);
      expect(session.lastError, isNull);
      expect(traces.where((l) => l.startsWith('0x2004 ←')), isNotEmpty);
    });

    test('未 ready 拒读;空/短 blob 与解密未中如实带原因', () async {
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError, contains('BLE 未连接'));

      await runHandshake();
      host.reads[kNikonCharConfig] = Uint8List(0);
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError, contains('未下发'));

      host.reads[kNikonCharConfig] =
          Uint8List.fromList(List<int>.generate(96, (i) => (i * 7 + 3) & 0xFF));
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError, contains('长度异常'));

      host.reads[kNikonCharConfig] =
          Uint8List.fromList(List<int>.generate(97, (i) => (i * 7 + 3) & 0xFF));
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError, contains('解密未中'));
    });

    test('读失败(特征不在/断链)→ null 带原因', () async {
      await runHandshake();
      host.readError = Exception('GATT 读失败');
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError, contains('读 AP 凭据失败'));
    });
  });
}

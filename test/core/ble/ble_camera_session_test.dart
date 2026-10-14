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
      return [const BleDevice(name: 'Z f_x', uuid: 'P1', rssi: -50)];
    }
    return const [];
  }

  @override
  Future<void> connectPaired(String peripheralUuid) async {}

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
  Future<void> runHandshake({bool resume = false}) async {
    Object? ok;
    final done = resume
        ? session.retryReconnect().then((v) => ok = v)
        : session.pair(device);
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

  test('GEO 节流:首点发;3m 内 20s 内不发;位移 ≥3m 发;陈旧 ≥20s 发', () async {
    await runHandshake();
    int geoCount() => host.countWrite(kNikonCharGeo);
    expect(geoCount(), 0);

    session.onFix(fixAt(35.5));
    await pump();
    expect(geoCount(), 1); // 首点

    session.onFix(fixAt(35.50001)); // ~1.1m
    await pump();
    expect(geoCount(), 1);

    session.onFix(fixAt(35.50003)); // ~3.3m
    await pump();
    expect(geoCount(), 2);

    now = now.add(const Duration(seconds: 21));
    session.onFix(fixAt(35.50003)); // 未动但 ≥20s
    await pump();
    expect(geoCount(), 3);
  });

  test('GEO 写失败入缓存:写闸前 tick 不重发,过闸 tick 重发', () async {
    await runHandshake();
    host.writeError = Exception('GATT 错误(唤醒窗)');
    session.onFix(fixAt(35.5));
    await pump();
    expect(host.countWrite(kNikonCharGeo), 1); // 失败也记账
    host.writeError = null;

    await session.tick(); // t+0 仍在 2.5s 写闸内
    expect(host.countWrite(kNikonCharGeo), 1);

    now = now.add(const Duration(seconds: 3));
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 2); // 缓存重发
  });

  test('keep-alive:30s 无发送,tick 重发最后定位', () async {
    await runHandshake();
    session.onFix(fixAt(35.5));
    await pump();
    expect(host.countWrite(kNikonCharGeo), 1);

    now = now.add(const Duration(seconds: 31));
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 2);
    // TIME:收口沿 1 帧(配对校时)+ 本 tick 心跳 1 帧 = 2。
    expect(host.countWrite(kNikonCharTime), 2); // 同 tick 的 TIME 心跳
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

  test('重连后写闸:2.5s 内 tick 不写,过闸恢复 TIME 心跳', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    host.reconnectDeviceId = session.identity!.deviceId;
    now = now.add(const Duration(seconds: 1));
    await runHandshake(resume: true);
    final geoBefore = host.countWrite(kNikonCharGeo);
    final timeBefore = host.countWrite(kNikonCharTime);

    session.onFix(fixAt(35.5)); // 闸内:onFix 不写 GEO
    await pump();
    expect(host.countWrite(kNikonCharGeo), geoBefore);

    await session.tick(); // 闸内:TIME 也不写
    expect(host.countWrite(kNikonCharTime), timeBefore);

    now = now.add(const Duration(seconds: 3));
    session.onFix(fixAt(35.5));
    await pump();
    expect(host.countWrite(kNikonCharGeo), geoBefore + 1);
    await session.tick();
    expect(host.countWrite(kNikonCharTime), timeBefore + 1);
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

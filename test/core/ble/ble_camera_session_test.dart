import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/ble_camera_session.dart';
import 'package:z_pill/core/ble/blowfish_hasher.dart';
import 'package:z_pill/core/ble/gatt_uuids.dart';
import 'package:z_pill/core/ble/geo_payload.dart';
import 'package:z_pill/core/ble/pairing_engine.dart';
import 'package:z_pill/core/ble/pairing_message.dart';
import 'package:z_pill/l10n/message.dart';
import 'package:z_pill/core/log/app_log.dart';
import 'package:z_pill/platform/ble_scanner.dart';

import 'wifi_credentials_test.dart' show craftBlob;

/// BleHost 假体:写序记录 + 事件注入 + 可编程失败。
final class FakeBleHost implements BleHost {
  final eventCtrl = StreamController<BleEvent>.broadcast();
  final writes = <(String, Uint8List)>[];
  final notifies = <String>[];
  final reads = <String, Uint8List?>{};
  final readCalls = <String>[];
  Object? writeError;
  Object? readError;
  int connectFailures = 0; // 前 N 次 connectPaired 抛错(二段直连失败注错)
  final deviceIdScans = <int>[]; // scanForDeviceId 调用记录(让路断言)
  int? reconnectDeviceId;
  Uint8List? reconnectMfg;
  final connects = <String>[];
  List<BleDevice> scanResult = const [];

  /// scanForDeviceId 调用数(连接页 hero 测试断言「重连循环真发了扫」)。
  int scanIdCalls = 0;

  /// 扫描闸(可空):非空时 scanForDeviceId 挂起等放行 —— 取消沿落在
  /// 扫描窗内的竞态用例(预连接纪元闸)。
  Completer<void>? scanGate;

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
      scanResult;

  @override
  Future<void> stopScan() async {}

  @override
  Future<List<BleDevice>> scanForDeviceId(int deviceId,
      {Duration timeout = const Duration(seconds: 10)}) async {
    scanIdCalls++;
    final gate = scanGate;
    if (gate != null) {
      await gate.future;
    }
    deviceIdScans.add(deviceId);
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
    if (connectFailures > 0) {
      connectFailures--;
      throw Exception('连接失败');
    }
  }

  @override
  Future<void> setNotify(String characteristicUuid) async {
    notifies.add(characteristicUuid);
  }

  @override
  Future<Uint8List?> read(String characteristicUuid) async {
    readCalls.add(characteristicUuid);
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
    session.geoEnabled = true; // 测试模型:注入层在跑(生产由 _syncInjectLayer 投影)
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

  /// 解第 [index] 笔 GEO 写入的 UTC 时间字段
  /// (年@16 u16LE/月@18/日@19/时@20/分@21/秒@22,见 GeoPayload 布局)。
  (int, int, int, int, int, int) geoTimeOf(int index) {
    final data = host
        .writes
        .where((w) => w.$1 == kNikonCharGeo)
        .toList()[index]
        .$2;
    final bd = ByteData.sublistView(data);
    return (
      bd.getUint16(16, Endian.little),
      bd.getUint8(18),
      bd.getUint8(19),
      bd.getUint8(20),
      bd.getUint8(21),
      bd.getUint8(22),
    );
  }

  /// 驱动完整握手:连接 → stage1 → stage2 → stage4 → NOT1。
  /// [not1] 传 false 抑制尾部 NOT1(探针用例:注册信号由探针路自收,
  /// 粘性位不能提前置上)。
  Future<void> runHandshake(
      {bool resume = false,
      BleCameraSession? target,
      bool? gateStandby,
      bool not1 = true}) async {
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
    if (not1) {
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
    }
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
    expect(session.identity!.name, 'ZPill');
    final name = host.lastWrite(kNikonCharName);
    expect(name.length, 32);
    expect(String.fromCharCodes(name.take('ZPill'.length)), 'ZPill');
    expect(name.skip('ZPill'.length).every((b) => b == 0), isTrue);
  });

  test('lastError 变化沿 errors 流实时发(同值不发,清空发 null)', () async {
    final seen = <L10nMessage?>[];
    final sub = session.errors.listen(seen.add);
    session.lastError = (key: '旧错', args: null);
    session.lastError = (key: '旧错', args: null); // 同值去重,不重复上屏
    session.lastError = (key: '新错', args: null);
    await pump();
    session.lastError = null;
    await pump();
    await sub.cancel();
    expect(seen.map((m) => m?.key), ['旧错', '新错', null]);
  });

  test('ready 沿清陈旧错误(重连几轮失败后终成,错误行不残留)', () async {
    session.lastError = (key: '第 1 轮无命中', args: null);
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
        short.pair(device, waitTimeout: const Duration(milliseconds: 1)), throwsA(isA<BlePairingException>()));
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
        session.pair(device, waitTimeout: const Duration(milliseconds: 1)), throwsA(isA<BlePairingException>()));
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
        session.pair(device, waitTimeout: const Duration(milliseconds: 1)), throwsA(isA<BlePairingException>()));
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    host.emit(const BleDisconnected('P1'));
    await pump();
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
    await done;
    expect(session.state, BleSessionState.idle);
  });

  test('取消落在重连扫描窗内:命中也不入 pairing(十五轮预连接纪元闸)',
      () async {
    final zombieHost = FakeBleHost()
      ..reconnectDeviceId = 0x11223344
      ..scanGate = Completer<void>();
    final zombieSession = BleCameraSession(host: zombieHost);
    zombieSession.identity = BleIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223344,
        nonce: 0x70,
        serial: 'S',
        name: 'N');
    final attempt = zombieSession.retryReconnect(gateStandby: false);
    await pump();
    expect(zombieSession.state, BleSessionState.idle,
        reason: '尝试在扫描窗内等待');
    // 取消沿(纪元推进)→ 扫描才放行命中:不得再入 pairing —— 否则
    // 僵尸 pairing 把后续尝试全挡在 guard 外(「断开后怎么都连不上」)。
    await zombieSession.disconnect();
    zombieHost.scanGate!.complete();
    expect(await attempt, isFalse);
    await pump();
    expect(zombieSession.state, BleSessionState.idle,
        reason: '预连接沿纪元闸:取消后命中也不推进状态');
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

  test('flushDueWrites 单飞:并发进入不重发 TIME(十六轮 busy 防)', () async {
    await runHandshake();
    now = now.add(const Duration(seconds: 3)); // 过首写门
    // 驱动拍与首写自发沿并发的形状:两笔 withResponse 写同特征,后笔
    // 撞 iOS 原生「同特征已有写在途」busy(真机 TIME 写失败实证)。
    final t1 = session.tick();
    final t2 = session.tick();
    await t1;
    await t2;
    expect(host.countWrite(kNikonCharTime), 1,
        reason: '十六轮:并发 flush 单飞,丢一拍下一拍兜底');
  });

  test('保鲜与保活:30s 无成功注入重发 GEO;TIME 45s 档到点写', () async {
    await runHandshake();
    session.onFix(fixAt(35.5));
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // 首笔回补 GEO + TIME
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(host.countWrite(kNikonCharTime), 1);
    expect(geoTimeOf(0), (2026, 10, 13, 8, 0, 0)); // 原点时间

    now = now.add(const Duration(seconds: 20));
    await session.tick(); // 20s:GEO 未到 30s、TIME 未到 45s → 静默
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(host.countWrite(kNikonCharTime), 1);

    now = now.add(const Duration(seconds: 12)); // 累计 32s
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 2); // GEO 保鲜重发
    expect(geoTimeOf(1), (2026, 10, 13, 8, 0, 35)); // 时间刷新到当前
    expect(host.countWrite(kNikonCharTime), 1); // 32s < 45s 仍未到点

    now = now.add(const Duration(seconds: 14)); // 距上次 TIME 46s
    await session.tick();
    expect(host.countWrite(kNikonCharTime), 2); // 45s 档到点
    expect(host.countWrite(kNikonCharGeo), 2); // 距保鲜成功 14s → 不重发
  });

  test('geoEnabled=false:关断后 onFix/tick 零 GEO(保鲜回补全停),TIME 心跳照常', () async {
    await runHandshake();
    session.geoEnabled = false; // 注入层关(设置开关沿投影)
    session.onFix(fixAt(35.5));
    now = now.add(const Duration(seconds: 3));
    await session.tick(); // TIME 到点写;GEO 全闸
    expect(host.countWrite(kNikonCharGeo), 0);
    expect(host.countWrite(kNikonCharTime), 1);
    now = now.add(const Duration(seconds: 45));
    await session.tick(); // 保鲜窗早过,关断期仍零 GEO
    expect(host.countWrite(kNikonCharGeo), 0);
    // 重新打开:下一个 fix 恢复发送
    session.geoEnabled = true;
    session.onFix(fixAt(35.5));
    expect(host.countWrite(kNikonCharGeo), 1);
  });

  test('重连 ready 沿即时一笔 GEO:缓存点刷当前时刻(SnapBridge 对齐)', () async {
    await runHandshake();
    session.onFix(fixAt(35.5)); // 闸内缓存
    now = now.add(const Duration(seconds: 3)); // 过首写门
    await session.tick(); // 首拍:回补 GEO + TIME
    expect(host.countWrite(kNikonCharGeo), 1);
    expect(host.countWrite(kNikonCharTime), 1);

    host.emit(const BleDisconnected('P1'));
    await pump();
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
    host.reconnectDeviceId = session.identity!.deviceId;
    now = now.add(const Duration(seconds: 1));
    await runHandshake(resume: true); // 重连 ready(一次性补发待办置上)
    now = now.add(const Duration(seconds: 3)); // 过首写门(重连新账)
    await session.tick();
    expect(host.countWrite(kNikonCharGeo), 2); // 即时一笔(无新点,缓存补)
    expect(geoTimeOf(1), (2026, 10, 13, 8, 0, 7)); // 时间=重连后当前时刻
    // 重连重置 TIME 锚(ready 沿 _lastTimeOkAt=null)→ 首拍即校时
    // (SnapBridge 每连必校时同款)。
    expect(host.countWrite(kNikonCharTime), 2);
  });

  test('握手失败退避归零:相机踢链=它醒着,下一拍 2s 快试(不背爬高旧账)', () async {
    await runHandshake();
    final saved = session.identity!;
    host.emit(const BleDisconnected('P1'));
    await pump();
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
    host.reconnectDeviceId = null; // 爬高:三轮无命中
    for (var i = 0; i < 3; i++) {
      await session.retryReconnect();
    }
    expect(session.nextRetryDelay, const Duration(seconds: 8));
    // 踢链:扫到并连上,stage1 写入即被掐(连上即踢)
    host.reconnectDeviceId = saved.deviceId;
    host.writeError = Exception('连接已断开');
    final fut = session.retryReconnect();
    await pump();
    expect(session.state, BleSessionState.pairing);
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump(); // stage1 写 → 抛 → handshakeStartFail → 归零 + idle
    expect(await fut, isFalse);
    expect(session.state, BleSessionState.reconnecting); // 重连循环不塌回
    expect(session.nextRetryDelay, const Duration(seconds: 2)); // 0+1 档快试
    host.writeError = null;
  });

  test('断链类写失败不上红字:静默缓存;非断链失败照常上报', () async {
    await runHandshake();
    now = now.add(const Duration(seconds: 3)); // 过首写门
    host.writeError = PlatformException(
        code: 'disconnected', message: '连接已断开');    session.onFix(fixAt(35.5)); // 直发 → 断链失败:静默
    expect(session.lastError, isNull);
    // 非断链失败(GPS 会话拒收类):红字照报
    host.writeError = Exception('GPS 会话未醒');
    now = now.add(const Duration(seconds: 3)); // 过失败闸(2.5s)
    session.onFix(fixAt(35.50001));
    await pump(); // 直发是 unawaited 异步:让写失败落地再断言
    expect(session.lastError?.key, 'ble.geoWriteFail');
    host.writeError = null;
  });

  test('断链首轮直连优先:静默态不空转扫描,直连失败才落回扫描', () async {
    await runHandshake();
    host.emit(const BleDisconnected('P1'));
    await pump();
    session.directFirstPending = false; // (replace_all 注入的扫描路径复位)
    // 本用例专属:重新武装直连优先 —— 静默态不空转扫描,直连先发
    session.directFirstPending = true;
    host.reconnectDeviceId = null; // 扫描必空(静默态)
    final fut = session.retryReconnect();
    await pump();
    expect(host.connects.length, 2); // 配对握手 1 + 直连 1(先发)
    expect(host.connects.last, 'P1');
    expect(host.scanIdCalls, 0); // 扫描未跑
    // 直连挂上但 stage1 被踢 → 直连失败 → 落回扫描
    host.writeError = Exception('连接已断开');
    host.emit(const BleConnected(
        uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
    await pump();
    host.writeError = null;
    expect(await fut, isFalse);
    expect(host.scanIdCalls, 1); // 落回扫描(静默态空扫一轮)
  });

  test('ready 断连 → reconnecting;重连复用身份(deviceId/nonce 不变)', () async {
    await runHandshake();
    final saved = session.identity!;
    host.emit(const BleDisconnected('P1'));
    await pump();
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    session.directFirstPending = false; // 扫描路径用例:直连优先不适用
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
    expect(session.lastError?.key, 'ble.timeWriteFail');
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
      expect(session.lastError?.key, 'ble.notConnectedReadCred');

      await runHandshake();
      host.reads[kNikonCharConfig] = Uint8List(0);
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError?.key, 'ble.noCredBroadcast');

      host.reads[kNikonCharConfig] =
          Uint8List.fromList(List<int>.generate(96, (i) => (i * 7 + 3) & 0xFF));
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError?.key, 'ble.credLengthAbnormal');

      host.reads[kNikonCharConfig] =
          Uint8List.fromList(List<int>.generate(97, (i) => (i * 7 + 3) & 0xFF));
      final errBefore = session.lastError;
      expect(await session.readWifiCredentials(), isNull);
      // 十七轮:解密未中不上 lastError(错误位让位「去系统连 Wi-Fi」
      // 红字提醒),改写 AppLog ble 域。
      expect(session.lastError, errBefore);
      expect(
          AppLog.entries
              .where((e) => e.domain == AppLog.ble)
              .map((e) => e.message),
          contains(contains('解密未中')));
    });

    test('读失败(特征不在/断链)→ null 带原因', () async {
      await runHandshake();
      host.readError = Exception('GATT 读失败');
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError?.key, 'ble.readCredFail');
    });
  });

  group('iOS 首配 bond 探针(v8b/v9:leg-1 收口 → 全访问面扫 → 断链二段直连)', () {
    test('收口校时即刻发(绕写闸);读 0x2008 清位应答 00 01→00 00;0x2005=0x02',
        () async {
      await runHandshake(not1: false);
      host.reads[kNikonCharNot1] = Uint8List.fromList([0x00, 0x01]); // Conn ON
      host.connectFailures = 1; // 二段直连失败 → 重扫无果,快速收尾
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(host.countWrite(kNikonCharTime), 1); // 收口校时(闸内即刻)
      expect(host.readCalls, contains(kNikonCharNot1));
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]); // 清位应答
      expect(host.countWrite(kNikonCharWifi), 1); // v6:btEstablishment
      expect(host.lastWrite(kNikonCharWifi), [0x02]);
      expect(await fut, isFalse); // 直连未成 + 扫描无果(scanResult 空)
      expect(host.connects, ['P1', 'P1']); // 配对 + 二段直连尝试(同 uuid)
      expect(session.state, BleSessionState.reconnecting);
    });

    test('读 null 照发清位应答 00 00', () async {
      await runHandshake(not1: false);
      host.connectFailures = 1;
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]);
      expect(await fut, isFalse);
    });

    test('二段全通:断链 → 直连(同 uuid)→ 复用握手(device/nonce)→ NOT1 → true、ready、补答校时',
        () async {
      await runHandshake(not1: false);
      final id = session.identity!;
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(host.connects, ['P1', 'P1']); // 断一连二(直连同 uuid)
      expect(session.state, BleSessionState.pairing);
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await pump();
      final stage1b = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      expect(stage1b.device, id.deviceId); // 复用握手
      expect(stage1b.nonce, id.nonce);
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1b).encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pump();
      expect(session.state, BleSessionState.ready);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
      expect(session.state, BleSessionState.ready); // 链路保持
      await pump();
      expect(host.countWrite(kNikonCharTime), 2); // 收口校时 + 成功沿补答
    });

    test('二段直连未成(旧 uuid 失效)→ 重扫兜底命中新广播 → NOT1 → true', () async {
      await runHandshake(not1: false);
      final id = session.identity!;
      host.connectFailures = 1; // 直连打给已旋转地址:连接失败
      host.scanResult = [
        const BleDevice(name: 'Z f_2', uuid: 'P2', rssi: -50)
      ];
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(host.connects, ['P1', 'P1', 'P2']); // 配对 + 直连尝试(败) + 重扫命中
      expect(session.state, BleSessionState.pairing);
      host.emit(const BleConnected(
          uuid: 'P2', characteristics: {}, writeWithoutResponseMtu: 20));
      await pump();
      final stage1b = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      expect(stage1b.device, id.deviceId); // 复用握手(device/nonce 与地址无关)
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1b).encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pump();
      expect(session.state, BleSessionState.ready);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
    });

    test('安顿窗内 NOT1 到 → 免二段原链收口', () async {
      await runHandshake(not1: false);
      final fut = session.runIosBondProbe(
          settle: const Duration(milliseconds: 30),
          window: const Duration(seconds: 5));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
      expect(host.connects, ['P1']); // 未二连
      expect(session.state, BleSessionState.ready);
      await pump();
      expect(host.countWrite(kNikonCharTime), 2); // 收口 + 补答
    });

    test('窗内静默(onFix/tick 零写),窗满 false 且会话主动断链(fail+ready)',
        () async {
      await runHandshake(not1: false);
      session.onFix(fixAt(35.5)); // 首写门内:缓存
      await pump();
      expect(host.countWrite(kNikonCharGeo), 0);
      final fut = session.runIosBondProbe(
          settle: Duration.zero,
          leg2Grace: Duration.zero,
          window: const Duration(milliseconds: 60));
      await pump();
      // 驱动二段直连握手到 ready(不发 NOT1 → 进等注册窗)
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await pump();
      final stage1b = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1b).encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pump();
      session.onFix(fixAt(35.6)); // 等注册窗:旗标缓存
      now = now.add(const Duration(seconds: 3));
      await session.tick();
      expect(host.countWrite(kNikonCharGeo), 0); // 静默整闸
      expect(host.countWrite(kNikonCharTime), 1); // TIME 不重复
      expect(await fut, isFalse); // 窗满
      // fail+ready:未注册链路保持无意义,会话主动断链(「去系统蓝牙」
      // 按钮只在非 ready 可见)。
      expect(session.state, BleSessionState.idle);
      now = now.add(const Duration(seconds: 3));
      await session.tick();
      expect(host.countWrite(kNikonCharGeo), 0); // 断链后零写(缓存待下链)
      expect(host.countWrite(kNikonCharTime), 1);
    });

    test('二段直连握手中断链 → 转重扫兜底(无广播)→ false、落 reconnecting',
        () async {
      await runHandshake(not1: false);
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(host.connects, ['P1', 'P1']); // 直连尝试(同 uuid)
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await pump();
      host.emit(const BleDisconnected('P1')); // 二段握手期断
      await pump();
      expect(await fut, isFalse); // 直连败 + 重扫无果
      expect(session.state, BleSessionState.reconnecting);
    });

    test('0x2008 请求位清位应答常轨:Time/Loc/Conn 各自清位(2026-10-21 SnapBridge 对齐)',
        () async {
      await runHandshake(not1: false);
      // Time 请求(`01 00`)→ 应答 `00 00`(清 Time 位)
      var before = host.countWrite(kNikonCharNot1);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      await pump();
      expect(host.countWrite(kNikonCharNot1), before + 1);
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]);
      // Loc 请求(`10 00`)→ 应答 `00 00`(清 Loc 位;重配对清 GPS 后
      // 位置会话重开的候选钥匙)
      before = host.countWrite(kNikonCharNot1);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x10, 0x00])));
      await pump();
      expect(host.countWrite(kNikonCharNot1), before + 1);
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]);
      // Conn 请求(`00 01`)→ 应答 `00 00`(清 Conn 位,v5 实证语义)
      before = host.countWrite(kNikonCharNot1);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x00, 0x01])));
      await pump();
      expect(host.countWrite(kNikonCharNot1), before + 1);
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]);
      // 组合请求(Time+Loc)→ 一次应答双清
      before = host.countWrite(kNikonCharNot1);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x11, 0x00])));
      await pump();
      expect(host.countWrite(kNikonCharNot1), before + 1);
      expect(host.lastWrite(kNikonCharNot1), [0x00, 0x00]);
      // 零请求位 → 不应答
      before = host.countWrite(kNikonCharNot1);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x00, 0x00])));
      await pump();
      expect(host.countWrite(kNikonCharNot1), before);
    });

    test('探针期三方让路:retryReconnect/reconnectDirect/reconnectScan 零扫描零连接',
        () async {
      await runHandshake(not1: false);
      // 有可命中广播也该让路(真机实证:面板重挂自动重连的扫描会掐死
      // 探针二段 —— iOS 原生扫描单槽,新扫描起即收旧扫描)。
      host.reconnectDeviceId = session.identity!.deviceId;
      final fut = session.runIosBondProbe(
          settle: const Duration(milliseconds: 60),
          window: const Duration(seconds: 5));
      await pump();
      expect(session.bondProbeActive, isTrue);
      expect(await session.retryReconnect(), isFalse); // 注入驱动路
      expect(await session.reconnectDirect(), isFalse); // 面板重连路
      expect(await session.reconnectScan(), isFalse);
      expect(host.deviceIdScans, isEmpty); // retryReconnect 未起扫
      expect(host.connects, ['P1']); // 零二连尝试
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
    });

    test('非 ready 门禁与重入闸立即 false', () async {
      expect(await session.runIosBondProbe(), isFalse); // idle 门禁
      await runHandshake(not1: false);
      final fut = session.runIosBondProbe(
          settle: Duration.zero,
          leg2Grace: Duration.zero,
          window: const Duration(seconds: 5));
      await pump();
      expect(await session.runIosBondProbe(), isFalse); // 重入闸(旗标挂窗)
      // 二段直连走完收尾
      host.emit(const BleConnected(
          uuid: 'P1', characteristics: {}, writeWithoutResponseMtu: 20));
      await pump();
      final stage1b = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1b).encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
    });

    test('探针期 wakeCameraWifi/readWifiCredentials 带因拒绝', () async {
      await runHandshake(not1: false);
      final fut = session.runIosBondProbe(
          settle: const Duration(milliseconds: 30),
          window: const Duration(seconds: 5));
      await pump();
      expect(await session.wakeCameraWifi(), isFalse);
      expect(session.lastError?.key, 'ble.probeGateOp');
      expect(await session.readWifiCredentials(), isNull);
      expect(session.lastError?.key, 'ble.probeGateReadCred');
      expect(host.countWrite(kNikonCharWifi), 1); // 仅探针自写 0x02,wake 被拒未加写
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      expect(await fut, isTrue);
    });

    test('waitRegistration:NOT1 先到未挂 → 粘性记忆,后挂即刻 true', () async {
      await runHandshake(not1: false);
      host.emit(BleNotified(
          uuid: kNikonCharNot1, data: Uint8List.fromList([0x01, 0x00])));
      await pump();
      expect(
          await session.waitRegistration(
              window: const Duration(milliseconds: 50)),
          isTrue);
    });

    test('v9 面扫:非协议特征逐个 读→写(零长)→订阅;协议特征不碰', () async {
      const c2083 = '00002083-3dd4-4255-8d62-6dc7b9bd5561';
      const c2084 = '00002084-3dd4-4255-8d62-6dc7b9bd5561';
      const c2087 = '00002087-3dd4-4255-8d62-6dc7b9bd5561';
      final done = expectLater(session.pair(device), completes);
      host.emit(const BleConnected(
          uuid: 'P1',
          characteristics: {
            kNikonCharPairing: 'read|write|indicate',
            kNikonCharWifi: 'read|write',
            kNikonCharNot1: 'read|write|notify',
            c2083: 'write',
            c2084: 'read|indicate',
            c2087: 'read|write|indicate',
            kNikonCharServerName: 'read',
          },
          writeWithoutResponseMtu: 20));
      await pump();
      final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
      await pump();
      host.emit(BleNotified(
          uuid: kNikonCharPairing, data: buildStage4().encode()));
      await pump();
      await done;
      host.connectFailures = 1; // 二段直连失败 → 重扫无果,快速收尾
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      await pump();
      expect(
          host.writes.any((w) => w.$1 == c2083 && w.$2.isEmpty), isTrue);
      expect(
          host.writes.any((w) => w.$1 == c2087 && w.$2.isEmpty), isTrue);
      expect(host.notifies, containsAll([c2084, c2087]));
      // 协议特征不被面扫碰:0x2005 仅探针自写 1 次(0x02),0x2000 仅握手。
      expect(host.countWrite(kNikonCharWifi), 1);
      expect(host.lastWrite(kNikonCharWifi), [0x02]);
      expect(await fut, isFalse); // 扫描无果收尾
    });

    test('面扫访问失败不炸探针(写错误照落,流程走完)', () async {
      await runHandshake(not1: false);
      host.writeError = Exception('Insufficient Authentication');
      host.connectFailures = 1; // 二段直连失败 → 重扫无果,快速收尾
      final fut = session.runIosBondProbe(
          settle: Duration.zero, leg2Grace: Duration.zero);
      await pump();
      expect(await fut, isFalse);
      expect(session.state, BleSessionState.reconnecting);
      expect(session.lastError, isNotNull);
    });
  });

  test('v7 全表扫描读:权限含 read 的特征全读,0x2000/0x2008/write-only 除外',
      () async {
    final done = expectLater(session.pair(device, waitTimeout: const Duration(milliseconds: 1)), completes);
    host.emit(const BleConnected(
        uuid: 'P1',
        characteristics: {
          kNikonCharPairing: 'read|write|indicate',
          kNikonCharConfig: 'read|write',
          kNikonCharNot1: 'read|write|notify',
          kNikonCharWifi: 'read|write',
          kNikonCharServerName: 'read',
          // iOS SIG 采纳 UUID 是 4 字符短串(CBUUID.uuidString):
          // 短串不能截 4-8(2026-10-19 真机 RangeError 实证)。
          '2a00': 'read|write',
        },
        writeWithoutResponseMtu: 20));
    await pump();
    await pump(); // intro 读在途,再排一轮
    final stage1 = PairingMessage.decode(host.lastWrite(kNikonCharPairing));
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage2(stage1).encode()));
    await pump();
    host.emit(BleNotified(
        uuid: kNikonCharPairing, data: buildStage4().encode()));
    await pump();
    await done;
    await pump();
    expect(
        host.readCalls,
        containsAll(
            [kNikonCharConfig, kNikonCharWifi, kNikonCharServerName, '2a00']));
    expect(host.readCalls, isNot(contains(kNikonCharPairing)));
    expect(host.readCalls, isNot(contains(kNikonCharNot1)));
  });
}

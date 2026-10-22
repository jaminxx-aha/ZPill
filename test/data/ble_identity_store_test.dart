import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/data/ble_identity_store.dart';

void main() {
  late Directory dir;
  late BleIdentityStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('np_ble_identity');
    addTearDown(() => dir.delete(recursive: true));
    store = BleIdentityStore(dataDir: () async => dir.path);
  });

  test('空档 load 返回 null', () async {
    expect(await store.load(), isNull);
  });

  test('save → load 往返(全字段)', () async {
    final id = BlePairedIdentity(
      peripheralUuid: 'P1-UUID',
      deviceId: 0x8014411,
      nonce: 0x1234ABCD,
      serial: '1641397',
      controllerName: 'ZPill',
      cameraName: 'Z f_8014411',
      pairedAt: DateTime.utc(2026, 10, 13, 8, 0, 0),
    );
    await store.save(id);
    final back = await store.load();
    expect(back, isNotNull);
    expect(back!.peripheralUuid, 'P1-UUID');
    expect(back.deviceId, 0x8014411);
    expect(back.nonce, 0x1234ABCD);
    expect(back.serial, '1641397');
    expect(back.controllerName, 'ZPill');
    expect(back.cameraName, 'Z f_8014411');
    expect(back.displayName, 'Z f_8014411');
    expect(back.pairedAt, DateTime.utc(2026, 10, 13, 8, 0, 0));
  });

  test('损坏 JSON → load 返回 null(按未配对)', () async {
    await File('${dir.path}/ble_identity.json')
        .writeAsString('{broken json');
    expect(await store.load(), isNull);
  });

  test('旧档缺 serial/name/cameraName → 空串/默认名回落', () async {
    await File('${dir.path}/ble_identity.json').writeAsString('''
{"peripheralUuid": "P2", "deviceId": 7, "nonce": 9, "pairedAt": "2026-10-13T08:00:00.000Z"}''');
    final back = await store.load();
    expect(back!.serial, isEmpty);
    expect(back.controllerName, 'ZPill');
    expect(back.cameraName, isEmpty);
    expect(back.displayName, 'ZPill',
        reason: '旧档无相机名 → 展示名回落控制器名');
  });

  test('clear 后 load 返回 null', () async {
    await store.save(BlePairedIdentity(
      peripheralUuid: 'P1',
      deviceId: 1,
      nonce: 2,
      serial: 'S',
      controllerName: 'N',
      pairedAt: DateTime.now(),
    ));
    await store.clear();
    expect(await store.load(), isNull);
  });
}

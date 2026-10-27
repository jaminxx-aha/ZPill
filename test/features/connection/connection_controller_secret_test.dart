import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/data/ble_identity_store.dart';
import 'package:z_pill/features/connection/connection_controller.dart';

void main() {
  late Directory dir;
  late BleIdentityStore store;
  late ConnectionController controller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('np_ble_secret');
    store = BleIdentityStore(dataDir: () async => dir.path);
    controller = ConnectionController(bleIdentityStore: store);
    addTearDown(() async {
      controller.dispose();
      await dir.delete(recursive: true);
    });
  });

  test('旧档案密码不载入会话，当前会话密码不回写磁盘', () async {
    const legacyPassword = 'legacy-secret';
    final file = File('${dir.path}/ble_identity.json');
    await file.writeAsString(jsonEncode({
      'peripheralUuid': 'P1',
      'deviceId': 0x8014411,
      'nonce': 0x1234ABCD,
      'serial': '1641397',
      'controllerName': 'ZPill',
      'cameraName': 'Z f_8014411',
      'wifiPassword': legacyPassword,
      'pairedAt': '2026-10-13T08:00:00.000Z',
    }));

    await controller.loadBleIdentity();
    expect(controller.bleIdentity?.deviceId, 0x8014411);
    expect(controller.sessionWifiPassword, isEmpty);

    const currentPassword = 'session-only-secret';
    await controller.saveWifiPassword(currentPassword);
    expect(controller.sessionWifiPassword, currentPassword);
    final persisted = await file.readAsString();
    expect(persisted, isNot(contains(legacyPassword)));
    expect(persisted, isNot(contains(currentPassword)));
    expect(persisted, isNot(contains('wifiPassword')));
  });
}

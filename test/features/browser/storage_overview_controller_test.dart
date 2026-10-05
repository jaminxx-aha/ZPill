import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/browser/storage_overview_controller.dart';

import '../../core/ptp/ptp_session_test.dart' show FakePtpTransport;

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  String? get error => null;

  @override
  String? get deviceName => null;

  @override
  bool get isWireless => false;

  @override
  Future<void> connect({String? instanceName, String? ip}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  String? get pairingCode => null;

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}
}

Uint8List _idsDataset(List<int> ids) {
  final w = ByteWriter()..u32(ids.length);
  for (final id in ids) {
    w.u32(id);
  }
  return w.takeBytes();
}

Uint8List _infoDataset({String description = 'Slot 1'}) {
  final w = ByteWriter()
    ..u16(0x0004)
    ..u16(0x0002)
    ..u16(0x0000)
    ..u64(64000000000)
    ..u64(21000000000)
    ..u32(480)
    ..u8(description.length + 1)
    ..utf16le(description)
    ..u16(0)
    ..u8(1)
    ..u16(0);
  return w.takeBytes();
}

PtpResult _ok(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

void main() {
  test('connected 触发拉取:双槽 ID+Info 齐上,槽序按 ID 升序', () async {
    final fake = FakePtpTransport()
      ..reply(_ok(_idsDataset([0x00020001, 0x00010001]))) // 故意倒序
      ..reply(_ok(_infoDataset(description: 'Slot 1')))
      ..reply(_ok(_infoDataset(description: 'Slot 2')));
    final conn = _FakeConnection();
    final controller = StorageOverviewController(
        session: PtpSession(transport: fake), connection: conn);
    addTearDown(controller.dispose);
    addTearDown(conn.statesCtrl.close);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.storages.map((s) => s.description), ['Slot 1', 'Slot 2']);
    // 首个请求 GetStorageIDs,其余逐槽 GetStorageInfo(按 ID 升序)。
    expect(fake.requests.length, 3);
    expect(fake.requests.first.opcode, PtpOperationCode.getStorageIds);
    expect(fake.requests[1].opcode, PtpOperationCode.getStorageInfo);
    expect(fake.requests[1].params.single, 0x00010001);
    expect(fake.requests[2].params.single, 0x00020001);
  });

  test('单槽拒答(卡未插)跳过,其余槽照常展示', () async {
    final fake = FakePtpTransport()
      ..reply(_ok(_idsDataset([0x00010001, 0x00020001])))
      ..reply(const PtpResult(responseCode: 0x2009)) // Slot 1 拒答
      ..reply(_ok(_infoDataset(description: 'Slot 2')));
    final conn = _FakeConnection();
    final controller = StorageOverviewController(
        session: PtpSession(transport: fake), connection: conn);
    addTearDown(controller.dispose);
    addTearDown(conn.statesCtrl.close);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.storages, hasLength(1));
    expect(controller.storages.single.description, 'Slot 2');
  });

  test('断连清空面板', () async {
    final fake = FakePtpTransport()
      ..reply(_ok(_idsDataset([0x00010001])))
      ..reply(_ok(_infoDataset()));
    final conn = _FakeConnection();
    final controller = StorageOverviewController(
        session: PtpSession(transport: fake), connection: conn);
    addTearDown(controller.dispose);
    addTearDown(conn.statesCtrl.close);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.storages, isNotEmpty);

    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    expect(controller.storages, isEmpty);
  });
}

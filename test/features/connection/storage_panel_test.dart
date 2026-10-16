import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/storage_info.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/features/browser/storage_overview_controller.dart';
import 'package:nikon_pill/features/connection/connection_status_card.dart';

import '../../core/ptp/ptp_session_test.dart' show FakePtpTransport;

final class _StubConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  CameraLinkState state = CameraLinkState.disconnected;

  @override
  String? get error => null;

  @override
  String? get deviceName => null;

  @override
  String? get deviceModel => null;

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

CameraStorage _card({required int id, required int freeImages}) =>
    CameraStorage(
      id: id,
      storageType: 0x0004,
      filesystemType: 0x0002,
      accessCapability: 0x0000,
      maxCapacityBytes: 64 << 30,
      freeSpaceBytes: 32 << 30,
      freeSpaceImages: freeImages,
    );

/// 桩控制器:字段直填后首泵上屏(ListenableBuilder 首建读现值),
/// 不走 PTP。
StorageOverviewController _stub({
  required List<CameraStorage> storages,
  int? activeSlot,
}) {
  final controller = StorageOverviewController(
    session: PtpSession(transport: FakePtpTransport()),
    connection: _StubConnection(),
  );
  controller
    ..storages = storages
    ..activeSlot = activeSlot;
  return controller;
}

void main() {
  testWidgets('描述/卷标全空走插槽名兜底;记录槽 1 徽标落首行;卡尾可拍张数',
      (tester) async {
    final controller = _stub(
      storages: [_card(id: 0x00010001, freeImages: 1683)],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StoragePanel(overview: controller)),
    ));

    expect(find.text('插槽 1'), findsOneWidget);
    expect(find.text('写入中'), findsOneWidget);
    expect(find.text('可拍 1683'), findsOneWidget);
    // 容量行照旧。
    expect(find.textContaining('可用'), findsOneWidget);
  });

  testWidgets('双槽记录(0xD1F2=3)两行都标写入中;张数全 0 不显示', (tester) async {
    final controller = _stub(
      storages: [
        _card(id: 0x00010001, freeImages: 0),
        _card(id: 0x00020001, freeImages: 0),
      ],
      activeSlot: 3,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StoragePanel(overview: controller)),
    ));

    expect(find.text('插槽 1'), findsOneWidget);
    expect(find.text('插槽 2'), findsOneWidget);
    expect(find.text('写入中'), findsNWidgets(2));
    expect(find.textContaining('可拍'), findsNothing);
  });

  testWidgets('记录槽指向未展示槽不误标;相机有描述优先用描述', (tester) async {
    final controller = StorageOverviewController(
      session: PtpSession(transport: FakePtpTransport()),
      connection: _StubConnection(),
    );
    addTearDown(controller.dispose);
    controller
      ..storages = [
        CameraStorage(
          id: 0x00010001,
          storageType: 0x0004,
          filesystemType: 0x0002,
          accessCapability: 0x0000,
          maxCapacityBytes: 64 << 30,
          freeSpaceBytes: 32 << 30,
          freeSpaceImages: 0,
          description: 'Slot 2',
        ),
      ]
      ..activeSlot = 2; // 写的是 2 号槽,面板只显示 1 行(1 号位)→ 不误标

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StoragePanel(overview: controller)),
    ));

    expect(find.text('Slot 2'), findsOneWidget);
    expect(find.text('写入中'), findsNothing);
  });
}

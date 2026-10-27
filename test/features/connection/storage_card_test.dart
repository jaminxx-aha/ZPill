import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/browser/storage_info.dart';
import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/features/browser/storage_overview_controller.dart';
import 'package:z_pill/features/connection/connected_overview.dart';
import 'package:z_pill/features/remote/remote_controller.dart';
import 'package:z_pill/l10n/message.dart';

import '../../core/ptp/ptp_session_harness.dart' show FakePtpTransport;

final class _StubConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  CameraLinkState state = CameraLinkState.disconnected;

  @override
  L10nMessage? get error => null;

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

CameraStorage _card({
  required int id,
  required int freeImages,
  int freeBytes = 32 << 30,
  int totalBytes = 64 << 30,
  String? description,
}) =>
    CameraStorage(
      id: id,
      storageType: 0x0004,
      filesystemType: 0x0002,
      accessCapability: 0x0000,
      maxCapacityBytes: totalBytes,
      freeSpaceBytes: freeBytes,
      freeSpaceImages: freeImages,
      description: description,
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

Future<void> _pumpCard(WidgetTester tester, StorageCard card) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: card),
  ));
}

void main() {
  testWidgets('插槽名兜底;记录槽绿点;用量串 已用/总量GB;胶囊条+可拍脚注',
      (tester) async {
    final controller = _stub(
      storages: [_card(id: 0x00010001, freeImages: 1683)],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('插槽 1'), findsOneWidget,
        reason: '描述/卷标全空走插槽名兜底');
    expect(find.byKey(const Key('storageRecordingDot')), findsOneWidget,
        reason: '记录槽 0xD1F2=1 命中本行亮绿点(徽标字退役)');
    expect(find.text('32/64GB'), findsOneWidget,
        reason: '用量串 = 已用/总量,GB 只缀总量后(定稿口径)');
    expect(find.text('50%'), findsOneWidget,
        reason: '百分比居中条内 = 已用 %(50%;条填充画剩余量)');
    expect(find.text('可拍 1683'), findsOneWidget, reason: '卡底附带脚注');
    final barRect = tester.getRect(find.byKey(const Key('storageUsageBar')));
    expect(barRect.height, 5);
    expect(barRect.width, greaterThan(300),
        reason: '条满宽(Stack 按文字宽收缩、Positioned.fill 跟塌的回归闸)');
    final fillRect =
        tester.getRect(find.byKey(const Key('storageBarFill')));
    expect(fillRect.height, 5,
        reason: '填充满高(ColoredBox 无 child 塌 0 的回归闸)');
    final fill = tester.widget<ColoredBox>(
        find.byKey(const Key('storageBarFill')));
    expect(fill.color, isNot(scheme(tester).error), reason: '剩余 50% 未过警戒线');
  });

  testWidgets('视频档脚注换可录时长(@816 同口径);时长无效宁缺不错',
      (tester) async {
    final controller = _stub(
      storages: [_card(id: 0x00010001, freeImages: 1683)],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    // 有效时长:h:mm:ss / m:ss 同拍摄页胶囊格式。
    await _pumpCard(tester, StorageCard(
      overview: controller,
      mode: CaptureMode.video,
      videoRemainingMs: 750000, // 12:30
    ));
    expect(find.text('可录 12:30'), findsOneWidget);
    expect(find.textContaining('可拍'), findsNothing,
        reason: '视频档张数被录像估算污染,不回退');

    // 时长无效(头没带/本帧无效):「可录 --」占位,污染张数不回退。
    await _pumpCard(tester, StorageCard(
      overview: controller,
      mode: CaptureMode.video,
      videoRemainingMs: 0,
    ));
    expect(find.text('可录 --'), findsOneWidget);
    expect(find.textContaining('可拍'), findsNothing);

    // 模式未读(null):同换档沿 —— 旧档张数作废,新鲜读到达才放行。
    await _pumpCard(tester, StorageCard(overview: controller));
    final placeholder = tester.widget<Opacity>(find.ancestor(
        of: find.textContaining('可拍'), matching: find.byType(Opacity)).first);
    expect(placeholder.opacity, 0,
        reason: 'video→null 也是换档沿:占位全透明,污染口径不显');
    controller.storages = [_card(id: 0x00010001, freeImages: 1683)];
    await _pumpCard(tester, StorageCard(overview: controller));
    expect(find.text('可拍 1683'), findsOneWidget);
  });

  testWidgets('换档沿旧档张数作废:切回照片不闪污染值,新鲜读才放行',
      (tester) async {
    // 视频档期 0x9209 镜像张数被机身录像估算污染成 4197(真机实证)。
    final controller = _stub(
      storages: [_card(id: 0x00010001, freeImages: 4197)],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(
      overview: controller,
      mode: CaptureMode.video,
      videoRemainingMs: 750000,
    ));
    expect(find.text('可录 12:30'), findsOneWidget);

    // 切回照片档(存储列表还是视频档污染值):不闪「可拍 4197」——
    // 同款文本全透明占位(行高不塌),污染值不显。
    await _pumpCard(tester, StorageCard(
      overview: controller,
      mode: CaptureMode.photo,
    ));
    final stale = tester.widget<Opacity>(find.ancestor(
        of: find.text('可拍 4197'), matching: find.byType(Opacity)));
    expect(stale.opacity, 0, reason: '换档沿作废旧档口径(拍摄页同款),占位不塌行高');
    expect(find.text('可录 12:30'), findsNothing);

    // 新鲜读到达(新列表对象):放行真值。
    controller.storages = [_card(id: 0x00010001, freeImages: 1683)];
    await _pumpCard(tester, StorageCard(
      overview: controller,
      mode: CaptureMode.photo,
    ));
    expect(find.text('可拍 1683'), findsOneWidget);
  });

  testWidgets('双槽记录(0xD1F2=3)两行都亮绿点;张数全 0 脚注不显示',
      (tester) async {
    final controller = _stub(
      storages: [
        _card(id: 0x00010001, freeImages: 0),
        _card(id: 0x00020001, freeImages: 0),
      ],
      activeSlot: 3,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('插槽 1'), findsOneWidget);
    expect(find.text('插槽 2'), findsOneWidget);
    expect(find.byKey(const Key('storageRecordingDot')), findsNWidgets(2));
    expect(find.textContaining('可拍'), findsNothing);
    expect(find.text('记录槽'), findsNothing,
        reason: '「记录槽」徽标字已退役,绿点扛语义');
    // 用量串贴右缘(Spamer/Flexible 平分余量沉淀行尾死空间的回归闸)。
    final first = tester.getRect(find.text('32/64GB').at(0));
    final second = tester.getRect(find.text('32/64GB').at(1));
    expect((first.right - second.right).abs(), lessThan(0.5),
        reason: '两槽用量串右缘对齐(与卡内边距齐平)');
  });

  testWidgets('记录槽指向未展示槽不亮点;相机有描述优先用描述', (tester) async {
    final controller = StorageOverviewController(
      session: PtpSession(transport: FakePtpTransport()),
      connection: _StubConnection(),
    );
    addTearDown(controller.dispose);
    controller
      ..storages = [
        _card(id: 0x00010001, freeImages: 0, description: 'Slot 2'),
      ]
      ..activeSlot = 2; // 写的是 2 号槽,面板只显示 1 行(1 号位)→ 不亮点

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('Slot 2'), findsOneWidget);
    expect(find.byKey(const Key('storageRecordingDot')), findsNothing);
  });

  testWidgets('Z f 卡型表:图标即槽标不出文字,弃相机上报原文', (tester) async {
    final controller = _stub(
      storages: [
        _card(
            id: 0x00010001,
            freeImages: 1683,
            description: 'NIKON Z f  [Slot 1]'),
        _card(
            id: 0x00020001,
            freeImages: 1683,
            description: 'NIKON Z f  [Slot 2]'),
      ],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller, model: 'Z f'));

    expect(find.text('SD'), findsOneWidget,
        reason: 'SD 槽图标卡面印「SD」字样');
    expect(find.text('m'), findsOneWidget,
        reason: 'mSD 槽图标卡面印「m」字样');
    expect(find.text('mSD'), findsNothing,
        reason: '不出独立槽名文字,卡型字样只印在卡面上');
    expect(find.textContaining('NIKON'), findsNothing,
        reason: '机型表命中即弃「NIKON Z f [Slot n]」上报原文');
    expect(find.byKey(const Key('storageRecordingDot')), findsOneWidget);
  });

  testWidgets('单插槽 2(卡在 2 号槽):槽位从 description 解析出 mSD 且绿点不漏',
      (tester) async {
    final controller = _stub(
      storages: [
        _card(
            id: 0x00020001,
            freeImages: 0,
            description: 'NIKON Z f  [Slot 2]'),
      ],
      activeSlot: 2,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller, model: 'Z f'));

    expect(find.text('mSD'), findsNothing,
        reason: '机型表命中 → 槽 2 小图标扛槽标,不出文字');
    expect(find.text('SD'), findsNothing);
    expect(find.byKey(const Key('storageRecordingDot')), findsOneWidget,
        reason: '0xD1F2=2 命中物理槽位 2(列表序会漏亮)');
  });

  testWidgets('未知机型回落相机上报描述(其它机身零回归)', (tester) async {
    final controller = _stub(
      storages: [
        _card(
            id: 0x00010001,
            freeImages: 0,
            description: 'NIKON Z 8 [Slot 1]'),
      ],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller, model: 'Z 8'));

    expect(find.text('NIKON Z 8 [Slot 1]'), findsOneWidget);
    expect(find.byKey(const Key('storageRecordingDot')), findsOneWidget);
  });

  testWidgets('剩余 <10% 胶囊条转警示红(填充 = 剩余量)', (tester) async {
    final controller = _stub(
      storages: [
        _card(id: 0x00010001, freeImages: 0, freeBytes: 4 << 30),
      ],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('94%'), findsOneWidget,
        reason: '条内百分比 = 已用 %(60/64 ≈ 94%);条填充画剩余 6%,<10% 转 error');
    final fill = tester.widget<ColoredBox>(
        find.byKey(const Key('storageBarFill')));
    expect(fill.color, scheme(tester).error, reason: '剩余 <10% 转 error 色');
  });

  testWidgets('容量未上报:显示容量未知,无条', (tester) async {
    final controller = _stub(
      storages: [
        _card(
            id: 0x00010001,
            freeImages: 0,
            freeBytes: 0,
            totalBytes: 0,
            description: 'SD'),
      ],
      activeSlot: 1,
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('容量未知'), findsOneWidget);
    expect(find.byKey(const Key('storageUsageBar')), findsNothing);
  });

  testWidgets('无槽不占位(卡壳退场)', (tester) async {
    final controller = _stub(storages: const [], activeSlot: null);
    addTearDown(controller.dispose);

    await _pumpCard(tester, StorageCard(overview: controller));

    expect(find.text('插槽 1'), findsNothing);
    expect(find.byKey(const Key('storageUsageBar')), findsNothing);
  });
}

ColorScheme scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(StorageCard))).colorScheme;

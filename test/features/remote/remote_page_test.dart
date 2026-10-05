import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/remote_page.dart';

/// 按序回放假传输(同 remote_controller_test;脚本耗尽抛 StateError,
/// 页面测试靠它兜住意外的多余请求)。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)}');
    }
    return script.removeFirst() as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventCtrl.stream;

  @override
  Future<void> close() async {}
}

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
  String? get pairingCode => null;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {}

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}

  @override
  Future<void> disconnect() async {}
}

/// PropDesc 数据集(无 FORM 变体即取值域未知)。
Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, List<int>? enums}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
  type.write(w, current);
  if (enums != null) {
    w
      ..u8(0x02) // FORM=0x02 枚举域
      ..u16(enums.length);
    for (final v in enums) {
      type.write(w, v);
    }
  } else {
    w.u8(0x00); // 无 FORM
  }
  return w.takeBytes();
}

/// 目录序全量 PropDesc 应答(模式 A · f/2.8 · 1/100s · ISO 200 ·
/// EV+0.3 · 白平衡自动 · 测光/对焦/画质=2 · 释放单张,均可写)。
void _scriptParams(_ScriptTransport t) {
  t
    ..ok(data: _propDescDataset(PtpDevicePropCode.exposureProgramMode,
        PtpDataType.uint16, 3,
        enums: [1, 2, 3, 4, 5]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.fNumber, PtpDataType.uint16, 28,
        enums: [28, 32, 40]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureTime, PtpDataType.uint32, 10000))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
        enums: [100, 200, 400, 800]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureBiasCompensation, PtpDataType.int16, 300))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.whiteBalance, PtpDataType.uint16, 2,
        enums: [1, 2, 4, 5, 6, 7]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureMeteringMode, PtpDataType.uint16, 2,
        enums: [1, 2, 3, 4, 5]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.focusMode, PtpDataType.uint16, 2,
        enums: [1, 2, 3]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.stillCaptureMode, PtpDataType.uint16, 1,
        enums: [1, 2, 3]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.compressionSetting, PtpDataType.uint16, 2,
        enums: [1, 2, 3]));
}

void main() {
  testWidgets('参数 chips:目录值中文上屏(三要素大芯片 + 其余小芯片)',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    _scriptParams(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 三要素大芯片
    expect(find.text('光圈'), findsOneWidget);
    expect(find.text('f/2.8'), findsOneWidget);
    expect(find.text('1/100s'), findsOneWidget);
    expect(find.text('ISO 200'), findsOneWidget);
    // 其余参数小芯片(目录标签 + 中文值;无标签表属性裸显)
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('光圈优先 A'), findsOneWidget);
    expect(find.text('EV'), findsOneWidget);
    expect(find.text('+0.3'), findsOneWidget);
    expect(find.text('白平衡'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('释放'), findsOneWidget);
    expect(find.text('单张'), findsOneWidget);
    expect(find.text('值 2'), findsNWidgets(3)); // 测光/对焦/画质
  });

  testWidgets('门禁关(生产默认):全部参数芯片只读不可点', (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    _scriptParams(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    final bigChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('光圈'), matching: find.byType(InkWell))
        .first);
    expect(bigChip.onTap, isNull, reason: '三要素芯片不可点');
    final smallChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('模式'), matching: find.byType(InkWell))
        .first);
    expect(smallChip.onTap, isNull, reason: '参数小芯片不可点');
  });

  testWidgets('门禁开 + 可写:点小芯片 → 枚举单选 → 0x1016 写 + 回读上屏',
      (tester) async {
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸注入)
    addTearDown(() => PtpSession.kSetPropEnabled = false);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptParams(transport);
    // 写路径脚本:0x1016 成功 + 回读 PropDesc(相机收下 4 = 快门优先 S)
    transport
      ..ok()
      ..ok(data: _propDescDataset(PtpDevicePropCode.exposureProgramMode,
          PtpDataType.uint16, 4,
          enums: [1, 2, 3, 4, 5]));
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.tap(find.text('模式')); // 此时面板未开,芯片是唯一「模式」
    await tester.pumpAndSettle();
    expect(find.text('快门优先 S'), findsOneWidget); // 面板枚举项

    await tester.tap(find.text('快门优先 S'));
    await tester.pumpAndSettle();

    final write = transport.requests.singleWhere(
        (r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.exposureProgramMode]);
    expect(write.dataOut, Uint8List.fromList([4, 0])); // u16 裸值
    expect(find.text('快门优先 S'), findsOneWidget); // 芯片已回读更新
    expect(find.text('光圈优先 A'), findsNothing);
  });

  testWidgets('门禁开 + 域未知:面板出「取值域未知」只读提示(不炸不写)',
      (tester) async {
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = false);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptParams(transport); // 快门 PropDesc 无 FORM:无枚举无范围
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.tap(find.text('快门').first); // 芯片标签(另一处为快门钮)
    await tester.pumpAndSettle();
    expect(find.text('该属性的取值域未知,暂不可调(待真机核对)'),
        findsOneWidget);
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
  });
}

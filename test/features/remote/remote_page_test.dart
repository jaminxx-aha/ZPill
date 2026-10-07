import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/remote/live_view_header.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/remote/live_view_overlays.dart';
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

/// PropDesc 数据集(u16 code + u16 type + u8 getSet + 当前值 + 出厂
/// 默认值 + FORM;ISO 15740 标准布局 —— 出厂值在 FORM 之前)。
Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, List<int>? enums}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
  // 值区顺序:gphoto2 权威 —— 出厂默认值在前,当前值在后;不同值
  // 锁死顺序(读反立刻炸)。
  type.write(w, current + 1); // 出厂默认值
  type.write(w, current); // 当前值
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

/// u32 裸值应答字节(小端;厂商读码路由用)。
Uint8List _u32Bytes(int v) => Uint8List.fromList(
    [for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF]);

/// 目录序全量应答(模式 M · f/2.8 · 1/100s · ISO 200 · EV+0.3 ·
/// 白平衡自动 · 色温 5500K · 闪光关闭 · 测光 2 · 对焦 AF-C · 对焦模式
/// AF-S · 释放单张 · 画质 RAW · RAW 无损 · 尺寸 2 · 区域 FX · 校准标准,
/// 均可写;快门/ISO 值走厂商读码裸值,末尾自动 ISO 状态(0xD054,关),
/// 与 remote_controller_test 同值。[mode] 参数化曝光模式(默认 M)。
void _scriptParams(_ScriptTransport t, {int mode = 1}) {
  t
    ..ok(data: _propDescDataset(PtpDevicePropCode.exposureProgramMode,
        PtpDataType.uint16, mode,
        enums: [1, 2, 3, 4, 5]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.fNumber, PtpDataType.uint16, 280,
        enums: [280, 320, 400]))
    // 快门:取值域直供(不读 0x500D PropDesc),值 = 0xD100 打包 1/100s
    ..ok(data: _u32Bytes(1 << 16 | 100))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
        enums: [100, 200, 400, 800]))
    ..ok(data: _u32Bytes(200)) // ISO 值 = 0xD0B5 有效 ISO
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureBiasCompensation, PtpDataType.int16, 300))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.whiteBalance, PtpDataType.uint16, 2,
        enums: [2, 4, 5, 6, 7, 0x8010]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.wbColorTemp, PtpDataType.uint16, 5500,
        enums: [2700, 5500, 6500]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.flashMode,
        PtpDataType.uint16, 2, enums: [2, 4, 0x8010, 0x8012]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureMeteringMode, PtpDataType.uint16, 2,
        enums: [1, 2, 3, 4, 5]))
    // 对焦模式 0xD061:pickValues 直供(不读 desc),值走裸读 u8 = 0(AF-S)
    ..ok(data: Uint8List.fromList([0]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.stillCaptureMode,
        PtpDataType.uint16, 1, enums: [1, 2, 0x8010, 0x8011]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.compressionSetting,
        PtpDataType.uint8, 7, enums: [4, 5, 7, 12]))
    // pickValues 参数(不读 desc,值走裸读):RAW 压缩 0 / 图像区域 0 /
    // 主体检测 0 / 色调 1 / 优化校准 1;AF 区域改相机 FORM 驱动
    // (2026-10-07 Zf 七值实证)→ 完整 PropDesc 应答
    ..ok(data: Uint8List.fromList([0])) // rawCompressionType u8
    ..ok(data: Uint8List.fromList([0])) // captureAreaCrop u8
    ..ok(data: _propDescDataset(PtpDevicePropCode.stillFocusMeteringMode,
        PtpDataType.uint16, 0x8010,
        enums: [0x8010, 0x8011, 0x8017, 0x8018, 0x8019, 0x801E, 0x801F]))
    ..ok(data: Uint8List.fromList([0])) // 主体检测 u8(Ex 码 0x0001D006)
    ..ok(data: Uint8List.fromList([1])) // 色调 u8(Ex 码 0x0001D01C)
    ..ok(data: Uint8List.fromList([1, 0])) // activePicCtrlItem u16
    ..ok(data: Uint8List.fromList([0])) // 0xD054 自动 ISO:关
    ..ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数
}

/// 挂起的 delay(永不完成):引擎帧轮询/AE 轮询在测试里驻停,
/// 不与被测路径抢脚本应答。
Future<void> _parkedDelay(Duration _) => Completer<void>().future;

/// 真实可解码 32×24 JPEG(Image.memory 要渲染,不能用手拼 SOF 假帧)。
Uint8List _realJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, x * 8, x * 8, x * 8, 255); // 左黑右白渐变
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 最小 display-info 头(6048×3400、单 AF 框):头按真机形态补 1024B
/// 定长 + SOI JPEG 尾(头长靠 SOI 位置定位),页面测试直接注到
/// engine.header 驱动 AF 框叠层。
Uint8List _headerObject() {
  final b = Uint8List(1024 + 4);
  void be16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  be16(16, 6048);
  be16(18, 3400);
  b[42] = 2; // 合焦
  b[44] = 1;
  be16(48, 240);
  be16(50, 240);
  be16(52, 3024);
  be16(54, 1700);
  b[1024] = 0xFF;
  b[1025] = 0xD8;
  b[1026] = 0xFF;
  return b;
}

/// 横滚参数行(页面里唯一的水平 Scrollable)。
final _chipsRow = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.right);

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

    // 读出条首屏(OpenZCine 顺序:模式/ISO/快门/光圈/释放/对焦模式…)
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('手动 M'), findsOneWidget);
    expect(find.text('ISO 200'), findsOneWidget);
    expect(find.text('1/100s'), findsOneWidget);
    expect(find.text('f/2.8'), findsOneWidget);
    expect(find.text('单张'), findsOneWidget, reason: '释放');
    expect(find.text('AF-S'), findsOneWidget, reason: '对焦模式(单一对焦芯片)');

    // 读出条懒构建:按条内顺序单向滚到底逐个断言
    // (模式/ISO/快门/光圈/释放/对焦模式/白平衡/色温/测光/EV/闪光/
    // 画质/RAW压缩/图像区域/优化校准)
    Future<void> scroll(String text) =>
        tester.scrollUntilVisible(find.text(text), 120, scrollable: _chipsRow);
    await scroll('自动'); // 白平衡
    await scroll('5500K'); // 色温
    await scroll('中央重点'); // 测光值表(尼康方言 2=中央重点)
    await scroll('EV');
    expect(find.text('+0.3'), findsOneWidget);
    await scroll('关闭'); // 闪光
    await scroll('RAW'); // 画质
    await scroll('无损压缩'); // RAW 压缩值
    await scroll('FX'); // 图像区域值
    await scroll('标准'); // 优化校准值
    // 辅助条(固定行,无需滚动):对焦后拍 + APP 接管
    expect(find.text('对焦后拍'), findsOneWidget);
    expect(find.text('APP 接管'), findsOneWidget);
  });

  testWidgets('总闸紧急关断:全部参数芯片只读不可点', (tester) async {
    PtpSession.kSetPropEnabled = false; // 生产已开,显式关断走分支
    addTearDown(() => PtpSession.kSetPropEnabled = true);
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
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptParams(transport);
    // 写路径脚本:0x1016 成功 + 回读 PropDesc(相机收下 4 = 直射阳光)
    transport
      ..ok()
      ..ok(data: _propDescDataset(PtpDevicePropCode.whiteBalance,
          PtpDataType.uint16, 4,
          enums: [2, 4, 5, 6, 7, 0x8010]));
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.tap(find.text('白平衡')); // 横滚行首屏内的芯片
    await tester.pumpAndSettle();
    expect(find.text('直射阳光'), findsOneWidget); // 面板枚举项

    await tester.tap(find.text('直射阳光'));
    await tester.pumpAndSettle();

    final write = transport.requests.singleWhere(
        (r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.whiteBalance]);
    expect(write.dataOut, Uint8List.fromList([4, 0])); // u16 裸值
    expect(find.text('直射阳光'), findsOneWidget); // 芯片已回读更新
    expect(find.text('自动'), findsNothing);
  });

  testWidgets('快门(拨盘拥有):先弹「APP 接管」确认 → 0x90C2 启用 → '
      '标准档面板直写打包值', (tester) async {
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptParams(transport);
    transport
      ..ok() // 0x90C2 [1] 启用接管
      ..ok() // 0x1016 写 0xD100 = (1<<16)|250
      ..ok(data: _u32Bytes(1 << 16 | 125)); // 回读 0xD100 裸值
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.tap(find.text('快门').first); // 芯片标签(另一处为快门钮)
    await tester.pumpAndSettle();
    // 影控台同款确认:受机身拨盘控制的参数需先接管
    expect(find.text('启用 APP 接管控制?'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(controller.takeoverActive, isTrue);

    // 面板 = 目录标准档直供(0x500D 枚举弃用),非相机 PropDesc 枚举;
    // **打开即定位到当前值**(1/100s,第 20 项 —— 不定位则列表头只有
    // 1/8000s 一带,当前值 tile 根本不构建)
    expect(find.text('1/100s'), findsNWidgets(2),
        reason: '芯片 + 面板当前值条目(面板已定位到当前值)');
    // 定位后可视区内点选相邻档(1/125s = 当前值上方两行)
    await tester.tap(find.text('1/125s'));
    await tester.pumpAndSettle();

    final write = transport.requests.singleWhere(
        (r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.stillShutterSpeed],
        reason: '快门写走 0xD100');
    expect(write.dataOut, Uint8List.fromList([0x7D, 0x00, 0x01, 0x00]));
    expect(find.text('1/125s'), findsOneWidget, reason: '回读更新上屏');
    final takeover =
        transport.requests.singleWhere((r) => r.opcode == NikonOperationCode.changeCameraMode);
    expect(takeover.params, [1]);
  });

  testWidgets('APP 接管芯片:未接管弹确认启用;已接管点按解除(0x90C2 [0])',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));

    await tester.scrollUntilVisible(find.text('APP 接管'), 120,
        scrollable: _chipsRow);
    // 行尾芯片可能只进缓存区未真入屏:滚到底再点
    await tester.drag(_chipsRow, const Offset(-240, 0));
    await tester.pump();
    transport.ok(); // 0x90C2 [1]
    await tester.tap(find.text('APP 接管'));
    await tester.pumpAndSettle();
    expect(find.text('启用 APP 接管控制?'), findsOneWidget);
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(controller.takeoverActive, isTrue);
    // 「APP 接管中」两处:信息胶囊徽标 + 辅助条芯片
    expect(find.text('APP 接管中'), findsNWidgets(2));

    transport.ok(); // 0x90C2 [0]
    await tester.tap(find.text('APP 接管中').last); // 辅助条芯片(可点)
    await tester.pumpAndSettle();
    expect(controller.takeoverActive, isFalse);
    expect(find.text('APP 接管'), findsOneWidget);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
            .last
            .params,
        [0]);
  });

  testWidgets('A(光圈优先)模式:快门芯片标「(自动)」置灰,光圈照常',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    _scriptParams(transport, mode: 3); // 光圈优先 A:快门是自动曝光变量
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    expect(find.text('1/100s(自动)'), findsOneWidget, reason: '标注自动');
    expect(find.text('f/2.8'), findsOneWidget, reason: '光圈无标注');
    final shutterChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('1/100s(自动)'), matching: find.byType(InkWell))
        .first);
    expect(shutterChip.onTap, isNull, reason: '模式门置灰,不弹接管确认');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeCameraMode),
        isEmpty,
        reason: '不可调参数不触发接管流程');
  });

  testWidgets('ISO 面板:「自动 ISO」开关置顶(0xD054;ISO 拨盘级参数'
      '先过接管确认)', (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    _scriptParams(transport); // M 模式,自动 ISO 关
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.isoAuto, isFalse);

    transport.ok(); // 0x90C2 [1] ISO 为拨盘级参数 → 接管确认
    await tester.tap(find.text('ISO')); // 三要素大芯片
    await tester.pumpAndSettle();
    expect(find.text('启用 APP 接管控制?'), findsOneWidget);
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(controller.takeoverActive, isTrue);
    expect(find.text('自动 ISO'), findsOneWidget);
    expect(find.text('ISO 200'), findsWidgets,
        reason: '面板枚举项照常(芯片 + 面板各一处)');

    transport
      ..ok() // 0xD054=1 开自动
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 800,
          enums: [100, 200, 400, 800]))
      ..ok(data: _u32Bytes(800)); // 0xD0B5 工作值
    await tester.tap(find.text('自动 ISO'));
    await tester.pumpAndSettle();
    expect(controller.isoAuto, isTrue);
    expect(controller.exposure?.iso, 800);
    final write = transport.requests.singleWhere(
        (r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.stillIsoAutoControl]);
    expect(write.dataOut, [1]);
  });

  testWidgets('门禁开 + 域未知:面板出「取值域未知」只读提示(不炸不写)',
      (tester) async {
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptParams(transport); // EV PropDesc 无 FORM:无枚举无范围
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('EV'), 120, scrollable: _chipsRow);
    await tester.tap(find.text('EV'));
    await tester.pumpAndSettle();
    expect(find.text('该属性的取值域未知,暂不可调(待真机核对)'),
        findsOneWidget);
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
  });

  testWidgets('切回拍摄 tab / 回前台 → 参数对表刷新(机身侧改动兜底)',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    _scriptParams(transport); // 连接时全量
    await tester.pumpWidget(
        MaterialApp(home: RemotePage(controller: controller, active: false)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.exposure?.fNumber, 280);

    // 切回 tab:对表刷一次(脚本耗尽会以 StateError 炸出 —— 刷了才消费)
    _scriptParams(transport);
    await tester.pumpWidget(
        MaterialApp(home: RemotePage(controller: controller, active: true)));
    await tester.pumpAndSettle();
    expect(controller.exposure?.fNumber, 280);

    // 回前台:同样对表
    _scriptParams(transport);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.exposure?.fNumber, 280);
  });

  testWidgets('点按取景画面 → 触控对焦(0x9205 帧像素坐标 + 对焦框回投)',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);

    transport
      ..ok() // 0x9201 开取景
      ..ok(data: _realJpeg()); // 首帧(真实 JPEG,Image.memory 要解码)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    // 取景开关 = 动作行按钮(点其「取景」标签)
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue);
    expect(controller.frameSize.value, (width: 32, height: 24));
    expect(find.byType(Image), findsOneWidget, reason: '首帧已上屏');

    transport
      ..ok() // changeAfArea
      ..ok(); // afDrive
    // contain 居中:画面中心 = 图像中心 → 归一化 (0.5, 0.5)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();

    final af = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.changeAfArea);
    expect(af.params, [16, 12], reason: '0.5×32、0.5×24');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.afDrive),
        hasLength(1));
    // contain 映射有浮点误差(0.49999…),归一化坐标近似断言即可;
    // 像素坐标已 round,精确 [16, 12]。
    expect(controller.afBox!.nx, closeTo(0.5, 1e-6));
    expect(controller.afBox!.ny, closeTo(0.5, 1e-6));
    expect(controller.error, isNull);
    // 对焦框回投:琥珀色(0xFFFFC107)描边方块画上屏(芯片描边是灰/主题色)
    const amber = Color(0xFFFFC107);
    expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) return false;
          final border = (w.decoration as BoxDecoration).border;
          return border is Border &&
              border.top.width == 2 &&
              border.top.color == amber;
        }),
        findsOneWidget);
  });

  testWidgets('「对焦后拍」开关:横滚行尾,点选即切换(零相机流量)',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    expect(controller.focusBeforeCapture, isFalse);
    await tester.scrollUntilVisible(find.text('对焦后拍'), 120,
        scrollable: _chipsRow);
    // 行尾芯片可能只进缓存区未真入屏(滚动落点在边缘外):滚到底再点
    await tester.drag(_chipsRow, const Offset(-240, 0));
    await tester.pump();
    await tester.tap(find.text('对焦后拍'));
    await tester.pumpAndSettle();
    expect(controller.focusBeforeCapture, isTrue);
    expect(transport.requests, isEmpty, reason: '纯本地开关,不发相机命令');
  });

  testWidgets('监看辅助开关:直方图等四个分析开关须同步启用帧分析器'
      '(直方图无数据回归)', (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    expect(controller.analyzer.enabled.value, isFalse);

    // 点辅助条图标盒(InkWell 只包图标,标签文字不在点击区)
    await tester.tap(find.byIcon(Icons.bar_chart)); // 直方图
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isTrue,
        reason: '开了直方图必须启用帧分析,否则永远无数据');

    await tester.tap(find.byIcon(Icons.bar_chart));
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isFalse);
  });

  testWidgets('相机自报 AF 框:帧头在册即叠加(真实尺寸框,无需点按)',
      (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);

    transport
      ..ok() // 0x9201
      ..ok(data: _realJpeg()); // 首帧(SOF 尺寸入册 → imageRect 可算)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(find.byType(AfAreasOverlay), findsNothing,
        reason: '无头/未取景不画相机 AF 框');

    controller.engine.header.value = parseLiveViewHeader(_headerObject());
    await tester.pump();
    expect(find.byType(AfAreasOverlay), findsOneWidget,
        reason: '头一到即叠加相机自报框(尺寸随 AF 区域设置)');

    // 头在册(相机自报框)时,点按占位框不叠加 —— 同屏只此一框
    controller.afBox = AfBox(nx: 0.5, ny: 0.5);
    await tester.pump();
    const amber = Color(0xFFFFC107);
    expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) {
            return false;
          }
          final border = (w.decoration as BoxDecoration).border;
          return border is Border &&
              border.top.width == 2 &&
              border.top.color == amber;
        }),
        findsNothing,
        reason: '头在册 = 相机真实框已在屏,占位框再画即双框');
  });

  testWidgets('横屏监看布局:取景画面全幅打底,控制条浮在画面上下',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);

    transport
      ..ok() // 0x9201
      ..ok(data: _realJpeg());
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue);

    // 横屏 Stack:取景区(含 Image)占满整屏,不再是竖屏 Column 里被
    // 控制条挤剩的一条 —— Image 组件盒 = 全屏尺寸
    final imageSize = tester.getSize(find.byType(Image).first);
    expect(imageSize.width, 1600);
    expect(imageSize.height, 800,
        reason: '画面打底占大块屏幕,按钮浮在其上');
    // 控制条在画面之上同屏可见(浮层,不再把画面挤出屏)
    expect(find.text('取景中'), findsOneWidget);
    expect(find.byIcon(Icons.grid_on), findsOneWidget);
  });
}

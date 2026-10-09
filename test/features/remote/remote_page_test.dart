import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:nikon_pill/data/settings_store.dart';
import 'package:nikon_pill/design/app_theme.dart';
import 'package:nikon_pill/features/remote/feed_quality.dart';
import 'package:nikon_pill/features/remote/live_view_overlays.dart';
import 'package:nikon_pill/features/remote/remote_banner.dart';
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
    // 优化校准:FORM 驱动(pickValues 已撤,2026-10-07)→ desc 应答;
    // 枚举全静态表内 → 不触发 0x90CC 名字拉取
    ..ok(data: _propDescDataset(PtpDevicePropCode.activePicCtrlItem,
        PtpDataType.uint16, 1, enums: [1, 2, 3, 4]))
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

/// 竖屏视口:flutter_test 默认 800×600 = 横屏,断言竖屏布局(横滚读出
/// 条/辅助条/动作行文字)的用例必须显式竖过来。
void _portrait(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 横屏视口(侧栏监看布局)。
void _landscape(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1600, 800)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// flutter/platform 通道里的方向消息(过滤同通道的其他系统消息)。
List<MethodCall> _orientationCalls(List<MethodCall> calls) => [
      for (final c in calls)
        if (c.method == 'SystemChrome.setPreferredOrientations') c,
    ];

void main() {
  testWidgets('参数 chips:目录值中文上屏(三要素大芯片 + 其余小芯片)',
      (tester) async {
    _portrait(tester);
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
    expect(find.text('ISO'), findsOneWidget, reason: 'ISO 小标签');
    expect(find.text('200'), findsOneWidget, reason: 'ISO 裸数值');
    expect(find.text('1/100s'), findsOneWidget);
    expect(find.text('f/2.8'), findsOneWidget);
    expect(find.text('单张'), findsOneWidget, reason: '释放');
    expect(find.text('AF-S'), findsOneWidget, reason: '对焦模式(单一对焦芯片)');

    // 读出条懒构建:按条内顺序单向滚到底逐个断言
    // (模式/ISO/快门/光圈/释放/对焦模式/白平衡/色温/测光/EV/闪光/
    // 画质/RAW压缩/图像区域/优化校准 + 目录余量 AF 区域/主体检测/色调)
    Future<void> scroll(String text) =>
        tester.scrollUntilVisible(find.text(text), 120, scrollable: _chipsRow);
    await scroll('自动'); // 白平衡
    await scroll('5500K'); // 色温
    await scroll('中央重点'); // 测光值表(尼康方言 2=中央重点)
    await scroll('EV');
    expect(find.text('+0.3'), findsOneWidget);
    await scroll('闪光'); // (值「关闭」与主体检测的「关闭」重字,滚标签)
    await scroll('RAW'); // 画质
    await scroll('无损压缩'); // RAW 压缩值
    await scroll('FX'); // 图像区域值
    await scroll('标准'); // 优化校准值
    // 目录余量上条(2026-10-07:曾因 _stripOrder 不追加余量而整组不渲染)
    await scroll('AF 区域');
    expect(find.text('单点'), findsOneWidget, reason: 'AF 区域 FORM 值');
    await scroll('主体检测');
    await scroll('色调');
    expect(find.text('SDR'), findsOneWidget, reason: '色调值');
    // 辅助开关收进胶囊 tune 钮的非模态浮层(手机相机式排版):
    // 开面板后断言对焦后拍 + APP 接管
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('对焦后拍'), findsOneWidget);
    expect(find.text('APP 接管'), findsOneWidget);
  });

  testWidgets('总闸紧急关断:全部参数芯片只读不可点', (tester) async {
    _portrait(tester);
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
    _portrait(tester);
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

  testWidgets('快门(拨盘拥有):面板先出接管区 → 0x90C2 启用 → '
      '标准档面板直写打包值', (tester) async {
    _portrait(tester);
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
    // 双层跳合一:面板直接打开,拨盘拥有参数的面板头是接管区(原
    // 「启用 APP 接管控制?」确认对话框的文案 + 启用钮搬进面板)。
    expect(find.text('启用 APP 接管控制?'), findsOneWidget);
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
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));

    // 辅助芯片收进胶囊 tune 钮的非模态浮层(手机相机式排版):
    // 开面板再点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
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
    _portrait(tester);
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
    _portrait(tester);
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

    transport.ok(); // 0x90C2 [1] ISO 为拨盘级参数 → 面板接管区
    await tester.tap(find.text('ISO')); // 读出条芯片(面板接管区在面板头)
    await tester.pumpAndSettle();
    expect(find.text('启用 APP 接管控制?'), findsOneWidget);
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(controller.takeoverActive, isTrue);
    expect(find.text('自动 ISO'), findsOneWidget);
    expect(find.text('200'), findsWidgets,
        reason: '面板枚举项照常(芯片裸数值 + 面板各一处)');

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
    _portrait(tester);
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
    _portrait(tester);
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
    // contain 居中:画面中心 = 图像中心 → 归一化 (0.5, 0.5)。
    // Image 住图像坐标系且 Transform transformHitTests: false —— 点按
    // 由外层取景手势(屏幕系收口)接收,命不中 Image 本体是设计使然。
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
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

  testWidgets('双指缩放:外扩即放大出角标,角标/双击复位,内收不小于适配',
      (tester) async {
    _portrait(tester);
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
      ..ok(data: _realJpeg()); // 首帧(此后 delay 挂起)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsNothing,
        reason: '适配态无角标');

    // ① 双指外扩:间距 200 → 400 = 放大,角标现身(倍率精确值取决于
    //    识别器在越过 slop 时锚定的初始跨距,不硬断言小数位)
    final c1 = await tester.startGesture(const Offset(300, 1100), pointer: 1);
    final c2 = await tester.startGesture(const Offset(500, 1100), pointer: 2);
    await tester.pump();
    await c1.moveBy(const Offset(-100, 0));
    await tester.pump();
    await c2.moveBy(const Offset(100, 0));
    await tester.pump();
    await c1.up();
    await c2.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsOneWidget,
        reason: '缩放角标现身');
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('feed-zoom-badge')),
            matching: find.byWidgetPredicate(
                (w) => w is Text && RegExp(r'^\d+(\.\d+)?×$').hasMatch(w.data!))),
        findsOneWidget,
        reason: '角标显倍率(如 1.3×)');

    // ② 缩放态点画面 → 对焦照常(screenToNorm 逆映射含缩放/平移;
    //    点图像中心,归一化仍是 (0.5, 0.5))
    transport
      ..ok() // changeAfArea
      ..ok(); // afDrive
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    final af = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.changeAfArea);
    expect(af.params, [16, 12], reason: '缩放/平移后逆映射仍回图像中心');

    // ③ 点角标复位
    await tester.tap(find.byKey(const ValueKey('feed-zoom-badge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsNothing,
        reason: '角标点按复位');

    // ④ 再放大后双击画面复位(第二击不再对焦)
    final c3 = await tester.startGesture(const Offset(300, 1100), pointer: 3);
    final c4 = await tester.startGesture(const Offset(500, 1100), pointer: 4);
    await tester.pump();
    await c3.moveBy(const Offset(-100, 0));
    await tester.pump();
    await c4.moveBy(const Offset(100, 0));
    await tester.pump();
    await c3.up();
    await c4.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsOneWidget);
    final focusCountBefore = transport.requests
        .where((r) => r.opcode == NikonOperationCode.changeAfArea)
        .length;
    transport
      ..ok() // 双击第一击的 changeAfArea
      ..ok(); // afDrive
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100)); // 双击窗内(<300ms)
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsNothing,
        reason: '双击复位');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea)
            .length,
        focusCountBefore + 1,
        reason: '双击的第二击不再对焦(只有第一击对焦一次)');

    // ⑤ 内收(缩小)钳到 1:不出角标不出 letterbox
    final c5 = await tester.startGesture(const Offset(300, 1100), pointer: 5);
    final c6 = await tester.startGesture(const Offset(500, 1100), pointer: 6);
    await tester.pump();
    await c5.moveBy(const Offset(50, 0));
    await tester.pump();
    await c6.moveBy(const Offset(-50, 0));
    await tester.pump();
    await c5.up();
    await c6.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-zoom-badge')), findsNothing,
        reason: '缩不放小于适配');
  });

  testWidgets('拉焦轮:开关出竖条,竖拖驱动 0x9204(下=向近),点轮子不对焦',
      (tester) async {
    _portrait(tester);
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
      ..ok(data: _realJpeg()); // 首帧(此后 delay 挂起)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-dial-rail')), findsNothing,
        reason: '默认不占取景画面');

    // 辅助浮层开「拉焦轮」
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉焦轮'));
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('focus-dial-rail'));
    expect(rail, findsOneWidget, reason: '开关即出竖条');

    // 竖拖(分两段:首段 20px 越过触摸 slop 起手势 —— 该段不入拖距;
    // 第二段干净 30px > 一步 24px)→ 0x9204 向近 60 脉冲
    transport.ok(); // 0x9204 应答
    final g = await tester.startGesture(tester.getCenter(rail));
    await g.moveBy(const Offset(0, 20)); // 越过 slop,起手势
    await tester.pump();
    await g.moveBy(const Offset(0, 30)); // +30 → 一步
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final mf = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.mfDrive);
    expect(mf.params, [1, 60], reason: '向下拖 = 向近一步(24px → 60 脉冲)');

    // 点轮子本体不触发触控对焦(自吃点按)
    await tester.tap(rail);
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '轮子点按不落到画面手势');
  });

  testWidgets('画质档路由:默认关 = 低采样 Image;高质量 → ShaderFeed',
      (tester) async {
    _portrait(tester);
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
    final settings = ValueNotifier<AppSettings>(const AppSettings());

    transport
      ..ok() // 0x9201 开取景
      ..ok(data: _realJpeg()); // 首帧(此后 delay 挂起)
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();

    // 默认关:普通 Image + 低采样(最省)
    expect(find.byType(ShaderFeed), findsNothing);
    expect(tester.widget<Image>(find.byType(Image).first).filterQuality,
        FilterQuality.low);

    // 切「快速」:同一 Image,filterQuality 升 high
    settings.value =
        const AppSettings(feedUpscaler: FeedUpscaler.fast);
    await tester.pump();
    expect(tester.widget<Image>(find.byType(Image).first).filterQuality,
        FilterQuality.high);

    // 切「高质量」:ShaderFeed 上树(时域降噪随设置带入)
    settings.value = const AppSettings(
        feedUpscaler: FeedUpscaler.quality, temporalDenoise: true);
    await tester.pump();
    expect(find.byType(ShaderFeed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「对焦后拍」开关:横滚行尾,点选即切换(零相机流量)',
      (tester) async {
    _portrait(tester);
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
    // 对焦后拍收进胶囊 tune 钮的非模态浮层(手机相机式排版):开面板再点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('对焦后拍'));
    await tester.pumpAndSettle();
    expect(controller.focusBeforeCapture, isTrue);
    expect(transport.requests, isEmpty, reason: '纯本地开关,不发相机命令');
  });

  testWidgets('监看辅助开关:直方图等四个分析开关须同步启用帧分析器'
      '(直方图无数据回归)', (tester) async {
    _portrait(tester);
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

    // 辅助开关收进胶囊 tune 钮浮层(手机相机式排版):开面板后点
    // 图标盒(InkWell 只包图标,标签文字不在点击区)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
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
    _portrait(tester);
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

  testWidgets('竖屏手机相机式排版:浮胶囊 + 底部三行(读出/动作/快门),'
      '辅助收 tune 浮层,纯净监看两段淡出可恢复', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    // 底部三行:参数读出行(内联小标签+数值)→ 动作行 → 快门行
    expect(find.text('模式'), findsOneWidget, reason: '读出行参数标签');
    expect(find.text('取景'), findsOneWidget, reason: '动作行取景钮');
    expect(find.text('对焦'), findsOneWidget);
    expect(find.text('录制'), findsOneWidget);
    expect(find.text('MF'), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget,
        reason: '快门行相册钮(无即拍图时图标占位)');
    expect(find.byIcon(Icons.visibility_off), findsOneWidget,
        reason: '快门行纯净监看钮');

    // 辅助开关收进胶囊 tune 钮的非模态浮层:默认不在树
    expect(find.text('对焦后拍'), findsNothing);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('对焦后拍'), findsOneWidget);

    // 纯净监看:顶部浮层与底部三行两段淡出 + 放行点击(AnimatedOpacity
    // 不裁树 —— 断言透明度与忽略指针;眼睛钮恢复)。
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();
    for (final key in const ['portrait-chrome-top', 'portrait-chrome-bottom']) {
      final chrome = find.byKey(ValueKey(key));
      expect(tester.widget<IgnorePointer>(chrome).ignoring, isTrue,
          reason: '$key 放行点击');
      expect(
          tester
              .widget<AnimatedOpacity>(
                  find.descendant(of: chrome, matching: find.byType(AnimatedOpacity)))
              .opacity,
          0.0,
          reason: '$key 淡出');
    }
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    for (final key in const ['portrait-chrome-top', 'portrait-chrome-bottom']) {
      final chrome = find.byKey(ValueKey(key));
      expect(tester.widget<IgnorePointer>(chrome).ignoring, isFalse);
      expect(
          tester
              .widget<AnimatedOpacity>(
                  find.descendant(of: chrome, matching: find.byType(AnimatedOpacity)))
              .opacity,
          1.0,
          reason: '$key 回来');
    }
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: 'chrome 回来');
  });

  testWidgets('横屏监看:画面全幅打底,参数竖列贴左、快门柱居右、'
      '动作行贴底,辅助开关收进顶栏浮层', (tester) async {
    _landscape(tester);
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

    // 单 FIFO 按消费顺序入队:connected 先吃掉 21 应答参数脚本,
    // 之后 tap 的 0x9201、首帧、AF 点按两应答依次就位。
    _scriptParams(transport);
    transport
      ..ok() // 0x9201(tap 后)
      ..ok(data: _realJpeg()); // 首帧(此后 delay 挂起)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    // 横屏取景钮 = 底部动作行(同竖屏一行)
    await tester.tap(find.byIcon(Icons.videocam_off_outlined));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue);

    // 画面打底占满整屏:Image 住在图像坐标系(32×24),经 Transform
    // 投到屏幕 contain 矩形 —— 断言画出来的矩形(getRect 含 paint 变换):
    // 32×24 在 1600×800 → fitScale 800/24 = 33.33…,
    // 宽 32×33.33 = 1066.67、居中左右各留 266.67 letterbox、高 800。
    final imageRect = tester.getRect(find.byType(Image).first);
    expect(imageRect.left, closeTo(1600 / 2 - 1600 / 3, 0.01));
    expect(imageRect.top, closeTo(0, 0.01));
    expect(imageRect.width, closeTo(3200 / 3, 0.01));
    expect(imageRect.height, closeTo(800, 0.01),
        reason: '画面打底,控制件浮在其上');

    // 参数读出 = 左栏竖向滚动(竖屏的横滚条在横屏不复存在)
    expect(
        find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down),
        findsOneWidget);
    expect(_chipsRow, findsNothing);
    expect(find.text('模式'), findsOneWidget, reason: '左栏参数 tile');

    // 动作行贴底 + 顶栏按钮在场
    expect(find.byIcon(Icons.center_focus_strong), findsOneWidget,
        reason: '底部动作行对焦钮');
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '辅助面板入口');

    // 快门柱纵向居右(2026-10-08 用户定案「拍照按钮在右侧中间」,
    // 非底部居中):锚右缘(10 边距),纵向中点在顶栏下沿(64)与
    // 底部动作行上沿(800-80)之间 → 中点 392。
    final shutter =
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 78);
    expect(shutter, findsOneWidget);
    expect(tester.getCenter(shutter).dx, 1551,
        reason: '快门贴右缘(10 边距 + 78/2)');
    expect(tester.getCenter(shutter).dy, 392, reason: '快门纵向居中');
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget,
        reason: '快门柱相册钮(无即拍图时图标占位)');
    expect(find.byIcon(Icons.visibility_off), findsOneWidget,
        reason: '快门柱纯净监看钮(顶栏不再重复)');

    // 辅助开关收浮层:默认不在树,点 tune 展开
    expect(find.byIcon(Icons.grid_on), findsNothing, reason: '默认收起');
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_on), findsOneWidget, reason: '面板开');

    // 点取景画面即收浮层 + 照常触控对焦(点左栏右沿与画幅左沿之间的
    // 空白;预置 AF 两应答)。
    transport
      ..ok() // changeAfArea
      ..ok(); // afDrive
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_on), findsNothing, reason: '点画面收起面板');
    final af = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.changeAfArea);
    // contain 映射照常:画面左缘外钳到 0,纵向居中
    expect(af.params, [0, 12]);
  });

  testWidgets('横屏纯净监看:控制浮层淡出放行点击,可一键恢复',
      (tester) async {
    _landscape(tester);
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

    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '隐前 chrome 在场');
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();

    // 淡出 + 放行点击(AnimatedOpacity 不裁树 —— 断言透明度与忽略
    // 指针,而非 finder 缺失)。Navigator 转场页自己也包 IgnorePointer,
    // 按类型全树找会撞多层 —— 按键定位 chrome 那一层。
    final chrome = find.byKey(const ValueKey('landscape-chrome'));
    final chromeOpacity =
        find.descendant(of: chrome, matching: find.byType(AnimatedOpacity));
    expect(tester.widget<AnimatedOpacity>(chromeOpacity).opacity, 0.0);
    expect(tester.widget<IgnorePointer>(chrome).ignoring, isTrue,
        reason: '点击放行给画面(触控对焦照常)');

    // 恢复钮(chrome 外的独立浮钮)在场可点
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(chromeOpacity).opacity, 1.0);
    expect(tester.widget<IgnorePointer>(chrome).ignoring, isFalse);
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: 'chrome 回来');
  });

  testWidgets('方向按钮点按横竖直切,图标恒定(Tooltip 已删,长按抬起=点按)'
      '(点按循环永不发空表:空表在 iOS 是 All mask,按物理姿态闪转)',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 竖屏视口:auto 态首击按屏向取反,默认 800×600 是横屏会翻成竖锁
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));

    // 初始 = 跟随系统:零方向消息,转屏图标
    expect(_orientationCalls(calls), isEmpty);
    expect(find.byIcon(Icons.screen_rotation), findsOneWidget);

    // 1) 竖屏下首击(auto):翻转屏向 → 锁横(系统转屏锁开着也能切)
    await tester.tap(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.screen_rotation), findsOneWidget,
        reason: '图标恒定,不随锁态换形');
    expect(_orientationCalls(calls).last.arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    // 2) 点按直切对半:锁横 → 锁竖(不经 auto;单值 portraitUp:plist
    // 未声明 UpsideDown,不留给系统自选)
    await tester.tap(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(_orientationCalls(calls).last.arguments,
        ['DeviceOrientation.portraitUp']);

    // 3) 再点直切回锁横 —— 点按循环永不发空表(2026-10-08 真机日志
    // 定案:空表 = iOS All mask,按物理姿态闪转竖→横→竖,多耗一击)
    await tester.tap(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(_orientationCalls(calls), hasLength(3));
    expect(_orientationCalls(calls).last.arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    // 4) 锁定态拆页:不**复位** —— 锁是会话级(挂 RemoteController),
    // dispose 不补发消息。
    calls.clear();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(_orientationCalls(calls), isEmpty, reason: '拆页不复位(会话级锁)');

    // 5) 同控制器重建页面:锁仍是横 —— 竖屏视口下点一下发 portraitUp
    // 即证(若锁丢回 auto,竖屏首击会发 landscape 对;图标恒定,靠消息断言)。
    await tester.pumpWidget(
        MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(_orientationCalls(calls).last.arguments,
        ['DeviceOrientation.portraitUp'],
        reason: '横锁跨页面回收存活,重建后首击直切竖');

    // 6) 长按:不弹「已锁xx」提示(Tooltip 已整体删除,用户点名单删);
    // 无 onLongPress 注册,长按抬起等同一次点按(Flutter 默认语义)
    // —— 只多一条消息,永不空表。
    await tester.longPress(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(find.textContaining('已锁'), findsNothing,
        reason: '无 Tooltip 长按弹提示');
    expect(_orientationCalls(calls), hasLength(2), reason: '长按抬起=点按');
    expect(_orientationCalls(calls).last.arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
  });

  testWidgets('横屏 auto 态首击:按屏向取反 → 锁竖(所见即所得)',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    tester.view
      ..physicalSize = const Size(2400, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));

    await tester.tap(find.byIcon(Icons.screen_rotation));
    await tester.pumpAndSettle();
    expect(_orientationCalls(calls).last.arguments,
        ['DeviceOrientation.portraitUp'],
        reason: '横屏首击翻成竖锁(不是默认锁横)');
  });

  testWidgets('拍摄页随主题:深色暖黑/浅色白底,画面内容层恒用暗面'
      '(2026-10-08「改成跟随主题」)', (tester) async {
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = RemoteController(
        session: PtpSession(transport: transport), connection: conn);
    addTearDown(controller.dispose);

    Color scaffoldBackground() =>
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: RemotePage(controller: controller),
    ));
    // 控制器 _linkUp 出厂为 true:喂一条断连沿,让「未连接」横幅上树
    conn.statesCtrl.add(CameraLinkState.disconnected);
    await tester.pumpAndSettle();
    expect(scaffoldBackground(), const Color(0xFF12100E),
        reason: '深色主题 = 暖黑现状,像素不变');

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      home: RemotePage(controller: controller),
    ));
    await tester.pumpAndSettle();
    expect(scaffoldBackground(), const Color(0xFFFFFEFB),
        reason: '浅色主题 = 白底(v8 统一令)');

    // 未连接横幅叠在取景画面上,是内容层:深浅主题下都恒用暗面玻璃
    // + 暗面金 —— 看图的内容层不随主题(同相册查看器口径)。
    Color bannerGlass() {
      final container = find
          .descendant(
              of: find.byType(LiveBanner), matching: find.byType(Container))
          .first;
      return (tester.widget<Container>(container).decoration!
              as BoxDecoration)
          .color!;
    }

    expect(bannerGlass(), const Color(0xB81B1713),
        reason: '浅色主题下横幅仍恒用暗面玻璃');

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: RemotePage(controller: controller),
    ));
    await tester.pumpAndSettle();
    expect(bannerGlass(), const Color(0xB81B1713),
        reason: '深色主题下横幅同一块暗面玻璃');
  });
}

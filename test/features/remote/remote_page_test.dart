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
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/intervalometer.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/remote/live_view_header.dart';
import 'package:nikon_pill/core/remote/peaking_engines.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/settings_store.dart';
import 'package:nikon_pill/design/app_theme.dart';
import 'package:nikon_pill/features/remote/feed_quality.dart';
import 'package:nikon_pill/features/remote/live_design.dart';
import 'package:nikon_pill/features/remote/live_view_overlays.dart';
import 'package:nikon_pill/features/remote/monitor_toggles.dart';
import 'package:nikon_pill/features/remote/remote_banner.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/remote_feed_area.dart';
import 'package:nikon_pill/features/remote/remote_info_pill.dart';
import 'package:nikon_pill/features/remote/remote_page.dart';
import 'package:nikon_pill/features/remote/remote_settings_panel.dart';
import 'package:nikon_pill/platform/volume_keys.dart';

/// 按序回放假传输(同 remote_controller_test;脚本耗尽抛 StateError,
/// 页面测试靠它兜住意外的多余请求)。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));

  /// 非应答码回放(PtpSession 层转 PtpResponseException 抛给调用方)。
  void reply(int responseCode) =>
      script.add(PtpResult(responseCode: responseCode));

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
  String? get deviceModel => null;

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

/// 音量键快门宿主假件:记录 setEnabled 推送,fire() 模拟原生 onKeyUp。
final class _FakeVolumeKeys implements VolumeKeyHost {
  final _ctrl = StreamController<VolumeKey>.broadcast();
  final calls = <bool>[];

  @override
  Stream<VolumeKey> get keys => _ctrl.stream;

  @override
  Future<void> setEnabled(bool enabled) async => calls.add(enabled);

  void fire() => _ctrl.add(VolumeKey.up);
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
/// 均可写;快门/ISO 值走厂商读码裸值,末尾自动 ISO 状态(0xD054,关)),
/// 与 remote_controller_test 同值。0xD1A6 模式镜像**打头**
/// ([d1a6]:0=照片/1=视频/null=不预置 —— 连接沿串链/进页对表都是模式读
/// 先于刷参,2026-10-11 真机反馈改制;重连流模式读应答预置在引擎重启
/// 对之前,参数块内不再带)。[mode] 参数化曝光模式(默认 M)。
/// 张数链首读(0xD1F1,refreshParams 打头,2026-10-16 改制)在 d1a6
/// 之后紧跟 —— [d1a6]=null 时它就是块首。
void _scriptParams(_ScriptTransport t,
    {int mode = 1, int? d1a6 = 0, bool tail = true}) {
  if (d1a6 != null) {
    t.ok(data: Uint8List.fromList([d1a6])); // 0xD1A6 模式镜像(链首读)
  }
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数(链首读)
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
    ..ok(data: Uint8List.fromList([0])) // 色调 u8(Ex 码 0x0001D01C;真域 [0,2],0=SDR)
    // 优化校准:FORM 驱动(pickValues 已撤,2026-10-07)→ desc 应答;
    // 枚举全静态表内 → 不触发 0x90CC 名字拉取
    ..ok(data: _propDescDataset(PtpDevicePropCode.activePicCtrlItem,
        PtpDataType.uint16, 1, enums: [1, 2, 3, 4]));
  if (tail) {
    t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
  }
}

/// 视频参数族应答块(页面版,2026-10-12 官方 §6.5.3/§6.5.12 目录落地):
/// 视频档连接沿/切换链尾补刷消费。FORM 驱动参数给 desc,直供参数裸值;
/// N-Log 只读。
void _scriptVideoParams(_ScriptTransport t) {
  const types = <int, PtpDataType>{
    PtpDevicePropCode.movieFnumber: PtpDataType.uint16,
    PtpDevicePropCode.movieShutterSpeed: PtpDataType.uint32,
    PtpDevicePropCode.movieExposureIndex: PtpDataType.uint32,
    PtpDevicePropCode.movieExposureBiasCompensation: PtpDataType.int16,
    PtpDevicePropCode.movieWhiteBalance: PtpDataType.uint16,
    PtpDevicePropCode.movieLogOutput: PtpDataType.uint8,
    PtpDevicePropCode.movieVibrationReduction: PtpDataType.uint8,
    PtpDevicePropCode.electronicVR: PtpDataType.uint8,
    PtpDevicePropCode.recordTimeCodes: PtpDataType.uint8,
    PtpDevicePropCode.timeCodeCountUpMethod: PtpDataType.uint8,
    PtpDevicePropCode.timeCodeDropFrame: PtpDataType.uint8,
    PtpDevicePropCode.movieCaptureAreaCrop: PtpDataType.uint8,
    PtpDevicePropCode.movieH265ToneMode: PtpDataType.uint8,
  };
  const values = <int, int>{
    PtpDevicePropCode.movieFnumber: 200,
    PtpDevicePropCode.movieShutterSpeed: 1 << 16 | 50,
    PtpDevicePropCode.movieExposureIndex: 100,
    PtpDevicePropCode.movieExposureBiasCompensation: 0,
    PtpDevicePropCode.movieWhiteBalance: 0x8015,
    PtpDevicePropCode.movieLogOutput: 0,
    PtpDevicePropCode.movieVibrationReduction: 0,
    PtpDevicePropCode.electronicVR: 0,
    PtpDevicePropCode.recordTimeCodes: 0,
    PtpDevicePropCode.timeCodeCountUpMethod: 0,
    PtpDevicePropCode.timeCodeDropFrame: 1,
    PtpDevicePropCode.movieCaptureAreaCrop: 0,
    PtpDevicePropCode.movieH265ToneMode: 0,
  };
  for (final param in kVideoShootingParams) {
    final type = types[param.code]!;
    final value = values[param.code]!;
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(param.code, type, value,
          getSet: param.code != PtpDevicePropCode.movieLogOutput));
    } else {
      final width = type.width!;
      t.ok(data: Uint8List.fromList(
          [for (var i = 0; i < width; i++) (value >> (8 * i)) & 0xFF]));
    }
  }
}

/// 视频档全量刷参块(消费序 = refreshParams 的
/// [d1a6? → 0xD1F1 → 照片参数 → 视频参数族 → 0xD054],张数链首读紧跟
/// 模式读,2026-10-16 改制)。
void _scriptParamsVideo(_ScriptTransport t, {int mode = 1, int? d1a6 = 0}) {
  _scriptParams(t, mode: mode, d1a6: d1a6, tail: false);
  _scriptVideoParams(t);
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
}

/// 挂起的 delay(永不完成):引擎帧轮询/AE 轮询在测试里驻停,
/// 不与被测路径抢脚本应答。
Future<void> _parkedDelay(Duration _) => Completer<void>().future;

/// 直挂拍摄页控制器(2026-10-10 取景默认打开后,直挂用例一律停摆引擎 +
/// 停摆 delay:进页自动起景的 0x9201 + 首帧两请求后一切驻停,真定时器
/// 不泄漏,后续脚本全归被测路径)。
RemoteController _directRemoteController(_ScriptTransport transport,
        {required _FakeConnection conn, bool Function()? setPropGate}) =>
    RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: _parkedDelay,
        setPropGate: setPropGate);

/// 直挂拍摄页的自动起景前置(FIFO 头两位:0x9201 + 首帧;initState 的
/// 自动起景同步入队 0x9201,首帧紧随其后,无初始延迟)。
void _scriptAutoStart(_ScriptTransport t) {
  t
    ..ok() // 0x9201(进页自动起景)
    ..ok(data: _realJpeg()); // 首帧(真实 JPEG,Image.memory 要渲染)
}

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
/// engine.header 驱动 AF 框叠层。[videoRemainingMs] 写 @816-819
/// (BE u32 毫秒,视频档胶囊「可录时长」用)。
Uint8List _headerObject({int? videoRemainingMs}) {
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
  if (videoRemainingMs != null) {
    b[816] = (videoRemainingMs >> 24) & 0xFF;
    b[817] = (videoRemainingMs >> 16) & 0xFF;
    b[818] = (videoRemainingMs >> 8) & 0xFF;
    b[819] = videoRemainingMs & 0xFF;
  }
  b[1024] = 0xFF;
  b[1025] = 0xD8;
  b[1026] = 0xFF;
  return b;
}

/// 横滚参数行 finder(2026-10-12 竖屏读出行删除后,仅用于断言「横滚行
/// 不复存在」)。
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
  testWidgets('参数区(设置浮层):目录值中文上屏,全目录 tile 一屏尽览',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 竖屏读出行已删(2026-10-12):全目录参数住设置浮层,tune 展开即出
    expect(_chipsRow, findsNothing, reason: '横滚读出行退场');
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 固定序打头(OpenZCine 顺序:模式/ISO/快门/光圈/释放/对焦模式…)
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('手动 M'), findsOneWidget);
    expect(find.text('ISO'), findsOneWidget, reason: 'ISO 小标签');
    expect(find.text('200'), findsOneWidget, reason: 'ISO 裸数值');
    expect(find.text('1/100s'), findsOneWidget);
    expect(find.text('f/2.8'), findsOneWidget);
    expect(find.text('单张'), findsOneWidget, reason: '释放');
    expect(find.text('AF-S'), findsOneWidget, reason: '对焦模式(单一对焦芯片)');
    // 其余目录值随 tile 平铺(设置浮层 SingleChildScrollView 全量构建,
    // 不复横滚懒构建)
    expect(find.text('自动'), findsOneWidget, reason: '白平衡');
    expect(find.text('5500K'), findsOneWidget, reason: '色温');
    expect(find.text('中央重点'), findsOneWidget, reason: '测光值表(尼康方言 2=中央重点)');
    expect(find.text('+0.3'), findsOneWidget, reason: 'EV');
    expect(find.text('关闭'), findsNWidgets(2),
        reason: '闪光与主体检测的值同字「关闭」');
    expect(find.text('RAW'), findsOneWidget, reason: '画质');
    expect(find.text('无损压缩'), findsOneWidget, reason: 'RAW 压缩值');
    expect(find.text('FX'), findsOneWidget, reason: '图像区域值');
    expect(find.text('标准'), findsOneWidget, reason: '优化校准值');
    // 目录余量照常上栏(2026-10-07:曾因 _stripOrder 不追加余量而整组不渲染)
    expect(find.text('单点'), findsOneWidget, reason: 'AF 区域 FORM 值');
    expect(find.text('SDR'), findsOneWidget, reason: '色调值');
    // 辅助开关同住设置浮层:对焦后拍 + APP 接管
    expect(find.text('对焦后拍'), findsOneWidget);
    expect(find.text('APP 接管'), findsOneWidget);
  });

  testWidgets('总闸紧急关断:全部参数芯片只读不可点', (tester) async {
    _portrait(tester);
    PtpSession.kSetPropEnabled = false; // 生产已开,显式关断走分支
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 参数 tile 在设置浮层(读出行已删):先展开
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final bigChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('光圈'), matching: find.byType(InkWell))
        .first);
    expect(bigChip.onTap, isNull, reason: '光圈 tile 不可点');
    final smallChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('模式'), matching: find.byType(InkWell))
        .first);
    expect(smallChip.onTap, isNull, reason: '参数 tile 不可点');
  });

  testWidgets('门禁开 + 可写:点小芯片 → 枚举单选 → 0x1016 写 + 回读上屏',
      (tester) async {
    _portrait(tester);
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸注入)
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
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

    // 白平衡 tile 在设置浮层:先展开再点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('白平衡'));
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
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport);
    transport
      ..ok() // 0x90C2 [1] 启用接管
      ..ok() // 0x1016 写 0xD100 = (1<<16)|250
      ..ok(data: _u32Bytes(1 << 16 | 125)); // 回读 0xD100 裸值
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 快门 tile 在设置浮层:先展开再点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快门').first); // tile 标签
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    // 辅助芯片收进控制行 tune 钮的设置浮层(手机相机式排版):
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
    // 「APP 接管中」两处:信息胶囊徽标 + 设置浮层芯片
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport, mode: 3); // 光圈优先 A:快门是自动曝光变量
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 参数 tile 在设置浮层:先展开
    await tester.tap(find.byIcon(Icons.tune));
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport); // M 模式,自动 ISO 关
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.isoAuto, isFalse);

    transport.ok(); // 0x90C2 [1] ISO 为拨盘级参数 → 面板接管区
    // ISO tile 在设置浮层:先展开再点(面板头即接管区)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ISO'));
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
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport); // EV PropDesc 无 FORM:无枚举无范围
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // EV tile 在设置浮层(全量构建,无横滚定位):展开直点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    // 首挂 active:false 页面自身不自动起景,但 connected 沿串链照发
    //(连接即监看,相机侧进取景;串链序 = 模式读打头 → 0x9201 + 首帧;
    // 帧轮询由页面可见性挂起)
    transport
      ..ok(data: Uint8List.fromList([0])) // 0xD1A6(连接链首读)
      ..ok() // 0x9201(connected 沿串链起景)
      ..ok(data: _realJpeg()); // 首帧
    _scriptParams(transport, d1a6: null); // 连接时全量(参数块)
    await tester.pumpWidget(
        MaterialApp(home: RemotePage(controller: controller, active: false)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.exposure?.fNumber, 280);

    // 切回 tab:引擎已在跑(connected 沿串链起景),回台沿只对表刷参
    //(0x9201 不再重发 —— autoLiveViewOnConnect 幂等门)
    _scriptParams(transport);
    await tester.pumpWidget(
        MaterialApp(home: RemotePage(controller: controller, active: true)));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView)
            .length,
        1,
        reason: '取景不重开,回台沿只刷参');
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
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
    // 对焦框回投:合焦绿框(0xFF2EC76B,机身屏同款;2026-10-12 用户需求
    // 「跟相机对齐」—— 合焦绿/未合焦红)描边方块画上屏
    const focusGreen = Color(0xFF2EC76B);
    expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) return false;
          final border = (w.decoration as BoxDecoration).border;
          return border is Border &&
              border.top.width == 2 &&
              border.top.color == focusGreen;
        }),
        findsOneWidget);
  });

  testWidgets('触控对焦未合焦(0xA002)→ 对焦框转红(2026-10-12 用户需求)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    transport
      ..ok() // changeAfArea
      ..reply(NikonResponseCode.outOfFocus); // afDrive 未合焦
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(controller.afBox!.focused, isFalse, reason: '0xA002 → 未合焦');
    expect(controller.error, contains('未合焦'));
    // 对焦框回投:未合焦红框(画面内容层恒暗面 → LiveDesign.dark.bad)
    expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) return false;
          final border = (w.decoration as BoxDecoration).border;
          return border is Border &&
              border.top.width == 2 &&
              border.top.color == LiveDesign.dark.bad;
        }),
        findsOneWidget,
        reason: '未合焦红框');
  });

  testWidgets('双指缩放:外扩即放大出角标,角标/双击复位,内收不小于适配',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    // 十二轮起开关组持久化:注入裸 ValueNotifier 隔离 AppServices 共享
    // 单例(开关写回不再泄漏给同文件后续用例)。
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-dial-rail')), findsNothing,
        reason: '默认不占取景画面');

    // 设置钮开设置浮层 → 开「拉焦轮」(2026-10-12 拉焦轮迁入设置浮层)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉焦轮'));
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('focus-dial-rail'));
    expect(rail, findsOneWidget, reason: '开关即出竖条');

    // 浮层开着时点空白收浮层的满铺手势层会挡住画面手势(拉焦轮拖动也
    // 在其下)—— 收掉浮层再拖
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 竖拖(分两段:首段 20px 越过触摸 slop 起手势 —— 该段不入拖距;
    // 第二段干净 30px > 一步 24px)→ 0x9204 向近 300 脉冲
    transport
      ..ok() // 0x9204 激活
      ..ok(); // 0x90C8 就绪探:完成
    final g = await tester.startGesture(tester.getCenter(rail));
    await g.moveBy(const Offset(0, 20)); // 越过 slop,起手势
    await tester.pump();
    await g.moveBy(const Offset(0, 30)); // +30 → 一步
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final mf = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.mfDrive);
    expect(mf.params, [1, 300],
        reason: '向下拖 = 向近一步(24px → 300 脉冲,真机可见量)');
    expect(controller.dialNetPulses.value, 300, reason: '刻度鼓派发即入账');

    // 点轮子本体不触发触控对焦(自吃点按)
    await tester.tap(rail);
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '轮子点按不落到画面手势');
  });

  testWidgets('拉焦轮端点态:0xA00C 后轮身压暗,反向拖一步即解锁复亮',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 开拉焦轮(设置浮层),收浮层再拖。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉焦轮'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('focus-dial-rail'));
    Opacity railOpacity() => tester.widget<Opacity>(
        find.descendant(of: rail, matching: find.byType(Opacity)).first);
    expect(railOpacity().opacity, 1.0, reason: '常态全亮');

    // 向近拖一步 → 0xA00C → 近端锁定:轮身压暗(既有 MF 门控 0.35 形态)。
    transport.reply(NikonResponseCode.mfDriveStepEnd);
    final g = await tester.startGesture(tester.getCenter(rail));
    await g.moveBy(const Offset(0, 20)); // 越过 slop,起手势
    await tester.pump();
    await g.moveBy(const Offset(0, 30)); // +30 → 向近一步
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(controller.mfNearEnd, isTrue);
    expect(railOpacity().opacity, 0.35, reason: '端点态轮身压暗');

    // 锁定方向继续拖:静默丢增量,零新流量(端点锁不发令)。
    int mfCount() => transport.requests
        .where((r) => r.opcode == NikonOperationCode.mfDrive)
        .length;
    final countBefore = mfCount();
    final g2 = await tester.startGesture(tester.getCenter(rail));
    await g2.moveBy(const Offset(0, 20));
    await tester.pump();
    await g2.moveBy(const Offset(0, 30));
    await tester.pump();
    await g2.up();
    await tester.pumpAndSettle();
    expect(mfCount(), countBefore, reason: '近端已锁:向近增量静默丢弃');

    // 反向(向上)拖一步 → 解锁 + 驱动成功 → 复亮。
    transport
      ..ok() // 0x9204 激活
      ..ok(); // 0x90C8 就绪探:完成
    final g3 = await tester.startGesture(tester.getCenter(rail));
    await g3.moveBy(const Offset(0, -20)); // 越过 slop
    await tester.pump();
    await g3.moveBy(const Offset(0, -30)); // -30 → 向远一步
    await tester.pump();
    await g3.up();
    await tester.pumpAndSettle();
    expect(railOpacity().opacity, 1.0, reason: '反向驱动解锁,复亮');
    final mf = transport.requests
        .lastWhere((r) => r.opcode == NikonOperationCode.mfDrive);
    expect(mf.params, [2, 300], reason: '解锁后的向远一步照发');
    expect(controller.dialNetPulses.value, 0,
        reason: '刻度鼓:向近 +300、向远 -300 对冲归零(端点锁定拖动不派发不入账)');
  });

  testWidgets('对焦区端点提示行:0xA00C 后常驻「近端已到」,反向步进即清',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 开设置浮层:MF 步进向近 → 0xA00C → 端点常驻提示行(对焦区)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    transport.reply(NikonResponseCode.mfDriveStepEnd);
    await tester.tap(find.text('MF 近'));
    await tester.pumpAndSettle();
    expect(controller.mfNearEnd, isTrue);
    expect(find.text('近端已到,反向驱动解锁'), findsOneWidget,
        reason: '常驻提示行形态(对焦区,0xA00C 向近归因)');

    // 反向步进(向远)成功 → 提示行随解锁消失。
    transport
      ..ok() // 0x9204 激活
      ..ok(); // 0x90C8 就绪探:完成
    await tester.tap(find.text('MF 远'));
    await tester.pumpAndSettle();
    expect(controller.mfNearEnd, isFalse);
    expect(find.text('近端已到,反向驱动解锁'), findsNothing);
    expect(find.text('远端已到,反向驱动解锁'), findsNothing);
  });

  testWidgets('画质档路由:默认关 = 低采样 Image;高质量 → ShaderFeed',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    final settings = ValueNotifier<AppSettings>(const AppSettings());

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
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

  testWidgets('监看 LUT 路由:选中即 ShaderFeed(画质档关也走 shader 查表路)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    final settings = ValueNotifier<AppSettings>(const AppSettings());

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderFeed), findsNothing);

    // 选内置 LUT(索引 0):off 档也自动走 shader 路(查表只在片元路径)
    settings.value = const AppSettings(monitorLutIndex: 0);
    await tester.pump();
    expect(find.byType(ShaderFeed), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 关 LUT:回落原路(off = 低采样 Image)
    settings.value = const AppSettings();
    await tester.pump();
    expect(find.byType(ShaderFeed), findsNothing);
  });

  testWidgets('示波器族:芯片循环四档随小盒分派,刻度行门控,分析器启停同步',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    _scriptAutoStart(transport);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(find.byType(ScopeView), findsNothing);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 关 → 波形:分析器启用(共享帧分析),波形小盒上屏 + 刻度行现
    await tester.tap(find.text('示波器'));
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isTrue,
        reason: '示波器共享帧分析,必须同步启用分析器,否则永远无数据');
    expect(find.byType(WaveformView), findsOneWidget);
    expect(find.text('波形'), findsOneWidget, reason: '芯片标签随档换字');
    expect(find.text('示波器刻度'), findsOneWidget, reason: '波形档吃 Y 轴刻度');
    expect(find.text('全幅'), findsOneWidget);
    expect(settings.value.monitorScope, ScopeKind.waveform.index);

    // 波形 → RGB:Parade 小盒上屏,刻度行仍在(Parade 同吃)
    await tester.tap(find.text('波形'));
    await tester.pumpAndSettle();
    expect(find.byType(ParadeView), findsOneWidget);
    expect(find.text('示波器刻度'), findsOneWidget);

    // RGB → 矢量
    await tester.tap(find.text('RGB'));
    await tester.pumpAndSettle();
    expect(find.byType(VectorView), findsOneWidget);
    expect(find.text('示波器刻度'), findsNothing,
        reason: '矢量盘无 Y 轴,刻度行收');

    // 矢量 → 红绿灯
    await tester.tap(find.text('矢量'));
    await tester.pumpAndSettle();
    expect(find.byType(TrafficLightsView), findsOneWidget);
    // 带标签经 t() 注入(画布绘制,find.text 不可见,查 widget 参数)
    expect(
        tester
            .widget<TrafficLightsView>(find.byType(TrafficLightsView))
            .bandLabels,
        const ['上部', '中部', '下部'],
        reason: '带标签注入(可译:显示点包 t())');

    // 红绿灯 → 关:分析器停(无其他监看开关在开),小盒退场
    await tester.tap(find.text('红绿灯'));
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isFalse);
    expect(find.byType(ScopeView), findsNothing);
    expect(find.text('示波器'), findsOneWidget, reason: '芯片回到关档标签');
    expect(settings.value.monitorScope, ScopeKind.off.index);
  });

  testWidgets('示波器 N-Log 刻度:波形档双芯片落盘 + 小盒换刻度(手动档)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    _scriptAutoStart(transport);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('示波器')); // 开波形
    await tester.pumpAndSettle();
    expect(settings.value.monitorScopeNLog, isFalse, reason: '默认全幅刻度');
    expect(
        tester.widget<WaveformView>(find.byType(WaveformView)).nLogScale,
        isFalse);

    // 切 N-Log:落盘 + 小盒刻度参数跟切(IRE 线 + 18% 灰虚线路径)
    await tester.tap(find.text('N-Log'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorScopeNLog, isTrue);
    expect(
        tester.widget<WaveformView>(find.byType(WaveformView)).nLogScale,
        isTrue);
    expect(tester.takeException(), isNull);

    // 切回全幅
    await tester.tap(find.text('全幅'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorScopeNLog, isFalse);
    expect(
        tester.widget<WaveformView>(find.byType(WaveformView)).nLogScale,
        isFalse);
  });

  testWidgets('峰值档位:开关门控选项行,灵敏度同步分析器阈值,颜色入叠层',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 峰值关:选项行不占面板
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('峰值灵敏度'), findsNothing);
    expect(find.text('峰值颜色'), findsNothing);

    // 开峰值:分析器启用 + 阈值 = 中档 40(默认,旧行为)+ 叠层金边
    await tester.tap(find.byIcon(Icons.blur_on)); // 峰值
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isTrue);
    expect(controller.analyzer.peakingThreshold, 40,
        reason: '默认中档 = 旧写死阈值');
    expect(find.text('峰值灵敏度'), findsOneWidget);
    expect(find.text('峰值颜色'), findsOneWidget);
    expect(find.text('峰值算法'), findsOneWidget);
    // 缺省引擎 = 双尺度(2026-10-15 新默认),参数 = 中档 2.10/450
    expect(controller.analyzer.peakingEngine, PeakingEngine.dualScale);
    expect(controller.analyzer.peakingRatioThreshold, 2.10);
    expect(controller.analyzer.peakingNoiseGate, 450);
    expect(tester.widget<PeakingOverlay>(find.byType(PeakingOverlay)).color,
        const Color(0xFFE9AC35),
        reason: '默认金 = 旧行为');

    // 选「高」→「低」:设置落档,阈值 64 / 24 同步分析器;双尺度
    // 参数随档同向(高 2.30/1200 → 低 1.90/160)
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorPeakingLevel, 2);
    expect(controller.analyzer.peakingThreshold, 64);
    expect(controller.analyzer.peakingRatioThreshold, 2.30);
    expect(controller.analyzer.peakingNoiseGate, 1200);
    await tester.tap(find.text('低'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorPeakingLevel, 0);
    expect(controller.analyzer.peakingThreshold, 24);
    expect(controller.analyzer.peakingRatioThreshold, 1.90);
    expect(controller.analyzer.peakingNoiseGate, 160);

    // 选「经典」:引擎切回单尺度梯度(手感回退),灵敏度档照旧生效
    await tester.tap(find.text('经典'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorPeakingEngine, 1);
    expect(controller.analyzer.peakingEngine, PeakingEngine.gradient);
    expect(controller.analyzer.peakingThreshold, 24,
        reason: '经典引擎仍吃灵敏度档(低档 24)');
    // 切回「双尺度」:缺省引擎回归
    await tester.tap(find.text('双尺度'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorPeakingEngine, 0);
    expect(controller.analyzer.peakingEngine, PeakingEngine.dualScale);

    // 选「红」:设置落档,叠层换色
    await tester.tap(find.text('红'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorPeakingColor, 2);
    expect(tester.widget<PeakingOverlay>(find.byType(PeakingOverlay)).color,
        LiveDesign.dark.bad);

    // 关峰值:选项行随退场(开关收行,不留孤儿档位)
    await tester.tap(find.byIcon(Icons.blur_on));
    await tester.pumpAndSettle();
    expect(find.text('峰值灵敏度'), findsNothing);
    expect(find.byType(PeakingOverlay), findsNothing);
  });

  testWidgets('构图遮幅:芯片循环 off→2.39→2.35→1.85,遮幅层随开关上屏',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byType(FramingOverlay), findsNothing);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('遮幅'));
    await tester.pumpAndSettle();
    expect(find.text('遮幅 2.39'), findsOneWidget,
        reason: 'off → 2.39 循环首站');
    expect(find.byType(FramingOverlay), findsOneWidget);

    // 2.39 → 2.35 → 1.85 → off:回到 off 全退
    await tester.tap(find.text('遮幅 2.39'));
    await tester.pumpAndSettle();
    expect(find.text('遮幅 2.35'), findsOneWidget);
    await tester.tap(find.text('遮幅 2.35'));
    await tester.pumpAndSettle();
    expect(find.text('遮幅 1.85'), findsOneWidget);
    expect(find.byType(FramingOverlay), findsOneWidget);
    await tester.tap(find.text('遮幅 1.85'));
    await tester.pumpAndSettle();
    expect(find.text('遮幅'), findsOneWidget);
    expect(find.byType(FramingOverlay), findsNothing,
        reason: 'off + 安全框/中心标全关 → 层整体退场');
  });

  testWidgets('「对焦后拍」开关:横滚行尾,点选即切换(零相机流量)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧入账)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.focusBeforeCapture, isFalse);
    final requestsBefore = transport.requests.length;
    // 对焦后拍收进控制行 tune 钮的设置浮层:开面板再点
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('对焦后拍'));
    await tester.pumpAndSettle();
    expect(controller.focusBeforeCapture, isTrue);
    expect(transport.requests.length, requestsBefore,
        reason: '纯本地开关,开关前后零相机流量');
  });

  testWidgets('监看辅助开关:直方图等四个分析开关须同步启用帧分析器'
      '(直方图无数据回归)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.analyzer.enabled.value, isFalse);

    // 监看开关收进控制行 tune 钮的设置浮层:开面板后点
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);

    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧,SOF 入册)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
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
    expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! BoxDecoration) {
            return false;
          }
          final border = (w.decoration as BoxDecoration).border;
          return border is Border && border.top.width == 2;
        }),
        findsNothing,
        reason: '头在册 = 相机真实框已在屏,占位框再画即双框');
  });

  testWidgets('录制读出:时间码+电平表随帧头上屏,显示关/待机静音退场',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byType(TimecodeView), findsNothing);
    expect(find.byType(AudioMetersView), findsNothing,
        reason: '零头(无录制读出域)不显示');

    // ① 录制中 + 机身时间码显示开:读数即帧头字节(@824-827 电平、
    // @828 录制、@831-835 时码)。
    final rec = _headerObject();
    rec[824] = 9; // L 峰值保持
    rec[825] = 9;
    rec[826] = 5; // L 当前
    rec[827] = 0; // R 静音(录制中也常驻 —— 静音正是要看见的)
    rec[828] = 1; // 录制中
    rec[831] = 1; // 时间码显示开
    rec[832] = 1;
    rec[833] = 23;
    rec[834] = 45;
    rec[835] = 12;
    controller.engine.header.value = parseLiveViewHeader(rec);
    await tester.pump();
    expect(find.text('01:23:45:12'), findsOneWidget);
    expect(find.byType(AudioMetersView), findsOneWidget);

    // ② 机身时间码显示关 + 待机零电平:读出随帧头退场(画面照常)。
    controller.engine.header.value = parseLiveViewHeader(_headerObject());
    await tester.pump();
    expect(find.byType(TimecodeView), findsNothing);
    expect(find.byType(AudioMetersView), findsNothing);

    // ③ 机身自报过热(@853=4)+ 倒计时(@836=30):过热徽章单独上屏
    // (时间码关、零电平也不连坐 —— 温度警告是独立的信息)。
    final hot = _headerObject();
    hot[853] = 4; // 过热「倒计时显示」态
    hot[836] = 0;
    hot[837] = 30; // BE u16 = 30s
    controller.engine.header.value = parseLiveViewHeader(hot);
    await tester.pump();
    expect(find.byType(OverheatBadge), findsOneWidget);
    expect(find.text('即将自动停止录制 0:30'), findsOneWidget);
    expect(find.byType(TimecodeView), findsNothing,
        reason: '时间码显示关不连坐过热徽章');

    // ④ 过热解除(@853=0):徽章退场。
    controller.engine.header.value = parseLiveViewHeader(_headerObject());
    await tester.pump();
    expect(find.byType(OverheatBadge), findsNothing);
  });

  testWidgets('竖屏 iPhone 相机式排版:控制行三键(对焦|快门|设置)+ 底行'
      '(相册|模式条|旋转),参数收设置浮层,隐藏/恢复同位两段淡出',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    // 参数读出行已删(2026-10-12 用户需求):横滚行退场,参数在设置浮层
    expect(_chipsRow, findsNothing);
    expect(find.text('模式'), findsNothing, reason: '参数 tile 不在树(浮层未开)');

    // 画面全幅铺底恒满宽(2026-10-12「竖拍不留侧黑边」):feed 盒整屏
    // 800×2400(底区两行是压画面下沿的浮层,不再分高),32×24 内容
    // widthFill(scale 800/32 = 25)→ 800×600 恒满宽(left 0 / width 800)
    // 垂直居中 y 900..1500 —— 两侧永无黑边。
    expect(tester.getSize(find.byType(RemoteFeedArea)),
        const Size(800, 2400),
        reason: '取景盒全幅铺底(整屏,不与底区分高)');
    final imageRect = tester.getRect(find.byType(Image).first);
    expect(imageRect.left, closeTo(0, 0.01),
        reason: 'widthFill 恒满宽:左无黑边');
    expect(imageRect.width, closeTo(800, 0.01),
        reason: 'widthFill 恒满宽:右无黑边');
    expect(imageRect.height, closeTo(600, 0.01));
    expect(imageRect.top, closeTo(900, 0.01), reason: '32×24 内容垂直居中');

    // 控制行三键自左向右:对焦 | 快门(78)| 设置
    final focus = find.byIcon(Icons.center_focus_strong);
    final shutter = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 78 && w.height == 78);
    final tune = find.byIcon(Icons.tune);
    var lastDx = -1.0;
    for (final f in [focus, shutter, tune]) {
      expect(f, findsOneWidget);
      final dx = tester.getCenter(f).dx;
      expect(dx, greaterThan(lastDx), reason: '控制行按键自左向右居排');
      lastDx = dx;
    }

    // 底行三键自左向右:相册 | 模式条(照片|视频)| 旋转;模式条在快门
    // 下方(2026-10-12 用户需求),且整条水平居中
    final album = find.byIcon(Icons.photo_library_outlined);
    final rotation = find.byIcon(Icons.screen_rotation);
    expect(album, findsOneWidget);
    expect(rotation, findsOneWidget);
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(tester.getCenter(album).dx,
        lessThan(tester.getCenter(find.text('照片')).dx));
    expect(tester.getCenter(find.text('视频')).dx,
        lessThan(tester.getCenter(rotation).dx));
    expect(
        (tester.getCenter(find.text('照片')).dx +
                tester.getCenter(find.text('视频')).dx) /
            2,
        closeTo(400, 1),
        reason: '模式条居中(两侧 54px 钮对称,两段文字中点即条心)');
    expect(tester.getCenter(find.text('照片')).dy,
        greaterThan(tester.getCenter(shutter).dy),
        reason: '模式条在快门下方');

    // 九轮边距统一 + 手调(2026-10-12 破安全区 + 「左右两侧按钮离边的
    // 距离和离下方的距离保持一致」):左右与屏底统一 [kScreenEdgePadding]
    // (九轮定 20,用户手调 30;层锚 bottom:,行内不垫底)。
    // 54 钮心 = 边距+27;底行钮心 = 2400-30-27(底行 padding bottom 0)。
    expect(tester.getCenter(focus).dx, 57, reason: '对焦钮距左缘 30(30+27)');
    expect(tester.getCenter(rotation).dx, 743, reason: '旋转钮距右缘 30');
    expect(tester.getCenter(album).dx, 57, reason: '相册钮距左缘 30');
    expect(tester.getCenter(rotation).dy, 2343,
        reason: '旋转钮物理屏缘 30(2400-30-27)');

    // 旧动作行文案退场:取景默认开、录像并快门、MF 步进在设置浮层
    expect(find.text('取景'), findsNothing);
    expect(find.text('录制'), findsNothing);
    expect(find.text('MF'), findsNothing);

    // 隐藏钮在信息胶囊行尾(右上角);隐藏后恢复钮出现在同一处
    final hide = find.byIcon(Icons.visibility_off);
    expect(hide, findsOneWidget, reason: '信息胶囊行尾纯净监看钮');
    final hideCorner = tester.getTopRight(hide);
    await tester.tap(hide);
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
    final restore = find.byIcon(Icons.visibility);
    expect(restore, findsOneWidget, reason: '恢复钮现身');
    final restoreCorner = tester.getTopRight(restore);
    expect(restoreCorner.dx, closeTo(hideCorner.dx, 20),
        reason: '隐藏/恢复同位(右上角,横向)');
    expect(restoreCorner.dy, closeTo(hideCorner.dy, 10),
        reason: '隐藏/恢复同位(纵向)');
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: 'chrome 回来');

    // 辅助开关收进设置浮层:默认不在树,tune 展开即出
    expect(find.text('对焦后拍'), findsNothing);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('对焦后拍'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget, reason: '监看开关入设置浮层');
  });

  testWidgets('横屏监看:取景盒左缩 60(画面右移 30)/右缩 118 让柱、'
      'heightFill 满高无黑边,快门柱五件贴右缘共轴于快门心且快门同竖屏 78'
      '(旋转在顶/相册坠底),模式条独占贴底,信息胶囊定宽居中取景盒与'
      '模式条同轴线、顶底同高 38 同距 6,设置浮层让位快门柱', (tester) async {
    _landscape(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    // 单 FIFO 按消费顺序入队:进页自动起景(0x9201+首帧)先于连接沿的
    // 对表刷参,AF 点按两应答随后。
    _scriptAutoStart(transport);
    _scriptParams(transport);
    transport
      ..ok() // changeAfArea(浮层收起后再点画面)
      ..ok(); // afDrive
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue, reason: '进页自动起景');

    // 取景盒**左缩 60 + 右缩 118**(右 = 快门柱让位:柱右距物理屏缘 30
    // ([kScreenEdgePadding] 手调值),柱带宽 30+78=108 + 10 间隙;
    // 左 = 九轮「取景往右侧移动一点」):feed 盒 60..1482(宽 1422),
    // Image 住在图像坐标系(32×24)经 Transform 投到屏幕 —— heightFill
    // 恒满高(scale 800/24 = 33.33…):上下永无黑边(top 0 / height 800),
    // 宽 32×33.33 = 1066.67 在盒内居中左右各留 177.67 → 画面左缘
    // 237.67(较左缩前右移 30)、右缘 1304.33 恒在柱带(1482..1600)
    // 之左;16:9 视频满高宽 1422.22 仅越盒 0.22(双侧各裁 0.11,
    // 不可见)。
    final imageRect = tester.getRect(find.byType(Image).first);
    expect(imageRect.top, closeTo(0, 0.01),
        reason: 'heightFill 恒满高:上无黑边');
    expect(imageRect.height, closeTo(800, 0.01),
        reason: 'heightFill 恒满高:下无黑边');
    expect(imageRect.left, closeTo(60 + (1422 - 3200 / 3) / 2, 0.01),
        reason: '画面右移 30(盒左缩 60,内容盒内居中)');
    expect(imageRect.width, closeTo(3200 / 3, 0.01));
    expect(imageRect.right, lessThan(1600 - 118), reason: '画面不进快门柱带');

    // 左参数栏已删(2026-10-12 二轮「把左侧的参数调整删了」):参数唯一
    // 入口 = 设置浮层全目录;竖向滚动列表(原 ParamRail)不在树。
    expect(
        find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down),
        findsNothing,
        reason: '左参数竖列已删');
    expect(_chipsRow, findsNothing);
    expect(find.text('模式'), findsNothing, reason: '参数 tile 不在树(浮层未开)');

    // 快门柱五件竖排贴右缘全高中置(2026-10-12 用户定案柱序自上而下
    // 旋转/设置/快门 78/对焦/相册 —— 方向钮自贴底条迁入柱顶,相册坠底;
    // 快门两向同 78 = 用户定案「横屏按钮保持和竖屏大小一样」):柱内容
    // 326(54+8+54+8+78+8+54+8+54)在 800 高屏居中(y 237..563)。
    // 十轮:五件**共轴于快门心**(crossAxisAlignment.center,用户
    // 「以拍照按钮居中对齐,而不是右边对齐」,废除右缘齐平/凸左);
    // 柱右距物理屏缘 30(kScreenEdgePadding 手调值)→ 共轴
    // 1600-30-39 = 1531。
    final rotation = find.byIcon(Icons.screen_rotation);
    final tune = find.byIcon(Icons.tune);
    final shutter = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 78 && w.height == 78);
    final focus = find.byIcon(Icons.center_focus_strong);
    final album = find.byIcon(Icons.photo_library_outlined);
    final column = [
      (rotation, 1531.0, '旋转'),
      (tune, 1531.0, '设置'),
      (shutter, 1531.0, '快门'),
      (focus, 1531.0, '对焦'),
      (album, 1531.0, '相册'),
    ];
    var lastDy = -1.0;
    for (final (f, dx, label) in column) {
      expect(f, findsOneWidget);
      final c = tester.getCenter(f);
      expect(c.dx, dx,
          reason: '$label 柱位(右缘齐平距物理屏缘 20,同竖屏底距)');
      expect(c.dy, greaterThan(lastDy),
          reason: '柱序自上而下 旋转/设置/快门/对焦/相册');
      lastDy = c.dy;
    }
    expect(tester.getCenter(shutter).dy, 400, reason: '快门在屏心(全高中置)');
    expect(tester.getCenter(rotation).dy, closeTo(264, 1), reason: '旋转在柱顶');
    expect(tester.getCenter(album).dy, closeTo(536, 1), reason: '相册坠柱底');

    // 信息胶囊定宽居中于取景盒(2026-10-12 用户定案「这一个按钮居中」;
    // 八轮定案与贴底模式条同轴线 —— 顶栏与盒同缩(左 60/右 118),
    // 盒心 = (60+1482)/2 = 771;九轮定宽 [kLandscapePillWidth](手调 460):
    // 胶囊内部 Spacer 拉开,隐藏钮贴行尾;十轮胶囊高 38、顶距 6,
    // 与贴底模式条 6+38 上下镜像「和底部一致」)。
    expect(tester.getSize(find.byType(RemoteInfoPill)).width,
        kLandscapePillWidth,
        reason: '胶囊定宽(九轮「长一点约为现在的两倍」,值手调)');
    expect(tester.getSize(find.byType(RemoteInfoPill)).height, 38,
        reason: '胶囊高 38,与贴底模式条同高(十轮「和底部一致」)');
    expect(
        tester.getCenter(find.byType(RemoteInfoPill)).dx,
        closeTo((60 + 1600 - 118) / 2, 1),
        reason: '胶囊居中于取景盒(与贴底模式条同轴线)');
    final hide = find.byIcon(Icons.visibility_off);
    expect(hide, findsOneWidget, reason: '胶囊行尾纯净监看钮');
    expect(tester.getCenter(hide).dx, greaterThan((60 + 1600 - 118) / 2),
        reason: '隐藏钮在胶囊行尾(取景盒心之右)');
    expect(tester.getCenter(hide).dx,
        lessThan((60 + 1600 - 118) / 2 + kLandscapePillWidth / 2),
        reason: '隐藏钮不越定宽胶囊右缘');
    expect(tester.getCenter(hide).dy, lessThan(44),
        reason: '在顶栏带内(6..44,与贴底镜像)');

    // 贴底条:模式条独占、居中于取景盒(旋转钮已迁柱顶;两段文字中点
    // 即条心)
    expect(find.text('照片'), findsOneWidget, reason: '贴底模式条');
    expect(
        (tester.getCenter(find.text('照片')).dx +
                tester.getCenter(find.text('视频')).dx) /
            2,
        closeTo((60 + 1600 - 118) / 2, 1),
        reason: '模式条居中于取景盒(与顶栏胶囊同轴线)');

    // 设置浮层:tune 展开 → 监看开关在树;让位右缘快门柱(right: 118)
    expect(find.byIcon(Icons.grid_on), findsNothing, reason: '默认收起');
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_on), findsOneWidget, reason: '面板开');

    // 点空白即收浮层(满铺手势层贪吃这一拍,不触发触控对焦);AF 应答
    // 在队但尚未消费。
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_on), findsNothing, reason: '点画面收起面板');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '收浮层这一拍被垫层贪吃');
    // 画幅左沿外的 letterbox 空白再点:出界点不挪对焦框(2026-10-16
    // 用户定案),不发 0x9205。
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '框外点按不触控对焦');
    // 点画面中心照常触控对焦:heightFill 纵向满高线性,横向盒内居中
    // (画面中心即盒心 771)→ 归一 (0.5, 0.5) → whole-size 32×24 → [16,12]。
    await tester.tapAt(const Offset(771, 400));
    await tester.pumpAndSettle();
    final af = transport.requests.singleWhere(
        (r) => r.opcode == NikonOperationCode.changeAfArea);
    expect(af.params, [16, 12]);
  });

  testWidgets('横屏纯净监看:控制浮层淡出放行点击,可一键恢复',
      (tester) async {
    _landscape(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
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
    // 引擎已在跑(首挂自动起景)→ 重建的 initState 走「进页对表」沿,
    // 预置参数脚本。
    _scriptParams(transport);
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
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
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)

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

  testWidgets('取景默认打开:进页零点按,恰一条 0x9201 + 首帧上屏',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 0x9201 + 首帧(本测的全部脚本)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    expect(controller.liveViewActive, isTrue, reason: '未点任何按钮即取景中');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '进页自动起景恰一条 0x9201');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
        hasLength(1),
        reason: '首帧恰一条 0x9428(取帧主力码;此后停摆 delay 驻停)');
    expect(find.byType(Image), findsOneWidget, reason: '首帧已上屏');
  });

  testWidgets('拍照/录像合一:模式条切视频 → 红芯快门整段点按起/停录像,'
      '录制中锁模式', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok() // 0x920A 起录
      ..ok(); // 0x920B 停录
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue);

    final shutter = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 78 && w.height == 78);
    expect(shutter, findsOneWidget);
    // 快门芯(圆芯 Container,ring 无色不计)
    Color coreColor() => (tester.widget<Container>(find
                .descendant(
                    of: shutter,
                    matching: find.byWidgetPredicate((w) =>
                        w is Container &&
                        w.decoration is BoxDecoration &&
                        (w.decoration as BoxDecoration).shape ==
                            BoxShape.circle &&
                        (w.decoration as BoxDecoration).color != null))
                .first)
            .decoration as BoxDecoration)
        .color!;

    // 照片模式:芯非红
    expect(coreColor(), isNot(LiveDesign.light.bad));
    // 切视频模式:本地直切(相机模式不在表 → 无门无面板),红芯
    //(iPhone 语义,进入即红非仅录制中)
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing, reason: '本地回落不弹面板');
    expect(coreColor(), LiveDesign.light.bad);

    // 整段点按起录:0x920A 恰一条,recording 真,芯内白色停止方块
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(controller.recording, isTrue);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startMovieRecInCard),
        hasLength(1));
    expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == Colors.white &&
            (w.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(4)),
        findsOneWidget,
        reason: '录制中芯内白色停止方块');
    expect(find.textContaining('REC'), findsOneWidget, reason: 'REC 时长入胶囊');

    // 录制中模式条锁:点「照片」无效(条已 IgnorePointer,命中被吞即
    // 证锁;停录入口不被模式切换甩开)
    await tester.tap(find.text('照片'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(coreColor(), LiveDesign.light.bad, reason: '录制中模式条锁死');

    // 再点快门停录:0x920B 恰一条
    await tester.tap(shutter);
    await tester.pumpAndSettle();
    expect(controller.recording, isFalse);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endMovieRec),
        hasLength(1));
  });

  testWidgets('模式条跟相机:连接读到视频档 → 视频段选中(红芯),照片段可切'
      '(0xD1A6 镜像,2026-10-11 Zf 实证)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParamsVideo(transport, d1a6: 1); // 连接沿读到视频档(全量含视频族)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    Color labelColor(String text) =>
        tester.widget<Text>(find.text(text)).style!.color!;
    expect(labelColor('视频'), LiveDesign.light.accent, reason: '视频段选中');
    expect(labelColor('照片'), LiveDesign.light.muted,
        reason: '视频档 → 照片可远程覆写,常灰度可切');

    // 快门芯随真模式红芯(不是页面本地态 —— 本页从未点过模式条)
    final shutter = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 78 && w.height == 78);
    expect(shutter, findsOneWidget);
    final core = (tester.widget<Container>(find
                .descendant(
                    of: shutter,
                    matching: find.byWidgetPredicate((w) =>
                        w is Container &&
                        w.decoration is BoxDecoration &&
                        (w.decoration as BoxDecoration).shape ==
                            BoxShape.circle &&
                        (w.decoration as BoxDecoration).color != null))
                .first)
            .decoration as BoxDecoration)
        .color!;
    expect(core, LiveDesign.light.bad, reason: '相机在视频档 → 红芯');
  });

  testWidgets('照片档连接:未接管点「视频」弹接管门(同点 ISO),启用后'
      '自动走切换链;已接管再点直切零面板(2026-10-12 R2 修正)', (tester) async {
    _portrait(tester);
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    _scriptParams(transport); // d1a6=0 照片档
    // ① 接管门「启用」→ 切换链:0x90C2(1) → 0x9202 → 写 D1A6=1 →
    //    0x9201 → 首帧 → 刷参
    transport
      ..ok() // 0x90C2(1) 接管(接管门「启用」)
      ..ok() // 0x9202 停景
      ..ok() // 0x1016 写 0xD1A6=1
      ..ok() // 0x9201 起景
      ..ok(data: _realJpeg()); // 首帧
    _scriptParamsVideo(transport, d1a6: null); // 切到视频:刷参含视频族
    // ② 已接管直切(视频 → 照片):0x9202 → 写 D1A6=0 → 0x9201 → 首帧 →
    //    刷参(0x90C2 不重发)
    transport
      ..ok() // 0x9202
      ..ok() // 0x1016 D1A6=0
      ..ok() // 0x9201
      ..ok(data: _realJpeg()); // 首帧
    _scriptParams(transport, d1a6: null); // 刷参
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    Color labelColor(String text) =>
        tester.widget<Text>(find.text(text)).style!.color!;
    expect(labelColor('照片'), LiveDesign.light.accent, reason: '照片段选中');

    // 未接管:点「视频」→ 接管门底单(启用 APP 接管控制?),不是选择列表
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.text('启用 APP 接管控制?'), findsOneWidget,
        reason: '接管门(同点 ISO 未接管时)');
    expect(find.text('拍摄模式'), findsOneWidget, reason: '门头标');

    // 「启用」:0x90C2(1) → 底单收口 → 自动切换链 → 视频档(写 1)
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing, reason: '底单收口');
    expect(controller.takeoverActive, isTrue);
    expect(controller.cameraMode, CaptureMode.video);
    expect(controller.modeOverridden, isTrue,
        reason: '写过即遮蔽(拨杆真档仍在照片)');
    expect(labelColor('视频'), LiveDesign.light.accent, reason: '模式条跟到视频');

    // 已接管:再点「照片」直切,零面板(不弹接管门/选择)
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing, reason: '已接管零面板');
    expect(controller.cameraMode, CaptureMode.photo);
    final writes = transport.requests
        .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
        .map((r) => r.dataOut)
        .toList();
    expect(writes, [
      [1], // 覆写成视频
      [0], // 切回照片
    ]);
  });

  testWidgets('照片模式快门:点按走快门码(0x9207),零录像请求', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok(); // 0x9207(落卡拍,CaptureSort 0xFFFFFFFF 直发)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 78 && w.height == 78));
    // capturing 转圈永驻(落定等待走停摆 delay),pumpAndSettle 永不静
    // —— 定长 pump 让捕获链入队即可断言。
    await tester.pump();
    await tester.pump();
    expect(
        transport.requests.where((r) =>
            r.opcode == NikonOperationCode.initiateCaptureRecInMedia ||
            r.opcode == PtpOperationCode.initiateCapture),
        hasLength(1),
        reason: '快门码直发一条(落定等待走停摆 delay,不炸)');
    expect(
        transport.requests.where((r) =>
            r.opcode == NikonOperationCode.startMovieRecInCard ||
            r.opcode == NikonOperationCode.endMovieRec),
        isEmpty,
        reason: '照片模式不发任何录像命令');
  });

  testWidgets('设置浮层参数区:tile 第二入口直达参数编辑底单,底单收后浮层仍在',
      (tester) async {
    _portrait(tester);
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport); // 连接沿对表(白平衡枚举在册)
    transport
      ..ok() // 0x1016 写白平衡 = 4
      ..ok(data: _propDescDataset(PtpDevicePropCode.whiteBalance,
          PtpDataType.uint16, 4,
          enums: [2, 4, 5, 6, 7, 0x8010])); // 回读
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // tune 开设置浮层:拍摄参数区(读出条之外的第二入口)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('拍摄参数'), findsOneWidget, reason: '浮层三段头之一');
    final wbInPanel = find.descendant(
        of: find.byType(CaptureSettingsPanel), matching: find.text('白平衡'));
    expect(wbInPanel, findsOneWidget, reason: '白平衡 tile 在浮层参数区');

    // 点浮层 tile → 参数编辑底单(枚举上树)
    await tester.tap(wbInPanel);
    await tester.pumpAndSettle();
    expect(find.text('直射阳光'), findsOneWidget, reason: '编辑底单枚举');

    // 点选枚举:写路径照常,底单收口后浮层仍在(第二入口不吞浮层)
    await tester.tap(find.text('直射阳光'));
    await tester.pumpAndSettle();
    expect(controller.paramProps[PtpDevicePropCode.whiteBalance]?.value, 4,
        reason: '0x1016 写 + 回读落值');
    expect(find.byType(CaptureSettingsPanel), findsOneWidget,
        reason: '底单收口,浮层仍在');
  });

  testWidgets('AF 区域面板宽C1/C2 常驻提示行 + 切换沿 notice(饱和轴'
      '触屏移框不动属相机行为,2026-10-12)', (tester) async {
    _portrait(tester);
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport,
        conn: conn, setPropGate: () => true);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景先吃 FIFO 头两位
    _scriptParams(transport); // 连接沿对表(AF 区域 FORM 七值在册)
    transport
      ..ok() // 0x1016 写 AF 区域 = 宽C1
      ..ok(data: _propDescDataset(PtpDevicePropCode.stillFocusMeteringMode,
          PtpDataType.uint16, 0x801E,
          enums: [0x8010, 0x8011, 0x8017, 0x8018, 0x8019, 0x801E, 0x801F]));
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // tune 开设置浮层 → 点 AF 区域 tile → 编辑底单(常驻提示行)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(CaptureSettingsPanel),
        matching: find.text('AF 区域')));
    await tester.pumpAndSettle();
    expect(
        find.text('宽C1/C2 为横带/竖条区域:触屏移框仅上下/左右单轴生效'),
        findsOneWidget,
        reason: 'AF 面板常驻提示行');

    // 选宽C1:写 + 回读落值,切换沿 notice 浮出(4s 淡出前断言)
    await tester.tap(find.text('宽C1'));
    await tester.pumpAndSettle();
    expect(
        controller
            .paramProps[PtpDevicePropCode.stillFocusMeteringMode]?.value,
        0x801E,
        reason: '0x1016 写 + 回读落值');
    expect(controller.notice, 'param.wideC1Hint',
        reason: '控制器层吐键;渲染层经 t() 落 zh 词表');
    expect(find.text('宽C1 是横向条形区域,触屏移框仅上下生效'),
        findsOneWidget,
        reason: '切换沿 notice 横幅在屏');
  });

  testWidgets('对焦钮点按即 AF(0x90C1)零面板;MF 步进/拉焦轮迁设置浮层'
      '(2026-10-12:对焦钮只负责对焦)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok() // afDrive 0x90C1(对焦钮直触发)
      ..ok() // mfDrive 0x9204 向近激活
      ..ok() // 0x90C8 就绪探:完成
      ..ok() // mfDrive 0x9204 向远激活
      ..ok(); // 0x90C8 就绪探:完成
    // 十二轮持久化:注入裸 ValueNotifier(拉焦轮开关会写回设置)。
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 控制行对焦钮:点按即驱动一次 AF,不弹任何面板
    await tester.tap(find.byIcon(Icons.center_focus_strong));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.afDrive),
        hasLength(1));
    expect(controller.focusing, isFalse, reason: '脚本应答即回,不转圈');
    expect(find.byType(CaptureSettingsPanel), findsNothing,
        reason: '对焦钮不开设置浮层');
    expect(find.text('拉焦轮'), findsNothing, reason: '拉焦轮不在面板外');

    // MF 步进/拉焦轮住设置浮层「对焦」段
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('对焦'), findsOneWidget, reason: '对焦段在场');

    // MF 步进:向近 [1,300] / 向远 [2,300](0x9204 相对量)
    await tester.tap(find.text('MF 近'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MF 远'));
    await tester.pumpAndSettle();
    final mf = transport.requests
        .where((r) => r.opcode == NikonOperationCode.mfDrive)
        .toList();
    expect(mf, hasLength(2));
    expect(mf[0].params, [1, 300], reason: '向近一步(300 脉冲)');
    expect(mf[1].params, [2, 300], reason: '向远一步');

    // 拉焦轮开关:开即出竖条(取景画面右缘)
    expect(find.byKey(const ValueKey('focus-dial-rail')), findsNothing);
    await tester.tap(find.text('拉焦轮'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-dial-rail')), findsOneWidget);
  });

  testWidgets('机身对焦模式 MF → 对焦钮灰化盲按零流量;设置浮层常驻提示 + '
      'MF 步进盲按零流量,拉焦轮压暗保留姿态', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()); // 首帧
    // 十二轮持久化:注入裸 ValueNotifier(拉焦轮开关会写回设置)。
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 0xD061 = 4(MF 选择,Zf 域内值):直置 paramProps(0x4006 事件 →
    // 裸值读链路在控制器用例已覆盖,这里只验页面消费端)
    controller.paramProps[PtpDevicePropCode.stillFocusMode] =
        const PropState(value: 4);
    controller.notifyListeners();
    await tester.pumpAndSettle();

    // 对焦钮盲按:零 AF 流量(灰化是第二道,控制器拦截是第一道)
    await tester.tap(find.byIcon(Icons.center_focus_strong));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.afDrive),
        isEmpty,
        reason: 'AF 盲按零流量');

    // 设置浮层「对焦」段:MF 常驻提示行在场 + 步进盲按零流量
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('机身对焦模式为 MF,远程对焦已停用'), findsOneWidget,
        reason: 'MF 常驻提示');
    await tester.tap(find.text('MF 近'));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.mfDrive),
        isEmpty,
        reason: 'MF 步进盲按零流量');

    // 开拉焦轮:MF 时压暗 0.35(姿态保留;拖动被控制器静默丢弃)
    await tester.tap(find.text('拉焦轮'));
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('focus-dial-rail'));
    expect(rail, findsOneWidget, reason: 'MF 下拉焦轮保留姿态');
    final opacity = tester.widget<Opacity>(
        find.descendant(of: rail, matching: find.byType(Opacity)));
    expect(opacity.opacity, 0.35, reason: 'MF 时拉焦轮压暗');
  });

  testWidgets('监看开关持久化(十二轮):浮层开关写回设置,重挂页面恢复无需再点',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    // 浮层开「网格」:设置值即时改写 + 当前页即出叠层
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(GridOverlay), findsNothing, reason: '默认无网格');
    await tester.tap(find.text('网格'));
    await tester.pumpAndSettle();
    expect(settings.value.monitorGrid, isTrue, reason: '开关落进设置值');
    expect(find.byType(GridOverlay), findsOneWidget, reason: '当前页即出网格');

    // 真重挂(SizedBox 卸载 → 同设置源、同控制器再挂;引擎在跑 → 新
    // initState 走进页对表沿,预置参数脚本):桥接恢复,无需再点
    _scriptParams(transport);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(find.byType(GridOverlay), findsOneWidget, reason: '重进拍摄页保持');
  });

  testWidgets('取景开关(十二轮「取景器关闭的开关」):关 = 0x9202 + 持久关,'
      '重挂不自动起景;再开 = 0x9201 起景 + 持久开', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue, reason: '默认开:进页自动起景');

    // 浮层「取景」关:0x9202 停景 + liveViewOn 落 false + 控制器总闸关
    transport.ok(); // 0x9202(引擎 stop 尽力)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(settings.value.liveViewOn, isFalse, reason: '持久位落 false');
    expect(controller.autoLiveViewEnabled, isFalse, reason: '控制器总闸关');
    expect(controller.liveViewActive, isFalse, reason: '引擎已停');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(1),
        reason: '恰一条 0x9202');

    // 真重挂(SizedBox 卸载再挂,initState 才会走自动起景沿):总闸挡住
    // —— 脚本不再预置应答,误发即耗尽脚本抛错(_ScriptTransport 兜底);
    // 引擎保持停
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isFalse, reason: '重进不自动起景');

    // 再开:0x9201 + 首帧(显式开不受闸),持久位回 true
    _scriptAutoStart(transport);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取景'));
    await tester.pumpAndSettle();
    expect(settings.value.liveViewOn, isTrue, reason: '持久位回 true');
    expect(controller.liveViewActive, isTrue, reason: '显式开照常起景');
  });

  testWidgets('设置浮层:再点锚钮即收,点空白即收且这一拍不触发触控对焦'
      '(2026-10-12 满铺手势层;收起后点画面照常对焦)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok() // changeAfArea(浮层收起后再点画面)
      ..ok(); // afDrive
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    // 设置开 → 再点设置钮:收
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsNothing,
        reason: '再点锚钮即收');

    // 再开 → 点空白即收:满铺手势层贪吃这一拍,只收浮层不触控对焦
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsOneWidget);
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsNothing,
        reason: '点空白收浮层');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '收浮层这一拍被垫层贪吃,零触控对焦');

    // 浮层收起后点画面:触控对焦照常
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        hasLength(1),
        reason: '收起后点画面照常触控对焦');
  });

  testWidgets('设置浮层:点底区按钮间空白也收(2026-10-12 夜续垫层垫到'
      '底区两行之后),按钮照常不被挡', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok(); // afDrive(对焦钮)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsOneWidget);

    // 底区两行(六轮后:层锚物理屏缘 20,控制行 2238..2324 / 底行
    // 2324..2380,总高 142)的空白:取景栈的垫层够不到,由垫在两行之后
    // 的第二垫层收 —— 点控制行对焦钮与快门之间的空档(x 200,y 2291)。
    await tester.tapAt(const Offset(200, 2291));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsNothing,
        reason: '底区空白也收浮层');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeAfArea),
        isEmpty,
        reason: '收浮层这一拍不触发触控对焦');

    // 按钮在垫层之上照常:再开浮层,对焦钮点按直接驱动一次 AF
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureSettingsPanel), findsOneWidget);
    await tester.tap(find.byIcon(Icons.center_focus_strong));
    await tester.pumpAndSettle();
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.afDrive),
        hasLength(1),
        reason: '浮层开着,底区按钮照常可用');
  });

  testWidgets('断链三态沿(2026-10-10):connected→reconnecting 不弹页出横幅压暗,'
      '重连成功就地恢复;reconnecting→failed 才弹回根页', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    _scriptParams(transport); // connected 沿对表刷参(模式读打头)
    transport.ok(); // 0x9202(reconnecting 沿引擎 stop 尽力)
    // 重连成功的 connected 沿串链:模式读打头 → 自愈重启(0x9201 + 首帧)
    // → 再对表刷参(参数块,模式读应答已在上)。
    transport
      ..ok(data: Uint8List.fromList([0])) // 0xD1A6(重连链首读)
      ..ok() // 0x9201(重连自愈重启)
      ..ok(data: _realJpeg()); // 首帧
    _scriptParams(transport, d1a6: null); // 重连沿再对表(参数块)

    // 根页 + 推入拍摄页:popUntil(isFirst) 的弹回才可观测
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    RemotePage(controller: controller))),
                        child: const Text('根页')))))));
    await tester.tap(find.text('根页'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '拍摄页已推入');
    expect(find.byType(Image), findsOneWidget, reason: '首帧已上屏');

    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.linkUp, isTrue);

    // ① connected → reconnecting:页面保留 + 横幅 + 压暗 + 冻结帧
    conn.statesCtrl.add(CameraLinkState.reconnecting);
    await tester.pumpAndSettle();
    expect(find.text('连接中断 —— 正在自动重连;画面为断开前的保持帧,非实时'),
        findsOneWidget, reason: '重连横幅(常驻)');
    expect(find.text('未连接相机 —— 请先在「相机」页建立连接'), findsNothing,
        reason: '「未连接」不得抢屏(横幅链重连最前)');
    expect(
        find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.black26),
        findsOneWidget,
        reason: '冻结帧压暗(非实时的视觉暗示)');
    expect(find.byType(Image), findsOneWidget, reason: '冻结帧保留不闪黑');
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '不弹页');

    // ② 重连成功:横幅/压暗撤下,就地恢复
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(find.text('连接中断 —— 正在自动重连;画面为断开前的保持帧,非实时'),
        findsNothing);
    expect(
        find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.black26),
        findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '仍在拍摄页');
    expect(controller.liveViewActive, isTrue,
        reason: '重连成功取景自愈重启(2026-10-11 修复:connected 沿串链,'
        '画面就地恢复,不再须退出拍摄页重进)');
    expect(find.byType(Image), findsOneWidget, reason: '自愈首帧替换冻结帧');

    // ③ 再断 + 放弃(reconnecting → failed 预算耗尽):弹回根页
    conn.statesCtrl.add(CameraLinkState.reconnecting);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.tune), findsOneWidget, reason: '恢复期仍不弹');
    conn.statesCtrl.add(CameraLinkState.failed);
    await tester.pumpAndSettle();
    expect(find.text('根页'), findsOneWidget, reason: '弹回根页拿重试入口');
    expect(find.byIcon(Icons.tune), findsNothing, reason: '拍摄页已出栈');
  });

  testWidgets('相机忙横幅(看门狗 BUSY 保持):连接在、画面保持的提示沿',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景(0x9201 + 首帧)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('相机忙(写卡/下载中),取景画面保持'), findsNothing);
    controller.engine.health.value = LiveViewHealth.busy;
    await tester.pump();
    expect(find.text('相机忙(写卡/下载中),取景画面保持'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.black26),
        findsNothing,
        reason: 'BUSY 保持不压暗(画面仍在实时,只是机身忙)');
    controller.engine.health.value = LiveViewHealth.ok;
    await tester.pump();
    expect(find.text('相机忙(写卡/下载中),取景画面保持'), findsNothing,
        reason: '新帧到达自我恢复,横幅撤下');
  });

  testWidgets('取景画质档(2026-10-12 官方 §6.5.11.4-5):浮层选档写回设置'
      '与控制器,「跟随」回 null', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('取景尺寸'), findsOneWidget);
    expect(find.text('取景画质'), findsOneWidget);
    expect(controller.liveViewImageSize, isNull, reason: '默认跟随相机');

    await tester.tap(find.text('XGA'));
    await tester.pumpAndSettle();
    expect(settings.value.liveViewImageSize, 3);
    expect(controller.liveViewImageSize, 3);

    await tester.tap(find.text('Fine 质量'));
    await tester.pumpAndSettle();
    expect(settings.value.liveViewImageCompression, 5);
    expect(controller.liveViewImageCompression, 5);

    // 回「跟随」:尺寸行第一个「跟随」(行序 = 尺寸在上)→ 写回 null
    await tester.tap(find.text('跟随').first);
    await tester.pumpAndSettle();
    expect(settings.value.liveViewImageSize, isNull);
    expect(controller.liveViewImageSize, isNull);
    expect(controller.liveViewImageCompression, 5, reason: '另一档互不连坐');
  });

  testWidgets('视频参数族面板(2026-10-12 官方 §6.5.3/§6.5.12):视频档追加'
      '视频 tile', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    _scriptParamsVideo(transport, d1a6: 1); // 视频档连接(全量刷参)
    await tester.pumpWidget(MaterialApp(home: RemotePage(
        controller: controller,
        settingsListenable: ValueNotifier(const AppSettings()))));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.cameraMode, CaptureMode.video);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('视频光圈'), findsOneWidget,
        reason: '视频档面板追加视频参数族');
    expect(find.text('视频 ISO'), findsOneWidget);
    expect(find.text('N-Log'), findsOneWidget);
  });

  testWidgets('信息胶囊:照片档显张数裸值(0xD1F1 相机自报可拍,用户定案'
      '不带「张」)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    _scriptParams(transport); // 照片档连接,0xD1F1=1234 链首读
    await tester.pumpWidget(MaterialApp(home: RemotePage(
        controller: controller,
        settingsListenable: ValueNotifier(const AppSettings()))));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.cameraMode, isNot(CaptureMode.video));
    expect(find.text('1234'), findsOneWidget);
  });

  testWidgets('信息胶囊:视频档张数换剩余可录时长(帧头 @816,2026-10-16 '
      '探针定案张数在该档被录像估算污染;用户定案裸显时间不带「可录」)',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    _scriptParamsVideo(transport, d1a6: 1); // 视频档连接(0xD1F1=1234 照读)
    await tester.pumpWidget(MaterialApp(home: RemotePage(
        controller: controller,
        settingsListenable: ValueNotifier(const AppSettings()))));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.cameraMode, CaptureMode.video);
    expect(find.text('1234'), findsNothing, reason: '视频档不显张数');

    // 帧头注入剩余可录 61s → 「1:01」上屏。
    controller.engine.header.value =
        parseLiveViewHeader(_headerObject(videoRemainingMs: 61000));
    await tester.pump();
    expect(find.text('1:01'), findsOneWidget);
  });

  testWidgets('视频参数族面板:照片档不出现视频 tile(零噪声)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    _scriptParams(transport); // 照片档连接
    await tester.pumpWidget(MaterialApp(home: RemotePage(
        controller: controller,
        settingsListenable: ValueNotifier(const AppSettings()))));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('视频光圈'), findsNothing, reason: '照片档零视频噪声');
    expect(find.text('视频 ISO'), findsNothing);
  });

  testWidgets('音量键快门(2026-10-14 Android,10-15 iOS):平台门禁 —— 无宿主(异端)'
      '不出行,宿主在出行', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    // 异端(测试宿主非 Android/iOS 且无注入):设置开着也不接线、行不出现
    final settings = ValueNotifier(
        const AppSettings().copyWith(volumeKeyShutter: true));
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller, settingsListenable: settings)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('音量键快门'), findsNothing,
        reason: 'ohos/桌面(无宿主)不出行 —— 未做原生拦截');
    // 卸页再挂:同型 widget 复用 State(late final 宿主锁首值),换树
    // 才走新 initState
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // 宿主在(Android / 单测注入):行出现(设置开着)
    final transport2 = _ScriptTransport();
    final conn2 = _FakeConnection();
    final controller2 = _directRemoteController(transport2, conn: conn2);
    addTearDown(controller2.dispose);
    _scriptAutoStart(transport2);
    final settings2 = ValueNotifier(
        const AppSettings().copyWith(volumeKeyShutter: true));
    addTearDown(settings2.dispose);
    final keys = _FakeVolumeKeys();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller2,
            settingsListenable: settings2,
            volumeKeys: keys)));
    await tester.pumpAndSettle();
    expect(keys.calls, [true], reason: '开关开 + 宿主在 → 进页即 setEnabled(true)');
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('音量键快门'), findsOneWidget,
        reason: '有宿主平台(Android/iOS,单测注入同型)出行');
  });

  testWidgets('音量键快门:芯片点选写设置 + 原生开关沿(开→关),选中态'
      '即时翻转', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    final settings = ValueNotifier(const AppSettings());
    addTearDown(settings.dispose);
    final keys = _FakeVolumeKeys();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller,
            settingsListenable: settings,
            volumeKeys: keys)));
    await tester.pumpAndSettle();
    expect(keys.calls, isEmpty, reason: '默认关:进页不推 setEnabled');

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final colorBefore =
        tester.widget<Text>(find.text('音量键快门')).style?.color;
    await tester.ensureVisible(find.text('音量键快门'));
    await tester.tap(find.text('音量键快门'));
    await tester.pumpAndSettle();
    expect(settings.value.volumeKeyShutter, isTrue, reason: '芯片写设置');
    expect(keys.calls, [true], reason: '开沿 → 原生 setEnabled(true)');
    expect(tester.widget<Text>(find.text('音量键快门')).style?.color,
        isNot(colorBefore),
        reason: '选中态即时翻转(设置镜像 setState)');

    await tester.ensureVisible(find.text('音量键快门'));
    await tester.tap(find.text('音量键快门'));
    await tester.pumpAndSettle();
    expect(settings.value.volumeKeyShutter, isFalse);
    expect(keys.calls, [true, false], reason: '关沿 → setEnabled(false) 还系统');
  });

  testWidgets('音量键快门:按键命中走控制器 capture(0x9207,与屏上快门'
      '同一守卫)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()) // 首帧
      ..ok(); // 0x9207(音量键命中 → capture)
    final settings = ValueNotifier(
        const AppSettings().copyWith(volumeKeyShutter: true));
    addTearDown(settings.dispose);
    final keys = _FakeVolumeKeys();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller,
            settingsListenable: settings,
            volumeKeys: keys)));
    await tester.pumpAndSettle();
    expect(keys.calls, [true]);

    keys.fire(); // 音量上键(上/下同效 = 快门)
    // capturing 转圈永驻(落定等待走停摆 delay),定长 pump 让捕获链入队
    await tester.pump();
    await tester.pump();
    expect(
        transport.requests.where((r) =>
            r.opcode == NikonOperationCode.initiateCaptureRecInMedia ||
            r.opcode == PtpOperationCode.initiateCapture),
        hasLength(1),
        reason: '命中即快门,走 capture() 同一守卫同一错误横幅');
  });

  testWidgets('音量键快门:离页退订 + setEnabled(false) 还系统', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    transport
      ..ok() // 0x9201(进页自动起景)
      ..ok(data: _realJpeg()); // 首帧
    final settings = ValueNotifier(
        const AppSettings().copyWith(volumeKeyShutter: true));
    addTearDown(settings.dispose);
    final keys = _FakeVolumeKeys();
    await tester.pumpWidget(MaterialApp(
        home: RemotePage(
            controller: controller,
            settingsListenable: settings,
            volumeKeys: keys)));
    await tester.pumpAndSettle();
    expect(keys.calls, [true]);

    // 换树卸页 → dispose:退订 + 还音量键给系统
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(keys.calls, [true, false], reason: '离页即 setEnabled(false)');

    // 退订后按键不再触发快门
    keys.fire();
    await tester.pump();
    await tester.pump();
    expect(
        transport.requests.where((r) =>
            r.opcode == NikonOperationCode.initiateCaptureRecInMedia ||
            r.opcode == PtpOperationCode.initiateCapture),
        isEmpty,
        reason: '退订后音量键零快门请求');
  });

  testWidgets('间隔拍摄:设置面板入口 → 参数底单开始 → 状态行/互锁灰化 → 停止',
      (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport); // 进页自动起景
    _scriptParams(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    // 设置浮层 → 辅助区间隔芯片
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('间隔拍摄'), findsOneWidget, reason: '辅助区入口芯片');

    // 参数底单(默认 5 秒 / 10 张)→ 首拍脚本就位后开始
    await tester.tap(find.text('间隔拍摄'));
    await tester.pumpAndSettle();
    expect(find.text('间隔拍摄参数'), findsOneWidget, reason: '底单标题');
    expect(find.text('5 秒'), findsOneWidget, reason: '间隔默认 5s');
    expect(find.text('10'), findsOneWidget, reason: '张数默认 10');
    transport
      ..ok() // 调度就绪探测(0x90C8)
      ..ok(); // 0x9207(首拍立即发,无首拍延迟)
    await tester.tap(find.byKey(const ValueKey('interval-start')));
    // capturing 期间快门芯 spinner 持续排帧,pumpAndSettle 会超时 ——
    // 有界 pump:处理点按(pop + startInterval 微任务链:探测 + 快门)。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.deviceReady)
            .length,
        1,
        reason: '调度就绪探测已发');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
            .length,
        1,
        reason: '首拍快门已发');

    // CaptureComplete 事件收口首拍 → 间隔等待驻停(parked delay)
    transport.eventCtrl.add(const PtpEvent(
        code: PtpEventCode.captureComplete, transactionId: 0xFFFFFFFF));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.intervalTaken, 1);

    // 浮层常开:芯片进度镜像 + 自拍/SDRAM 互锁灰化(芯片 onTap 置空)。
    expect(find.text('间隔 1/10'), findsOneWidget,
        reason: '芯片进度镜像运行态');
    final selfTimerChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('自拍'), matching: find.byType(InkWell))
        .first);
    expect(selfTimerChip.onTap, isNull, reason: '运行中自拍让位灰化');
    final sdramChip = tester.widget<InkWell>(find
        .ancestor(of: find.text('SDRAM 直拍'), matching: find.byType(InkWell))
        .first);
    expect(sdramChip.onTap, isNull, reason: '运行中 SDRAM 直拍禁中途开');

    // 收设置浮层(tune 再点即收)→ 状态行常驻贴底(第 x/y 张 + 停止钮;
    // 浮层开着时满铺收层会垫在状态行前,停止钮须收浮层后才可点)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('间隔拍摄'), findsNothing, reason: '浮层已收(芯片随撤)');
    expect(find.byKey(const ValueKey('interval-status-row')), findsOneWidget);
    expect(find.text('间隔拍摄 1/10 张'), findsOneWidget);

    // 停止:状态行即撤,摘要横幅透出
    await tester.tap(find.byKey(const ValueKey('interval-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.intervalStatus, IntervalometerStatus.stopped);
    expect(find.byKey(const ValueKey('interval-status-row')), findsNothing);
    expect(find.text('间隔拍摄已停止:共 1 张'), findsOneWidget);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
            .length,
        1,
        reason: '停轮后不再发快门');

    // 摘要横幅 4s 淡出计时:推过窗收口,不留挂起 Timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  });
}

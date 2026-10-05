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

/// 目录序全量 PropDesc 应答(模式 A · f/2.8 · 1/100s · ISO 200 · EV+0.3 ·
/// 白平衡自动 · 色温 5500K · 闪光关闭 · 测光 2 · 对焦 AF-C · 对焦模式
/// AF-S · 释放单张 · 画质 RAW · RAW 无损 · 尺寸 2 · 区域 FX · 校准标准,
/// 均可写;与 remote_controller_test 的 _kParamSpecs 同值)。
void _scriptParams(_ScriptTransport t) {
  t
    ..ok(data: _propDescDataset(PtpDevicePropCode.exposureProgramMode,
        PtpDataType.uint16, 3,
        enums: [1, 2, 3, 4, 5]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.fNumber, PtpDataType.uint16, 280,
        enums: [280, 320, 400]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureTime, PtpDataType.uint32, 10000))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
        enums: [100, 200, 400, 800]))
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
    ..ok(data: _propDescDataset(PtpDevicePropCode.focusMode,
        PtpDataType.uint16, 1, enums: [0, 1, 2, 4]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.stillFocusMode,
        PtpDataType.uint8, 0, enums: [0, 1, 4, 5]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.stillCaptureMode,
        PtpDataType.uint16, 1, enums: [1, 2, 0x8010, 0x8011]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.compressionSetting,
        PtpDataType.uint8, 7, enums: [4, 5, 7, 12]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.rawCompressionType,
        PtpDataType.uint8, 0, enums: [0, 3, 4]))
    ..ok(data: _propDescDataset(
        PtpDevicePropCode.imageSize, PtpDataType.uint16, 2,
        enums: [1, 2, 3]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.captureAreaCrop,
        PtpDataType.uint8, 0, enums: [0, 2, 4, 5]))
    ..ok(data: _propDescDataset(PtpDevicePropCode.activePicCtrlItem,
        PtpDataType.uint16, 1, enums: [1, 2, 3, 4]));
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

    // 三要素大芯片
    expect(find.text('光圈'), findsOneWidget);
    expect(find.text('f/2.8'), findsOneWidget);
    expect(find.text('1/100s'), findsOneWidget);
    expect(find.text('ISO 200'), findsOneWidget);
    // 横滚行首屏(无需滚动即构建):模式/白平衡等
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('光圈优先 A'), findsOneWidget);
    expect(find.text('EV'), findsOneWidget);
    expect(find.text('+0.3'), findsOneWidget);
    expect(find.text('白平衡'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);

    // 横滚行懒构建:逐个滚到可见再断言(目录序,单向滚到底)
    Future<void> scroll(String text) =>
        tester.scrollUntilVisible(find.text(text), 120, scrollable: _chipsRow);
    await scroll('色温');
    expect(find.text('5500K'), findsOneWidget);
    await scroll('闪光');
    expect(find.text('关闭'), findsOneWidget);
    await scroll('测光');
    expect(find.text('值 2'), findsWidgets, reason: '测光无值表,裸显');
    await scroll('AF-C'); // 对焦(focusMode=1)值
    await scroll('AF-S'); // 对焦模式(stillFocusMode=0)值
    await scroll('释放');
    expect(find.text('单张'), findsOneWidget);
    await scroll('画质');
    expect(find.text('RAW'), findsOneWidget);
    await scroll('无损压缩'); // RAW 压缩(rawCompressionType=0)值
    await scroll('图像尺寸');
    expect(find.text('值 2'), findsWidgets);
    await scroll('FX'); // 图像区域(captureAreaCrop=0)值
    await scroll('标准'); // 优化校准(activePicCtrlItem=1)值
    await scroll('对焦后拍'); // 行尾开关芯片
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
    // FAB 的 heroTag 定位(下方「取景」文字标签不可点)
    final lvFab = find.byWidgetPredicate(
        (w) => w is FloatingActionButton && w.heroTag == 'liveview');
    await tester.tap(lvFab);
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
    await tester.tap(find.text('对焦后拍'));
    await tester.pumpAndSettle();
    expect(controller.focusBeforeCapture, isTrue);
    expect(transport.requests, isEmpty, reason: '纯本地开关,不发相机命令');
  });
}

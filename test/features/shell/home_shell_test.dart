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
import 'package:nikon_pill/features/connection/connection_page.dart';
import 'package:nikon_pill/features/remote/live_view_overlays.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/remote_page.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';
import 'package:nikon_pill/features/shell/home_shell.dart';

/// 假传输:双道应答回放。连接沿有两条独立链并发入队 —— 控制器链
/// (参数读,走 FIFO 兜底道)与引擎链(0x9201/0x9428/0x9202,按 op
/// 定向道取件);二者各持 PtpSession,传输层交错序是微任务时序,全局
/// FIFO 必错位,定向道互不串道即可各自按序消费。两道皆空抛
/// StateError,兜住意外的多余请求。
final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> generic = Queue(); // FIFO 兜底道(控制器参数链)
  final lanes = <int, Queue<Object>>{}; // 按 op 定向道(引擎链)
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      generic.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));

  /// 给指定 op 定向应答(引擎链 0x9201/0x9428/0x9202)。
  void okFor(int opcode, {Uint8List? data}) =>
      (lanes[opcode] ??= Queue())
          .add(PtpResult(responseCode: PtpResponseCode.ok, data: data));

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    final lane = lanes[request.opcode];
    if (lane != null && lane.isNotEmpty) {
      return lane.removeFirst() as PtpResult;
    }
    if (generic.isNotEmpty) {
      return generic.removeFirst() as PtpResult;
    }
    throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)}');
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

/// PropDesc 数据集(ISO 15740 标准布局:出厂默认值在前,当前值在后)。
Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, List<int>? enums}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
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

/// u32 裸值应答字节(小端)。
Uint8List _u32Bytes(int v) => Uint8List.fromList(
    [for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF]);

/// 裸值应答字节(按类型宽度:u8 一字节 / u16 两字节 / u32 四字节)。
Uint8List _rawValueBytes(PtpDataType type, int value) {
  final width = type.width!;
  return Uint8List.fromList(
      [for (var i = 0; i < width; i++) (value >> (8 * i)) & 0xFF]);
}

/// 目录序参数应答表(与 remote_controller_test 同款:模式 M · f/2.8 ·
/// 1/100s · ISO 200 …,均可写;[drive] 释放档)。
typedef _ParamSpec = ({
  int code,
  PtpDataType type,
  int value,
  List<int>? enums,
});

const _kParamSpecs = <_ParamSpec>[
  (code: PtpDevicePropCode.exposureProgramMode, type: PtpDataType.uint16, value: 1, enums: [1, 2, 3, 4, 5]),
  (code: PtpDevicePropCode.fNumber, type: PtpDataType.uint16, value: 280, enums: [280, 320, 400]),
  (code: PtpDevicePropCode.exposureTime, type: PtpDataType.uint32, value: 10000, enums: null),
  (code: PtpDevicePropCode.exposureIndex, type: PtpDataType.uint16, value: 200, enums: [100, 200, 400, 800]),
  (code: PtpDevicePropCode.exposureBiasCompensation, type: PtpDataType.int16, value: 300, enums: null),
  (code: PtpDevicePropCode.whiteBalance, type: PtpDataType.uint16, value: 2, enums: [2, 4, 5, 6, 7, 0x8010]),
  (code: PtpDevicePropCode.wbColorTemp, type: PtpDataType.uint16, value: 5500, enums: [2700, 5500, 6500]),
  (code: PtpDevicePropCode.flashMode, type: PtpDataType.uint16, value: 2, enums: [2, 4, 0x8010, 0x8012]),
  (code: PtpDevicePropCode.exposureMeteringMode, type: PtpDataType.uint16, value: 2, enums: [1, 2, 3, 4, 5]),
  (code: PtpDevicePropCode.stillFocusMode, type: PtpDataType.uint8, value: 0, enums: [0, 1, 4, 5]),
  (code: PtpDevicePropCode.stillCaptureMode, type: PtpDataType.uint16, value: 1, enums: [1, 2, 0x8010, 0x8011]),
  (code: PtpDevicePropCode.compressionSetting, type: PtpDataType.uint8, value: 7, enums: [4, 5, 7, 12]),
  (code: PtpDevicePropCode.rawCompressionType, type: PtpDataType.uint8, value: 0, enums: [0, 3, 4]),
  (code: PtpDevicePropCode.captureAreaCrop, type: PtpDataType.uint8, value: 0, enums: [0, 2, 4, 5]),
  (code: PtpDevicePropCode.stillFocusMeteringMode, type: PtpDataType.uint16, value: 0x8010, enums: null),
  (code: 0x0001D006, type: PtpDataType.uint8, value: 0, enums: null), // 主体检测(Ex 扩展码)
  (code: 0x0001D01C, type: PtpDataType.uint8, value: 1, enums: null), // 色调(Ex 扩展码)
  (code: PtpDevicePropCode.activePicCtrlItem, type: PtpDataType.uint16, value: 1, enums: [1, 2, 3, 4]),
];

/// 值回读路由(厂商读码)的应答值:快门 = 0xD100 打包 1/100s;ISO =
/// 0xD0B5 裸数(有效 ISO)。
const _kVendorReadValues = <int, int>{
  PtpDevicePropCode.exposureTime: 1 << 16 | 100,
  PtpDevicePropCode.exposureIndex: 200,
};

/// 目录序全量应答(与 remote_controller_test._scriptParams 同款:
/// PropDesc(取值域直供表参数跳过)+ 值回读(路由参数读厂商码裸值)
/// + 末尾自动 ISO 状态与剩余张数)。
void _scriptParams(_ScriptTransport t) {
  for (final s in _kParamSpecs) {
    final param = shootingParamByCode[s.code]!;
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(s.code, s.type, s.value, enums: s.enums));
    } else if (_kVendorReadValues[s.code] == null) {
      // 取值域直供参数:不读 desc,值走裸读 —— 裸值应答(有厂商读码
      // 路由的由下方 vendor 应答覆盖)
      t.ok(data: _rawValueBytes(s.type, s.value));
    }
    final vendor = _kVendorReadValues[s.code];
    if (vendor != null) {
      t.ok(data: _u32Bytes(vendor));
    }
  }
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数
}

/// 挂起的 delay(永不完成):引擎帧轮询/AE 轮询在测试里驻停。
Future<void> _parkedDelay(Duration _) => Completer<void>().future;

/// 真实可解码 32×24 JPEG(首帧;Image.memory 要渲染)。
Uint8List _realJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, x * 8, x * 8, x * 8, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// NavigationBar 上的 tab 标签(与页面 AppBar 标题同名的,收窄到栏内)。
Finder _navTab(String label) => find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label));

/// NavigationRail(横屏外壳)上的 tab 标签。
Finder _railTab(String label) => find.descendant(
    of: find.byType(NavigationRail), matching: find.text(label));

/// 拍摄页内匹配(IndexedStack 常驻其他 tab,offstage 页也在树里)。
Finder _inRemotePage(Finder f) =>
    find.descendant(of: find.byType(RemotePage), matching: f);

int _selectedIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

void main() {
  testWidgets('连接转正沿:不切 tab、连接即取景;切 tab 不停取景'
      '(取景生命周期跟连接走)', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final connCtrl = ConnectionController(connection: conn);
    addTearDown(connCtrl.dispose);
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        // 引擎 delay 挂起:首帧后轮询驻停,测试不发无脚本的取帧。
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay);
    addTearDown(controller.dispose);

    _scriptParams(transport); // connected → 控制器沿参数刷新(FIFO 道)
    transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧 0x9428(轮询首拍,此后 delay 挂起)
    await tester.pumpWidget(MaterialApp(
        home: HomeShell(
            connectionController: connCtrl, remoteController: controller)));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0, reason: '初始在相机 tab');

    // 连接转正(有线/无线同一状态机):留在原 tab,相机侧照进取景。
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0, reason: '不切 tab(2026-10-07 用户明示)');
    expect(controller.liveViewActive, isTrue,
        reason: '连接即取景:拍摄页不可见不影响 0x9201');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1));

    // 切到拍摄 tab:回台对表刷参数,取景保持(不发 0x9202)。
    _scriptParams(transport);
    await tester.tap(_navTab('拍摄'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1);
    expect(controller.liveViewActive, isTrue, reason: '取景不因切台停');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '切台只挂起帧轮询,取景生命周期跟连接走');

    // 切回相机 tab:同样不停取景。
    await tester.tap(_navTab('相机'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0);
    expect(controller.liveViewActive, isTrue);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty);

    // 重复 connected(状态未离开的重复通知):不重复取景(已运行幂等),
    // 控制器沿照常再刷一遍参数。
    _scriptParams(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0, reason: '重复 connected 沿不切 tab');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '连接即取景每次连接只一次(已运行直通)');

    // 断连:取景随连接收口(0x9202 只在断连或用户显式关时发)。
    transport.okFor(NikonOperationCode.endLiveView); // 0x9202(引擎道)
    conn.statesCtrl.add(CameraLinkState.disconnected);
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isFalse);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(1));
  });

  testWidgets('连接期间用户在图库 tab:不拽人,取景照开(相机侧进及时取景)',
      (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final connCtrl = ConnectionController(connection: conn);
    addTearDown(connCtrl.dispose);
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay);
    addTearDown(controller.dispose);

    _scriptParams(transport); // connected → 控制器沿参数刷新(照常,FIFO 道)
    await tester.pumpWidget(MaterialApp(
        home: HomeShell(
            connectionController: connCtrl, remoteController: controller)));
    await tester.pumpAndSettle();
    await tester.tap(_navTab('图库'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2);

    transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道)
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2, reason: '不把浏览中的用户拽走');
    expect(controller.liveViewActive, isTrue,
        reason: '连接即取景与页面无关:0x9201 照发,相机侧进及时取景');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1));
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '不可见只挂起帧轮询');
    // 帧轮询挂起:首帧之后零取帧(delay 挂起,不再耗脚本)。
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
        hasLength(1),
        reason: '页面不可见:只取首帧即挂起');
  });

  testWidgets('横屏外壳:底栏换左侧 NavigationRail,拍摄 tab 切换照常',
      (tester) async {
    tester.view
      ..physicalSize = const Size(2400, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final connCtrl = ConnectionController(connection: conn);
    addTearDown(connCtrl.dispose);
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay);
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
        home: HomeShell(
            connectionController: connCtrl, remoteController: controller)));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget, reason: '横屏换 rail');
    expect(find.byType(NavigationBar), findsNothing,
        reason: '底栏退位(80px 高度还给监看画面)');
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0,
        reason: '初始在相机 tab');

    // 切拍摄 tab:回台对表刷参数(active 沿;linkUp 乐观态即发)。
    _scriptParams(transport);
    await tester.tap(_railTab('拍摄'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1);
    expect(controller.exposure?.fNumber, 280, reason: 'rail 切台照常刷参数');
  });

  testWidgets('竖→横旋转:拍摄页状态全程保留(网格在、取景不重启)'
      '—— key 保 IndexedStack', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final transport = _ScriptTransport();
    final conn = _FakeConnection();
    final connCtrl = ConnectionController(connection: conn);
    addTearDown(connCtrl.dispose);
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay);
    addTearDown(controller.dispose);

    _scriptParams(transport); // connected → 控制器沿参数刷新(FIFO 道)
    transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道,此后 delay 挂起)
    await tester.pumpWidget(MaterialApp(
        home: HomeShell(
            connectionController: connCtrl, remoteController: controller)));
    await tester.pumpAndSettle();
    conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(controller.liveViewActive, isTrue);

    _scriptParams(transport); // 回台对表刷参数
    await tester.tap(_navTab('拍摄'));
    await tester.pumpAndSettle();
    // 开网格(页面 State)—— 旋转后此开关必须还在
    await tester.tap(_inRemotePage(find.byIcon(Icons.grid_on)));
    await tester.pumpAndSettle();
    expect(_inRemotePage(find.byType(GridOverlay)), findsOneWidget);
    expect(_inRemotePage(find.byType(Image)), findsOneWidget,
        reason: '首帧在屏');

    // 旋转到横屏:底栏换 rail,页面 State 全程保留
    tester.view.physicalSize = const Size(2400, 800);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget, reason: '横屏 rail 接班');
    expect(find.byType(NavigationBar), findsNothing);
    expect(_inRemotePage(find.byType(GridOverlay)), findsOneWidget,
        reason: '网格开关跨旋转保留(无 key 会整树重建丢 State)');
    expect(_inRemotePage(find.byType(Image)), findsOneWidget, reason: '帧不丢');
    expect(controller.liveViewActive, isTrue);
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '旋转不重启取景');
  });
}

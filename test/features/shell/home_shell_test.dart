import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:z_pill/app_services.dart';
import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/core/ptp/device_prop.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/remote/live_view_engine.dart';
import 'package:z_pill/core/utils/byte_writer.dart';
import 'package:z_pill/design/app_theme.dart';
import 'package:z_pill/features/connection/connection_controller.dart';
import 'package:z_pill/features/remote/live_view_overlays.dart';
import 'package:z_pill/features/remote/remote_controller.dart';
import 'package:z_pill/features/remote/remote_page.dart';
import 'package:z_pill/features/remote/shooting_param_catalog.dart';
import 'package:z_pill/features/settings/settings_page.dart';
import 'package:z_pill/features/shell/home_shell.dart';
import 'package:z_pill/platform/gallery_saver.dart';
import '../../helpers/fake_connection.dart';

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
/// 1/100s · ISO 200 …,均可写;[drive] 释放档)。[fNumber] 可覆写 ——
/// push 流测试用它区分「进页对表」刷的是第二遍脚本。
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
  (code: 0x0001D01C, type: PtpDataType.uint8, value: 0, enums: null), // 色调(Ex 扩展码;真域 [0,2])
  (code: PtpDevicePropCode.activePicCtrlItem, type: PtpDataType.uint16, value: 1, enums: [1, 2, 3, 4]),
];

/// 值回读路由(厂商读码)的应答值:快门 = 0xD100 打包 1/100s;ISO =
/// 0xD0B5 裸数(有效 ISO)。
const _kVendorReadValues = <int, int>{
  PtpDevicePropCode.exposureTime: 1 << 16 | 100,
  PtpDevicePropCode.exposureIndex: 200,
};

/// 目录序全量应答(与 remote_controller_test._scriptParams 同款:
/// 张数链首读(0xD1F1,refreshParams 打头,2026-10-16 改制)+ PropDesc
/// (取值域直供表参数跳过)+ 值回读(路由参数读厂商码裸值)+ 末尾
/// 自动 ISO 状态;0xD1A6 模式镜像**打头** —— 连接沿串链/进页对表都是
/// 模式读先于刷参,2026-10-11 真机反馈改制)。
void _scriptParams(_ScriptTransport t, {int fNumber = 280}) {
  t.ok(data: Uint8List.fromList([0])); // 0xD1A6 模式镜像(链首读)
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数(链首读)
  for (final s in _kParamSpecs) {
    final param = shootingParamByCode[s.code]!;
    final value = s.code == PtpDevicePropCode.fNumber ? fNumber : s.value;
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(s.code, s.type, value, enums: s.enums));
    } else if (_kVendorReadValues[s.code] == null) {
      // 取值域直供参数:不读 desc,值走裸读 —— 裸值应答(有厂商读码
      // 路由的由下方 vendor 应答覆盖)
      t.ok(data: _rawValueBytes(s.type, value));
    }
    final vendor = _kVendorReadValues[s.code];
    if (vendor != null) {
      t.ok(data: _u32Bytes(vendor));
    }
  }
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
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

/// 拍摄页内匹配(路由覆盖下相机页仍在树里,收窄到拍摄页)。
Finder _inRemotePage(Finder f) =>
    find.descendant(of: find.byType(RemotePage), matching: f);

int _selectedIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

/// 三 tab 外壳 + 拍摄页 push 流的公共脚手架:假连接 + 脚本化遥控
/// 控制器(引擎 delay 挂起:首帧后轮询驻停,测试不发无脚本的取帧)。
typedef _Fakes = ({
  _ScriptTransport transport,
  FakeConnection conn,
  ConnectionController connCtrl,
  RemoteController remote,
});

_Fakes _fakes() {
  final transport = _ScriptTransport();
  final conn = FakeConnection();
  final connCtrl = ConnectionController(connection: conn);
  final remote = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: _parkedDelay),
      delay: _parkedDelay);
  return (
    transport: transport,
    conn: conn,
    connCtrl: connCtrl,
    remote: remote,
  );
}

void main() {
  // 图库 tab 随首屏预建(allowImplicitScrolling),LocalLibraryPage 走
  // AppServices 真单例列下载目录(2026-10-22 refreshAppFiles 异步化后是
  // 真 dart:IO)。mock 给真实临时目录(空):通道错误不落进 runAsync
  // 排水窗(与 local_library_page_test 同款),扫描链可在窗内收口。
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zpill_shell');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel,
            (call) async => switch (call.method) {
                  'dataDir' || 'previewsDir' || 'downloadsDir' => dir.path,
                  _ => null,
                });
    // 同因:AppServices 装配即 ConnectionController 起 BLE/NSD 两个扫描
    // 事件流,listen 无 mock 即 MissingPluginException,异步错在哪个用例
    // 的排水窗上浮看运气 —— mock 成空应答(壳用例注入假控制器,事件流
    // 本就不该发事件)钉死顺序无关(local_library_page_test 同款)。
    for (final name in const ['zpill/ble/events', 'zpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name),
              (call) async => call.method == 'listen' ? '' : null);
    }
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel, null);
    for (final name in const ['zpill/ble/events', 'zpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 泵外壳 + 首扫排水:图库 tab 预建即起首次目录扫描(真 IO),未收口
  /// 前页面在扫描转圈 —— 直接 pumpAndSettle 会挂在转圈动画帧上。逐窗
  /// 排水到扫描收口(AppServices 单例跨用例保值:首个用例排水,后续
  /// 直通;统一走此助手保持对用例顺序不敏感)。
  Future<void> pumpShell(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    final transfers = AppServices.instance.transfersController;
    for (var i = 0; i < 20 && !transfers.appFilesScanned; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('连接转正沿:不切 tab、连接即取景;切 tab 不停取景'
      '(取景生命周期跟连接走)', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(FIFO 道)
    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧 0x9428(轮询首拍,此后 delay 挂起)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    expect(_selectedIndex(tester), 0, reason: '初始在相机 tab');

    // 连接转正(有线/无线同一状态机):留在原 tab,相机侧照进取景。
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0,
        reason: '不切 tab(2026-10-07 用户明示;进拍摄页由用户点击)');
    expect(f.remote.liveViewActive, isTrue,
        reason: '连接即取景:拍摄页未挂载不影响 0x9201');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1));

    // 切到图库 tab:取景保持(不发 0x9202)。
    await tester.tap(_navTab('图库'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1);
    expect(f.remote.liveViewActive, isTrue, reason: '取景不因切台停');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '切台只挂起帧轮询,取景生命周期跟连接走');

    // 切回相机 tab:同样不停取景。
    await tester.tap(_navTab('相机'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0);
    expect(f.remote.liveViewActive, isTrue);
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty);

    // 重复 connected(状态未离开的重复通知):不重复取景(已运行幂等),
    // 控制器沿照常再刷一遍参数。
    _scriptParams(f.transport);
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0, reason: '重复 connected 沿不切 tab');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '连接即取景每次连接只一次(已运行直通)');

    // 断连:取景随连接收口(0x9202 只在断连或用户显式关时发)。
    f.transport.okFor(NikonOperationCode.endLiveView); // 0x9202(引擎道)
    f.conn.statesCtrl.add(CameraLinkState.disconnected);
    await tester.pumpAndSettle();
    expect(f.remote.liveViewActive, isFalse);
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        hasLength(1));
  });

  testWidgets('连接期间用户在图库 tab:不拽人,取景照开(相机侧进及时取景)',
      (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(照常,FIFO 道)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    await tester.tap(_navTab('图库'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1);

    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道)
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1, reason: '不把浏览中的用户拽走');
    expect(f.remote.liveViewActive, isTrue,
        reason: '连接即取景与页面无关:0x9201 照发,相机侧进及时取景');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1));
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '拍摄页未挂载只挂起帧轮询');
    // 帧轮询挂起:首帧之后零取帧(delay 挂起,不再耗脚本)。
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
        hasLength(1),
        reason: '拍摄页未挂载:只取首帧即挂起');
  });

  testWidgets('拍摄页 push 流:相机页「进入拍摄」→ 全屏路由;进页对表、'
      '返回挂起帧轮询、取景不停', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(FIFO 道)
    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(f.remote.liveViewActive, isTrue);

    // 相机页已连接视图:主操作「进入拍摄」在场(状态卡正下方)。
    expect(find.text('进入拍摄'), findsOneWidget);

    // 进页对表:initState 刷第二遍参数脚本(值改 320 以证明确实刷了)。
    _scriptParams(f.transport, fNumber: 320);
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();
    expect(find.byType(RemotePage), findsOneWidget, reason: '全屏路由上场');
    expect(_inRemotePage(find.byIcon(Icons.arrow_back)), findsOneWidget,
        reason: '路由态信息胶囊带返回钮');
    expect(f.remote.exposure?.fNumber, 320,
        reason: '进页对表刷参数(原 tab 模式「回台对表」沿移到 initState)');
    expect(f.remote.liveViewActive, isTrue);

    // 返回:pop 回相机页,只挂起帧轮询(不发 0x9202)。
    await tester.tap(_inRemotePage(find.byIcon(Icons.arrow_back)));
    await tester.pumpAndSettle();
    expect(find.byType(RemotePage), findsNothing, reason: '返回即回相机页');
    expect(find.text('进入拍摄'), findsOneWidget, reason: '相机页回来了');
    expect(f.remote.liveViewActive, isTrue, reason: '取景不因离页停');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '离页只挂起帧轮询,取景生命周期跟连接走');
  });

  testWidgets('横锁离页还竖:返回相机页回竖屏,锁态复位、再进从竖起步'
      '(portraitUp 具体方向,永不发空表)', (tester) async {
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
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport);
    f.transport
      ..okFor(NikonOperationCode.startLiveView)
      ..okFor(NikonOperationCode.getLiveViewImageEx, data: _realJpeg());
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    _scriptParams(f.transport); // 进页对表
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();

    List<MethodCall> orientationCalls() => [
          for (final c in calls)
            if (c.method == 'SystemChrome.setPreferredOrientations') c,
        ];

    // 点方向钮:auto(竖屏)→ 锁横
    await tester.tap(_inRemotePage(find.byIcon(Icons.screen_rotation)));
    await tester.pumpAndSettle();
    expect(f.remote.orientationLock.value, OrientationLock.landscape);
    expect(
        orientationCalls().last.arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);

    // 返回:离页收口 —— 外壳还竖(具体方向 portraitUp,非空表 All
    // mask);锁态复位 portrait(方向钮是监看页专属,SystemChrome 全局)。
    await tester.tap(_inRemotePage(find.byIcon(Icons.arrow_back)));
    await tester.pumpAndSettle();
    expect(find.byType(RemotePage), findsNothing);
    expect(find.text('进入拍摄'), findsOneWidget, reason: '回相机页');
    expect(f.remote.orientationLock.value, OrientationLock.portrait,
        reason: '锁态复位:再进从竖起步');
    expect(orientationCalls().last.arguments, ['DeviceOrientation.portraitUp'],
        reason: '横锁还竖发具体方向,永不发空表');

    // 再进:从竖起步(零新方向消息),点按直切横(portrait→landscape,
    // 不绕 auto,无白点一击)。
    _scriptParams(f.transport); // 进页对表
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();
    expect(orientationCalls(), hasLength(2),
        reason: '进页不自动转屏(锁已复位 portrait)');
    await tester.tap(_inRemotePage(find.byIcon(Icons.screen_rotation)));
    await tester.pumpAndSettle();
    expect(orientationCalls(), hasLength(3));
    expect(
        orientationCalls().last.arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
  });

  testWidgets('断连自动退页:监看中断连 pop 回相机页(连接方式视图,'
      '重连入口在彼)', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport);
    f.transport
      ..okFor(NikonOperationCode.startLiveView)
      ..okFor(NikonOperationCode.getLiveViewImageEx, data: _realJpeg());
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    _scriptParams(f.transport); // 进页对表
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();
    expect(find.byType(RemotePage), findsOneWidget);
    expect(f.remote.liveViewActive, isTrue);

    // 断连(拔线/掉网):取景随连接收口(0x9202),页面自动退回
    // 相机页 —— 链路没了监看页无从看,重连入口在相机页。
    f.transport.okFor(NikonOperationCode.endLiveView);
    f.conn.statesCtrl.add(CameraLinkState.disconnected);
    await tester.pumpAndSettle();
    expect(f.remote.liveViewActive, isFalse);
    expect(find.byType(RemotePage), findsNothing, reason: '断连即退页');
    expect(find.text('有线'), findsOneWidget,
        reason: '相机页回未连接主视图(方式行,默认有线)');
    expect(find.byKey(const ValueKey('conn_method_hero')), findsOneWidget,
        reason: 'hero 在场(点按即连接;五轮中央连接钮退役)');
    expect(find.text('进入拍摄'), findsNothing, reason: '入口随断连消失');
  });

  testWidgets('横屏外壳:底栏换左侧 NavigationRail,tab 切换照常(三 tab)',
      (tester) async {
    tester.view
      ..physicalSize = const Size(2400, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    expect(find.byType(NavigationRail), findsOneWidget, reason: '横屏换 rail');
    expect(find.byType(NavigationBar), findsNothing,
        reason: '底栏退位(80px 高度还给监看画面)');
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0,
        reason: '初始在相机 tab');

    await tester.tap(_railTab('图库'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
        reason: 'rail 切台照常');
  });

  testWidgets('竖屏底栏样式闸:胶囊撤除、选中直充 secondary', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    await pumpShell(tester, MaterialApp(
        theme: AppTheme.light,
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));

    // 胶囊撤除(2026-10-26 定案):指示器随布局仍挂件但必须透明,选中
    // 图标+文字直充 secondary(亮 #8C7400),未选钉 onSurfaceVariant。
    // 底栏文字带显式 style,直接从 Text 取。
    const selected = Color(0xFF8C7400);
    const unselected = Color(0xFF57534A);
    final indicators = tester
        .widgetList<NavigationIndicator>(find.byType(NavigationIndicator));
    expect(indicators.length, 3, reason: '三目的地各挂一枚指示器');
    for (final indicator in indicators) {
      expect(indicator.color, Colors.transparent, reason: '胶囊=指示器透明');
    }
    final selectedIcon = find.descendant(
        of: find.byType(NavigationBar), matching: find.byIcon(Icons.photo_camera));
    expect(IconTheme.of(tester.element(selectedIcon)).color, selected,
        reason: '选中图标直充(实底相机图标只在选中位渲染)');
    expect(tester.widget<Text>(_navTab('相机')).style?.color, selected,
        reason: '选中文字直充');
    expect(tester.widget<Text>(_navTab('图库')).style?.color, unselected,
        reason: '未选文字钉 onSurfaceVariant');
    // 按压涟漪与胶囊同形,随胶囊一并撤(底栏走主题 overlayColor 钩子)。
    expect(
        Theme.of(tester.element(find.byType(NavigationBar)))
            .navigationBarTheme
            .overlayColor
            ?.resolve(const {WidgetState.pressed}),
        Colors.transparent,
        reason: '点击不闪胶囊涟漪');
  });

  testWidgets('横屏 rail 样式闸:胶囊撤除、选中直充,三 tab 重排无溢出',
      (tester) async {
    tester.view
      ..physicalSize = const Size(2400, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    await pumpShell(tester, MaterialApp(
        theme: AppTheme.light,
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));

    // 同底栏一套色;rail 落件方式不同 —— 图标包 IconTheme、文字包
    // DefaultTextStyle(Text 自身 style 为 null),断言各从其取。
    const selected = Color(0xFF8C7400);
    const unselected = Color(0xFF57534A);
    final indicators = tester
        .widgetList<NavigationIndicator>(find.byType(NavigationIndicator));
    expect(indicators.length, 3, reason: '三目的地各挂一枚指示器');
    for (final indicator in indicators) {
      expect(indicator.color, Colors.transparent, reason: '胶囊=指示器透明');
    }
    final selectedIcon = find.descendant(
        of: find.byType(NavigationRail), matching: find.byIcon(Icons.photo_camera));
    expect(IconTheme.of(tester.element(selectedIcon)).color, selected,
        reason: '选中图标直充');
    expect(DefaultTextStyle.of(tester.element(_railTab('相机'))).style.color,
        selected,
        reason: '选中文字直充');
    expect(DefaultTextStyle.of(tester.element(_railTab('图库'))).style.color,
        unselected,
        reason: '未选文字钉 onSurfaceVariant');
    // rail 无 overlayColor 钩子(涟漪硬编码 primary),外壳局部 Theme
    // 把子树 primary 覆透明 → 涟漪/悬停全灭。
    final railLocalTheme = tester.firstWidget<Theme>(
        find.ancestor(of: find.byType(NavigationRail), matching: find.byType(Theme)));
    expect(railLocalTheme.data.colorScheme.primary, Colors.transparent,
        reason: '点击不闪胶囊涟漪(rail 涟漪=primary)');

    // 三 tab 逐台重排:横屏宽幅下各页回流不溢出(RenderFlex 溢出在
    // 测试框架即判败,takeException 再兜一层显式断言)。
    for (final label in const ['相机', '图库', '设置']) {
      await tester.tap(_railTab(label));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull, reason: '三 tab 横屏无溢出/异常');
  });

  testWidgets('竖→横旋转:拍摄页状态全程保留(网格在、取景不重启)',
      (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(FIFO 道)
    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道,此后 delay 挂起)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(f.remote.liveViewActive, isTrue);

    _scriptParams(f.transport); // 进页对表
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();
    // 开网格(页面 State)—— 旋转后此开关必须还在。辅助开关收进胶囊
    // tune 钮浮层(2026-10-08 手机相机式竖屏排版):先开面板再开网格。
    await tester.tap(_inRemotePage(find.byIcon(Icons.tune)));
    await tester.pumpAndSettle();
    await tester.tap(_inRemotePage(find.byIcon(Icons.grid_on)));
    await tester.pumpAndSettle();
    expect(_inRemotePage(find.byType(GridOverlay)), findsOneWidget);
    expect(_inRemotePage(find.byType(Image)), findsOneWidget,
        reason: '首帧在屏');

    // 旋转到横屏:页面 State 全程保留(拍摄页是独立路由,不随外壳
    // 横竖切换重排;网格开关/帧不动)
    tester.view.physicalSize = const Size(2400, 800);
    await tester.pumpAndSettle();
    expect(_inRemotePage(find.byType(GridOverlay)), findsOneWidget,
        reason: '网格开关跨旋转保留');
    expect(_inRemotePage(find.byType(Image)), findsOneWidget, reason: '帧不丢');
    expect(f.remote.liveViewActive, isTrue);
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '旋转不重启取景');
  });

  testWidgets('方向锁定全程:点按横竖直切不丢锁、旋转不误发消息'
      '(真机回归:竖→横→竖闪屏 + 白点一击 —— 点按永不发空表,图标恒定)',
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
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(FIFO 道)
    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();

    _scriptParams(f.transport); // 进页对表
    await tester.tap(find.text('进入拍摄'));
    await tester.pumpAndSettle();

    List<MethodCall> orientationCalls() => [
          for (final c in calls)
            if (c.method == 'SystemChrome.setPreferredOrientations') c,
        ];

    // 第一击:竖屏下 auto 翻转屏向 → 锁横,系统随之转横(图标恒定)
    await tester.tap(_inRemotePage(find.byIcon(Icons.screen_rotation)));
    await tester.pumpAndSettle();
    expect(_inRemotePage(find.byIcon(Icons.screen_rotation)), findsOneWidget,
        reason: '图标恒定,不随锁态换形');
    expect(orientationCalls(), hasLength(1));
    expect(
        orientationCalls().last.arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    tester.view.physicalSize = const Size(2400, 800);
    await tester.pumpAndSettle();

    // 第二击:直切锁竖(landscape → portrait,不绕 auto —— auto 空表
    // 在 iOS 是 All mask,真机按物理姿态闪转的元凶)
    await tester.tap(_inRemotePage(find.byIcon(Icons.screen_rotation)));
    await tester.pumpAndSettle();
    expect(orientationCalls(), hasLength(2), reason: '只该有一次锁竖消息');
    expect(
        orientationCalls().last.arguments, ['DeviceOrientation.portraitUp']);
    tester.view.physicalSize = const Size(800, 2400);
    await tester.pumpAndSettle();

    // 旋转后:锁仍竖,且旋转全程零多余消息 —— 锁挂控制器,页面重建
    // 不丢、不补发 auto(闪屏元凶);横锁的离页还竖是另一条沿(见
    // 「横锁离页还竖」测试),本测不离开页面。
    expect(orientationCalls(), hasLength(2),
        reason: '旋转不得触发复位消息(auto 空表会让真机按物理姿态闪转)');

    // 第三击:直切回锁横 —— 发 landscape 对即证锁竖态跨旋转存活;
    // 点按循环永不发空表(旧三态的 auto 空表按物理姿态闪转,白点多耗
    // 一击;图标恒定无长按,态只经消息序可见)
    await tester.tap(_inRemotePage(find.byIcon(Icons.screen_rotation)));
    await tester.pumpAndSettle();
    expect(orientationCalls(), hasLength(3));
    expect(
        orientationCalls().last.arguments,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    tester.view.physicalSize = const Size(2400, 800);
    await tester.pumpAndSettle();
    expect(orientationCalls(), hasLength(3), reason: '旋转零方向消息');
  });

  testWidgets('横滑切台:相机→图库→设置线性往复,底栏选中跟随,尽头不回绕',
      (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    expect(_selectedIndex(tester), 0, reason: '初始在相机 tab');

    // 左滑向深:相机→图库→设置(一次拖拽恰好跨一页:PageScrollPhysics
    // 落点按半页阈值取整)。
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1, reason: '左滑进图库,底栏跟随');
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2, reason: '再左滑进设置');

    // 右滑向浅:设置→图库→相机。
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1);
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0, reason: '滑回相机');

    // 尽头不回绕:设置页上再左滑,停在设置(线性往复,不绕回相机)。
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2);
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2, reason: '设置上左滑尽头不回绕');
  });

  testWidgets('连接中横滑切台:取景照开不停(0x9201 不重发、0x9202 不发、'
      '首帧后轮询挂起)', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    _scriptParams(f.transport); // connected → 控制器沿参数刷新(FIFO 道)
    f.transport
      ..okFor(NikonOperationCode.startLiveView) // 0x9201 连接即取景(引擎道)
      ..okFor(NikonOperationCode.getLiveViewImageEx,
          data: _realJpeg()); // 首帧(引擎道,此后 delay 挂起)
    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));
    f.conn.statesCtrl.add(CameraLinkState.connected);
    await tester.pumpAndSettle();
    expect(f.remote.liveViewActive, isTrue);

    // 横滑到图库:与底栏切台同一契约 —— 滑台只挂帧轮询,取景生命周期
    // 跟连接走。
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 1);
    expect(f.remote.liveViewActive, isTrue);
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.endLiveView),
        isEmpty,
        reason: '横滑切台不发 0x9202');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1),
        reason: '横滑切台不重启取景');
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
        hasLength(1),
        reason: '拍摄页未挂载:首帧后轮询挂起');

    // 滑回相机:同样不重启取景。
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0);
    expect(f.remote.liveViewActive, isTrue);
    expect(
        f.transport.requests
            .where((r) => r.opcode == NikonOperationCode.startLiveView),
        hasLength(1));
  });

  testWidgets('横滑往返页 State 常驻:设置页滑出 cacheExtent(相邻一页)'
      '不卸载重建(keepalive 等价旧 IndexedStack)', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = _fakes();
    addTearDown(f.connCtrl.dispose);
    addTearDown(f.remote.dispose);

    await pumpShell(tester, MaterialApp(
        home: HomeShell(
            connectionController: f.connCtrl, remoteController: f.remote)));

    // 相机→图库→设置:首次建设置页,记下 element。
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final before = tester.element(find.byType(SettingsPage));

    // 设置→图库→相机:相机页上设置页落在 cacheExtent(1 页)之外 ——
    // keepalive 必须钉住;若卸载重建,树里找不到旧 element。
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 0);
    final survivor = find.byType(SettingsPage, skipOffstage: false);
    expect(survivor, findsOneWidget,
        reason: 'keepalive:设置页滑出 cache 仍挂在树上(未卸载)');
    expect(identical(before, tester.element(survivor)), isTrue,
        reason: 'element 不换新(未重建,State 原地保留)');
  });
}

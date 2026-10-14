import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/remote/live_view_header.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';

final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void reply(int responseCode) =>
      script.add(PtpResult(responseCode: responseCode));
  void fail(Object e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)}');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventCtrl.stream;

  @override
  Future<void> close() async {}

  int count(int opcode) => requests.where((r) => r.opcode == opcode).length;
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

/// 手动放行的 delay(capture 的 DeviceReady 轮询节拍)。
final class _GatedDelay {
  final _gates = Queue<Completer<void>>();

  Future<void> call(Duration d) {
    final c = Completer<void>();
    _gates.add(c);
    return c.future;
  }

  void release() => _gates.removeFirst().complete();
}

/// PropDesc 数据集(u16 code + u16 type + u8 getSet + 当前值 + 出厂
/// 默认值 + FORM;ISO 15740 标准布局 —— 出厂值在 FORM 之前)。
Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, List<int>? enums}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
  // 值区顺序(gphoto2 ptp_unpack_DPD 权威):出厂默认值在前,当前值
  // 在后 —— 两者写不同值,解析器读反时 currentValue 会拿到出厂值,
  // 断言立刻炸(2026-10-06 光圈卡死 f/2.0 的教训)。
  type.write(w, current + 1); // 出厂默认值(值区第一个)
  type.write(w, current); // 当前值(值区第二个)
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

/// 目录序参数应答表(模式 A · f/2.8 · 1/100s · ISO 200 · EV+0.3 ·
/// 白平衡自动 · 色温 5500K · 闪光关闭 · 测光 2 · 对焦 AF-C · 对焦模式
/// AF-S · 释放单张 · 画质 RAW · RAW 无损 · 尺寸 2 · 区域 FX · 校准标准)。
typedef _ParamSpec = ({
  int code,
  PtpDataType type,
  int value,
  List<int>? enums,
});

const _kParamSpecs = <_ParamSpec>[
  (code: PtpDevicePropCode.exposureProgramMode, type: PtpDataType.uint16, value: 3, enums: [1, 2, 3, 4, 5]),
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

/// u32 裸值应答字节(小端)。
Uint8List _u32Bytes(int v) => Uint8List.fromList(
    [for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF]);

/// 目录序全量应答:PropDesc(取值域直供表参数跳过 —— 快门不读标准码
/// PropDesc)+ 值回读(路由参数读厂商码裸值)+ 末尾自动 ISO 状态
/// (0xD054 裸读,u8)。[mode] 参数化曝光模式值(默认 M=1:快门/光圈/
/// ISO 都可调;[modeUnreadable] 模拟模式读不到 → 不猜锁);
/// readonlyCodes 指定只读属性;[picCtrlEnums]/[picCtrlValue] 覆写优化校准
/// 的 FORM 枚举与当前值(默认 [1,2,3,4] 全静态表内,不触发 0x90CC)。
/// 0xD1A6 模式镜像应答**不在**本表 —— 连接沿串链在 refreshParams 之前
/// 先读它(模式读打头:视频档进页即时跟随,2026-10-11 真机反馈),预置
/// 在 [_emitConnected](队首,让过 0x90CC 等刷参中段的追加应答)。
void _scriptParams(_ScriptTransport t,
    {Set<int> readonlyCodes = const {},
    int mode = 1,
    int drive = 1,
    bool modeUnreadable = false,
    List<int>? picCtrlEnums,
    int picCtrlValue = 1,
    bool tail = true}) {
  for (final s in _kParamSpecs) {
    var value = s.value;
    if (s.code == PtpDevicePropCode.exposureProgramMode) value = mode;
    if (s.code == PtpDevicePropCode.stillCaptureMode) value = drive;
    if (s.code == PtpDevicePropCode.activePicCtrlItem && picCtrlEnums != null) {
      value = picCtrlValue;
    }
    final param = shootingParamByCode[s.code]!;
    if (s.code == PtpDevicePropCode.exposureProgramMode && modeUnreadable) {
      t
        ..reply(PtpResponseCode.operationNotSupported) // desc 拒
        ..reply(PtpResponseCode.generalError); // 裸值也拒 → 值 null
      continue;
    }
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(s.code, s.type, value,
          getSet: !readonlyCodes.contains(s.code),
          enums: (s.code == PtpDevicePropCode.activePicCtrlItem
              ? picCtrlEnums
              : s.enums)));
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
  if (tail) {
    t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
    t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数
  }
}

/// 视频档全量刷参块(照片参数无尾 + 视频参数族 + 自动 ISO + 剩余张数
/// —— 消费序 = refreshParams 的 [照片参数 → 视频参数 → 0xD054 →
/// 0xD1F1],视频档追加视频族,尾两读永远在最后)。
void _scriptParamsVideo(_ScriptTransport t) {
  _scriptParams(t, tail: false);
  _scriptVideoParams(t);
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数
}

/// 0x90CC GetPictCtrlData 应答数据集(digiCamControl 布局:[0]未知
/// [1]单色 [2]自定义 [3..23) ASCII 名 NUL 填充;尾部补到 32B)。
Uint8List _picCtrlData(String name) {
  final b = Uint8List(32);
  b[2] = 1; // 自定义标志
  for (var i = 0; i < name.length && i < 20; i++) {
    b[3 + i] = name.codeUnitAt(i);
  }
  return b;
}

/// 视频参数族应答块(2026-10-12 官方 §6.5.3/§6.5.12 目录落地):视频档
/// 连接沿/事件沿的补刷都会消费它。FORM 驱动参数(无 pickValues)给
/// PropDesc,直供参数给裸值;N-Log 只读(getSet=false),[logOutput]
/// 参数化它的值。
const _kVideoParamTypes = <int, PtpDataType>{
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

const _kVideoParamValues = <int, int>{
  PtpDevicePropCode.movieFnumber: 200, // ƒ/2.0
  PtpDevicePropCode.movieShutterSpeed: 1 << 16 | 50, // 1/50s
  PtpDevicePropCode.movieExposureIndex: 100,
  PtpDevicePropCode.movieExposureBiasCompensation: 0,
  PtpDevicePropCode.movieWhiteBalance: 0x8015, // 同照片设置
  PtpDevicePropCode.movieLogOutput: 0,
  PtpDevicePropCode.movieVibrationReduction: 0,
  PtpDevicePropCode.electronicVR: 0,
  PtpDevicePropCode.recordTimeCodes: 0,
  PtpDevicePropCode.timeCodeCountUpMethod: 0,
  PtpDevicePropCode.timeCodeDropFrame: 1,
  PtpDevicePropCode.movieCaptureAreaCrop: 0,
  PtpDevicePropCode.movieH265ToneMode: 0,
};

void _scriptVideoParams(_ScriptTransport t, {int logOutput = 0}) {
  for (final param in kVideoShootingParams) {
    final type = _kVideoParamTypes[param.code]!;
    var value = _kVideoParamValues[param.code]!;
    if (param.code == PtpDevicePropCode.movieLogOutput) value = logOutput;
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(param.code, type, value,
          getSet: param.code != PtpDevicePropCode.movieLogOutput));
    } else {
      t.ok(data: _rawValueBytes(type, value));
    }
  }
}

/// PropDesc 全拒的回退应答(值走裸读;路由参数读厂商码)。
void _scriptParamsRawFallback(_ScriptTransport t, {int mode = 1}) {
  for (final s in _kParamSpecs) {
    final value = s.code == PtpDevicePropCode.exposureProgramMode ? mode : s.value;
    final param = shootingParamByCode[s.code]!;
    if (param.pickValues == null) {
      t.reply(PtpResponseCode.operationNotSupported); // 0x1014 拒
    }
    final vendor = _kVendorReadValues[s.code];
    if (vendor != null) {
      t.ok(data: _u32Bytes(vendor));
    } else {
      t.ok(data: _rawValueBytes(s.type, value));
    }
  }
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数
}

/// 裸值应答字节(按类型宽度:u8 一字节 / u16 两字节 / u32 四字节)。
Uint8List _rawValueBytes(PtpDataType type, int value) {
  final width = type.width!;
  return Uint8List.fromList(
      [for (var i = 0; i < width; i++) (value >> (8 * i)) & 0xFF]);
}

/// GetDeviceInfo 数据集(布局独立于被测代码;ops 可注入 —— 快门码
/// 选择用)。
Uint8List _deviceInfoDataset({required List<int> ops}) {
  final w = ByteWriter()
    ..u16(0x0100) // StandardVersion
    ..u32(0x0000000A) // VendorExtensionId(尼康)
    ..u16(0x0064); // VendorExtensionVersion
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str('Nikon'); // VendorExtensionDesc
  w.u16(0x0000); // FunctionalMode 标准
  w.u32(ops.length);
  for (final op in ops) {
    w.u16(op);
  }
  w.u32(0); // events
  w.u32(0); // deviceProps
  w.u32(0); // captureFormats
  w.u32(0); // imageFormats
  str('Nikon Corp'); // manufacturer
  str('TestModel'); // model
  str('V1.00'); // deviceVersion
  str('012345678901'); // serialNumber
  return w.takeBytes();
}

/// 挂起的 delay(永不完成):引擎帧轮询/AE 轮询在测试里驻停,
/// 不与被测路径抢脚本应答。
Future<void> _parkedDelay(Duration _) => Completer<void>().future;

/// 发 connected 沿(预置串链头三位于队首):控制器 connected 沿串链
/// [0xD1A6 模式读, 0x9201, 首帧, 参数…] 按序消费,故必须排在
/// [_scriptParams] 应答之前(2026-10-11 起景驱动移入控制器 connected
/// 沿 + 模式读打头);引擎轮询首帧后驻停于门控/parked delay,不与后续
/// 脚本抢位。0xD1A6 模式镜像应答([d1a6]:0=照片/1=视频)在链首 ——
/// 测试追加的 0x90CC 等刷参中段应答仍按追加序被 refreshParams 消费。
void _emitConnected(_ScriptTransport t, _FakeConnection c, {int d1a6 = 0}) {
  t.script
    ..addFirst(PtpResult(
        responseCode: PtpResponseCode.ok, data: _fakeFrame())) // 首帧
    ..addFirst(PtpResult(responseCode: PtpResponseCode.ok)) // 0x9201
    ..addFirst(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([d1a6]))); // 0xD1A6(链首读)
  c.statesCtrl.add(CameraLinkState.connected);
}

/// SOF-only 假帧(SOI + SOF0 段头,32×24):够 jpegSofSize 取尺寸,
/// 不必是可解码 JPEG(控制器测试不渲染)。
Uint8List _fakeFrame({int width = 32, int height = 24}) =>
    Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xC0, 0x00, 0x0B, 0x08, // SOF0:段长 11、精度 8
      (height >> 8) & 0xFF, height & 0xFF, // 高
      (width >> 8) & 0xFF, width & 0xFF, // 宽
      0x01, 0x00, 0x00, 0x00, // 1 分量(占位,尺寸解析不读)
    ]);

/// 最小 display-info 头(坐标系 6048×3400、单框;[recording] 写 @828):
/// 头按真机形态补 1024B 定长 + SOI JPEG 尾(头长靠 SOI 位置定位),
/// 控制器测试直接注到 engine.header。
Uint8List _minimalHeaderFrame({required bool recording}) {
  final b = Uint8List(1024 + 4);
  void be16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  be16(16, 6048);
  be16(18, 3400);
  b[42] = 2; // 合焦
  b[44] = 1; // areaCount
  be16(48, 240);
  be16(50, 240);
  be16(52, 3024);
  be16(54, 1700);
  if (recording) b[828] = 1;
  b[1024] = 0xFF;
  b[1025] = 0xD8;
  b[1026] = 0xFF;
  return b;
}

/// GetObjectInfo 数据集(SDRAM 直拍链测试):52B 定长头 + 文件名/拍摄/
/// 修改三串(format 0x3801 = JPEG → ObjectKind.image)。
Uint8List _objectInfoDataset({
  String name = 'DSC_0001.JPG',
  int size = 123456,
  int format = 0x3801,
}) {
  final w = ByteWriter()
    ..u32(1) // storageId
    ..u16(format)
    ..u16(0) // protection
    ..u32(size)
    ..u16(0)..u32(0)..u32(0)..u32(0) // 缩略图四件
    ..u32(0)..u32(0)..u32(0) // 图像宽/高/位深
    ..u32(0) // parentObject
    ..u16(0)..u32(0)..u32(0); // assocType/assocDesc/sequence
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str(name);
  str('20261013T120000.0');
  str('20261013T120000.0');
  return w.takeBytes();
}

/// 0x941C GetEventEx 数据集(单事件单参数)。
Uint8List _eventExDataset(int code, int param) {
  final w = ByteWriter()
    ..u32(1)
    ..u16(code)
    ..u16(1)
    ..u32(param);
  return w.takeBytes();
}

/// 图库导入假引擎(SDRAM 直拍收尾链):enqueue 记账并广播一帧终态。
final class _FakeTransferEngine implements TransferEngine {
  final enqueued = <ObjectEntry>[];
  TransferDestination? lastDestination;
  TransferState state = TransferState.completed;
  final tasksCtrl = StreamController<List<TransferTask>>.broadcast();

  @override
  Stream<List<TransferTask>> get tasks => tasksCtrl.stream;

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {
    enqueued.addAll(entries);
    lastDestination = destination;
    for (final e in entries) {
      tasksCtrl.add([
        TransferTask(
          id: 't0',
          handle: e.handle,
          filename: e.name,
          totalBytes: e.sizeInBytes,
          destination: destination,
          state: state,
        ),
      ]);
    }
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

void main() {
  late _ScriptTransport transport;
  late _FakeConnection conn;
  late _GatedDelay delay;
  late RemoteController controller;

  setUp(() {
    transport = _ScriptTransport();
    conn = _FakeConnection();
    delay = _GatedDelay();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
        session: PtpSession(transport: transport),
        delay: delay.call,
      ),
      delay: delay.call,
    );
  });

  tearDown(() async {
    controller.dispose();
  });

  test('连接成功 → 参数自动刷新(目录全量:三要素 + 模式/白平衡等)', () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 280);
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
        reason: '快门值 = 0xD100 打包分数(1/100s),标准码不跟厂商写');
    expect(controller.exposure?.iso, 200, reason: 'ISO 值 = 0xD0B5 有效 ISO');
    expect(controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value,
        1, reason: '模式 = 手动 M(默认脚本:快门/光圈/ISO 都可调)');
    expect(controller.paramProps[PtpDevicePropCode.whiteBalance]?.value, 2);
    expect(controller.linkUp, isTrue);
  });

  test('capture:CaptureComplete 事件先到 → 提前收口,轮询不到 10 次', () async {
    transport.ok(); // initiateCapture
    transport.reply(PtpResponseCode.deviceBusy); // 第 1 轮 DeviceReady:忙
    transport.reply(PtpResponseCode.deviceBusy); // 第 2 轮 DeviceReady:忙
    final capture = controller.capture();
    await pumpEventQueue();
    expect(controller.capturing, isTrue);

    delay.release(); // 第 1 轮 300ms 到点 → DeviceReady 忙(false)
    await pumpEventQueue();
    delay.release(); // 第 2 轮
    await pumpEventQueue();
    expect(
        transport.count(NikonOperationCode.deviceReady), 2,
        reason: '前两轮均在等待,尚未收口');

    // 事件到达 → 下一轮 Future.any 命中事件分支
    transport.eventCtrl.add(const PtpEvent(code: PtpEventCode.captureComplete, transactionId: 0xFFFFFFFF));
    await capture;
    expect(controller.capturing, isFalse);
    expect(controller.error, isNull);
    expect(transport.count(NikonOperationCode.deviceReady), 2,
        reason: '事件收口后不再轮询');
  });

  test('capture:无事件 → DeviceReady 兜底收口', () async {
    transport.ok(); // initiateCapture
    transport.ok(); // deviceReady → true
    final capture = controller.capture();
    await pumpEventQueue();
    delay.release();
    await capture;
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 1);
  });

  test('capture:DeviceReady 非忙错误 → 放弃兜底不算失败(命令已被接受)',
      () async {
    transport.ok(); // initiateCapture
    transport.reply(PtpResponseCode.operationNotSupported); // deviceReady 抛
    final capture = controller.capture();
    await pumpEventQueue();
    delay.release();
    await capture;
    expect(controller.capturing, isFalse);
    expect(controller.error, isNull);
  });

  test('capture:快门 0x2019 忙 → 报错且不轮询', () async {
    transport
      ..reply(PtpResponseCode.deviceBusy) // 首选码忙(0x9207)
      ..ok(data: _u32Bytes(0x0)); // 0xD102 复核:无警告位
    await controller.capture();
    expect(controller.error, contains('快门释放失败'));
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
    expect(transport.count(PtpOperationCode.initiateCapture), 0,
        reason: '忙不是换码信号,不得回退');
  });

  test('capture:0x200F 拒(机顶拨杆在视频档)→ 拨杆指向性提示;'
      '换码重试同拒不成功', () async {
    transport
      ..reply(PtpResponseCode.accessDenied) // 0x9207(波轮视频档,相机锁定)
      ..reply(PtpResponseCode.accessDenied); // 0x100E 换码重试同拒
    await controller.capture();
    expect(controller.error, contains('照片/视频'));
    expect(controller.error, contains('拨回照片档'));
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0,
        reason: '被拒不进入落地等待');
  });

  test('capture:0x2013 双因提示(卡检查 + 视频档别名),换码重试同拒不成功',
      () async {
    transport
      ..reply(PtpResponseCode.storeNotAvailable) // 0x9207(视频档另证/无卡)
      ..reply(PtpResponseCode.storeNotAvailable); // 0x100E 换码重试同拒
    await controller.capture();
    expect(controller.error, contains('存储卡与插槽'),
        reason: '标准义在先:无卡/卡错误照旧指卡槽');
    expect(controller.error, contains('视频档'),
        reason: '卡在位时的别名也指(2026-10-11 真机)');
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
  });

  test('capture:首选 0x9207 被拒(无 op 表缓存时默认现代面)→ 回退 0x100E,'
      '后续直发', () async {
    transport
      ..reply(PtpResponseCode.generalError) // 0x9207:被拒(异常态/老机身)
      ..ok() // 0x100E 回退成功
      ..ok(); // deviceReady → true
    final first = controller.capture();
    await pumpEventQueue();
    delay.release(); // 第 1 轮 DeviceReady
    await first;
    expect(controller.error, isNull);
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
    expect(transport.count(PtpOperationCode.initiateCapture), 1);

    // 第二次:直发缓存码 0x100E,不再重试尼康码
    transport
      ..ok() // 0x100E 直发
      ..ok(); // deviceReady → true
    final second = controller.capture();
    await pumpEventQueue();
    delay.release(); // 第 1 轮 DeviceReady
    await second;
    expect(controller.error, isNull);
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
        reason: '缓存码后不再重试尼康码');
    expect(transport.count(PtpOperationCode.initiateCapture), 2);
  });

  test('capture:两码皆拒 → 报后码异常,不轮询', () async {
    transport
      ..reply(PtpResponseCode.generalError) // 0x9207 拒
      ..reply(PtpResponseCode.operationNotSupported) // 0x100E 也拒
      ..ok(data: _u32Bytes(0x0)); // 0xD102 复核:无警告位
    await controller.capture();
    expect(controller.error, contains('快门释放失败'));
    expect(controller.error, contains('0x100E'), reason: '回退码失败更可诊断');
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
  });

  test('capture:0x9207 报 0x201D(参数域拒)→ CaptureSort 换形重试,'
      '成功形缓存直发', () async {
    transport
      ..reply(PtpResponseCode.invalidParameter) // 0xFFFFFFFF 被拒(真机形态)
      ..ok() // 0x00000000 旧实证形成功
      ..ok(); // deviceReady
    final first = controller.capture();
    await pumpEventQueue();
    delay.release();
    await first;
    expect(controller.error, isNull);
    final mediaOps = transport.requests
        .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
        .toList();
    expect(mediaOps, hasLength(2));
    expect(mediaOps[0].params, [0xFFFFFFFF, 0]);
    expect(mediaOps[1].params, [0x00000000, 0], reason: '换形重试');

    // 第二次:直发缓存形 0x0000
    transport
      ..ok() // 0x9207 直发(缓存形)
      ..ok(); // deviceReady
    final second = controller.capture();
    await pumpEventQueue();
    delay.release();
    await second;
    final mediaOps2 = transport.requests
        .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
        .toList();
    expect(mediaOps2, hasLength(3));
    expect(mediaOps2[2].params, [0x00000000, 0], reason: '成功形缓存直发');
  });

  test('capture:CaptureSort 全形态皆 0x201D → 报错不轮询(0x100E 不掺和)',
      () async {
    transport
      ..reply(PtpResponseCode.invalidParameter) // 0xFFFFFFFF
      ..reply(PtpResponseCode.invalidParameter) // 0x00000000
      ..reply(PtpResponseCode.invalidParameter); // 0xFFFFFFFE
    await controller.capture();
    expect(controller.error, contains('0x201D'));
    expect(controller.error, contains('全部已知形态'));
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 3);
    expect(transport.count(PtpOperationCode.initiateCapture), 0,
        reason: '参数域错误不换码');
    expect(transport.count(NikonOperationCode.deviceReady), 0);
  });

  test('capture:对焦后拍开 = 固定 0xFFFFFFFE,被 0x201D 拒后仍换形兜底',
      () async {
    controller.focusBeforeCapture = true;
    transport
      ..reply(PtpResponseCode.invalidParameter) // 0xFFFFFFFE 被拒
      ..ok() // 0xFFFFFFFF 兜底成功
      ..ok(); // deviceReady
    final c = controller.capture();
    await pumpEventQueue();
    delay.release();
    await c;
    expect(controller.error, isNull);
    final mediaOps = transport.requests
        .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
        .toList();
    expect(mediaOps[0].params, [0xFFFFFFFE, 0], reason: '显式意图先行');
    expect(mediaOps[1].params, [0xFFFFFFFF, 0], reason: '拒后按候选序兜底');
  });

  group('快门码 op 表选择(OpenZCine 全系口径:在册 0x9207 直用)', () {
    test('表在册 0x9207 → 首发直用,零标准码流量', () async {
      transport.ok(data: _deviceInfoDataset(
          ops: [NikonOperationCode.initiateCaptureRecInMedia]));
      await controller.session.getDeviceInfo(); // 连接层已取过,预热缓存
      transport
        ..ok() // 0x9207 直发
        ..ok(); // deviceReady
      final c = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c;
      expect(transport.count(PtpOperationCode.initiateCapture), 0,
          reason: '在册即直用,不试标准码');
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
    });

    test('表不含 0x9207(STA 小表人设)→ 标准码先行,被拒回退 0x9207',
        () async {
      transport.ok(data: _deviceInfoDataset(ops: [PtpOperationCode.getObject]));
      await controller.session.getDeviceInfo();
      transport
        ..reply(PtpResponseCode.generalError) // 0x100E:被拒
        ..ok() // 0x9207 回退成功
        ..ok(); // deviceReady
      final c = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c;
      expect(transport.count(PtpOperationCode.initiateCapture), 1);
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
      expect(controller.error, isNull);
    });
  });

  group('APP 接管控制(0x90C2 remote 模式,影控台同款)', () {
    test('启用 → 0x90C2 [1] + 状态;解除 → [0]', () async {
      transport.ok(); // 0x90C2 [1]
      expect(await controller.enableTakeover(), isTrue);
      expect(controller.takeoverActive, isTrue);
      final enable = transport.requests
          .singleWhere((r) => r.opcode == NikonOperationCode.changeCameraMode);
      expect(enable.params, [1]);

      transport.ok(); // 0x90C2 [0]
      await controller.releaseTakeover();
      expect(controller.takeoverActive, isFalse);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
              .last
              .params,
          [0]);
    });

    test('启用被拒(0xA003 释放/AF 中)→ false + 友好提示', () async {
      transport.reply(NikonResponseCode.changeCameraModeFailed);
      expect(await controller.enableTakeover(), isFalse);
      expect(controller.takeoverActive, isFalse);
      expect(controller.error, contains('相机模式切换失败'));
    });

    test('未连接启用 → 提示不发', () async {
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(await controller.enableTakeover(), isFalse);
      expect(transport.requests, isEmpty);
    });

    test('断链时持有接管 → 重连后防御性解除(拨盘不留锁)', () async {
      transport.ok(); // 启用接管
      await controller.enableTakeover();
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(controller.takeoverActive, isFalse, reason: '断链即失效');

      // 生产链建模:断链 teardown 即 session.close()(camera_connection
      // 顺序),remote 旗标随链复位 —— 否则重连沿会把它误读作「连接流
      // 已进 remote 模式」而跳过防御性解除。(会话未 Open 时 close 不
      // 下链路,无 closeSession 应答可消费。)
      await controller.session.close();

      // 重连:先防御性解除,再全量刷参
      transport.ok(); // 0x90C2 [0]
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      final modes = transport.requests
          .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
          .toList();
      expect(modes, hasLength(2));
      expect(modes[1].params, [0], reason: '重连后防御性解除 remote 模式');
      expect(controller.exposure?.fNumber, 280, reason: '解除后照常刷参');
    });

    test('USB 连接流括号 1→0 全通 → 接管从 OFF 起步(连接即及时取景)'
        '(OpenZCine 效果,2026-10-07 v8/v9 真机定案)', () async {
      // 生产链建模:USB 连接流 enableAppControl(remoteLatch) 的
      // 0x90C2(1)→(0) 开闩括号 —— 闩单向,退步不关门;remote 持有态
      // 才是机身停「已连接到计算机」屏的元凶,开闩即还身(已连接屏只
      // 闪一次往返的宽度,机身直回自己的取景屏)。
      transport.reply(PtpResponseCode.operationNotSupported); // 0x9435 拒
      transport.ok(); // 0x90C2 [1] 开闩兜底通
      transport.ok(); // 0x90C2 [0] 括号退步通(还身)
      await controller.session.enableAppControl(remoteLatch: true);
      expect(controller.session.remoteModeActive, isFalse,
          reason: '开闩即还身,remote 不持有');

      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.takeoverActive, isFalse,
          reason: '连接流已还身,接管芯片从 OFF 起步');
      expect(controller.exposure?.fNumber, 280, reason: '照常刷参');

      // 未激活:enableTakeover 真发 0x90C2 [1](接管是用户的显式动作)。
      transport.ok();
      expect(await controller.enableTakeover(), isTrue);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
              .map((r) => r.params),
          [
            [1],
            [0],
            [1]
          ],
          reason: '连接括号 [1][0] + 用户接管 [1]');
    });

    test('断链悬挂 + 新链括号退步被拒 → 静默对齐接管,不发防御性解除'
        '(不与括号退步重复)', () async {
      transport.ok(); // 启用接管
      await controller.enableTakeover();
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      await controller.session.close(); // teardown 建模(旗标复位)

      // 新链:连接流括号的退步被拒(边沿:机身正忙/模式切换中)→
      // remote 仍持有 —— connected 沿静默对齐接管态;防御性解除不再发
      // (对齐分支先于悬挂分支,重复 [0] 无益;闩已开,门不会丢)。
      transport.reply(PtpResponseCode.operationNotSupported); // 0x9435 拒
      transport.ok(); // 0x90C2 [1] 开闩通
      transport.reply(NikonResponseCode.changeCameraModeFailed); // [0] 退步被拒
      await controller.session.enableAppControl(remoteLatch: true);
      expect(controller.session.remoteModeActive, isTrue,
          reason: '退步被拒 → remote 仍持有');
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.takeoverActive, isTrue,
          reason: '新链的 remote 是连接括号抬的,不是悬挂残留');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
              .map((r) => r.params),
          [
            [1],
            [1],
            [0]
          ],
          reason: '旧链接管 [1] + 新链括号 [1][0];无防御性解除的第 4 发');
      expect(controller.exposure?.fNumber, 280, reason: '照常刷参');

      // 已激活:enableTakeover 幂等直通,不再发 0x90C2。
      expect(await controller.enableTakeover(), isTrue);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
              .length,
          3);
    });

    test('拨盘参数写被拒(0x200F)→ 提示先启用 APP 接管', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      transport.reply(PtpResponseCode.accessDenied); // 0x1016 0xD100 被拒
      await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
      expect(controller.error, contains('APP 接管'));
    });
  });

  group('拍摄模式跟随与切换(0xD1A6 镜像;2026-10-11 Zf USB 实证:两方向都'
      '可覆写、拍照门跟镜像值;录像门跟物理拨杆硬互锁,开录时才拒)', () {
    test('连接沿初读:0xD1A6=1 → 视频;表外方言值(2)不猜 → null 本地回落',
        () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.video);
      expect(controller.dialMode, CaptureMode.video);
      expect(controller.modeOverridden, isFalse);

      // 重连报表外值(未来机身第三态/方言):已知值不清,宁缺不错。
      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 2);
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.video,
          reason: '表外值不猜也不闪清:保持已知态');
    });

    test('0x4006(0xD1A6)事件 → 模式跟随(拨杆翻转实时上屏)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn); // d1a6=0 照片档
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.photo);

      // 拨杆拨到视频档:事件 → 定向读跟随(+ 模式翻转沿补刷参数:
      // 照片块 + 视频块,拨到视频档要拉整条视频参数链)
      transport.ok(data: Uint8List.fromList([1]));
      _scriptParamsVideo(transport); // 照片参数 + 视频参数族 + 尾两读
      transport.eventCtrl.add(const PtpEvent(
          code: PtpEventCode.devicePropChanged,
          transactionId: 0xFFFFFFFF,
          params: [PtpDevicePropCode.liveViewSelector]));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(controller.cameraMode, CaptureMode.video);
      expect(controller.dialMode, CaptureMode.video);
    });

    test('switchMode(视频→照片):接管 + 停景 + 写 0xD1A6=0 + 起景 + 刷参',
        () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.video);

      transport
        ..ok() // 0x90C2(1) 接管(顺带 engine.remoteHeld)
        ..ok() // 0x9202 停景
        ..ok() // 0x1016 写 0xD1A6=0
        ..ok() // 0x9201 起景
        ..ok(data: _fakeFrame()); // 首帧
      _scriptParams(transport); // 刷参块(模式族属性连片变)
      final chainStart = transport.requests.length;
      expect(await controller.switchMode(CaptureMode.photo), isTrue);
      expect(controller.error, isNull);

      expect(controller.cameraMode, CaptureMode.photo);
      expect(controller.modeOverridden, isTrue,
          reason: '软件态(照片)≠ 拨杆真档(视频)');
      expect(controller.dialMode, CaptureMode.video,
          reason: '覆写期拨杆真档不可见,不被软件态污染');
      expect(controller.takeoverActive, isTrue);
      expect(controller.engine.remoteHeld, isTrue,
          reason: '接管持有期自愈梯不得碰 0x90C2');
      // 探针实证序:0x90C2(1) → 0x9202 → 写 D1A6 → 0x9201 → 首帧 → 参数
      expect(
          transport.requests
              .skip(chainStart)
              .map((r) => r.opcode)
              .take(5),
          [
            NikonOperationCode.changeCameraMode,
            NikonOperationCode.endLiveView,
            PtpOperationCode.setDevicePropValue,
            NikonOperationCode.startLiveView,
            NikonOperationCode.getLiveViewImageEx,
          ],
          reason: '停景后写、原生档起景');
      final write = transport.requests.singleWhere(
          (r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.liveViewSelector]);
      expect(write.dataOut, [0]);
    });

    test('switchMode 写被拒(0x200F)→ 回滚起景 + 会话级缓存,两方向早退提示',
        () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();

      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..reply(PtpResponseCode.accessDenied) // 0x1016 写被拒
        ..ok() // 0x9201 回滚起景
        ..ok(data: _fakeFrame()); // 首帧
      expect(await controller.switchMode(CaptureMode.photo), isFalse);
      await pumpEventQueue();
      expect(controller.modeWriteRejected, isTrue);
      expect(controller.error, contains('切换拍摄模式失败'));
      expect(controller.cameraMode, CaptureMode.video, reason: '写被拒模式不变');
      expect(controller.liveViewActive, isTrue, reason: '停景已发生,回滚起回');

      // 缓存生效:本会话内两方向都不再撞写(早退 + 拨杆提示)
      final baseline = transport.requests.length;
      expect(await controller.switchMode(CaptureMode.photo), isFalse);
      expect(controller.error, contains('机顶拨杆'));
      expect(transport.requests.length, baseline);
    });

    test('自然照片档 switchMode(视频)→ 双向可切(2026-10-11 R1:去方向门,'
        '覆写两向都被接受;录像门跟物理拨杆,开录时才拒)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn); // d1a6=0 照片档
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.photo);

      transport
        ..ok() // 0x90C2(1) 接管
        ..ok() // 0x9202 停景
        ..ok() // 0x1016 写 0xD1A6=1
        ..ok() // 0x9201 起景
        ..ok(data: _fakeFrame()); // 首帧
      _scriptParamsVideo(transport); // 切到视频档:刷参 = 照片 + 视频族 + 尾
      final chainStart = transport.requests.length;
      expect(await controller.switchMode(CaptureMode.video), isTrue);
      expect(controller.error, isNull);
      expect(controller.cameraMode, CaptureMode.video);
      expect(controller.modeOverridden, isTrue);
      expect(controller.dialMode, CaptureMode.photo,
          reason: '拨杆真档不动:覆写的是软件态');
      expect(
          transport.requests
              .skip(chainStart)
              .map((r) => r.opcode)
              .take(5),
          [
            NikonOperationCode.changeCameraMode,
            NikonOperationCode.endLiveView,
            PtpOperationCode.setDevicePropValue,
            NikonOperationCode.startLiveView,
            NikonOperationCode.getLiveViewImageEx,
          ]);
      final write = transport.requests.singleWhere(
          (r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.dataOut, [1], reason: '写 0xD1A6=1(视频)');
    });

    test('覆写态解除接管 → 释放后读回拨杆真档对表(覆写死亡,读值不再被'
        '软件态遮蔽)', () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..ok() // 0x1016 D1A6=0
        ..ok() // 0x9201
        ..ok(data: _fakeFrame());
      _scriptParams(transport);
      expect(await controller.switchMode(CaptureMode.photo), isTrue);

      transport
        ..ok() // 0x90C2(0) 解除
        ..ok(data: Uint8List.fromList([1])); // 释放后读回 D1A6:拨杆=视频
      _scriptParamsVideo(transport); // 读回翻转沿补刷(photo+video+尾)
      await controller.releaseTakeover();
      await pumpEventQueue(); // 翻转沿补刷是 unawaited:泵完再断言/teardown
      expect(controller.cameraMode, CaptureMode.video,
          reason: '覆写随解除死亡:读回拨杆真档(覆写期可能被拨过,不猜)');
      expect(controller.dialMode, CaptureMode.video);
      expect(controller.modeOverridden, isFalse);
      expect(controller.engine.remoteHeld, isFalse);
    });

    test('覆写期拨杆被拨到照片档 → 释放读回对表照片(不可凭旧态猜)', () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..ok() // 0x1016 D1A6=0
        ..ok() // 0x9201
        ..ok(data: _fakeFrame());
      _scriptParams(transport);
      expect(await controller.switchMode(CaptureMode.photo), isTrue);
      expect(controller.dialMode, CaptureMode.video); // 我们以为拨杆在视频

      transport
        ..ok() // 0x90C2(0) 解除
        ..ok(data: Uint8List.fromList([0])); // 读回:拨杆其实在照片档
      await controller.releaseTakeover();
      expect(controller.cameraMode, CaptureMode.photo);
      expect(controller.dialMode, CaptureMode.photo);
      expect(controller.modeOverridden, isFalse);
    });

    test('覆写期 0x4006(D1A6)事件 → 读值是软件态回声:零动作,拨杆真档'
        '不被回声污染', () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..ok() // 0x1016 D1A6=0
        ..ok() // 0x9201
        ..ok(data: _fakeFrame());
      _scriptParams(transport);
      expect(await controller.switchMode(CaptureMode.photo), isTrue);

      // 覆写期读 0xD1A6 得软件态回声(与拨杆真档不可分):与已知软件态
      // 相同即零动作 —— 拨杆真档的真相留给释放接管后的读回。
      transport.ok(data: Uint8List.fromList([0]));
      transport.eventCtrl.add(const PtpEvent(
          code: PtpEventCode.devicePropChanged,
          transactionId: 0xFFFFFFFF,
          params: [PtpDevicePropCode.liveViewSelector]));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(controller.cameraMode, CaptureMode.photo);
      expect(controller.modeOverridden, isTrue);
      expect(controller.dialMode, CaptureMode.video,
          reason: '回声不碰拨杆真档');
    });

    test('模式写被拒 → 会话级缓存;重连(新会话)复位再试', () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..reply(PtpResponseCode.accessDenied) // 0x1016 写被拒
        ..ok() // 0x9201 回滚起景
        ..ok(data: _fakeFrame());
      expect(await controller.switchMode(CaptureMode.photo), isFalse);
      await pumpEventQueue();
      expect(controller.modeWriteRejected, isTrue);

      // 重连:新会话再试一次(拒答缓存随连接复位)
      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      expect(controller.modeWriteRejected, isFalse);
      expect(controller.cameraMode, CaptureMode.video);
    });

    test('断链:覆写/切换中/remoteHeld 清,cameraMode 对齐拨杆真档'
        '(覆写随会话死亡)', () async {
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      transport
        ..ok() // 0x90C2(1)
        ..ok() // 0x9202
        ..ok() // 0x1016 D1A6=0
        ..ok() // 0x9201
        ..ok(data: _fakeFrame());
      _scriptParams(transport);
      expect(await controller.switchMode(CaptureMode.photo), isTrue);

      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(controller.modeOverridden, isFalse);
      expect(controller.engine.remoteHeld, isFalse);
      expect(controller.cameraMode, CaptureMode.video,
          reason: '覆写随会话死亡:拨杆真档即真相(不变式:非覆写 ⇒ '
              'cameraMode == dialMode);重连沿串链再对表');
      expect(controller.dialMode, CaptureMode.video);
    });
  });

  test('0x4006 事件(机身拨盘/菜单改动)→ 定向刷新被点名参数;表外码忽略',
      () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();

    // 表外属性码:不触发刷新
    final baseline = transport.requests.length;
    transport.eventCtrl.add(const PtpEvent(
        code: PtpEventCode.devicePropChanged,
        transactionId: 0xFFFFFFFF,
        params: [0x5011]));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(transport.requests.length, baseline,
        reason: '目录外属性(dateTime)不刷新');

    // 目录内:光圈被拨 → 定向重读
    transport.ok(data: _propDescDataset(
        PtpDevicePropCode.fNumber, PtpDataType.uint16, 400,
        enums: [280, 320, 400]));
    transport.eventCtrl.add(const PtpEvent(
        code: PtpEventCode.devicePropChanged,
        transactionId: 0xFFFFFFFF,
        params: [PtpDevicePropCode.fNumber]));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(controller.exposure?.fNumber, 400, reason: '拨盘改动 → 定向刷新');
  });

  test('厂商路由参数:标准码 getSet=false 不影响可写(真机:0x500F 报只读'
      '但 0xD0B4 可写)', () async {
    _scriptParams(transport, readonlyCodes: {
      PtpDevicePropCode.exposureIndex,
      PtpDevicePropCode.exposureTime
    });
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.propWritable(PtpDevicePropCode.exposureIndex), isTrue,
        reason: 'ISO 写走厂商码,标准码 getSet 不作数');
    expect(controller.propWritable(PtpDevicePropCode.exposureTime), isTrue,
        reason: '快门写走厂商码,同上');
  });

  group('曝光变量模式门(OpenZCine stillAllows* 同款;真机:A 模式影控台'
      '同样不能改快门)', () {
    test('A(光圈优先):快门本地拒绝零流量,光圈可调;芯片标「自动」', () async {
      _scriptParams(transport, mode: 3); // A
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.shutterAdjustable, isFalse);
      expect(controller.apertureAdjustable, isTrue);
      expect(controller.paramAutoControlled(PtpDevicePropCode.exposureTime),
          isTrue);
      expect(controller.paramAutoControlled(PtpDevicePropCode.fNumber),
          isFalse);
      expect(controller.propWritable(PtpDevicePropCode.exposureTime), isFalse);

      await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
      expect(controller.error, contains('光圈优先 A'));
      expect(controller.error, contains('由相机自动控制'));
      expect(
          transport.requests
              .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
          isEmpty,
          reason: '模式门在本地拦下,不再撞 0x200F');
    });

    test('S(快门优先):光圈拒绝,快门可调', () async {
      _scriptParams(transport, mode: 4); // S
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.apertureAdjustable, isFalse);
      expect(controller.shutterAdjustable, isTrue);
      await controller.setParam(PtpDevicePropCode.fNumber, 320);
      expect(controller.error, contains('快门优先 S'));
      expect(controller.error, contains('光圈由相机自动控制'));
    });

    test('场景档:快门/光圈/ISO 全由相机拥有', () async {
      _scriptParams(transport, mode: 0x8010); // 自动(场景段)
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.shutterAdjustable, isFalse);
      expect(controller.apertureAdjustable, isFalse);
      expect(controller.isoManualAllowed, isFalse);
      expect(controller.paramAutoControlled(PtpDevicePropCode.exposureIndex),
          isTrue);
    });

    test('U 档/模式未读:不猜锁,交给相机应答', () async {
      _scriptParams(transport, mode: 0x8050); // U1
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.shutterAdjustable, isTrue, reason: 'U 档按内部程序跑');
      expect(controller.apertureAdjustable, isTrue);

      // 模式读不到(desc 与裸值双拒 → 值 null):同样不锁
      final t2 = _ScriptTransport();
      final conn2 = _FakeConnection();
      final c2 = RemoteController(
          session: PtpSession(transport: t2),
          connection: conn2,
          // connected 沿串链会自动起景(取帧轮询),停摆 delay 驻住不抢脚本
          engine: LiveViewEngine(
              session: PtpSession(transport: t2), delay: _parkedDelay));
      addTearDown(c2.dispose);
      _scriptParams(t2, modeUnreadable: true);
      _emitConnected(t2, conn2);
      await pumpEventQueue();
      expect(
          c2.paramProps[PtpDevicePropCode.exposureProgramMode]?.value, isNull);
      expect(c2.shutterAdjustable, isTrue);
      expect(c2.apertureAdjustable, isTrue);
    });

    test('自动 ISO 开:写 ISO 直发 0xD0B4(开关与手动值互不干扰,不联动)',
        () async {
      // 倒数第二个应答(0xD054 自动 ISO)改 [1](自动开);末尾是 0xD1F1
      _scriptParams(transport);
      final last = transport.script.removeLast(); // 0xD1F1 剩余张数
      transport.script.removeLast(); // 0xD054
      transport
        ..ok(data: Uint8List.fromList([1])) // 0xD054 自动开
        ..script.add(last); // 0xD1F1 摆回
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.isoAuto, isTrue);
      expect(controller.paramAutoControlled(PtpDevicePropCode.exposureIndex),
          isTrue);
      expect(controller.propWritable(PtpDevicePropCode.exposureIndex), isTrue,
          reason: '自动开仍可调(开关与手动值互不干扰)');

      transport
        ..ok() // 0x1016 直接写 0xD0B4 = 400(不再先发 0xD054=0)
        ..ok(data: _propDescDataset(PtpDevicePropCode.exposureIndex,
            PtpDataType.uint16, 400,
            enums: [100, 200, 400, 800]))
        ..ok(data: _u32Bytes(400));
      await controller.setParam(PtpDevicePropCode.exposureIndex, 400);
      final writes = transport.requests
          .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
          .toList();
      expect(writes, hasLength(1), reason: '只发 ISO 写,不动自动开关');
      expect(writes[0].params, [PtpDevicePropCode.exposureIndexEx]);
      expect(controller.isoAuto, isTrue, reason: '自动开关保持,互不干扰');
      expect(controller.exposure?.iso, 400);
    });

    test('setIsoAuto(true):写 0xD054=1,ISO 工作值跟随刷新', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.isoAuto, isFalse);

      transport
        ..ok() // 0xD054=1
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 800,
            enums: [100, 200, 400, 800]))
        ..ok(data: _u32Bytes(800)); // 0xD0B5 工作值跟随
      await controller.setIsoAuto(true);
      final write = transport.requests
          .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.stillIsoAutoControl]);
      expect(write.dataOut, [1]);
      expect(controller.isoAuto, isTrue);
      expect(controller.exposure?.iso, 800);
    });
  });

  group('连拍按住(OpenZCine shutterPressLatchedBurst 同款)', () {
    test('连续释放档按下:括持(0x90C2[1] + burstNumber 65535)+ 释放;'
        '抬起:0x920C 终止 + 0x90C2[0] 解除', () async {
      // connected 沿串链自动起景(引擎轮询驻停):换 parked 引擎,不与
      // 连拍帧间等待抢门控 delay 的放行。
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
      );
      controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
      // 不启,门控 delay 放行全部留给连拍/快门流程
      _scriptParams(transport, drive: 2); // 释放档 = 高速连拍
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x90C2 [1] 括持
        ..ok() // 0x1016 写 burstNumber 0x5018 = 65535
        ..ok(); // 第 1 帧 0x9207
      final press = controller.capturePressed();
      await pumpEventQueue();
      expect(controller.capturing, isTrue, reason: '按住中');

      // 帧间等待挂起(gated delay);抬起 → 终止 + 解除括持
      transport
        ..ok() // 0x920C 终止
        ..ok(); // 0x90C2 [0] 解除
      await controller.captureReleased();
      delay.release(); // 放行帧间等待 → 循环见锁已断,收尾
      await press;

      expect(controller.error, isNull);
      expect(controller.capturing, isFalse);
      expect(transport.count(NikonOperationCode.changeCameraMode), 2);
      final modes = transport.requests
          .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
          .toList();
      expect(modes[0].params, [1], reason: '按下开括持');
      expect(modes[1].params, [0], reason: '抬起解除');
      final burst = transport.requests.singleWhere(
          (r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(burst.params, [PtpDevicePropCode.burstNumber]);
      expect(burst.dataOut, [0xFF, 0xFF], reason: '连拍上限 65535');
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
      expect(transport.count(NikonOperationCode.terminateCapture), 1);
    });

    test('单张释放档按下 = 原单张路径(无括持无终止);抬起静默', () async {
      // 同上:parked 引擎,DeviceReady 轮询的门控放行不被引擎轮询抢走。
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
      );
      controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
      // 不启,门控 delay 放行全部留给连拍/快门流程
      _scriptParams(transport); // 释放档 = 单张
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x9207
        ..ok(); // deviceReady
      final press = controller.capturePressed();
      await pumpEventQueue();
      delay.release(); // DeviceReady 轮询放行
      await press;
      expect(controller.capturing, isFalse);
      expect(transport.count(NikonOperationCode.changeCameraMode), 0);
      expect(transport.count(NikonOperationCode.terminateCapture), 0);
      await controller.captureReleased(); // 无锁:静默零流量
      expect(transport.requests
              .where((r) => r.opcode == NikonOperationCode.terminateCapture),
          isEmpty);
    });

    test('断连即终止连拍状态(链发循环止步)', () async {
      // 同组口径:parked 引擎,链发循环的等待独享门控放行。
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
      );
      controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
      // 不启,门控 delay 放行全部留给连拍/快门流程
      _scriptParams(transport, drive: 0x8010); // 低速连拍
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x90C2 [1]
        ..ok() // burstNumber
        ..ok(); // 第 1 帧
      final press = controller.capturePressed();
      await pumpEventQueue();
      conn.statesCtrl.add(CameraLinkState.disconnected);
      delay.release();
      await press;
      expect(controller.capturing, isFalse);
      expect(controller.linkUp, isFalse);
    });
  });

  test('色温写入:先切 WB=色温档(0x8012)再写 0xD01E(WB 非色温档时联动)',
      () async {
    _scriptParams(transport); // WB desc value = 2(自动)
    _emitConnected(transport, conn);
    await pumpEventQueue();

    transport
      ..ok() // 0x1016 写 0x5005 = 0x8012
      ..ok() // 0x1016 写 0xD01E = 5000
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.wbColorTemp, PtpDataType.uint16, 5000));
    await controller.setParam(PtpDevicePropCode.wbColorTemp, 5000);
    final writes = transport.requests
        .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
        .toList();
    expect(writes[0].params, [PtpDevicePropCode.whiteBalance],
        reason: 'K 值只在 WB=色温档生效,先切档');
    expect(writes[0].dataOut, [0x12, 0x80]);
    expect(writes[1].params, [PtpDevicePropCode.wbColorTemp]);
    expect(writes[1].dataOut, [0x88, 0x13]); // 5000 = 0x1388
    expect(controller.error, isNull);
  });

  group('自拍定时', () {
    test('档位 2s:按下倒计时 2 拍后释放;倒计时中切档取消', () async {
      controller.setSelfTimer(2);
      expect(controller.selfTimerSeconds, 2);

      transport
        ..ok() // 0x9207
        ..ok(); // deviceReady
      final press = controller.capturePressed();
      await pumpEventQueue();
      expect(controller.selfTimerCountdown, 2);
      delay.release(); // 第 1 秒
      await pumpEventQueue();
      expect(controller.selfTimerCountdown, 1);
      delay.release(); // 第 2 秒 → 倒计时归零,fire() 内的 capture 启动
      await pumpEventQueue();
      delay.release(); // capture 内 DeviceReady 轮询放行
      await press;
      expect(controller.selfTimerCountdown, isNull);
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
          reason: '倒计时走完释放');
      expect(controller.error, isNull);
    });

    test('倒计时中被取消(切档)→ 不释放零流量', () async {
      controller.setSelfTimer(10);
      final press = controller.capturePressed();
      await pumpEventQueue();
      expect(controller.selfTimerCountdown, 10);
      controller.setSelfTimer(0); // 取消
      delay.release();
      await press;
      expect(controller.selfTimerCountdown, isNull);
      expect(transport.requests
              .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia),
          isEmpty);
    });
  });

  group('B 门/Time:按住开曝光', () {
    test('快门值 Bulb(0xFFFFFFFF):按下释放不等待,抬起 0x920C 结束', () async {
      // connected 沿串链自动起景(引擎轮询驻停):换 parked 引擎,不与
      // B 门按住等待环抢门控 delay 的放行。
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
      );
      controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
      // 不启,门控 delay 放行全部留给连拍/快门流程
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      // 快门值直接置 Bulb 哨兵(0xD100 打包分数空间)
      controller.paramProps[PtpDevicePropCode.exposureTime] =
          const PropState(value: 0xFFFFFFFF);

      transport
        ..ok() // 0x9207(Bulb 开)
        ..ok(); // 0x920C(抬起结束)
      final press = controller.capturePressed();
      await pumpEventQueue();
      expect(controller.capturing, isTrue, reason: '按住中 = 曝光开着');
      await controller.captureReleased();
      delay.release(); // 按住等待环收口
      await press;
      expect(controller.capturing, isFalse);
      expect(transport.count(NikonOperationCode.terminateCapture), 1);
      expect(controller.error, isNull);
    });
  });

  group('录制(0x920A/0x920B)', () {
    test('取景中起录/停录;事件对齐状态', () async {
      // 起录/停录(取景前置在 controller 内检查 liveViewActive —— 测试
      // 用引擎状态伪造太重,直接验证事件对齐与 op 形态)
      transport
        ..ok() // 0x920A
        ..ok(); // 0x920B
      // liveViewActive 需要 engine running —— 用事件驱动状态验证
      transport.eventCtrl.add(const PtpEvent(
          code: NikonEventCode.movieRecordStarted, transactionId: 0xFFFFFFFF));
      await pumpEventQueue();
      expect(controller.recording, isTrue);
      expect(controller.recordingSince, isNotNull);
      transport.eventCtrl.add(const PtpEvent(
          code: NikonEventCode.movieRecordComplete, transactionId: 0xFFFFFFFF));
      await pumpEventQueue();
      expect(controller.recording, isFalse);
      expect(controller.recordingSince, isNull);
    });

    test('未开取景点录制 → 提示不发', () async {
      await controller.toggleRecord();
      expect(controller.error, contains('请先开启取景'));
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.startMovieRecInCard),
          isEmpty);
    });

    test('帧头录制态同步(@828):机身自启录制对齐;停止帧复位', () async {
      controller.engine.header.value =
          parseLiveViewHeader(_minimalHeaderFrame(recording: true));
      expect(controller.recording, isTrue);
      expect(controller.recordingSince, isNotNull);

      controller.engine.header.value =
          parseLiveViewHeader(_minimalHeaderFrame(recording: false));
      expect(controller.recording, isFalse);
      expect(controller.recordingSince, isNull);
    });
  });

  group('控制锁(0x200F 拒绝 → tile 锁标)', () {
    test('写被拒打锁标;写通解除;断连清空', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport.reply(PtpResponseCode.accessDenied); // 0x1016 白平衡被拒
      await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
      expect(controller.lockedProps, contains(PtpDevicePropCode.whiteBalance));

      // 写通:锁解除
      transport
        ..ok()
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.whiteBalance, PtpDataType.uint16, 4,
            enums: [2, 4, 5, 6, 7, 0x8010]));
      await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
      expect(controller.lockedProps, isEmpty);

      // 再拒 → 断连清空
      transport.reply(PtpResponseCode.accessDenied);
      await controller.setParam(PtpDevicePropCode.whiteBalance, 2);
      expect(controller.lockedProps, isNotEmpty);
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(controller.lockedProps, isEmpty);
    });
  });

  test('剩余张数:refreshParams 读 0xD1F1 上屏', () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.shotsRemaining, 1234, reason: '_scriptParams 末尾预置');
  });

  test('优化校准:FORM 全量入状态 + 自定义/云组真名 0x90CC 拉取'
      '(内置/创意组静态表已有,跳过)', () async {
    _scriptParams(transport,
        picCtrlEnums: [1, 101, 201, 202, 301], picCtrlValue: 201);
    transport
      ..ok(data: _picCtrlData('My Landscape')) // 201
      ..ok(data: _picCtrlData('')) // 202:空名 → 回落静态占位
      ..ok(data: _picCtrlData('Cloud 9')); // 301
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(
        controller
            .paramProps[PtpDevicePropCode.activePicCtrlItem]?.desc?.enumValues,
        [1, 101, 201, 202, 301],
        reason: '相机 FORM 驱动:枚举全量入状态(真机 46 项同理)');
    expect(controller.paramProps[PtpDevicePropCode.activePicCtrlItem]?.value,
        201);
    expect(transport.count(NikonOperationCode.getPictCtrlData), 3,
        reason: '只拉静态表外的槽位:1(标准)/101(Dream)不发 0x90CC');
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.getPictCtrlData)
            .map((r) => r.params.first),
        [201, 202, 301],
        reason: '按 FORM 枚举序逐槽位读,params=[槽位,0]');
    expect(
        controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201),
        'My Landscape',
        reason: '自定义组真名(机身用户起名)替掉「自定义 1」占位');
    expect(
        controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 202),
        '自定义 2',
        reason: '空名(null)回落静态段位格式化');
    expect(
        controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 301),
        'Cloud 9',
        reason: '云组真名替掉「云 1」占位');
    expect(
        controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 1),
        '标准',
        reason: '静态表标签照常');
  });

  test('优化校准:0x90CC 首槽位被拒 → 整组停(不逐个撞),显示回落静态',
      () async {
    _scriptParams(transport, picCtrlEnums: [201, 202], picCtrlValue: 202);
    transport.reply(PtpResponseCode.operationNotSupported);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(transport.count(NikonOperationCode.getPictCtrlData), 1,
        reason: '首异常即停:202 不再试');
    expect(controller.picCtrlNames, isEmpty);
    expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 202),
        '自定义 2');
  });

  test('优化校准:断连清缓存;重连重取(每连接一次,重复 connected 不重拉)',
      () async {
    _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
    transport.ok(data: _picCtrlData('My Fav'));
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201),
        'My Fav');

    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    expect(controller.picCtrlNames, isEmpty, reason: '断连清缓存');
    expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201),
        '自定义 1', reason: '回落静态占位');

    // 重连:再次拉取(新连接档案重建)。
    _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
    transport.ok(data: _picCtrlData('My Fav'));
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201),
        'My Fav');
    expect(transport.count(NikonOperationCode.getPictCtrlData), 2,
        reason: '两次连接各拉一次');

    // 状态未离开的重复 connected 沿:不重拉(一次性旗标)。
    _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(transport.count(NikonOperationCode.getPictCtrlData), 2,
        reason: '同连接内已拉过,不重复');
  });

  test('ObjectAdded → 「已拍摄」提示 + 参数刷新;断连后迟到事件丢弃', () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.exposure?.iso, 200);

    // 即拍即览缩略图先行(事件处理序:缩略图 → 参数刷新),再全量刷参
    transport.ok(data: Uint8List.fromList([1, 2, 3]));
    _scriptParams(transport);
    transport.eventCtrl
        .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x1234]));
    await pumpEventQueue();
    expect(controller.notice, '已拍摄');

    // 断连:_invalidate 清态
    conn.statesCtrl.add(CameraLinkState.failed);
    await pumpEventQueue();
    expect(controller.linkUp, isFalse);
    expect(controller.notice, isNull);
    expect(controller.exposure, isNull);

    // 断连后的迟到事件:notice 不得回屏
    transport.eventCtrl
        .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x5678]));
    await pumpEventQueue();
    expect(controller.notice, isNull);
  });

  test('未连接 capture:直接提示,不发操作', () async {
    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    await controller.capture();
    expect(controller.error, '未连接相机');
    expect(transport.requests, isEmpty);
  });

  test('PropDesc 驱动:desc 域入状态(枚举值/可写性可见)', () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    final f = controller.paramProps[PtpDevicePropCode.fNumber]!;
    expect(f.value, 280);
    expect(f.desc?.enumValues, [280, 320, 400]);
    expect(f.desc?.getSet, isTrue);
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100);
    final mode = controller.paramProps[PtpDevicePropCode.exposureProgramMode]!;
    expect(mode.desc?.enumValues, [1, 2, 3, 4, 5]);
    expect(mode.desc?.getSet, isTrue);
  });

  test('PropDesc 不可用退回裸值 0x1015(域未知但值可用)', () async {
    _scriptParamsRawFallback(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 280);
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
        reason: '快门不读标准码(取值域直供),0xD100 裸值直达');
    expect(controller.exposure?.iso, 200);
    expect(controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value,
        1);
    expect(controller.paramProps[PtpDevicePropCode.fNumber]?.desc, isNull,
        reason: 'PropDesc 拒答后不得残留旧 desc');
  });

  test('门禁开:ISO 写走厂商码 0xD0B4(u32),回读仍读 0x500F', () async {
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();

    transport
      ..ok() // 0x1016 写 0xD0B4 = 400(u32)
      ..ok(data: _propDescDataset( // 回读:先 0x500F PropDesc(取值域)
          PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 400,
          enums: [100, 200, 400, 800]))
      ..ok(data: _u32Bytes(400)); // 再 0xD0B5 裸值(值路由)
    await controller.setParam(PtpDevicePropCode.exposureIndex, 400);
    final write = transport.requests
        .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.exposureIndexEx],
        reason: 'Z 系 ISO 写走厂商码');
    expect(write.dataOut, Uint8List.fromList([0x90, 0x01, 0x00, 0x00]));
    expect(controller.exposure?.iso, 400, reason: '屏显以回读为准');
    expect(controller.error, isNull);
  });

  test('门禁开:快门直写 0xD100 打包分数(面板值即写值,无 µs 换算)', () async {
    PtpSession.kSetPropEnabled = true;
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();

    transport
      ..ok() // 0x1016 写 0xD100 = (1<<16)|100
      ..ok(data: _u32Bytes(1 << 16 | 100)); // 回读 0xD100 裸值
    await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
    final write = transport.requests
        .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.stillShutterSpeed],
        reason: 'Z 系快门写走厂商码');
    expect(write.dataOut, Uint8List.fromList([0x64, 0x00, 0x01, 0x00]));
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100);
  });

  test('模式(机顶转盘拥有 → dialOwned):相机报只读(getSet=false)仍可写'
      ' —— 0x500E u16 标准码直发(接管锁转盘后写入,OpenZCine 同款)',
      () async {
    // 真机形态:0x500E 拨盘拥有,相机 PropDesc 上报 getSet=false
    _scriptParams(transport, readonlyCodes: {PtpDevicePropCode.exposureProgramMode});
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
        isTrue,
        reason: 'dialOwned 参数绕过 getSet 门(相机报只读是拨盘语义,'
            '接管后可写)—— 否则芯片置灰点不动(2026-10-06 真机)');

    transport
      ..ok() // 0x1016 写 0x500E = 4(S 档)
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.exposureProgramMode, PtpDataType.uint16, 4,
          getSet: false, enums: [1, 2, 3, 4, 5]));
    await controller.setParam(PtpDevicePropCode.exposureProgramMode, 4);
    final write = transport.requests
        .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.exposureProgramMode]);
    expect(write.dataOut, Uint8List.fromList([0x04, 0x00]));
    expect(
        controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value, 4);
    expect(controller.error, isNull);
  });

  test('对焦单一芯片:0x500A 镜像移出目录,0xD061 可调(pickValues 直供)',
      () async {
    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(shootingParamByCode.containsKey(PtpDevicePropCode.focusMode),
        isFalse,
        reason: '0x500A 只读镜像移出,避免「对焦/对焦模式」双芯片');
    expect(controller.propWritable(PtpDevicePropCode.stillFocusMode), isTrue,
        reason: '0xD061 pickValues 直供,PropDesc 拒答也可调');
  });

  test('总闸紧急关断:setParam 直接拒绝,零流量', () async {
    PtpSession.kSetPropEnabled = false; // 生产已开,显式关断走分支
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    await controller.setParam(PtpDevicePropCode.fNumber, 320);
    expect(controller.error, contains('总闸关断'));
    expect(transport.requests, isEmpty);
    expect(controller.writing, isFalse);
  });

  test('门禁开:0x1016 裸值写出 + 回读刷新(相机 clamp 以回读为准)', () async {
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.canAdjustParams, isTrue);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue);
    expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
        isTrue,
        reason: '模式 dialOwned 可写(接管确认后写入,相机侧决定收否)');

    transport
      ..ok() // 0x1016 写 fNumber=320
      ..ok(data: _propDescDataset( // 回读:相机 clamp 到 400
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 400,
          enums: [280, 320, 400]));
    await controller.setParam(PtpDevicePropCode.fNumber, 320);

    final write = transport.requests
        .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
    expect(write.params, [PtpDevicePropCode.fNumber]);
    expect(write.dataOut, Uint8List.fromList([0x40, 0x01])); // u16 裸值 320
    expect(controller.exposure?.fNumber, 400, reason: '屏显以回读为准');
    expect(controller.error, isNull);
    expect(controller.writing, isFalse);
  });

  test('门禁开:相机上报只读(getSet=false)→ 拒写(dialOwned 参数除外)',
      () async {
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    // 白平衡(菜单级)报只读 → 拒写;光圈(dialOwned)报只读不拦
    _scriptParams(transport, readonlyCodes: {
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.fNumber
    });
    _emitConnected(transport, conn);
    await pumpEventQueue();

    await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
    expect(controller.error, contains('只读'));
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
    expect(controller.propWritable(PtpDevicePropCode.whiteBalance), isFalse);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue,
        reason: '拨盘级参数的只读上报是拨盘语义,接管模型覆盖(不拦)');
  });

  test('门禁开:写失败(0x2019 忙)→ 报错,值不漂移', () async {
    PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
    addTearDown(() => PtpSession.kSetPropEnabled = true);
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    _scriptParams(transport);
    _emitConnected(transport, conn);
    await pumpEventQueue();

    transport.reply(PtpResponseCode.deviceBusy); // 0x1016 忙
    await controller.setParam(PtpDevicePropCode.fNumber, 320);
    expect(controller.error, contains('参数写入失败'));
    expect(controller.exposure?.fNumber, 280, reason: '失败后原值不动');
    expect(controller.writing, isFalse);
  });

  test('对焦后拍默认关:0x9207 首参 0xFFFFFFFF(直接释放,OpenZCine 形态)',
      () async {
    transport
      ..ok() // 0x9207 直发(无 op 表缓存 → 默认现代面)
      ..ok(); // deviceReady
    final c = controller.capture();
    await pumpEventQueue();
    delay.release();
    await c;
    expect(
        transport.requests
            .singleWhere(
                (r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
            .params,
        [0xFFFFFFFF, 0]);
  });

  test('对焦后拍开:首发与缓存直发的 0x9207 都带 CaptureSort 首参',
      () async {
    controller.focusBeforeCapture = true;
    expect(controller.focusBeforeCapture, isTrue);
    transport
      ..ok() // 0x9207(对焦后拍)
      ..ok(); // deviceReady
    final first = controller.capture();
    await pumpEventQueue();
    delay.release();
    await first;

    transport
      ..ok() // 0x9207 直发
      ..ok(); // deviceReady
    final second = controller.capture();
    await pumpEventQueue();
    delay.release();
    await second;

    final mediaOps = transport.requests
        .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
        .toList();
    expect(mediaOps, hasLength(2));
    expect(mediaOps[0].params, [0xFFFFFFFE, 0]);
    expect(mediaOps[1].params, [0xFFFFFFFE, 0],
        reason: '缓存码直发路径同样携带');
  });

  group('拍摄页可见性(取景生命周期跟连接走)', () {
    test('setViewerVisible(false):帧轮询与 AE 轮询挂起,不发 0x9202;'
        '回台恢复', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn); // 串链自动起景(0x9201 + 首帧)
      await pumpEventQueue();
      expect(controller.liveViewActive, isTrue,
          reason: 'connected 沿串链起景(2026-10-11 移入)');
      expect(transport.count(NikonOperationCode.getLiveViewImageEx), 1);

      // 离台:放行挂着的 delay(AE 间隔 + 引擎间隔 + 若干挂起 tick),
      // 不得再发任何请求(脚本无应答可耗,有请求即 StateError 炸出)。
      controller.setViewerVisible(false);
      final reqsAtHide = transport.requests.length;
      for (var i = 0; i < 4; i++) {
        // release 后轮询协程异步苏醒:逐把放行逐轮冲刷(AE 醒即退出,
        // 引擎醒见挂起标志 → 再挂 tick;醒多少轮都不取帧)。
        delay.release();
        await pumpEventQueue();
      }
      expect(transport.requests.length, reqsAtHide, reason: '不可见零流量');
      expect(controller.liveViewActive, isTrue,
          reason: '相机侧取景保持(不发 0x9202)');
      expect(transport.count(NikonOperationCode.endLiveView), 0);

      // 回台:引擎恢复取帧,AE 轮询重启。AE 一轮 = fNumber PropDesc +
      // 快门 0xD100 裸读 + ISO PropDesc + ISO 0xD0B5 裸读(四请求)。
      transport.ok(data: _fakeFrame()); // 回台首帧
      transport.ok(data: _propDescDataset( // AE:fNumber PropDesc
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 280,
          enums: [280, 320, 400]));
      transport.ok(data: _u32Bytes(1 << 16 | 100)); // AE:0xD100 快门
      transport.ok(data: _propDescDataset( // AE:ISO PropDesc
          PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
          enums: [100, 200, 400, 800]));
      transport.ok(data: _u32Bytes(200)); // AE:0xD0B5 有效 ISO
      controller.setViewerVisible(true);
      delay.release(); // 引擎挂起 tick 醒 → 取帧
      await pumpEventQueue();
      delay.release(); // AE 间隔醒 → 三连读
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.getLiveViewImageEx), 2,
          reason: '回台恢复帧轮询');
      expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
          reason: 'AE 轮询照常刷读数');
    });

    test('connected 沿串链起景:页面不可见也 0x9201 照发、帧轮询挂起'
        '(相机侧进取景)', () async {
      controller.setViewerVisible(false); // 拍摄页不在前台
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.liveViewActive, isTrue,
          reason: '连接即取景:0x9201 不等页面可见');
      expect(transport.count(NikonOperationCode.startLiveView), 1);
      expect(transport.count(NikonOperationCode.endLiveView), 0,
          reason: '不可见只挂起轮询,不发 0x9202');

      // 不可见:放行引擎 delay 不得再取帧(醒一轮挂一轮)。
      final frames = transport.count(NikonOperationCode.getLiveViewImageEx);
      delay.release();
      await pumpEventQueue();
      delay.release();
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.getLiveViewImageEx), frames,
          reason: '帧轮询挂起,零流量');

      // 幂等:已运行再调不重发 0x9201。
      await controller.autoLiveViewOnConnect();
      expect(transport.count(NikonOperationCode.startLiveView), 1);
    });

    test('autoLiveViewOnConnect 单飞:同拍双调用共享一次 start'
        '(连接沿串链与进页沿同到的防线)', () async {
      transport
        ..ok() // 0x9201(两次调用共享这一次)
        ..ok(data: _fakeFrame()); // 首帧
      final a = controller.autoLiveViewOnConnect();
      // 首个仍在途(running 要等 0x9201 应答才置,并发 start() 会双发):
      // 单飞共享 Future,第二个调用不再过 start 门。
      final b = controller.autoLiveViewOnConnect();
      await Future.wait([a, b]);
      await pumpEventQueue();
      expect(controller.liveViewActive, isTrue);
      expect(transport.count(NikonOperationCode.startLiveView), 1);
      expect(transport.count(NikonOperationCode.getLiveViewImageEx), 1,
          reason: '轮询循环仅一条');
    });
  });

  group('触控对焦与对焦驱动(候选码,待真机核对)', () {
    late _ScriptTransport transport;
    late _FakeConnection conn;
    late RemoteController controller;

    setUp(() {
      transport = _ScriptTransport();
      conn = _FakeConnection();
      // 引擎帧轮询/AE 轮询驻停(不抢脚本);控制器 delay 保留门控
      // 供 0x2019 忙退避测试放行。
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
        aeDelay: _parkedDelay,
      );
    });

    tearDown(() async {
      controller.dispose();
    });

    /// 开取景:0x9201 + 首帧(SOF 32×24)→ 帧轮询驻停,帧尺寸已入册。
    Future<void> startLiveView() async {
      transport
        ..ok() // 0x9201
        ..ok(data: _fakeFrame()); // 首帧
      await controller.toggleLiveView();
      await pumpEventQueue();
      expect(controller.frameSize.value, (width: 32, height: 24));
    }

    test('点按 → 0x9205 帧像素坐标 + 0x90C1 驱动 + 对焦框上屏', () async {
      await startLiveView();
      transport
        ..ok() // changeAfArea
        ..ok(); // afDrive
      await controller.touchFocus(0.5, 0.25);
      final af = transport.requests
          .singleWhere((r) => r.opcode == NikonOperationCode.changeAfArea);
      expect(af.params, [16, 6], reason: '0.5×32、0.25×24(无头退回 SOF 帧)');
      expect(transport.count(NikonOperationCode.afDrive), 1);
      expect(controller.afBox, isNotNull);
      expect(controller.afBox!.nx, 0.5);
      expect(controller.afBox!.ny, 0.25);
      expect(controller.error, isNull);
      expect(controller.focusing, isFalse);
    });

    test('帧头在册 → 0x9205 参数用 whole-size 坐标系(6048×3400)', () async {
      await startLiveView();
      controller.engine.header.value =
          parseLiveViewHeader(_minimalHeaderFrame(recording: false));
      transport
        ..ok() // changeAfArea
        ..ok(); // afDrive
      await controller.touchFocus(0.5, 0.25);
      final af = transport.requests
          .singleWhere((r) => r.opcode == NikonOperationCode.changeAfArea);
      expect(af.params, [3024, 850],
          reason: '0.5×6048、0.25×3400(OpenZCine recentre 同坐标系)');
    });

    test('录制被 0xA004 拒(机顶拨杆在照片档)→ 拨杆提示,录制态不变',
        () async {
      await startLiveView();
      transport.reply(NikonResponseCode.invalidStatus); // 0x920A 被拒
      await controller.toggleRecord();
      expect(controller.error, contains('照片/视频'));
      expect(controller.recording, isFalse, reason: '被拒不翻转录制态');
    });

    test('0x9205 忙(0x2019)→ 短退避重试后成功', () async {
      await startLiveView();
      transport
        ..reply(PtpResponseCode.deviceBusy)
        ..reply(PtpResponseCode.deviceBusy)
        ..ok() // changeAfArea 第 3 次成功
        ..ok(); // afDrive
      final f = controller.touchFocus(0.25, 0.25);
      await pumpEventQueue();
      delay.release(); // 第 1 次退避
      await pumpEventQueue();
      delay.release(); // 第 2 次退避
      await f;
      expect(transport.count(NikonOperationCode.changeAfArea), 3);
      expect(controller.afBox, isNotNull);
      expect(controller.error, isNull);
    });

    test('未开取景点按 → 静默忽略,零流量', () async {
      await controller.touchFocus(0.5, 0.5);
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.changeAfArea),
          isEmpty);
      expect(controller.error, isNull);
    });

    test('取景中但帧无 SOF(尺寸未知)→ 提示且不发对焦', () async {
      transport
        ..ok() // 0x9201
        ..ok(data: Uint8List.fromList([1, 2, 3])); // 非 JPEG 帧
      await controller.toggleLiveView();
      await pumpEventQueue();
      expect(controller.frameSize.value, isNull);
      await controller.touchFocus(0.5, 0.5);
      expect(controller.error, contains('暂无取景帧'));
      expect(transport.count(NikonOperationCode.changeAfArea), 0);
    });

    test('对焦按钮:0x90C1 成功;0xA002 未合焦转友好提示;框色随判'
        '(2026-10-12 两色制:未合焦红/合焦绿)', () async {
      await startLiveView();
      transport.ok(); // afDrive 成功
      await controller.afDriveNow();
      expect(controller.error, isNull);
      expect(controller.focusing, isFalse);
      expect(controller.afBox, isNull, reason: '按钮路径无点位,不造框');

      transport.reply(NikonResponseCode.outOfFocus);
      await controller.afDriveNow();
      expect(controller.error, contains('未合焦'));
      expect(controller.focusing, isFalse);

      // 框色随判:触控对焦框 0xA002 后 focused=false(红),合焦后 true
      transport
        ..ok() // changeAfArea
        ..reply(NikonResponseCode.outOfFocus); // afDrive 未合焦
      await controller.touchFocus(0.5, 0.25);
      expect(controller.afBox!.focused, isFalse, reason: '未合焦红框');
      transport
        ..ok() // changeAfArea
        ..ok(); // afDrive 合焦
      await controller.touchFocus(0.5, 0.25);
      expect(controller.afBox!.focused, isTrue, reason: '合焦绿框');
    });

    test('对焦按钮:未开取景 → 提示不发(0xA00B notLiveView 应答形态)',
        () async {
      await controller.afDriveNow();
      expect(controller.error, contains('请先开启取景'));
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.afDrive),
          isEmpty);
    });

    test('对焦框:停取景即清', () async {
      await startLiveView();
      transport
        ..ok()
        ..ok();
      await controller.touchFocus(0.5, 0.5);
      expect(controller.afBox, isNotNull);
      transport.ok(); // 0x9202
      await controller.toggleLiveView(); // 关取景
      await pumpEventQueue();
      expect(controller.afBox, isNull);
    });

    test('机身对焦模式 MF(0xD061=3 固定/4 选择,全方言两态同拦)→ '
        '触控对焦/AF 钮/MF 步进全拦,提示且零流量', () async {
      await startLiveView();
      for (final mf in kStillFocusModeMfValues) {
        controller.paramProps[PtpDevicePropCode.stillFocusMode] =
            PropState(value: mf);
        await controller.touchFocus(0.5, 0.5);
        await controller.afDriveNow();
        await controller.mfDriveStep(towardNear: true);
        expect(transport.count(NikonOperationCode.changeAfArea), 0,
            reason: 'MF=$mf 触控对焦拦');
        expect(transport.count(NikonOperationCode.afDrive), 0,
            reason: 'MF=$mf AF 钮拦');
        expect(transport.count(NikonOperationCode.mfDrive), 0,
            reason: 'MF=$mf 步进拦');
        expect(controller.notice, contains('MF'), reason: 'MF=$mf 提示');
        expect(controller.error, isNull, reason: '门闩是状态说明不是错误');
        expect(controller.afBox, isNull, reason: '对焦框不上屏');
      }
    });

    test('机身对焦模式 MF → 拉焦轮拖动丢弃,切回 AF 后无陈旧爆发', () async {
      await startLiveView();
      controller.paramProps[PtpDevicePropCode.stillFocusMode] =
          const PropState(value: 4); // MF(选择,Zf 域内值)
      controller.focusDialDrag(48); // 攒了两步的量:MF 下全部丢弃
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.mfDrive), 0);

      // 切回 AF-S(等价 0x4006 定向刷新落值):解锁后新拖动照常驱动,
      // 锁定期余量不爆发(恰一步 = 恰一条 0x9204)。
      controller.paramProps[PtpDevicePropCode.stillFocusMode] =
          const PropState(value: 0);
      transport.ok(); // 0x9204
      controller.focusDialDrag(24);
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.mfDrive), 1);
    });

    test('0xD061 值未知(desc 拒答未读到)→ 不锁,触控对焦照常', () async {
      await startLiveView();
      // paramProps 无 stillFocusMode 条目 = 值未知(fail-open,不把可用
      // 控制锁死)。
      transport
        ..ok() // changeAfArea
        ..ok(); // afDrive
      await controller.touchFocus(0.5, 0.5);
      expect(transport.count(NikonOperationCode.afDrive), 1);
      expect(controller.notice, isNull);
    });
  });

  test('AE 轮换轮询:取景运行期间按节拍刷三要素,停取景即停', () async {
    final aeGates = Queue<Completer<void>>();
    final aeController = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: _parkedDelay),
      delay: _parkedDelay,
      aeDelay: (_) {
        final c = Completer<void>();
        aeGates.add(c);
        return c.future;
      },
    );
    addTearDown(aeController.dispose);
    transport
      ..ok() // 0x9201
      ..ok(data: _fakeFrame()); // 首帧
    await aeController.toggleLiveView();
    await pumpEventQueue();
    expect(aeController.liveViewActive, isTrue);

    // 第 1 拍:三要素全刷(机身重算 → 快门 1/50、ISO 400;快门/ISO 走
    // 厂商读码路由:0xD100 打包裸值 / 0xD0B5 有效 ISO)
    transport
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 280))
      ..ok(data: _u32Bytes(1 << 16 | 50)) // 0xD100:1/50s 打包
      ..ok(data: _propDescDataset(
          PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 400))
      ..ok(data: _u32Bytes(400)); // 0xD0B5
    aeGates.removeFirst().complete();
    await pumpEventQueue();
    expect(aeController.exposure?.iso, 400);
    expect(aeController.exposure?.shutterRaw, 1 << 16 | 50);

    // 停取景 → 轮询停:在途节拍放行也不得再刷(脚本未预置应答,
    // 若错误刷新会以脚本耗尽 StateError 炸出 —— Error 不被 on Exception 捕)。
    transport.ok(); // 0x9202
    await aeController.toggleLiveView();
    await pumpEventQueue();
    expect(aeController.liveViewActive, isFalse);
    aeGates.removeFirst().complete();
    await pumpEventQueue();
    expect(aeController.exposure?.iso, 400, reason: '停取景后不得再刷');
  });

  group('断链自动重连沿(2026-10-10)', () {
    test('reconnecting 沿:_invalidate 清态 + reconnecting=true;'
        '引擎停转但末帧保留(页面冻结帧不闪黑)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn); // 串链自动起景(0x9201 + 首帧)
      await pumpEventQueue();
      expect(controller.linkUp, isTrue);
      expect(controller.exposure?.fNumber, 280);
      expect(controller.liveViewActive, isTrue);
      final frozenFrame = controller.engine.frame.value;
      expect(frozenFrame, isNotNull);

      var notified = 0;
      controller.addListener(() => notified++);
      transport.ok(); // 0x9202(恢复期引擎 stop 尽力)

      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      expect(controller.reconnecting, isTrue);
      expect(controller.linkUp, isFalse, reason: '断连收口门闩(迟到值/事件被挡)');
      expect(controller.paramProps, isEmpty);
      expect(controller.exposure, isNull, reason: '参数清态');
      expect(controller.liveViewActive, isFalse, reason: '引擎停转(相机侧收景)');
      expect(controller.engine.frame.value, same(frozenFrame),
          reason: '末帧保留:页面横幅压暗下保留冻结帧等重连');
      expect(notified, greaterThan(0), reason: '_invalidate 通知页面(横幅驱动)');
      expect(transport.count(NikonOperationCode.endLiveView), 1);
    });

    test('reconnecting → connected:旗标清、参数重载、取景自愈重启'
        '(重连成功自动恢复 —— 2026-10-11 修复:connected 沿串链自动起景,'
        '画面就地恢复,不再须退出拍摄页重进)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn); // 首连:串链起景 + 刷参
      await pumpEventQueue();
      expect(controller.liveViewActive, isTrue);
      transport.ok(); // 0x9202(reconnecting 沿引擎 stop 尽力)
      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      expect(controller.reconnecting, isTrue);
      expect(controller.linkUp, isFalse);
      expect(controller.liveViewActive, isFalse, reason: '恢复期引擎停转');

      _scriptParams(transport);
      _emitConnected(transport, conn); // 重连成功:串链再起景 + 再刷参
      await pumpEventQueue();
      expect(controller.reconnecting, isFalse);
      expect(controller.linkUp, isTrue);
      expect(controller.exposure?.fNumber, 280, reason: '重连成功全量刷参');
      expect(controller.liveViewActive, isTrue,
          reason: '重连成功取景自愈重启(画面就地恢复)');
      expect(transport.count(NikonOperationCode.startLiveView), 2,
          reason: '两次 connected 沿各一次 0x9201');
      expect(controller.engine.frame.value, isNotNull,
          reason: '自愈首帧已发布,冻结画面已被替换');
    });

    test('reconnecting → failed:旗标清,终态留给页面弹回(预算耗尽)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      conn.statesCtrl.add(CameraLinkState.reconnecting);
      await pumpEventQueue();
      expect(controller.reconnecting, isTrue);

      conn.statesCtrl.add(CameraLinkState.failed);
      await pumpEventQueue();
      expect(controller.reconnecting, isFalse);
      expect(controller.linkUp, isFalse);
    });

    test('liveViewBusyHold:引擎健康度透传,BUSY 保持沿通知页面(横幅)', () async {
      expect(controller.liveViewBusyHold, isFalse);
      var notified = 0;
      controller.addListener(() => notified++);

      controller.engine.health.value = LiveViewHealth.busy;
      expect(controller.liveViewBusyHold, isTrue);
      expect(notified, 1, reason: '_onEngineHealth → notifyListeners');

      controller.engine.health.value = LiveViewHealth.ok;
      expect(controller.liveViewBusyHold, isFalse);
      expect(notified, 2);
    });
  });

  group('取景画质档(2026-10-12 官方 §6.5.11.4-5)', () {
    test('连接沿:设过档 → 模式读后、起景前写 0xD1AC/0xD1BC(u8 显式)',
        () async {
      controller.setLiveViewQuality(imageSize: 1, compression: 5);
      _scriptParams(transport);
      _emitConnected(transport, conn);
      // 两笔画质写应答插到链首 [0xD1A6 之后、0x9201 之前]
      final d1a6 = transport.script.removeFirst();
      final start = transport.script.removeFirst();
      final frame = transport.script.removeFirst();
      transport.script
        ..addFirst(frame)
        ..addFirst(const PtpResult(responseCode: PtpResponseCode.ok)) // 0xD1BC
        ..addFirst(const PtpResult(responseCode: PtpResponseCode.ok)) // 0xD1AC
        ..addFirst(start)
        ..addFirst(d1a6);
      await pumpEventQueue();
      final ops = transport.requests.map((r) => r.opcode).toList();
      // 序 = [0xD1A6 读, 0x9201?, ...] 实际 = 模式读 → 两笔画质写 → 起景
      final writeIdx = ops.indexOf(PtpOperationCode.setDevicePropValue);
      final startIdx = ops.indexOf(NikonOperationCode.startLiveView);
      expect(writeIdx, inInclusiveRange(1, 2), reason: '画质写在模式读之后');
      expect(startIdx, 3, reason: '起景在画质写之后(首帧即目标分辨率)');
      final writes = transport.requests
          .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
          .toList();
      expect(writes[0].params, [PtpDevicePropCode.liveViewImageSize]);
      expect(writes[0].dataOut, [1]);
      expect(writes[1].params, [PtpDevicePropCode.liveViewImageCompression]);
      expect(writes[1].dataOut, [5]);
      expect(controller.liveViewImageSize, 1);
      expect(controller.liveViewImageCompression, 5);
    });

    test('未设档(null = 跟随相机):连接沿零画质流量,序不变形', () async {
      expect(controller.liveViewImageSize, isNull);
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      final ops = transport.requests.map((r) => r.opcode).toList();
      expect(ops.take(2), [
        PtpOperationCode.getDevicePropValue, // 0xD1A6
        NikonOperationCode.startLiveView, // 直接起景
      ]);
      expect(transport.requests.where((r) => r.params.contains(
              PtpDevicePropCode.liveViewImageSize)), isEmpty,
          reason: '「跟随相机」不写机身菜单既有值');
    });

    test('取景运行中改档:即时写(两码独立,失败互不连坐)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      final baseline = transport.requests.length;
      transport
        ..reply(PtpResponseCode.accessDenied) // 0xD1AC 拒
        ..ok(); // 0xD1BC 通
      controller.setLiveViewQuality(imageSize: 3, compression: 3);
      await pumpEventQueue();
      final writes = transport.requests.skip(baseline).toList();
      expect(writes[0].params, [PtpDevicePropCode.liveViewImageSize]);
      expect(writes[0].dataOut, [3]);
      expect(writes[1].params, [PtpDevicePropCode.liveViewImageCompression]);
      expect(writes[1].dataOut, [3]);
      expect(controller.liveViewImageSize, 3,
          reason: '写被拒本地值保持(尽力而为,重连沿再补)');
    });
  });

  group('视频参数写后复读守卫(2026-10-13 探针:Zf 视频曝光写收下但弹回)', () {
    test('写 0xD1A9 成功但读回拨盘值 → notice 明说;读回一致 → 无提示',
        () async {
      // 视频档连接(0xD1A6=1):当前光圈 200(拨盘值)
      _scriptParamsVideo(transport);
      _emitConnected(transport, conn, d1a6: 1);
      await pumpEventQueue();
      expect(controller.cameraMode, CaptureMode.video);

      // 写 280 → 0x1016 OK,复读回 200(弹回)→ notice
      transport
        ..ok() // 0x1016 写 280
        ..ok(data: _propDescDataset(PtpDevicePropCode.movieFnumber,
            PtpDataType.uint16, 200,
            getSet: true, enums: [200, 280])); // 复读回弹值
      await controller.setParam(PtpDevicePropCode.movieFnumber, 280);
      expect(controller.error, isNull);
      expect(controller.notice, contains('回弹'));
      expect(controller.notice, contains('机身拨盘拥有'));

      // 写 200(= 拨盘值)→ 复读一致 → 无守卫提示
      transport
        ..ok() // 0x1016 写 200
        ..ok(data: _propDescDataset(PtpDevicePropCode.movieFnumber,
            PtpDataType.uint16, 200,
            getSet: true, enums: [200, 280]));
      await controller.setParam(PtpDevicePropCode.movieFnumber, 200);
      expect(controller.notice, isNull);
    });
  });

  group('官方指令书候选区接线·控制器(2026-10-13 批:AF 取消/主体追踪/'
      'AE 锁/0xD102/SDRAM 直拍)', () {
    late _ScriptTransport transport;
    late _FakeConnection conn;
    late _FakeTransferEngine gallery;
    late RemoteController controller;

    setUp(() {
      transport = _ScriptTransport();
      conn = _FakeConnection();
      gallery = _FakeTransferEngine();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        transferEngine: gallery,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: delay.call,
        aeDelay: _parkedDelay,
      );
      // 5s/120s 真窗拨小:超时分支即时收口,不拖测试钟。
      controller
        ..sdramHandleTimeout = const Duration(milliseconds: 80)
        ..sdramTransferTimeout = const Duration(milliseconds: 80);
    });

    tearDown(() async {
      controller.dispose();
    });

    Future<void> startLiveView() async {
      transport
        ..ok() // 0x9201
        ..ok(data: _fakeFrame()); // 首帧
      await controller.toggleLiveView();
      await pumpEventQueue();
    }

    test('对焦中再点对焦钮 → 0x9206 取消 + notice(打断实效待真机核对)',
        () async {
      controller.focusing = true;
      transport.ok(); // 0x9206
      await controller.afDriveNow();
      expect(transport.requests.single.opcode,
          NikonOperationCode.afDriveCancel);
      expect(controller.notice, '已取消对焦');
      expect(controller.error, isNull);
    });

    test('主体追踪:未开取景 → 拦下不发票', () async {
      await controller.startTracking();
      expect(controller.error, '请先开启取景');
      expect(transport.requests, isEmpty);
    });

    test('主体追踪:AF 区域非「自动」(0x8010 单点)→ notice 指引,不发票',
        () async {
      await startLiveView();
      controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
          const PropState(value: 0x8010);
      await controller.startTracking();
      expect(controller.notice, contains('自动'));
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.startTracking),
          isEmpty);
    });

    test('主体追踪:启动 → 0x9424 whole-size 中心坐标(无触控点),'
        'tracking=true', () async {
      await startLiveView();
      controller.engine.header.value =
          parseLiveViewHeader(_minimalHeaderFrame(recording: false));
      controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
          const PropState(value: 0x8011);
      transport.ok(); // 0x9424
      await controller.startTracking();
      final req = transport.requests
          .singleWhere((r) => r.opcode == NikonOperationCode.startTracking);
      expect(req.params, [3024, 1700],
          reason: '0.5×6048、0.5×3400(0x9205 同坐标系)');
      expect(controller.tracking, isTrue);
      expect(controller.error, isNull);
    });

    test('主体追踪:停止 → 0x9425 无参,tracking=false', () async {
      await startLiveView();
      controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
          const PropState(value: 0x8011);
      transport
        ..ok() // 0x9424
        ..ok(); // 0x9425
      await controller.startTracking();
      await controller.endTracking();
      expect(transport.count(NikonOperationCode.startTracking), 1);
      final end = transport.requests
          .singleWhere((r) => r.opcode == NikonOperationCode.endTracking);
      expect(end.params, isEmpty);
      expect(controller.tracking, isFalse);
    });

    test('AE 锁:切换写 0x9426 [1,2]/[0,2](探针形),0xD105 读回对表',
        () async {
      transport
        ..ok() // 0x9426 锁
        ..ok(data: Uint8List.fromList([1])) // 0xD105:1=锁定
        ..ok() // 0x9426 解锁
        ..ok(data: Uint8List.fromList([0])); // 读回 0
      await controller.toggleAELock();
      expect(transport.requests[0].opcode, NikonOperationCode.changeAELock);
      expect(transport.requests[0].params, [1, 2]);
      expect(controller.aeLocked, isTrue);
      await controller.toggleAELock();
      expect(transport.requests[2].params, [0, 2]);
      expect(controller.aeLocked, isFalse);
    });

    test('AE 锁:0x200F 拒(WB 非 auto 时机身拒 AWB 锁)→ error,旗标不动',
        () async {
      transport.reply(PtpResponseCode.accessDenied);
      await controller.toggleAELock();
      expect(controller.error, contains('AE 锁切换失败'));
      expect(controller.aeLocked, isFalse);
    });

    test('AE 锁:读回与乐观态不一致 → 以读回为准(不亮假锁)', () async {
      transport
        ..ok() // 0x9426 OK
        ..ok(data: Uint8List.fromList([0])); // 0xD105 读回未锁
      await controller.toggleAELock();
      expect(controller.aeLocked, isFalse);
    });

    test('内屏强关:0x9422 [1]/[0] 切换,0xD1BA 读回对表(B 组)', () async {
      transport
        ..ok() // 0x9422 强关
        ..ok(data: Uint8List.fromList([1])) // 0xD1BA:1=已强关
        ..ok() // 0x9422 取消
        ..ok(data: Uint8List.fromList([0])); // 读回 0
      await controller.toggleMonitorOff();
      expect(transport.requests[0].opcode, NikonOperationCode.changeMonitorOff);
      expect(transport.requests[0].params, [1]);
      expect(controller.monitorOff, isTrue);
      await controller.toggleMonitorOff();
      expect(transport.requests[2].params, [0]);
      expect(controller.monitorOff, isFalse);
    });

    test('内屏强关:拒答 → error,旗标不动', () async {
      transport.reply(PtpResponseCode.accessDenied); // 电池耗尽等拒 0x200F
      await controller.toggleMonitorOff();
      expect(controller.error, contains('内屏开关失败'));
      expect(controller.monitorOff, isFalse);
    });

    test('capture 通用错误 + 0xD102 Bit0 → 追加序列错误自愈指引'
        '(官方 §11.7.5:下一次释放自清)', () async {
      transport
        ..reply(NikonResponseCode.hardwareError) // 0x9207 → hint
        ..ok(data: _u32Bytes(0x1)); // 0xD102 Bit0=1
      await controller.capture();
      expect(controller.error, contains('相机硬件错误'));
      expect(controller.error, contains('再按一次快门'));
    });

    test('capture 通用错误 + 0xD102 无位 → 原错误不动', () async {
      transport
        ..reply(NikonResponseCode.hardwareError)
        ..ok(data: _u32Bytes(0x0));
      await controller.capture();
      expect(controller.error, contains('相机硬件错误'));
      expect(controller.error, isNot(contains('序列错误')));
    });

    test('SDRAM 直拍全链:0x90CB → 手拉事件 0xC101 句柄 → ObjectInfo → '
        '图库入队(gallery)→ 终态 notice', () async {
      controller.sdramCapture = true;
      transport
        ..ok() // 0x90CB AF+SDRAM 一体
        ..ok() // deviceReady → true(settle)
        ..ok(data: _eventExDataset(NikonEventCode.objectAddedInSdram, 0x1234))
        ..ok(data: _objectInfoDataset()); // getObjectInfo(0x1234)
      final capture = controller.capture();
      await pumpEventQueue();
      delay.release(); // DeviceReady 轮询放行
      await capture;
      expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1);
      expect(gallery.enqueued, hasLength(1));
      expect(gallery.enqueued.single.handle, 0x1234);
      expect(gallery.lastDestination, TransferDestination.gallery);
      expect(controller.notice, '已拍摄并保存到图库(SDRAM,不入卡)');
      expect(controller.error, isNull);
      expect(controller.capturing, isFalse);
    });

    test('SDRAM 直拍:0xC101 未到(5s 窗)→ notice 如实,不上 error 不入队',
        () async {
      controller.sdramCapture = true;
      transport
        ..ok() // 0x90CB
        ..ok() // deviceReady
        ..ok(data: Uint8List.fromList([0, 0, 0, 0])); // getEventEx 空队列
      final capture = controller.capture();
      await pumpEventQueue();
      delay.release();
      await capture;
      expect(controller.notice, contains('未收到相机回传对象'));
      expect(controller.error, isNull);
      expect(gallery.enqueued, isEmpty);
    });

    test('SDRAM 直拍被拒(0x2005)→ 回落常规 0x9207 入卡 + notice 如实;'
        '模型级拒绝记本连接不再重试', () async {
      controller.sdramCapture = true;
      transport
        ..reply(PtpResponseCode.operationNotSupported) // 0x90CB 被拒
        ..ok() // 0x9207 回落
        ..ok() // deviceReady(settle)
        ..ok() // 第二拍 0x9207 直发
        ..ok(); // deviceReady
      final c1 = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c1;
      expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1);
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
          reason: '回退必须实发 0x9207 —— 照片入卡不丢');
      expect(controller.notice, contains('已改常规拍摄入卡'),
          reason: '照片去了卡而非 SDRAM,机制变更必须如实带出');
      expect(controller.notice, contains('本连接不再重试'));
      expect(controller.error, isNull);
      expect(gallery.enqueued, isEmpty);
      final c2 = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c2;
      expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1,
          reason: '0x2005 模型个性跨连接稳定,第二拍不再试 0x90CB');
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 2,
          reason: '第二拍 0x9207 直发(会话缓存)');
      expect(controller.error, isNull);
    });

    test('SDRAM 直拍状态类拒绝(0x200F)→ 回落但逐拍回试 0x90CB', () async {
      controller.sdramCapture = true;
      transport
        ..reply(PtpResponseCode.accessDenied) // 第一拍 0x90CB(拨杆位)
        ..ok() // 0x9207 回落
        ..ok() // deviceReady
        ..reply(PtpResponseCode.accessDenied) // 第二拍 0x90CB 仍回试
        ..ok() // 0x9207
        ..ok(); // deviceReady
      final c1 = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c1;
      final c2 = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c2;
      expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 2,
          reason: '状态类拒绝(拨杆位)不是模型个性,逐拍回试');
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 2,
          reason: '每次回退都要实发 0x9207 —— 照片必须入卡不丢');
      expect(controller.notice, contains('已改常规拍摄入卡'));
      expect(controller.error, isNull);
    });

    test('SDRAM 直拍忙(0x2019)不回落:照旧 error,不发票 0x9207', () async {
      controller.sdramCapture = true;
      transport
        ..reply(PtpResponseCode.deviceBusy) // 0x90CB 忙
        ..ok(data: _u32Bytes(0x0)); // 0xD102 序列错误位读(无位 → 原错误)
      await controller.capture();
      expect(controller.error, contains('快门释放失败'),
          reason: '忙 = 相机没收下命令,回落重拍反而添乱');
      expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 0);
      expect(gallery.enqueued, isEmpty);
    });

    test('断链 → tracking/AE 锁旗标清零(会话级状态不跨会话)', () async {
      await startLiveView();
      controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
          const PropState(value: 0x8011);
      transport
        ..ok() // 0x9424
        ..ok() // 0x9426 锁
        ..ok(data: Uint8List.fromList([1])); // 0xD105 读回
      await controller.startTracking();
      await controller.toggleAELock();
      expect(controller.tracking, isTrue);
      expect(controller.aeLocked, isTrue);
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(controller.tracking, isFalse);
      expect(controller.aeLocked, isFalse);
    });
  });
}

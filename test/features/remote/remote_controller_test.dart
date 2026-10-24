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
import 'package:nikon_pill/core/remote/intervalometer.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
import 'package:nikon_pill/core/remote/live_view_header.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';
import '../../helpers/fake_connection.dart';

part 'remote_controller_test_capture.dart';
part 'remote_controller_test_prop.dart';
part 'remote_controller_test_lv.dart';
part 'remote_controller_test_af.dart';
part 'remote_controller_test_cross.dart';




final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final eventCtrl = StreamController<PtpEvent>.broadcast();

  /// 观察钩子(起景段落定门用例):每笔请求入队时回调 —— 采样「门已放行」
  /// 在刷参链首笔入队时点上的真值,判别「门挂起景段落定」还是「门挂链尾」。
  void Function(PtpRequest request)? onRequest;

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void reply(int responseCode) =>
      script.add(PtpResult(responseCode: responseCode));
  void fail(Object e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    onRequest?.call(request);
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
  (code: 0x0001D01C, type: PtpDataType.uint8, value: 0, enums: null), // 色调(Ex 扩展码;真域 [0,2])
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

/// 目录序全量应答:链首张数裸读(0xD1F1,refreshParams 打头,2026-10-16
/// 改制)+ PropDesc(取值域直供表参数跳过 —— 快门不读标准码
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
  if (tail) {
    t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数(链首读)
  }
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
  }
}

/// 视频档全量刷参块(张数链首读 + 照片参数无尾 + 视频参数族 + 自动 ISO
/// —— 消费序 = refreshParams 的 [0xD1F1 → 照片参数 → 视频参数 →
/// 0xD054],视频档追加视频族,张数永远在最前)。
void _scriptParamsVideo(_ScriptTransport t) {
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数(链首读)
  _scriptParams(t, tail: false);
  _scriptVideoParams(t);
  t.ok(data: Uint8List.fromList([0])); // 0xD054 自动 ISO:关
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

/// PropDesc 全拒的回退应答(值走裸读;路由参数读厂商码)。张数链首读
/// 同 _scriptParams 口径。
void _scriptParamsRawFallback(_ScriptTransport t, {int mode = 1}) {
  t.ok(data: _u32Bytes(1234)); // 0xD1F1 剩余张数(链首读)
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
void _emitConnected(_ScriptTransport t, FakeConnection c,
    {int d1a6 = 0, bool apTakeover = false}) {
  t.script
    ..addFirst(PtpResult(
        responseCode: PtpResponseCode.ok, data: _fakeFrame())) // 首帧
    ..addFirst(PtpResult(responseCode: PtpResponseCode.ok)) // 0x9201
    ..addFirst(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([d1a6]))); // 0xD1A6(链首读)
  // [apTakeover] = AP 连接沿主动接管的链首 0x90C2(1) 应答(_onConnected
  // Chain 起在模式读之前)—— 级联之后 addFirst 才真在队首。
  if (apTakeover) {
    t.script
        .addFirst(PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(1)
  }
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

/// 最小 display-info 头(坐标系 6048×3400、单框;[recording] 写 @828,
/// [videoRemainingMs] 写 @816-819 BE u32):头按真机形态补 1024B 定长 +
/// SOI JPEG 尾(头长靠 SOI 位置定位),控制器测试直接注到 engine.header。
Uint8List _minimalHeaderFrame({required bool recording, int? videoRemainingMs}) {
  final b = Uint8List(1024 + 4);
  void be16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  void be32(int o, int v) {
    b[o] = (v >> 24) & 0xFF;
    b[o + 1] = (v >> 16) & 0xFF;
    b[o + 2] = (v >> 8) & 0xFF;
    b[o + 3] = v & 0xFF;
  }

  be16(16, 6048);
  be16(18, 3400);
  b[42] = 2; // 合焦
  b[44] = 1; // areaCount
  be16(48, 240);
  be16(50, 240);
  be16(52, 3024);
  be16(54, 1700);
  if (videoRemainingMs != null) be32(816, videoRemainingMs);
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
  Future<void> removeRecord(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

// ---- 共享夹具(库级 late;setUp 每案重建,各组函数/分片共用)----
late _ScriptTransport transport; // ignore: library_private_types_in_public_api
late FakeConnection conn;
late _GatedDelay delay; // ignore: library_private_types_in_public_api
late RemoteController controller;

void main() {
  setUp(() {
    transport = _ScriptTransport();
    conn = FakeConnection();
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
    controller.dispose();  });


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

  test('起景段落定门:0x9201 落定即放行(先于链尾刷参),落定后预换下一沿新门',
      () async {
    _scriptParams(transport);
    var gateDone = false;
    unawaited(controller.connectedStartSettled.then((_) => gateDone = true));
    // 刷参链首笔 = 张数裸读(0x1014 [0xD1F1]):入队时点上采样门真值。
    // 门挂起景段落定 ⇒ 此刻必已放行;误挂链尾 ⇒ 必未放行,一采样即判别。
    var gateDoneAtFirstParam = false;
    transport.onRequest = (r) {
      if (r.opcode == PtpOperationCode.getDevicePropValue &&
          r.params.single == PtpDevicePropCode.exposureRemaining) {
        gateDoneAtFirstParam = gateDone;
      }
    };
    _emitConnected(transport, conn);
    await pumpEventQueue();
    expect(controller.engine.status.value, LiveViewStatus.running);
    expect(gateDone, isTrue);
    expect(gateDoneAtFirstParam, isTrue,
        reason: '门在起景段落定即完成,先于刷参链首笔入队');
    // 本沿门已决;此刻取门 = 下一沿预建新门(不携本沿已决,等窗不空放)。
    var nextEdgeDone = false;
    unawaited(controller.connectedStartSettled.then((_) => nextEdgeDone = true));
    await pumpEventQueue();
    expect(nextEdgeDone, isFalse);
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
    expect(controller.error?.key, 'remote.errShutterFail');
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
    expect(controller.error?.key, 'remote.errLeverPhoto');
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
    expect(controller.error?.key, 'remote.errShutterStorage',
        reason: '标准义在先:无卡/卡错误指卡槽;卡在位别名也指(2026-10-11 真机)');
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
    expect(controller.error?.key, 'remote.errShutterFail');
    expect(controller.error?.args?['e'], contains('0x100E'),
        reason: '回退码失败更可诊断(异常文本带操作码)');
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
    expect(controller.error?.key, 'remote.errShutterParam');
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
  _captureGroups();
  _propGroups();
  _lvGroups();
  _afGroups();
  _crossGroups();
}

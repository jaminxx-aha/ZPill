import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/live_view_engine.dart';
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
  (code: PtpDevicePropCode.focusMode, type: PtpDataType.uint16, value: 1, enums: [0, 1, 2, 4]),
  (code: PtpDevicePropCode.stillFocusMode, type: PtpDataType.uint8, value: 0, enums: [0, 1, 4, 5]),
  (code: PtpDevicePropCode.stillCaptureMode, type: PtpDataType.uint16, value: 1, enums: [1, 2, 0x8010, 0x8011]),
  (code: PtpDevicePropCode.compressionSetting, type: PtpDataType.uint8, value: 7, enums: [4, 5, 7, 12]),
  (code: PtpDevicePropCode.rawCompressionType, type: PtpDataType.uint8, value: 0, enums: [0, 3, 4]),
  (code: PtpDevicePropCode.imageSize, type: PtpDataType.uint16, value: 2, enums: [1, 2, 3]),
  (code: PtpDevicePropCode.captureAreaCrop, type: PtpDataType.uint8, value: 0, enums: [0, 2, 4, 5]),
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
/// PropDesc)+ 值回读(路由参数读厂商码裸值;readonlyCodes 指定只读属性)。
void _scriptParams(_ScriptTransport t, {Set<int> readonlyCodes = const {}}) {
  for (final s in _kParamSpecs) {
    final param = shootingParamByCode[s.code]!;
    if (param.pickValues == null) {
      t.ok(data: _propDescDataset(s.code, s.type, s.value,
          getSet: !readonlyCodes.contains(s.code), enums: s.enums));
    }
    final vendor = _kVendorReadValues[s.code];
    if (vendor != null) {
      t.ok(data: _u32Bytes(vendor));
    }
  }
}

/// PropDesc 全拒的回退应答(值走裸读;路由参数读厂商码)。
void _scriptParamsRawFallback(_ScriptTransport t) {
  for (final s in _kParamSpecs) {
    final param = shootingParamByCode[s.code]!;
    if (param.pickValues == null) {
      t.reply(PtpResponseCode.operationNotSupported); // 0x1014 拒
    }
    final vendor = _kVendorReadValues[s.code];
    t.ok(data: vendor != null ? _u32Bytes(vendor) : _rawBytes(s));
  }
}

/// 裸值应答字节(按类型宽度:u8 一字节 / u16 两字节 / u32 四字节;
/// 供 0x1015 回退路径)。
Uint8List _rawBytes(_ParamSpec s) {
  final width = s.type.width!;
  return Uint8List.fromList(
      [for (var i = 0; i < width; i++) (s.value >> (8 * i)) & 0xFF]);
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
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 280);
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
        reason: '快门值 = 0xD100 打包分数(1/100s),标准码不跟厂商写');
    expect(controller.exposure?.iso, 200, reason: 'ISO 值 = 0xD0B5 有效 ISO');
    expect(controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value,
        3, reason: '模式 = 光圈优先 A');
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
    transport.reply(PtpResponseCode.deviceBusy); // 首选码忙(0x9207)
    await controller.capture();
    expect(controller.error, contains('快门释放失败'));
    expect(controller.capturing, isFalse);
    expect(transport.count(NikonOperationCode.deviceReady), 0);
    expect(transport.count(PtpOperationCode.initiateCapture), 0,
        reason: '忙不是换码信号,不得回退');
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
      ..reply(PtpResponseCode.operationNotSupported); // 0x100E 也拒
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

      // 重连:先防御性解除,再全量刷参
      transport.ok(); // 0x90C2 [0]
      _scriptParams(transport);
      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();
      final modes = transport.requests
          .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
          .toList();
      expect(modes, hasLength(2));
      expect(modes[1].params, [0], reason: '重连后防御性解除 remote 模式');
      expect(controller.exposure?.fNumber, 280, reason: '解除后照常刷参');
    });

    test('拨盘参数写被拒(0x200F)→ 提示先启用 APP 接管', () async {
      _scriptParams(transport);
      conn.statesCtrl.add(CameraLinkState.connected);
      await pumpEventQueue();
      transport.reply(PtpResponseCode.accessDenied); // 0x1016 0xD100 被拒
      await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
      expect(controller.error, contains('APP 接管'));
    });
  });

  test('0x4006 事件(机身拨盘/菜单改动)→ 定向刷新被点名参数;表外码忽略',
      () async {
    _scriptParams(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
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
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.propWritable(PtpDevicePropCode.exposureIndex), isTrue,
        reason: 'ISO 写走厂商码,标准码 getSet 不作数');
    expect(controller.propWritable(PtpDevicePropCode.exposureTime), isTrue,
        reason: '快门写走厂商码,同上');
  });

  test('ObjectAdded → 「已拍摄」提示 + 参数刷新;断连后迟到事件丢弃', () async {
    _scriptParams(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.iso, 200);

    _scriptParams(transport); // ObjectAdded 触发的刷新
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
    conn.statesCtrl.add(CameraLinkState.connected);
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
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.exposure?.fNumber, 280);
    expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
        reason: '快门不读标准码(取值域直供),0xD100 裸值直达');
    expect(controller.exposure?.iso, 200);
    expect(controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value,
        3);
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
    conn.statesCtrl.add(CameraLinkState.connected);
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
    conn.statesCtrl.add(CameraLinkState.connected);
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

  test('模式(机顶转盘拥有):遥控只读,零流量', () async {
    _scriptParams(transport);
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
        isFalse,
        reason: '转盘参数不受 getSet 上报影响');
    await controller.setParam(PtpDevicePropCode.exposureProgramMode, 4);
    expect(controller.error, contains('机身转盘'));
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
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
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.canAdjustParams, isTrue);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue);
    expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
        isFalse,
        reason: '模式由机顶转盘拥有,遥控只读(不受 getSet 上报影响)');

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

  test('门禁开:相机上报只读(getSet=false)→ 拒写', () async {
    controller.dispose();
    controller = RemoteController(
      session: PtpSession(transport: transport),
      connection: conn,
      engine: LiveViewEngine(
          session: PtpSession(transport: transport), delay: delay.call),
      delay: delay.call,
      setPropGate: () => true,
    );

    _scriptParams(transport,
        readonlyCodes: {PtpDevicePropCode.fNumber}); // 光圈只读
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    await controller.setParam(PtpDevicePropCode.fNumber, 320);
    expect(controller.error, contains('只读'));
    expect(
        transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
        isEmpty);
    expect(controller.propWritable(PtpDevicePropCode.fNumber), isFalse);
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
    conn.statesCtrl.add(CameraLinkState.connected);
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
      expect(af.params, [16, 6], reason: '0.5×32、0.25×24');
      expect(transport.count(NikonOperationCode.afDrive), 1);
      expect(controller.afBox, isNotNull);
      expect(controller.afBox!.nx, 0.5);
      expect(controller.afBox!.ny, 0.25);
      expect(controller.error, isNull);
      expect(controller.focusing, isFalse);
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

    test('对焦按钮:0x90C1 成功;0xA002 未合焦转友好提示', () async {
      await startLiveView();
      transport.ok(); // afDrive 成功
      await controller.afDriveNow();
      expect(controller.error, isNull);
      expect(controller.focusing, isFalse);

      transport.reply(NikonResponseCode.outOfFocus);
      await controller.afDriveNow();
      expect(controller.error, contains('未合焦'));
      expect(controller.focusing, isFalse);
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
}

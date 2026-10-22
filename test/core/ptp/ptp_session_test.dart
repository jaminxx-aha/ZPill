import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptp/device_prop.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/ptpusb/containers.dart';
import 'package:z_pill/core/ptpusb/usb_transport.dart';
import 'package:z_pill/core/utils/byte_writer.dart';

import '../ptpusb/fake_usb_byte_pipe.dart';

/// 门控应答:先等 [gate] 完成再回放(测「枚举途中」时序用)。
final class _GatedReply {
  const _GatedReply(this.gate, this.result);
  final Future<void> gate;
  final Object result; // PtpResult 或 Exception(延迟失败)
}

/// 假传输层:按序回放预置结果(PtpResult)或异常。
///
/// 实现 [PtpCancelCapable] 以覆盖 Cancel-Drain 接线(计数即可,排水
/// 收口由脚本预置 failAfter(PtpCancelledException) 模拟)。
final class FakePtpTransport implements PtpTransport, PtpCancelCapable {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final StreamController<PtpEvent> _eventCtrl = StreamController.broadcast();

  /// 事件注入(测试:模拟相机 ObjectAdded 等事件到达)。
  void emitEvent(PtpEvent event) => _eventCtrl.add(event);

  /// cancelInFlight 调用计数(Cancel-Drain 接线断言用)。
  var cancelInFlightCalls = 0;

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  /// 预置一个延迟应答:execute 在 [gate] 完成前挂起。
  void replyAfter(Future<void> gate, PtpResult result) =>
      script.add(_GatedReply(gate, result));

  /// 预置一个延迟失败:execute 在 [gate] 完成前挂起,然后抛 [e]。
  void failAfter(Future<void> gate, Exception e) =>
      script.add(_GatedReply(gate, e));

  @override
  Future<bool> cancelInFlight() async {
    cancelInFlightCalls++;
    return true;
  }

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 ${request.opcode.toRadixString(16)} 的响应');
    }
    var next = script.removeFirst();
    if (next is _GatedReply) {
      await next.gate;
      next = next.result;
    }
    if (next is Exception) throw next;
    var result = next as PtpResult;
    if (onData != null && result.data != null) {
      // 模拟流式:数据切成两块回调,模拟大文件分块
      final d = result.data!;
      final mid = d.length ~/ 2;
      if (mid > 0) {
        onData(Uint8List.sublistView(d, 0, mid));
        onData(Uint8List.sublistView(d, mid));
        result =
            PtpResult(responseCode: result.responseCode, params: result.params);
      }
    }
    return result;
  }

  @override
  Stream<PtpEvent> get events => _eventCtrl.stream;

  @override
  Future<void> close() async {}
}

/// 首次 execute 挂在 [gate] 上不放行(验证串行锁排队的探针传输层)。
final class LockProbeTransport implements PtpTransport {
  LockProbeTransport(this.gate);

  final Completer<void> gate;
  final List<int> startedHandles = [];
  var _calls = 0;

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    startedHandles.add(request.params.single);
    if (_calls++ == 0) {
      await gate.future;
    }
    return PtpResult(
      responseCode: PtpResponseCode.ok,
      data: Uint8List.fromList([0xFF, 0xD8]),
    );
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

/// cancelInFlight 一调就炸的能力假件(取消通道自身异常的降级测试用)。
final class _CancelFailingTransport implements PtpTransport, PtpCancelCapable {
  @override
  Future<bool> cancelInFlight() async => throw Exception('排水通道抖动');

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    throw UnimplementedError();
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

/// 手搓 0x9805 ObjectPropList 数据集(官方 §6.2.11.5 数据集表,布局
/// 独立于被测代码):u32 计数 + N×(u32 句柄 + u16 属性码 + u16 类型 +
/// DTS 值),**无 GetSet 字节**(那是 0x9802 ObjectPropDesc 的布局)。
final class PropListDataset {
  final _entries = <Uint8List>[];

  void _entry(int handle, int code, int type, void Function(ByteWriter w) v) {
    final w = ByteWriter()
      ..u32(handle)
      ..u16(code)
      ..u16(type);
    v(w);
    _entries.add(w.takeBytes());
  }

  /// UINT16(0x0004)条目。
  void u16(int handle, int code, int value) =>
      _entry(handle, code, 0x0004, (w) => w.u16(value));

  /// UINT32(0x0006)条目。
  void u32(int handle, int code, int value) =>
      _entry(handle, code, 0x0006, (w) => w.u32(value));

  /// UINT64(0x0008)条目。
  void u64(int handle, int code, int value) =>
      _entry(handle, code, 0x0008, (w) => w.u64(value));

  /// STR(0xFFFF)条目。
  void str(int handle, int code, String value) =>
      _entry(handle, code, 0xFFFF, (w) => w.ptpString(value));

  /// 自定类型码 + 原始值字节(未知类型/INT128/数组等防错位场景用)。
  void raw(int handle, int code, int type, List<int> valueBytes) =>
      _entry(handle, code, type, (w) => w.raw(valueBytes));

  Uint8List build() {
    final w = ByteWriter()..u32(_entries.length);
    for (final e in _entries) {
      w.raw(e);
    }
    return w.takeBytes();
  }
}

/// 最小 ObjectInfo 数据集(0x9805 降级后「GetObjectInfo 仍可用」断言用;
/// 52B 定长头 + 文件名串,日期串未提供)。
Uint8List minimalObjectInfoDataset(String filename) {
  final w = ByteWriter()
    ..u32(0x00010001) // StorageID
    ..u16(0x3801) // ObjectFormat
    ..u16(0) // ProtectionStatus
    ..u32(1000) // CompressedSize
    ..u16(0x3808) // ThumbFormat
    ..u32(0) // ThumbCompressedSize
    ..u32(0) // ThumbPixWidth
    ..u32(0) // ThumbPixHeight
    ..u32(0) // ImagePixWidth
    ..u32(0) // ImagePixHeight
    ..u32(0) // ImageBitDepth
    ..u32(0) // ParentObject
    ..u16(0) // AssociationType
    ..u32(0) // AssociationDesc
    ..u32(0) // SequenceNumber
    ..ptpString(filename)
    ..ptpString(null) // captureDate 未提供
    ..ptpString(null); // modificationDate 未提供
  return w.takeBytes();
}

/// 手搓 GetDeviceInfo 数据集(ByteWriter;字段布局独立于被测代码)。
/// [operations] 可覆盖操作码表(默认不含 0x90C4,测「不在册」路径用)。
/// [serial] 可覆盖序列号(默认含前导零,覆盖 Zf 补零方言归一用例)。
/// 默认操作码表 = 「正常相机」基线:GetDeviceInfo/OpenSession/GetObject/
/// GetPartialObjectEx(连接层的受限画像检查以 GetObject 在册为准,
/// 2026-10-01 真机受限态就是缺它)。
Uint8List buildDeviceInfoDataset(
    {List<int> operations = const [0x1001, 0x1007, 0x1009, 0x9431],
    String serial = '012345678901'}) {
  final w = ByteWriter()
    ..u16(0x0100) // StandardVersion = 100(PTP/1.0)
    ..u32(0x0000000A) // VendorExtensionId(尼康)
    ..u16(0x0064); // VendorExtensionVersion
  putPtpString(w, 'Nikon'); // VendorExtensionDesc
  w.u16(0x0000); // FunctionalMode 标准
  // 五组 u32 计数 + N 个 u16(计数与元素必须相邻)
  w.u32(operations.length);
  for (final op in operations) {
    w.u16(op);
  }
  w
    ..u32(1)
    ..u16(0x4002) // events
    ..u32(2)
    ..u16(0x5001)
    ..u16(0x5007) // deviceProps
    ..u32(0) // captureFormats
    ..u32(2)
    ..u16(0x3000)
    ..u16(0x3801); // imageFormats
  putPtpString(w, 'Nikon Corp'); // manufacturer
  putPtpString(w, 'TestModel'); // model
  putPtpString(w, 'V1.00'); // deviceVersion
  putPtpString(w, serial); // serialNumber
  return w.takeBytes();
}

/// PTP STRING 数据集类型:u8 字符数 + UTF-16LE + 结尾 NUL(Zf 真机带 NUL)。
void putPtpString(ByteWriter w, String s) {
  w.u8(s.length + 1);
  w.utf16le(s);
  w.u16(0);
}

void main() {
  group('PtpDeviceInfo.parse', () {
    test('字段与五组数组完整解析,NUL 剥离', () {
      final info = PtpDeviceInfo.parse(buildDeviceInfoDataset());
      expect(info.standardVersion, 0x0100);
      expect(info.vendorExtensionId, 0x0000000A);
      expect(info.functionalMode, 0);
      expect(info.operationsSupported, [0x1001, 0x1007, 0x1009, 0x9431]);
      expect(info.eventsSupported, [0x4002]);
      expect(info.devicePropsSupported, [0x5001, 0x5007]);
      expect(info.captureFormats, isEmpty);
      expect(info.imageFormats, [0x3000, 0x3801]);
      expect(info.manufacturer, 'Nikon Corp');
      expect(info.model, 'TestModel');
      expect(info.deviceVersion, 'V1.00');
      expect(info.serialNumber, '12345678901'); // 前导零剥除(方言归一)
      expect(info.supportsOperation(0x9431), isTrue);
      expect(info.supportsOperation(0x90C8), isFalse);
    });

    test('序列号 Zf 方言:定宽 32 左补零剥前导零;全零占位 → null', () {
      // 真机实测(2026-10-09 定案):Zf 回 25 个 '0' + 8014411,
      // 尾段与 mDNS 实例名 Z_f_8014411 同源。
      expect(
          PtpDeviceInfo.parse(buildDeviceInfoDataset(
                  serial: '00000000000000000000000008014411'))
              .serialNumber,
          '8014411');
      expect(
          PtpDeviceInfo.parse(buildDeviceInfoDataset(serial: '000000000000'))
              .serialNumber,
          isNull,
          reason: '全零占位视为未提供');
    });
  });

  group('会话生命周期', () {
    test('正常打开:一次 OpenSession 即成', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
      expect(
          fake.requests.map((r) => r.opcode), [PtpOperationCode.openSession]);
      expect(fake.requests.single.params, [1]);
    });

    test('0x201E 自动恢复:CloseSession 后重开(probe ensure_session 同款)', () async {
      final fake = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.ok)) // CloseSession 的响应(内容不查)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        PtpOperationCode.openSession,
        PtpOperationCode.closeSession,
        PtpOperationCode.openSession,
      ]);
    });

    test('恢复中 CloseSession 抛异常也不阻断重开', () async {
      final fake = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
        ..fail(TimeoutException('链路抖动'))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
    });

    test('打开失败抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      await expectLater(session.open(), throwsA(isA<PtpResponseException>()));
      expect(session.isSessionOpen, isFalse);
    });

    test('close 幂等且拔线不报错', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..fail(TimeoutException('相机已拔出'));
      final session = PtpSession(transport: fake);
      await session.open();
      await session.close(); // CloseSession 超时,但清理不抛
      await session.close(); // 未开会话,直接返回
      expect(session.isSessionOpen, isFalse);
    });
  });

  group('浏览/下载操作', () {
    test('getObjectHandles:u32 计数 + N 个 u32', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count=2
            0x11, 0x00, 0x00, 0x00, // 0x11
            0x22, 0x00, 0x00, 0x00, // 0x22
          ]),
        ));
      final session = PtpSession(transport: fake);
      final handles = await session.getObjectHandles();
      expect(handles, [0x11, 0x22]);
      // 默认参数 = Zf 语义全量枚举:storageAll / formatAll / parent=0
      final req = fake.requests.single;
      expect(req.params, [
        GetObjectHandlesParams.storageAll,
        GetObjectHandlesParams.formatAll,
        GetObjectHandlesParams.parentRoot,
      ]);
    });

    test('getObjectInfo:错误码抛 PtpResponseException 并带操作码', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)); // ObjectNotOpen-ish 非法态
      final session = PtpSession(transport: fake);
      try {
        await session.getObjectInfo(42);
        fail('应抛 PtpResponseException');
      } on PtpResponseException catch (e) {
        expect(e.opcode, PtpOperationCode.getObjectInfo);
        expect(e.responseCode, 0x2009);
      }
    });

    test('getObject:流式回调,错误码照样校验', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList(List.generate(10, (i) => i)),
        ));
      final session = PtpSession(transport: fake);
      final chunks = <Uint8List>[];
      await session.getObject(7, onData: chunks.add);
      expect(chunks.length, 2); // 假传输层切成两块
      expect(chunks.expand((c) => c), List.generate(10, (i) => i));
      expect(fake.requests.single.opcode, PtpOperationCode.getObject);
      expect(fake.requests.single.params, [7]);
    });

    test('getThumb:数据整体返回,参数为 handle', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
        ));
      final session = PtpSession(transport: fake);
      final data = await session.getThumb(0x11);
      expect(data, [0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);
      expect(fake.requests.single.opcode, PtpOperationCode.getThumb);
      expect(fake.requests.single.params, [0x11]);
    });

    test('getThumb:相机非 OK 响应抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getThumb(0x11), throwsA(isA<PtpResponseException>()));
    });

    test('deleteObject:params=[handle],OK 即成;非 OK 抛异常带操作码', () async {
      final ok = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: ok);
      await session.deleteObject(0x33);
      final req = ok.requests.single;
      expect(req.opcode, PtpOperationCode.deleteObject);
      expect(req.params, [0x33]);

      final denied = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)); // 非法态
      final session2 = PtpSession(transport: denied);
      try {
        await session2.deleteObject(0x33);
        fail('应抛 PtpResponseException');
      } on PtpResponseException catch (e) {
        expect(e.opcode, PtpOperationCode.deleteObject);
        expect(e.responseCode, 0x2009);
      }
    });

    test('getLargeThumb:在册即发 0x90C4,前置杂字节剥到 SOI', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: buildDeviceInfoDataset(
                operations: [0x1001, NikonOperationCode.getLargeThumb])))
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          // 3 字节尼康头 + JPEG SOI:防御「头 + JPEG」形态
          data: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xFF, 0xD8, 0xFF, 0xE2]),
        ));
      final session = PtpSession(transport: fake);
      final data = await session.getLargeThumb(0x22);
      expect(data, [0xFF, 0xD8, 0xFF, 0xE2]);
      expect(fake.requests[1].opcode, NikonOperationCode.getLargeThumb);
      expect(fake.requests[1].params, [0x22]);
    });

    test('getLargeThumb:码表不在册抛 UnsupportedError,不发操作', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      // buildDeviceInfoDataset 的操作码表不含 0x90C4
      await expectLater(
          session.getLargeThumb(0x22), throwsA(isA<UnsupportedError>()));
      expect(fake.requests.length, 1); // 只有 GetDeviceInfo
    });

    test('getLargeThumb:非 JPEG 载荷(无 SOI)→ UnsupportedError + 会话降级秒拒', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            // NEF 压缩条带形态:整段无 FFD8
            data: Uint8List.fromList(List.filled(64, 0x55))));
      final session = PtpSession(transport: fake);
      await expectLater(session.getLargeThumb(0x22, force: true),
          throwsA(isA<UnsupportedError>()));
      expect(session.largeThumbDegraded, isTrue);
      // 降级后:force 直发秒拒(不再上链浪费 RTT)
      await expectLater(session.getLargeThumb(0x23, force: true),
          throwsA(isA<UnsupportedError>()));
      expect(fake.requests.length, 1);
    });

    test('getLargeThumb:超时 → 会话降级;open() 开新会话复位重探', () async {
      final fake = FakePtpTransport()
        ..fail(TimeoutException('bulkRead 窗口内未收到数据'))
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)) // openSession
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])));
      final session = PtpSession(transport: fake);
      await expectLater(session.getLargeThumb(0x22, force: true),
          throwsA(isA<TimeoutException>()));
      expect(session.largeThumbDegraded, isTrue);

      // 新会话:降级旗标复位,重新真发并成功
      await session.open();
      expect(session.largeThumbDegraded, isFalse);
      expect(await session.getLargeThumb(0x22, force: true),
          [0xFF, 0xD8, 0xFF, 0xD9]);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLargeThumb, // 首试(超时,置旗标)
        PtpOperationCode.openSession, // 新会话
        NikonOperationCode.getLargeThumb, // 复位后重探
      ]);
    });

    test('getDeviceInfo 缓存:第二次不发请求', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      final info = await session.getDeviceInfo();
      expect(info.model, 'TestModel');
      await session.getDeviceInfo();
      expect(fake.requests.length, 1);
    });

    test('cachedDeviceInfo:未取为 null,取后可读(纯读零流量)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      expect(session.cachedDeviceInfo, isNull);
      await session.getDeviceInfo();
      expect(session.cachedDeviceInfo?.model, 'TestModel');
      expect(fake.requests.length, 1, reason: 'cachedDeviceInfo 不发事务');
    });

    test('getEventEx:0x941C 事件列表解析(u32 计数 + N×(u16 码 + u16 参数数 + 参数))',
        () async {
      final w = ByteWriter()
        ..u32(2)
        // 0x4006 DevicePropChanged,1 参数(0x5007)
        ..u16(PtpEventCode.devicePropChanged)
        ..u16(1)
        ..u32(PtpDevicePropCode.fNumber)
        // 0x4002 ObjectAdded,1 参数(handle)
        ..u16(PtpEventCode.objectAdded)
        ..u16(1)
        ..u32(0x1234);
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final events = await session.getEventEx();
      expect(fake.requests.single.opcode, NikonOperationCode.getEventEx);
      expect(events, hasLength(2));
      expect(events[0].code, PtpEventCode.devicePropChanged);
      expect(events[0].params, [PtpDevicePropCode.fNumber]);
      expect(events[1].code, PtpEventCode.objectAdded);
      expect(events[1].params, [0x1234]);
    });

    test('事件并流:轮询注入与异步通道同时可达消费者', () async {
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final seen = <int>[];
      final sub = session.events.listen((e) => seen.add(e.code));
      fake._eventCtrl.add(const PtpEvent(
          code: PtpEventCode.captureComplete, transactionId: 0xFFFFFFFF));
      session.emitPolledEvents([
        const PtpEvent(
            code: PtpEventCode.objectAdded,
            transactionId: 0xFFFFFFFF,
            params: [1]),
      ]);
      await pumpEventQueue();
      expect(
          seen,
          containsAll(
              [PtpEventCode.captureComplete, PtpEventCode.objectAdded]));
      await sub.cancel();
    });

    test('mfDrive:0x9204 params [方向, 脉冲](钳 1..32767);结果分类', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.ok)) // 0x90C8 就绪探:完成
        ..reply(const PtpResult(responseCode: NikonResponseCode.mfDriveStepEnd))
        ..reply(const PtpResult(
            responseCode: NikonResponseCode.mfDriveStepInsufficiency))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.mfDrive(towardNear: true, pulses: 999999),
          MfDriveOutcome.complete,
          reason: '激活 OK + 就绪探 OK:完成');
      expect(fake.requests.first.params, [1, 32767], reason: '钳到上限');
      expect(await session.mfDrive(towardNear: false, pulses: 300),
          MfDriveOutcome.endOfTravel,
          reason: '激活即回 0xA00C(他机身方言兼容路径),无需就绪探');
      expect(fake.requests.last.params, [2, 300], reason: '向远 = 2');
      expect(await session.mfDrive(towardNear: true, pulses: 1),
          MfDriveOutcome.stepTooSmall);
      expect(await session.mfDrive(towardNear: true, pulses: 0),
          MfDriveOutcome.refused,
          reason: '0 钳到 1,但响应 invalidStatus → refused');
    });

    test('mfDrive 收尾:激活 OK 后完成态经 0x90C8 就绪轮询读回(§6.2.5.3)',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 激活:已开始
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.deviceBusy)) // 驱动中
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.deviceBusy)) // 驱动中
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 完成
      final session = PtpSession(
          transport: fake, mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.complete);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.mfDrive,
        NikonOperationCode.deviceReady,
        NikonOperationCode.deviceReady,
        NikonOperationCode.deviceReady,
      ], reason: '首探立即,忙两拍后完成');
    });

    test('mfDrive 收尾:就绪探回 0xA00C 尽头 / 0xA00E 过小,按结果归因',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: NikonResponseCode.mfDriveStepEnd))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(
            responseCode: NikonResponseCode.mfDriveStepInsufficiency));
      final session = PtpSession(
          transport: fake, mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.endOfTravel, reason: '就绪探 0xA00C = 行程尽头');
      expect(await session.mfDrive(towardNear: false, pulses: 300),
          MfDriveOutcome.stepTooSmall, reason: '就绪探 0xA00E = 步进过小');
    });

    test('mfDrive 收尾:就绪轮询拍数用尽 → 乐观按已派出(complete)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy))
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(
          transport: fake,
          mfReadyPolls: 2,
          mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.complete,
          reason: '超时不判失败:驱动已接受,端点归因下一拍自愈');
      expect(
          fake.requests
              .where((r) => r.opcode == NikonOperationCode.deviceReady),
          hasLength(2));
    });

    test('录制双 op:0x920A 无参起录 / 0x920B 无参停录', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.startMovieRec();
      await session.endMovieRec();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.startMovieRecInCard,
        NikonOperationCode.endMovieRec,
      ]);
      expect(fake.requests.first.params, isEmpty);
    });

    test('Ex 属性码路由:>0xFFFF 读走 0x943B / 写走 0x943C,标准码不变', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([2]))) // 主体检测读:u8 = 2(人)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final v = await session.getDevicePropValue(0x0001D006);
      expect(v.value, 2);
      expect(
          fake.requests.first.opcode, NikonOperationCode.getDevicePropValueEx);
      expect(fake.requests.first.params, [0x0001D006]);
      await session.setDevicePropValue(PtpDevicePropValue(
          code: 0x0001D006, dataType: PtpDataType.uint8, value: 3));
      expect(
          fake.requests.last.opcode, NikonOperationCode.setDevicePropValueEx);
      // 标准码不受影响
      fake.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 280));
      expect(fake.requests.last.opcode, PtpOperationCode.setDevicePropValue);
    });

    test('相机时钟:读 0x5011(PTP STR);漂移 > 5s 写回,≤ 5s 不写', () async {
      String strOf(DateTime t) {
        String two(int v) => v.toString().padLeft(2, '0');
        return '${t.year}${two(t.month)}${two(t.day)}T'
            '${two(t.hour)}${two(t.minute)}${two(t.second)}';
      }

      final now = DateTime(2026, 10, 6, 12, 0, 0);
      // PTP 字符串数据集:u8 字符数(含结尾 NUL)+ UTF16LE + NUL
      ByteWriter clockBytes(DateTime t) {
        final w = ByteWriter()..u8(16); // 15 字符 + NUL
        for (final c in strOf(t).codeUnits) {
          w.u16(c);
        }
        w.u16(0);
        return w;
      }

      // 相机慢 10 秒:测试自读一次 + sync 内部再读一次 + 写
      final slowBytes =
          clockBytes(now.subtract(const Duration(seconds: 10))).takeBytes();
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: slowBytes))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: slowBytes))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final read = await session.getCameraClock();
      expect(read, DateTime(2026, 10, 6, 11, 59, 50));
      await session.syncCameraClock(now: now);
      expect(fake.requests, hasLength(3), reason: '自读 + sync 读 + 写');
      expect(fake.requests.last.opcode, PtpOperationCode.setDevicePropValue);
      expect(fake.requests.last.params, [PtpDevicePropCode.dateTime]);

      // 相机只慢 2 秒:读后不写
      final fake2 = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: clockBytes(now.subtract(const Duration(seconds: 2)))
                .takeBytes()));
      final session2 = PtpSession(transport: fake2);
      await session2.syncCameraClock(now: now);
      expect(fake2.requests, hasLength(1), reason: '漂移在阈内:只读不写');
    });

    test(
        'changeCameraMode:0x90C2 params=[mode](APP 接管控制);非 OK 抛异常;'
        'remoteModeActive 随成功应答同步、被拒不翻', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.changeCameraMode(1);
      expect(fake.requests.single.opcode, NikonOperationCode.changeCameraMode);
      expect(fake.requests.single.params, [1]);
      expect(session.remoteModeActive, isTrue, reason: '0x90C2(1) 成功即置位');

      fake.reply(
          PtpResult(responseCode: NikonResponseCode.changeCameraModeFailed));
      await expectLater(
          session.changeCameraMode(0), throwsA(isA<PtpResponseException>()));
      expect(fake.requests.last.params, [0]);
      expect(session.remoteModeActive, isTrue, reason: '解除被拒不翻旗(相机侧模式未变)');

      fake.reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeCameraMode(0);
      expect(session.remoteModeActive, isFalse, reason: '解除成功即熄');
    });

    test('getStorageIds:u32 计数 + N 个 u32(双卡槽)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, // 0x00010001
            0x01, 0x00, 0x02, 0x00, // 0x00020001
          ]),
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getStorageIds(), [0x00010001, 0x00020001]);
      expect(fake.requests.single.opcode, PtpOperationCode.getStorageIds);
    });

    test('getStorageInfo:params=[storageId],数据集完整解析', () async {
      final w = ByteWriter()
        ..u16(0x0004) // removableRAM
        ..u16(0x0002)
        ..u16(0x0000)
        ..u64(64000000000)
        ..u64(21000000000)
        ..u32(480)
        ..u8(7)
        ..utf16le('Slot 1')
        ..u16(0)
        ..u8(1)
        ..u16(0); // volumeLabel 空串
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final storage = await session.getStorageInfo(0x00010001);
      expect(fake.requests.single.params, [0x00010001]);
      expect(storage.id, 0x00010001);
      expect(storage.isRemovable, isTrue);
      expect(storage.freeSpaceBytes, 21000000000);
      expect(storage.description, 'Slot 1');
    });

    test('getStorageInfo:相机非 OK(卡槽空)抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009));
      final session = PtpSession(transport: fake);
      await expectLater(session.getStorageInfo(0x00010001),
          throwsA(isA<PtpResponseException>()));
    });
  });

  group('无线配对操作', () {
    test('getPairingCode:u32 计数 + 数字字节拼接成验证码(NiConn 抓包形态)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          // count=4 + 05 00 07 07 → "5077"(Zf STA op 表 0x952B)
          data: Uint8List.fromList([4, 0, 0, 0, 0x05, 0x00, 0x07, 0x07]),
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), '5077');
      expect(
          fake.requests.single.opcode, NikonOperationCode.getPtpIpPairingCode);
      expect(fake.requests.single.params, isEmpty);
    });

    test('getPairingCode:相机非 OK 响应 → null(多数 = 本客户端已配对)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), isNull);
    });

    test('getPairingCode:载荷畸形(计数超长)→ null,不抛', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([9, 0, 0, 0, 1]), // count=9 但只有 1 字节
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), isNull);
    });

    test('completePairing:发 0x935A + param 0x2001,OK 即成', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.completePairing();
      expect(fake.requests.single.opcode, NikonOperationCode.completePairing);
      expect(fake.requests.single.params, [0x2001]);
    });

    test('completePairing:非 OK 抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.completePairing(), throwsA(isA<PtpResponseException>()));
    });
  });

  group('遥控操作', () {
    test('getDevicePropValue:fNumber 按 u16 解码,params=[propCode]', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([18, 0]), // u16 裸值
        ));
      final session = PtpSession(transport: fake);
      final v = await session.getDevicePropValue(PtpDevicePropCode.fNumber);
      expect(v.dataType, PtpDataType.uint16);
      expect(v.value, 18);
      expect(fake.requests.single.opcode, PtpOperationCode.getDevicePropValue);
      expect(fake.requests.single.params, [PtpDevicePropCode.fNumber]);
    });

    test('getDevicePropDesc:数据集字段完整解析', () async {
      final w = ByteWriter()
        ..u16(PtpDevicePropCode.exposureIndex)
        ..u16(PtpDataType.uint16.code)
        ..u8(1)
        ..u16(100) // 出厂默认值(值区第一个,gphoto2 权威顺序)
        ..u16(200) // 当前值(值区第二个)
        ..u8(0x02) // FORM 枚举
        ..u16(2)
        ..u16(100)
        ..u16(6400);
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final d =
          await session.getDevicePropDesc(PtpDevicePropCode.exposureIndex);
      expect(d.currentValue, 200);
      expect(d.factoryValue, 100);
      expect(d.enumValues, [100, 6400]);
      expect(d.getSet, isTrue);
    });

    test('enableAppControl:0x9435 ok → true,单发无属性回退', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.single.opcode,
          NikonOperationCode.changeApplicationMode);
      expect(fake.requests.single.params, [1]);
    });

    test('enableAppControl:0x9435 拒 → 直落 0xD1F0 兜底(不写身份、不重试)', () async {
      // OpenZCine 全程不写 0xD406 身份(写身份会让机身把主机按新身份
      // 归类、停「已连接到计算机」屏),连接链因此没有身份段。
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(fake.requests[1].params, [PtpDevicePropCode.applicationMode]);
      expect(fake.requests[1].dataOut, Uint8List.fromList([1]));
    });

    test(
        'enableAppControl:0x9435 回 0x200F(USB 人设)→ 同样直落 0xD1F0'
        '(拒绝码不分支,非 OK 一律走兜底)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.accessDenied))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(fake.requests[1].params, [PtpDevicePropCode.applicationMode]);
    });

    test('enableAppControl:全拒 → false 不抛;不受拍摄参数总闸约束', () async {
      PtpSession.kSetPropEnabled = false; // 应用模式切换非拍摄参数写
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isFalse);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue, // 0xD1F0 兜底(仍拒)
      ]);
    });

    test('writeInitiatorIdentity:载荷 = PTP 串(u8 字符数 + UTF-16LE 无终止符)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.writeInitiatorIdentity(), isTrue);
      final req = fake.requests.single;
      expect(req.opcode, PtpOperationCode.setDevicePropValue);
      expect(req.params, [PtpDevicePropCode.sessionInitiatorInfo]);
      // 'ZPill' PTP 字符串:u8 计数(字符数,不含 NUL)+ UTF-16LE,
      // 无终止符 —— 与探针 ptp_str 同款(Zf USB 实证载荷,2026-10-07)。
      final expected = <int>['ZPill'.length];
      for (final cu in 'ZPill'.codeUnits) {
        expected.addAll([cu & 0xFF, cu >> 8]);
      }
      expect(req.dataOut, Uint8List.fromList(expected));
    });

    test('writeInitiatorIdentity:被拒/链路异常 → false 不抛', () async {
      final rejected = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported));
      expect(await PtpSession(transport: rejected).writeInitiatorIdentity(),
          isFalse);
      // 脚本耗尽(execute 抛 StateError)也兜住:尽力而为语义。
      final dead = FakePtpTransport();
      expect(
          await PtpSession(transport: dead).writeInitiatorIdentity(), isFalse);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 拒(USB 人设)→ '
        '0x90C2(1)→(0) 开闩括号 → true,remoteModeActive 归 false(2026-10-07 '
        'v8/v9 定案:上传优先门单向闩,开了不因退而关;remote 持有态才是'
        '「已连接到计算机」屏元凶,开闩即还身,机身直回取景屏)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(fake.requests[1].params, [1]);
      expect(fake.requests[2].params, [0], reason: '开闩即还身:1→0 背靠背');
      expect(session.remoteModeActive, isFalse, reason: '括号已退 remote');
    });

    test(
        'enableAppControl(remoteLatch):0x9435 回 OK(IC 假钥匙)→ '
        '仍走 0x90C2(1)→(0) 括号(2026-10-07 归因梯定案:0x9435 接受 ≠ '
        '解锁 0x9201,唯一实证开闩钥匙 = 0x90C2(1)),梯记三步', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(fake.requests[1].params, [1]);
      expect(fake.requests[2].params, [0]);
      expect(session.remoteModeActive, isFalse);
      expect(session.connectLadder, ['9435:OK', '90C2:OK', '90C2退:OK']);
    });

    test(
        'enableAppControl(remoteLatch):0x90C2(0) 退步被拒 → 仍 true '
        '(闩已开,流不受影响),remoteModeActive 保持 true(接管侧如实对齐,'
        '退由 teardown 兜底)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)); // 0x90C2(0) 拒
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(session.remoteModeActive, isTrue, reason: '退被拒 = remote 仍持有');
      expect(session.connectLadder, ['9435:OK', '90C2:OK', '90C2退:拒']);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 OK + 0x90C2 拒 → '
        '仍 true(应用模式已接受,不发 0xD1F0),梯记拒码;open() 清梯', () async {
      final fake = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)) // OpenSession
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)); // 0x90C2(1) 拒
      final session = PtpSession(transport: fake);
      session.noteLadder('旧账');
      await session.open();
      expect(session.connectLadder, isEmpty, reason: 'open() 一连接一账');
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        PtpOperationCode.openSession,
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(session.remoteModeActive, isFalse, reason: '0x90C2 被拒不置位');
      expect(session.connectLadder, ['9435:OK', '90C2:0x2005']);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 链路异常 → '
        '0x90C2 兜底照走(尽力而为,异常不得拦连接主流程)', () async {
      // 首发传输层异常(execute 抛)也落兜底:on Object 兜底语义。
      final fake = FakePtpTransport()
        ..fail(Exception('链路异常')) // 0x9435 抛
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
    });

    test(
        'enableAppControl(remoteLatch):0x90C2 也拒 → 0xD1F0 兜底 → '
        'true,remoteModeActive 不置位', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)) // 0x90C2 op 缺席
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0xD1F0
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(fake.requests[2].params, [PtpDevicePropCode.applicationMode]);
      expect(fake.requests[2].dataOut, Uint8List.fromList([1]));
      expect(session.remoteModeActive, isFalse, reason: '0x90C2 被拒不置位');
    });

    test('enableAppControl(remoteLatch):三段全拒 → false 不抛', () async {
      final allRejected = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x90C2 拒
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.generalError)); // 0xD1F0 拒
      final session2 = PtpSession(transport: allRejected);
      expect(await session2.enableAppControl(remoteLatch: true), isFalse);
      expect(allRejected.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        PtpOperationCode.setDevicePropValue,
      ]);
    });

    test(
        'enableAppControl:不带 usbRemoteFallback(无线调用形态)→ '
        '0x90C2 不发,链与旧版一致', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0xD1F0
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(
          fake.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode),
          isEmpty,
          reason: 'latch 不开就不发 0x90C2(接口默认语义;连接流两路现在都开)');
    });

    test('remoteModeActive 生命周期:close()/open() 复位(旧链持有态不带到新链)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)); // openSession
      final session = PtpSession(transport: fake);
      await session.changeCameraMode(1);
      expect(session.remoteModeActive, isTrue);
      await session.close();
      expect(session.remoteModeActive, isFalse, reason: 'close 即复位');
      await session.open();
      expect(session.remoteModeActive, isFalse, reason: 'open 新链仍为空');
    });

    test('setDevicePropValue:总闸紧急关断抛 UnsupportedError 且不发请求', () async {
      PtpSession.kSetPropEnabled = false; // 生产已开,这里显式关断走分支
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final v = PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 18);
      await expectLater(
          session.setDevicePropValue(v), throwsA(isA<UnsupportedError>()));
      expect(fake.requests, isEmpty);
    });

    test('setDevicePropValue:总闸开(生产默认)→ 0x1016 带码参数与裸值数据', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final v = PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 320);
      await session.setDevicePropValue(v);
      expect(fake.requests, hasLength(1));
      expect(fake.requests.single.opcode, PtpOperationCode.setDevicePropValue);
      expect(fake.requests.single.params, [PtpDevicePropCode.fNumber]);
      expect(fake.requests.single.dataOut, Uint8List.fromList([0x40, 0x01]));
    });

    test('startLiveView/endLiveView:候选码直发,无参数', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.startLiveView();
      await session.endLiveView();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.startLiveView,
        NikonOperationCode.endLiveView,
      ]);
      expect(fake.requests.every((r) => r.params.isEmpty), isTrue);
    });

    test('getLiveViewImage:前置杂字节剥到 SOI(防御「头+JPEG」形态)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList(
              [0x01, 0x02, 0x03, 0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
        ));
      final session = PtpSession(transport: fake);
      final frame = await session.getLiveViewImage();
      expect(frame, [0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      expect(fake.requests.single.opcode, NikonOperationCode.getLiveViewImage);
    });

    test('getLiveViewObject:默认 0x9428 取帧,原样返回(帧头解析留给上层)', () async {
      final raw = Uint8List.fromList(
          [0x00, 0x64, 0x00, 0x00, 0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      final object = await session.getLiveViewObject();
      expect(object, same(raw));
      expect(
          fake.requests.single.opcode, NikonOperationCode.getLiveViewImageEx);
    });

    test('getLiveViewObject:0x9428 被拒 → 本拍抛错,下一拍起走 0x9203', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.getLiveViewImageEx,
            responseCode: 0x2005)) // OperationNotSupported
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      final object = await session.getLiveViewObject();
      expect(object, same(raw));
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImage,
      ]);
    });

    test('getLiveViewObject:0x2019 忙不置回退旗标(继续 0x9428 重试)', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      await session.getLiveViewObject();
      // 忙是瞬时态,两次都必须是 Ex 码(忙即降级会永久锁死旧码)
      expect(
          fake.requests
              .every((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
          isTrue);
    });

    test('getLiveViewObject:startLiveView 重置回退旗标(换机自愈)', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.getLiveViewImageEx,
            responseCode: 0x2005))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: raw)) // 0x9203
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // start
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw)); // Ex
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      await session.getLiveViewObject(); // 走 0x9203
      await session.startLiveView(); // 重置旗标
      await session.getLiveViewObject(); // 回到 0x9428
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImage,
        NikonOperationCode.startLiveView,
        NikonOperationCode.getLiveViewImageEx,
      ]);
    });

    test('initiateCapture:params 恒 [0, 0];0x2019 忙按异常上抛', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.initiateCapture(), throwsA(isA<PtpResponseException>()));
      expect(fake.requests.single.opcode, PtpOperationCode.initiateCapture);
      expect(fake.requests.single.params, [0, 0]);
    });

    test('无卡拍/落卡拍候选码直发;CaptureSort 首参(OpenZCine 形态)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.initiateCaptureRecInSdram();
      await session.initiateCaptureRecInMedia();
      await session.initiateCaptureRecInMedia(captureSort: 0xFFFFFFFE);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.initiateCaptureRecInSdram,
        NikonOperationCode.initiateCaptureRecInMedia,
        NikonOperationCode.initiateCaptureRecInMedia,
      ]);
      // 默认 0xFFFFFFFF 直接释放(preserveFocus 形态);显式 0xFFFFFFFE 先 AF
      expect(fake.requests[1].params, [0xFFFFFFFF, 0]);
      expect(fake.requests[2].params, [0xFFFFFFFE, 0]);
    });

    test('对焦三 op:0x9205 双参直发 / 0x90C1、0x9206 无参(候选码)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.changeAfArea(320, 240);
      await session.afDrive();
      await session.afDriveCancel();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeAfArea,
        NikonOperationCode.afDrive,
        NikonOperationCode.afDriveCancel,
      ]);
      expect(fake.requests[0].params, [320, 240]);
      expect(fake.requests[1].params, isEmpty);
      expect(fake.requests[2].params, isEmpty);
    });

    test('deviceReady:0x2019 忙 → false(语义不是错误)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(transport: fake);
      expect(await session.deviceReady(), isFalse);
    });

    test(
        'deviceReady:0xA200/0xA201(Bulb/Silent_Release_Busy,官方'
        ' §2.8.4 步 5 / §6.3.2.15-16)→ false 继续等,不抛', () async {
      // B 门曝光进行中 DeviceReady 即回 0xA200(官方 B 门序列步 5);
      // 0xA201 静音快门同族 —— 收门/落定等待据此继续等。
      final bulb = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: NikonResponseCode.bulbReleaseBusy));
      expect(await PtpSession(transport: bulb).deviceReady(), isFalse);
      final silent = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: NikonResponseCode.silentReleaseBusy));
      expect(await PtpSession(transport: silent).deviceReady(), isFalse);
    });

    test(
        'getPictureControlName:0x90CC params=[槽位,0],name=数据[3..23) NUL 截断'
        '(digiCamControl 布局)', () async {
      final data = Uint8List(40); // [3..23) 名区,余 NUL 填充
      data[1] = 1; // 单色标志
      data[2] = 1; // 自定义标志
      const name = 'My Landscape';
      for (var i = 0; i < name.length; i++) {
        data[3 + i] = name.codeUnitAt(i);
      }
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: data));
      final session = PtpSession(transport: fake);
      expect(await session.getPictureControlName(201), 'My Landscape');
      final req = fake.requests.single;
      expect(req.opcode, NikonOperationCode.getPictCtrlData);
      expect(req.params, [201, 0]);
    });

    test('getPictureControlName:短数据(<23B)/ 空名 / 纯空白 → null 不抛', () async {
      final blanks = Uint8List(32);
      for (var i = 3; i < 8; i++) {
        blanks[i] = 0x20; // 空格,trim 后为空
      }
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(10)))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(32)))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: blanks));
      final session = PtpSession(transport: fake);
      expect(await session.getPictureControlName(201), isNull, reason: '短数据');
      expect(await session.getPictureControlName(202), isNull,
          reason: '名区全 NUL');
      expect(await session.getPictureControlName(203), isNull,
          reason: '纯空白 trim 后为空');
    });

    test('getPictureControlName:非 OK 抛 PtpResponseException(控制器首异常即停)',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported));
      final session = PtpSession(transport: fake);
      await expectLater(session.getPictureControlName(301),
          throwsA(isA<PtpResponseException>()));
    });

    test('deviceReady:OK → true;其余响应码照常抛', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.deviceReady(), isTrue);
      await expectLater(
          session.deviceReady(), throwsA(isA<PtpResponseException>()));
    });
  });

  group('全局串行锁', () {
    test('并发操作排队:第二个不进传输层直到第一个完成', () async {
      final gate = Completer<void>();
      final fake = LockProbeTransport(gate);
      final session = PtpSession(transport: fake);

      final first = session.getThumb(1);
      final second = session.getThumb(2);
      await pumpEventQueue();
      expect(fake.startedHandles, [1]); // 第二个仍被锁挡在门外

      gate.complete();
      await Future.wait([first, second]);
      expect(fake.startedHandles, [1, 2]);
    });

    test('前一个失败不断链:后续操作照常执行', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)) // 第一次失败
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0xFF, 0xD8])));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getThumb(1), throwsA(isA<PtpResponseException>()));
      final data = await session.getThumb(2);
      expect(data, [0xFF, 0xD8]);
    });
  });

  group('取消-排水透传(cancelInFlight)', () {
    test('在途事务持锁时绕过串行锁立即返回(不排队死等)', () async {
      final gate = Completer<void>();
      final fake = FakePtpTransport()
        ..replyAfter(
            gate.future,
            PtpResult(
                responseCode: PtpResponseCode.ok,
                data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      final exec = session.getDeviceInfo(); // 持锁挂在相机闸上
      await pumpEventQueue();

      // 若 cancelInFlight 排队等锁,timeout 先到 → 失败可见
      final cancelled = await session
          .cancelInFlight()
          .timeout(const Duration(milliseconds: 200));
      expect(cancelled, isTrue);
      expect(fake.cancelInFlightCalls, 1);

      gate.complete();
      await exec; // 原事务不受牵连,照常完成(假件不真取消)
    });

    test('链路不支持(USB / 未实现能力)→ false no-op', () async {
      final session = PtpSession(transport: LockProbeTransport(Completer<void>()));
      expect(await session.cancelInFlight(), isFalse);
    });

    test('取消通道异常 → false 落回旧路径(取消不当失败放大)', () async {
      final session = PtpSession(transport: _CancelFailingTransport());
      expect(await session.cancelInFlight(), isFalse);
    });
  });

  group('字节级端到端:PtpSession over UsbPtpTransport over FakeUsbBytePipe', () {
    test('open → getObjectHandles 全链容器字节', () async {
      final pipe = FakeUsbBytePipe();
      final session = PtpSession(transport: UsbPtpTransport(pipe: pipe));

      // 相机脚本:OpenSession 响应 OK
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      await session.open();

      // GetObjectHandles:DATA(count=2) + RESPONSE OK
      pipe.enqueue(encodeUsbData(
        opcode: PtpOperationCode.getObjectHandles,
        transactionId: 1,
        payload: Uint8List.fromList([
          0x02, 0x00, 0x00, 0x00, //
          0x11, 0x00, 0x00, 0x00, //
          0x22, 0x00, 0x00, 0x00, //
        ]),
      ));
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 1));
      final handles = await session.getObjectHandles();
      expect(handles, [0x11, 0x22]);

      // 发出的两个命令容器:opcode 与 txid 递增
      expect(pipe.outWrites.length, 2);
      expect(pipe.outWrites[0][6], 0x02); // OpenSession 低字节
      expect(pipe.outWrites[0][8], 0); // txid=0
      expect(pipe.outWrites[1][6], 0x07); // GetObjectHandles 低字节
      expect(pipe.outWrites[1][8], 1); // txid=1
    });
  });

  group('官方指令书扩展通道(2026-10-12):保护标记 / 厂商码表 / 4 字节包装 op', () {
    late FakePtpTransport t;
    late PtpSession session;
    setUp(() {
      t = FakePtpTransport();
      session = PtpSession(transport: t);
    });

    test('setObjectProtection:params=[句柄, 0x0000/0x0001](§6.2.1.14)', () async {
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.setObjectProtection(0x1234, protect: true);
      await session.setObjectProtection(0x1234, protect: false);
      expect(t.requests.map((r) => r.opcode), [
        PtpOperationCode.setObjectProtection,
        PtpOperationCode.setObjectProtection
      ]);
      expect(t.requests.first.params, [0x1234, 0x0001]);
      expect(t.requests.last.params, [0x1234, 0x0000]);
    });

    test('getVendorCodes:u32 计数 + N×u32 码;0x09=操作码表 / 0x0D=属性码表', () async {
      final table = Uint8List.fromList([
        0x03, 0x00, 0x00, 0x00, //
        0x39, 0x94, 0x00, 0x00, //
        0x01, 0xD0, 0x01, 0x00, // 0x0001D001(4 字节扩展形态)
        0x28, 0x94, 0x00, 0x00,
      ]);
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: table))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: table));
      final ops = await session.getVendorCodes(deviceProps: false);
      final props = await session.getVendorCodes(deviceProps: true);
      expect(t.requests.first.params, [0x09]);
      expect(t.requests.last.params, [0x0D]);
      expect(ops, [0x9439, 0x0001D001, 0x9428]);
      expect(props, ops);
    });

    test('getVendorCodes:空表 / 数据不足 4B → 空列表不炸', () async {
      t
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0, 0, 0, 0])))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(2)));
      expect(await session.getVendorCodes(deviceProps: false), isEmpty);
      expect(await session.getVendorCodes(deviceProps: true), isEmpty);
    });

    test('extendedOperationNone/Receive/Send:P1=扩展码,参数透传', () async {
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: Uint8List.fromList([7])))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.extendedOperationNone(0x0001D006, params: [1, 2]);
      final got = await session.extendedOperationReceive(0x0001D001);
      await session.extendedOperationSend(0x0001D048,
          params: [3], data: Uint8List.fromList([9]));
      expect(t.requests.map((r) => r.opcode).toList(), [
        NikonOperationCode.operationDataNone,
        NikonOperationCode.operationReceiveData,
        NikonOperationCode.operationSendData,
      ]);
      expect(t.requests[0].params, [0x0001D006, 1, 2]);
      expect(t.requests[1].params, [0x0001D001]);
      expect(t.requests[2].params, [0x0001D048, 3]);
      expect(t.requests[2].dataOut, [9]);
      expect(got.data, [7]);
    });

    test(
        'getDevicePropDesc:Ex 码(>0xFFFF)路由 0x943A,u32 码定宽解析'
        '(2026-10-13 USB 探针实证 0x0001D001 色调)', () async {
      // 探针实录数据集:code u32 + u8 型 + getSet + 出厂 + 当前 + 枚举{0,1,2}
      final exDesc = Uint8List.fromList([
        0x01, 0xD0, 0x01, 0x00, // 0x0001D001(u32 LE)
        0x02, 0x00, // UINT8
        0x01, // getSet = 可写
        0x00, // 出厂 = 0(SDR,官方默认)
        0x02, // 当前 = 2(HLG,相机实际值)
        0x02, 0x03, 0x00, 0x00, 0x01, 0x02, // 枚举 3 值 {0,1,2}
      ]);
      t.reply(PtpResult(responseCode: PtpResponseCode.ok, data: exDesc));
      final d = await session.getDevicePropDesc(0x0001D001);
      expect(t.requests.single.opcode, NikonOperationCode.getDevicePropDescEx);
      expect(t.requests.single.params, [0x0001D001]);
      expect(d.dataType, PtpDataType.uint8);
      expect(d.getSet, isTrue);
      expect(d.factoryValue, 0);
      expect(d.currentValue, 2);
      expect(d.enumValues, [0, 1, 2]);
    });
  });

  group('官方指令书候选区接线(2026-10-13 探针批 + §6.2 规格比对)', () {
    late FakePtpTransport t;
    late PtpSession session;
    setUp(() {
      t = FakePtpTransport();
      session = PtpSession(transport: t);
    });

    test(
        'getFhdPicture:params=[句柄],JPEG SOI 嗅探;0xA00F 无 FHD 抛'
        'PtpResponseException', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xFF, 0xD8, 1, 2, 3])));
      final jpeg = await session.getFhdPicture(0x1234);
      final req = t.requests.single;
      expect(req.opcode, NikonOperationCode.getFhdPicture);
      expect(req.params, [0x1234]);
      expect(jpeg, [0xFF, 0xD8, 1, 2, 3]);

      // 「头 + JPEG」形态:SOI 嗅探剥头
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([3, 0, 0, 0, 0xFF, 0xD8, 9])));
      expect(await session.getFhdPicture(1), [0xFF, 0xD8, 9]);

      t.reply(const PtpResult(responseCode: NikonResponseCode.noFullHdPresent));
      await expectLater(
          session.getFhdPicture(1), throwsA(isA<PtpResponseException>()));
    });

    test(
        'changeAELock:params=[1,2] 锁 / [0,2] 解锁(探针双 OK 形),'
        'type 可指定', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: true);
      expect(t.requests.single.opcode, NikonOperationCode.changeAELock);
      expect(t.requests.single.params, [1, 2]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: false);
      expect(t.requests.last.params, [0, 2]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: true, type: 0);
      expect(t.requests.last.params, [1, 0]);
    });

    test('startTracking/endTracking:参数同 0x9205 两参 / 无参', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.startTracking(3024, 2016);
      expect(t.requests.single.opcode, NikonOperationCode.startTracking);
      expect(t.requests.single.params, [3024, 2016]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.endTracking();
      expect(t.requests.last.opcode, NikonOperationCode.endTracking);
      expect(t.requests.last.params, isEmpty);
    });

    test('clearEvent/afAndCaptureRecInSdram/saveCameraSetting:无参直发', () async {
      for (final _ in [
        NikonOperationCode.clearEvent,
        NikonOperationCode.afAndCaptureRecInSdram,
        NikonOperationCode.saveCameraSetting,
      ]) {
        t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      }
      await session.clearEvent();
      await session.afAndCaptureRecInSdram();
      await session.saveCameraSetting();
      expect(t.requests.map((r) => r.opcode).toList(), [
        NikonOperationCode.clearEvent,
        NikonOperationCode.afAndCaptureRecInSdram,
        NikonOperationCode.saveCameraSetting,
      ]);
      expect(t.requests.every((r) => r.params.isEmpty), isTrue);
    });

    test('changeMonitorOff:params=[1] 强制关 / [0] 取消(§6.2.2.17)', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeMonitorOff(off: true);
      expect(t.requests.single.opcode, NikonOperationCode.changeMonitorOff);
      expect(t.requests.single.params, [1]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeMonitorOff(off: false);
      expect(t.requests.last.params, [0]);
    });

    test('getCameraSettingData:64B 文件名(63+NUL)+ 文件体拆分', () async {
      final name = 'Z7_2_01012026.NCSETUTF8'.codeUnits;
      final dataset = <int>[
        ...name,
        ...List.filled(64 - name.length, 0), // NUL 填充到 64B
        0xDE, 0xAD, 0xBE, 0xEF, // 文件体
      ];
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok, data: Uint8List.fromList(dataset)));
      final setting = await session.getCameraSettingData();
      expect(t.requests.single.opcode, NikonOperationCode.getCameraSettingData);
      expect(setting.name, 'Z7_2_01012026.NCSETUTF8');
      expect(setting.data, [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('sendCameraSettingData:dataOut = 64B 文件名 + 文件体', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.sendCameraSettingData('AB', Uint8List.fromList([1, 2, 3]));
      final out = t.requests.single.dataOut!;
      expect(out.length, 67);
      expect(out.sublist(0, 2), 'AB'.codeUnits);
      expect(out.sublist(2, 64), List.filled(62, 0));
      expect(out.sublist(64), [1, 2, 3]);
    });

    test('getObjectPropsSupported:u32 计数 + N×u16 解析', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count = 2
            0x04, 0x00, // 0x0004 ProtectionStatus
            0x08, 0x00, // 0x0008 ObjectSize
          ])));
      final props = await session.getObjectPropsSupported();
      expect(
          t.requests.single.opcode, NikonOperationCode.getObjectPropsSupported);
      expect(props, [0x0004, 0x0008]);
    });

    test(
        'getObjectPropDesc:参数 [句柄, 属性码],数据集裸透传(无消费方,'
        '定宽解留接线时)', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x06, 0x00, 0x00, 0x00])));
      final desc = await session.getObjectPropDesc(0x1234, 0x0004);
      expect(t.requests.single.opcode, NikonOperationCode.getObjectPropDesc);
      expect(t.requests.single.params, [0x1234, 0x0004]);
      expect(desc, [0x06, 0x00, 0x00, 0x00]);
    });

    test(
        'getObjectPropValue/setObjectPropValue:参数 [句柄, 属性码],'
        '裸值透传', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x01, 0x00])));
      final value = await session.getObjectPropValue(0x1234, 0x0004);
      expect(t.requests.single.params, [0x1234, 0x0004]);
      expect(value, [0x01, 0x00]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.setObjectPropValue(
          0x1234, 0x0004, Uint8List.fromList([0x00, 0x00]));
      expect(t.requests.last.opcode, NikonOperationCode.setObjectPropValue);
      expect(t.requests.last.params, [0x1234, 0x0004]);
      expect(t.requests.last.dataOut, [0x00, 0x00]);
    });

    test('getObjectPropList:u32 计数 + N×(句柄+码+类型+DTS 值)解析', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count = 2
            0x34, 0x12, 0x00, 0x00, // 句柄 0x1234
            0x04, 0x00, // 属性 0x0004 ProtectionStatus
            0x06, 0x00, // UINT32
            0x01, 0x00, 0x00, 0x00, // 值 1(只读)
            0x35, 0x12, 0x00, 0x00, // 句柄 0x1235
            0x08, 0x00, // 属性 0x0008 ObjectSize
            0x04, 0x00, // UINT16
            0xF4, 0x01, // 值 500
          ])));
      final props =
          await session.getObjectPropList(0x1234, propCode: 0xFFFFFFFF);
      expect(t.requests.single.params, [0x1234, 0x00000000, 0xFFFFFFFF]);
      expect(props, hasLength(2));
      expect(props[0].handle, 0x1234);
      expect(props[0].code, 0x0004);
      expect(props[0].dataType, PtpDataType.uint32.code);
      expect(props[0].value, 1);
      expect(props[1].handle, 0x1235);
      expect(props[1].code, 0x0008);
      expect(props[1].value, 500);
    });

    test('getObjectPropList:depth 省略时 3 参;给了 P5 组码补位 P4', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10, propCode: 0x0004);
      expect(t.requests.single.params, [0x10, 0, 0x0004]);

      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10,
          propCode: 0x0004, depth: 0xFFFFFFFF);
      // P4/P5 按位序不可跳:给了 depth 而未给组码,P4 补 0x00000000。
      expect(
          t.requests.last.params, [0x10, 0, 0x0004, 0x00000000, 0xFFFFFFFF]);

      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10,
          propCode: 0x00000000, groupCode: 0x00000001);
      // P3=0 按 P4 组码取(官方 §6.2.11.5:Zf §6.6 信息组 = 0x00000001)。
      expect(t.requests.last.params, [0x10, 0, 0x00000000, 0x00000001]);
    });

    test(
        'getObjectPropList 批量解析:多对象多属性(含变长串),'
        '首屏五参全量形 = n-link 生产同款', () async {
      final ds = PropListDataset()
        ..u16(0x13, PtpObjectPropCode.objectFormat, 0x3801)
        ..str(0x13, PtpObjectPropCode.objectFilename, 'DSC_0002.JPG')
        ..u64(0x13, PtpObjectPropCode.objectSize, 8400000)
        ..u32(0x13, PtpObjectPropCode.parentObject, 0x11)
        ..str(0x13, PtpObjectPropCode.dateCreated, '20260926T090000')
        ..u16(0x10, PtpObjectPropCode.objectFormat, 0x3001)
        ..str(0x10, PtpObjectPropCode.objectFilename, 'DCIM');
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props = await session.getObjectPropList(0xFFFFFFFF,
          formatCode: 0x00000000, propCode: 0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(t.requests.single.opcode, NikonOperationCode.getObjectPropList);
      expect(t.requests.single.params,
          [0xFFFFFFFF, 0x00000000, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]);
      expect(props, hasLength(7));
      Object? val(int h, int c) =>
          props.firstWhere((p) => p.handle == h && p.code == c).value;
      expect(val(0x13, PtpObjectPropCode.objectFilename), 'DSC_0002.JPG');
      expect(val(0x13, PtpObjectPropCode.objectSize), 8400000);
      expect(val(0x13, PtpObjectPropCode.parentObject), 0x11);
      expect(val(0x13, PtpObjectPropCode.dateCreated), '20260926T090000');
      expect(val(0x10, PtpObjectPropCode.objectFormat), 0x3001);
      expect(session.objectPropListDegraded, isFalse);
    });

    test(
        'getObjectPropList:未知 DataType 整体弃(FormatException)'
        '+ 本会话降级秒拒不再发', () async {
      final ds = PropListDataset()
        ..u16(0x13, PtpObjectPropCode.objectFormat, 0x3801) // 首条正常
        ..raw(0x13, 0xDC41, 0x5555, [1, 2, 3, 4]); // 表外类型 → 整体弃
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(session.objectPropListDegraded, isTrue);
      // 秒拒:本会话后续调用直接 UnsupportedError,不再消耗往返。
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<UnsupportedError>()));
      expect(t.requests, hasLength(1));
    });

    test(
        'getObjectPropList:相机拒(错误应答)→ 降级 → 秒拒 → '
        '回退 GetObjectInfo 仍可用', () async {
      t.reply(
          const PtpResult(responseCode: PtpResponseCode.operationNotSupported));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<PtpResponseException>()));
      expect(session.objectPropListDegraded, isTrue);
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<UnsupportedError>()));
      expect(t.requests, hasLength(1)); // 拒答只发生一次

      // 降级不连坐:逐对象 GetObjectInfo 路径照常(仓库回退的根基)。
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: minimalObjectInfoDataset('DSC_0002.JPG')));
      final info = await session.getObjectInfo(0x13);
      expect(info.filename, 'DSC_0002.JPG');
    });

    test('getObjectPropList:open() 复位降级旗标,新会话重新探测', () async {
      t.reply(
          const PtpResult(responseCode: PtpResponseCode.operationNotSupported));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<PtpResponseException>()));
      expect(session.objectPropListDegraded, isTrue);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok)); // OpenSession
      await session.open();
      expect(session.objectPropListDegraded, isFalse);

      final ds = PropListDataset()
        ..str(0x13, PtpObjectPropCode.objectFilename, 'DSC_0002.JPG');
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props =
          await session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(props.single.value, 'DSC_0002.JPG');
    });

    test(
        'getObjectPropList:INT128/数组型按已知宽跳过不弃解析'
        '(Zf §6.6 实型:PersistentUID / RepresentativeSampleData)', () async {
      final ds = PropListDataset()
        ..raw(0x12, 0xDC41, 0x000A, List.filled(16, 0xAB)) // UINT128
        ..raw(0x12, 0xDC86, 0x4002, [3, 0, 0, 0, 9, 9, 9]) // AUINT8×3
        ..u64(0x12, PtpObjectPropCode.objectSize, 26843545);
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props =
          await session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(props, hasLength(3));
      // 128 位/数组:值不解(null),rawValue 按实宽留档;后续条目不错位。
      expect(props[0].value, isNull);
      expect(props[0].rawValue, hasLength(16));
      expect(props[1].value, isNull);
      expect(props[1].rawValue, hasLength(7)); // u32 元素数 + 3 字节
      expect(props[2].value, 26843545);
      expect(session.objectPropListDegraded, isFalse);
    });

    test('getObjectPropList:计数与字节流不符(尾巴/提前耗尽)判不可信降级',
        () async {
      // 尾巴:count=1 但流内还有第二条的字节。
      final w = ByteWriter()
        ..u32(1)
        ..u32(0x13)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3801)
        ..u32(0x10)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3001);
      t.reply(PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(session.objectPropListDegraded, isTrue);

      // 提前耗尽:count=2 只有一条(另起会话验证)。
      final t2 = FakePtpTransport();
      final s2 = PtpSession(transport: t2);
      final w2 = ByteWriter()
        ..u32(2)
        ..u32(0x13)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3801);
      t2.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: w2.takeBytes()));
      await expectLater(
          s2.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(s2.objectPropListDegraded, isTrue);
    });

    test('非 OK 响应统一抛 PtpResponseException(clearEvent 例)', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      await expectLater(
          session.clearEvent(), throwsA(isA<PtpResponseException>()));
    });
  });
}

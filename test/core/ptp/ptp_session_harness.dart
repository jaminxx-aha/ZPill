import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

/// PtpSession 三份测试(core / browse / remote)共用的桩传输与数据集
/// 工厂;原 ptp_session_test.dart 单文件同缝拆出,原私有类转公开。

/// 门控应答:先等 [gate] 完成再回放(测「枚举途中」时序用)。
final class GatedReply {
  const GatedReply(this.gate, this.result);
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
      script.add(GatedReply(gate, result));

  /// 预置一个延迟失败:execute 在 [gate] 完成前挂起,然后抛 [e]。
  void failAfter(Future<void> gate, Exception e) =>
      script.add(GatedReply(gate, e));

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
    if (next is GatedReply) {
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
final class CancelFailingTransport implements PtpTransport, PtpCancelCapable {
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


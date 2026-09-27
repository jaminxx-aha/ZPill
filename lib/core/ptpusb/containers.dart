/// PTP/USB 容器编解码(USB Still Image 设备类 / ISO 15740 附录 D)。
///
/// 与 PTP-IP(TCP 封装)平行:命令/数据/响应容器走 bulk 端点,
/// 事件容器走 interrupt IN 端点。全字段小端(TODO.md 实现注意事项 1)。
///
/// 布局(bulk 容器,共 12 字节头):
/// ```
/// dwLength      u32   容器总长(含自身 4 字节)
/// usType        u16   1=命令 / 2=数据 / 3=响应
/// usCode        u16   命令:操作码 / 数据:所属操作码 / 响应:响应码
/// dwTransactionID u32
/// 后续          命令/响应: 0..5 个 u32 参数;数据: payload
/// ```
///
/// 事件容器(interrupt IN,头 12 字节,与 bulk 容器同构 —— **长度字段是 u32**;
/// 依据 USB STI 规范与 libgphoto2 PTPUSBEventContainer,2026-09-27 订正):
/// ```
/// dwLength        u32   容器总长(含自身 4 字节)
/// usType          u16   4=事件
/// usEventCode     u16
/// dwTransactionID u32
/// 后续            0..3 个 u32 参数
/// ```
///
/// 传输层契约:本文件只接受"单个完整容器"的字节;跨 USB 传输包的
/// 重组(先读头、按长度字段补齐)在 core/ptpusb/usb_transport.dart,
/// native 侧只做字节管道(单次读、短读合法),见 UsbBytePipe 契约。
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';

/// 容器 type 字段取值。
abstract final class UsbContainerType {
  static const int command = 1;
  static const int data = 2;
  static const int response = 3;

  /// 仅 interrupt IN 端点,须用 [decodeUsbEvent] 解析。
  static const int event = 4;
}

/// bulk 容器头长度:dwLength(u32) + usType(u16) + usCode(u16) + dwTransactionID(u32)。
const int kUsbContainerHeaderLength = 12;

/// 事件容器头长度:dwLength(u32) + usType(u16) + usEventCode(u16) + dwTransactionID(u32),
/// 与 bulk 容器头同构。
const int kUsbEventHeaderLength = 12;

/// PTP/USB 容器(密封基类;[decodeUsbContainer]/[decodeUsbEvent] 的产物)。
sealed class UsbPtpContainer {
  const UsbPtpContainer({required this.transactionId});

  final int transactionId;
}

/// 命令容器(bulk OUT)。
final class UsbCommandContainer extends UsbPtpContainer {
  const UsbCommandContainer({
    required this.opcode,
    required super.transactionId,
    this.params = const [],
  });

  /// 操作码,见 core/ptp/operation_codes.dart 的 PtpOperationCode。
  final int opcode;

  /// ≤5 个 u32。
  final List<int> params;
}

/// 数据容器(bulk OUT 或 bulk IN)。
final class UsbDataContainer extends UsbPtpContainer {
  const UsbDataContainer({
    required this.opcode,
    required super.transactionId,
    required this.payload,
  });

  /// 所属操作的 opcode(容器 usCode 字段)。
  final int opcode;

  final Uint8List payload;
}

/// 响应容器(bulk IN)。
final class UsbResponseContainer extends UsbPtpContainer {
  const UsbResponseContainer({
    required this.responseCode,
    required super.transactionId,
    this.params = const [],
  });

  /// 响应码,见 core/ptp/operation_codes.dart 的 PtpResponseCode。
  final int responseCode;

  final List<int> params;
}

/// 事件容器(interrupt IN)。
final class UsbEventContainer extends UsbPtpContainer {
  const UsbEventContainer({
    required this.eventCode,
    required super.transactionId,
    this.params = const [],
  });

  /// 事件码,见 core/ptp/operation_codes.dart 的 PtpEventCode。
  final int eventCode;

  final List<int> params;
}

// ── 编码 ─────────────────────────────────────────────────────────────

/// 编码命令容器(bulk OUT)。
Uint8List encodeUsbCommand({
  required int opcode,
  required int transactionId,
  List<int> params = const [],
}) {
  if (params.length > 5) {
    throw ArgumentError('PTP 命令最多 5 个参数,收到 ${params.length} 个');
  }
  final w = ByteWriter()
    ..u32(kUsbContainerHeaderLength + 4 * params.length)
    ..u16(UsbContainerType.command)
    ..u16(opcode)
    ..u32(transactionId);
  for (final p in params) {
    w.u32(p);
  }
  return w.takeBytes();
}

/// 编码数据容器(数据出相位)。
Uint8List encodeUsbData({
  required int opcode,
  required int transactionId,
  required Uint8List payload,
}) {
  return (ByteWriter()
        ..u32(kUsbContainerHeaderLength + payload.length)
        ..u16(UsbContainerType.data)
        ..u16(opcode)
        ..u32(transactionId)
        ..raw(payload))
      .takeBytes();
}

/// 编码响应容器(测试/回环用;真实链路上响应方是相机)。
Uint8List encodeUsbResponse({
  required int responseCode,
  required int transactionId,
  List<int> params = const [],
}) {
  final w = ByteWriter()
    ..u32(kUsbContainerHeaderLength + 4 * params.length)
    ..u16(UsbContainerType.response)
    ..u16(responseCode)
    ..u32(transactionId);
  for (final p in params) {
    w.u32(p);
  }
  return w.takeBytes();
}

/// 编码事件容器(测试/回环用;真实链路上事件由相机 interrupt IN 上报)。
Uint8List encodeUsbEvent({
  required int eventCode,
  required int transactionId,
  List<int> params = const [],
}) {
  final w = ByteWriter()
    ..u32(kUsbEventHeaderLength + 4 * params.length)
    ..u16(UsbContainerType.event)
    ..u16(eventCode)
    ..u32(transactionId);
  for (final p in params) {
    w.u32(p);
  }
  return w.takeBytes();
}

// ── 解码 ─────────────────────────────────────────────────────────────

/// 解析 bulk 端点上的一个完整容器(命令 / 数据 / 响应)。
///
/// [bytes] 必须恰为一个容器(长度字段与字节数一致),跨包重组由传输层负责。
UsbPtpContainer decodeUsbContainer(Uint8List bytes) {
  if (bytes.length < kUsbContainerHeaderLength) {
    throw FormatException('bulk 容器不足头部长度:仅 ${bytes.length} 字节');
  }
  final r = ByteReader(bytes);
  final length = r.u32();
  if (length != bytes.length) {
    throw FormatException('容器长度字段 $length ≠ 实际字节 ${bytes.length}');
  }
  final type = r.u16();
  final code = r.u16();
  final txid = r.u32();
  switch (type) {
    case UsbContainerType.command:
      return UsbCommandContainer(
        opcode: code,
        transactionId: txid,
        params: _readParams(r, length),
      );
    case UsbContainerType.data:
      return UsbDataContainer(
        opcode: code,
        transactionId: txid,
        payload: r.raw(r.remaining),
      );
    case UsbContainerType.response:
      return UsbResponseContainer(
        responseCode: code,
        transactionId: txid,
        params: _readParams(r, length),
      );
    default:
      throw FormatException('未知容器类型 $type(事件容器须走 decodeUsbEvent)');
  }
}

/// 解析 interrupt IN 端点上的一个完整事件容器。
UsbEventContainer decodeUsbEvent(Uint8List bytes) {
  if (bytes.length < kUsbEventHeaderLength) {
    throw FormatException('事件容器不足头部长度:仅 ${bytes.length} 字节');
  }
  final r = ByteReader(bytes);
  final length = r.u32();
  // 长度字段为 u32 且含头(与 bulk 容器 dwLength 语义一致)。
  // 2026-09-27 Zf 真机终验:21 个事件全部 16 字节(len=16=12 头+1 参数),
  // type=4,异步事件 txid 恒为 0xFFFFFFFF(无关联事务)。
  if (length != bytes.length) {
    throw FormatException('事件长度字段 $length ≠ 实际字节 ${bytes.length}');
  }
  final type = r.u16();
  if (type != UsbContainerType.event) {
    throw FormatException('事件容器类型应为 ${UsbContainerType.event},收到 $type');
  }
  final eventCode = r.u16();
  final txid = r.u32();
  final paramsArea = bytes.length - kUsbEventHeaderLength;
  if (paramsArea % 4 != 0) {
    throw FormatException('事件参数区 $paramsArea 字节,不是 4 的倍数');
  }
  return UsbEventContainer(
    eventCode: eventCode,
    transactionId: txid,
    params: [for (var i = 0; i < paramsArea ~/ 4; i++) r.u32()],
  );
}

/// 读 bulk 容器参数区(命令/响应共用):长度字段驱动,校验对齐与上限。
List<int> _readParams(ByteReader r, int containerLength) {
  final paramsArea = containerLength - kUsbContainerHeaderLength;
  if (paramsArea % 4 != 0) {
    throw FormatException('参数区 $paramsArea 字节,不是 4 的倍数');
  }
  final count = paramsArea ~/ 4;
  if (count > 5) {
    throw FormatException('参数个数 $count 超过 5');
  }
  return [for (var i = 0; i < count; i++) r.u32()];
}

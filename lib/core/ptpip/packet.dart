/// PTP-IP 包类型常量、包头与包数据模型。
///
/// 依据 TODO.md §一 与 USB-IF《Picture Transfer Protocol over TCP/IP
/// Networks》:
/// - 所有多字节字段一律**小端序**;大端包会被相机静默丢弃(TODO 注意事项 1)
/// - 包头 = 包类型(uint32 LE) + 包长度(uint32 LE,长度含包头自身 8 字节)
/// - 字节级编解码见 `codec.dart`,传输见 `channels.dart`
library;

import 'dart:typed_data';

/// 包类型常量(TODO.md §一)。
abstract final class PtpIpPacketType {
  static const int initCommandRequest = 1;
  static const int initCommandResponse = 2;
  static const int initEventRequest = 3;
  static const int initEventResponse = 4;
  static const int initFail = 5;
  static const int operationRequest = 6;
  static const int operationResponse = 7;
  static const int event = 8;
  static const int startData = 9;
  static const int data = 10;
  static const int cancel = 11;
  static const int endData = 12;
  static const int probeRequest = 13;
  static const int probeResponse = 14;
}

/// 包头固定长度:类型 4B + 长度 4B。
const int kPtpIpHeaderLength = 8;

/// 已按包头切好帧的原始包(类型 + 去头后的 body)。
final class PtpIpFrame {
  const PtpIpFrame({required this.type, required this.body});
  final int type;
  final Uint8List body;
}

/// 包基类;具体编解码由 [PtpIpCodec] 实现,这里只承载字段。
sealed class PtpIpPacket {
  const PtpIpPacket({required this.type});
  final int type;
}

/// 1: Init Command Request。
/// GUID(16B) + 主机名长度(uint32 LE,注意是 4 字节) + UTF-16LE 主机名。
final class InitCommandRequestPacket extends PtpIpPacket {
  const InitCommandRequestPacket({required this.guid, required this.hostname})
      : super(type: PtpIpPacketType.initCommandRequest);
  final Uint8List guid; // 16 字节
  final String hostname;
}

/// 2: Init Command Response:连接号(uint32)。
final class InitCommandResponsePacket extends PtpIpPacket {
  const InitCommandResponsePacket({required this.connectionNumber})
      : super(type: PtpIpPacketType.initCommandResponse);
  final int connectionNumber;
}

/// 3: Init Event Request:连接号(uint32)。
/// 必须发在独立的 event socket 上(TODO.md §一)。
final class InitEventRequestPacket extends PtpIpPacket {
  const InitEventRequestPacket({required this.connectionNumber})
      : super(type: PtpIpPacketType.initEventRequest);
  final int connectionNumber;
}

/// 4: Init Event Response:无负载。
final class InitEventResponsePacket extends PtpIpPacket {
  const InitEventResponsePacket() : super(type: PtpIpPacketType.initEventResponse);
}

/// 5: Init Fail:原因码(uint32)。
final class InitFailPacket extends PtpIpPacket {
  const InitFailPacket({required this.reason})
      : super(type: PtpIpPacketType.initFail);
  final int reason;
}

/// 6: Operation Request。
/// DataPhaseInfo(uint32 LE) + opcode(uint16 LE) + transactionId(uint32 LE) + params(变长 uint32)。
final class OperationRequestPacket extends PtpIpPacket {
  const OperationRequestPacket({
    required this.dataPhaseInfo,
    required this.opcode,
    required this.transactionId,
    this.params = const [],
  }) : super(type: PtpIpPacketType.operationRequest);
  final int dataPhaseInfo;
  final int opcode;
  final int transactionId;
  final List<int> params;
}

/// 7: Operation Response:响应码(uint16) + transactionId(uint32) + params。
final class OperationResponsePacket extends PtpIpPacket {
  const OperationResponsePacket({
    required this.responseCode,
    required this.transactionId,
    this.params = const [],
  }) : super(type: PtpIpPacketType.operationResponse);
  final int responseCode;
  final int transactionId;
  final List<int> params;
}

/// 8: Event:事件码(uint16) + transactionId(uint32) + params。
final class EventPacket extends PtpIpPacket {
  const EventPacket({
    required this.eventCode,
    required this.transactionId,
    this.params = const [],
  }) : super(type: PtpIpPacketType.event);
  final int eventCode;
  final int transactionId;
  final List<int> params;
}

/// 9: Start Data:transactionId(uint32) + 数据总长度(uint64)。
final class StartDataPacket extends PtpIpPacket {
  const StartDataPacket({required this.transactionId, required this.totalLength})
      : super(type: PtpIpPacketType.startData);
  final int transactionId;
  final int totalLength; // uint64,大文件支持
}

/// 10: Data:transactionId(uint32) + 负载。
final class DataPacket extends PtpIpPacket {
  const DataPacket({required this.transactionId, required this.payload})
      : super(type: PtpIpPacketType.data);
  final int transactionId;
  final Uint8List payload;
}

/// 12: End Data:transactionId(uint32) + 最后一段负载。
final class EndDataPacket extends PtpIpPacket {
  const EndDataPacket({required this.transactionId, required this.payload})
      : super(type: PtpIpPacketType.endData);
  final int transactionId;
  final Uint8List payload;
}

/// 11: Cancel:transactionId(uint32)。
final class CancelPacket extends PtpIpPacket {
  const CancelPacket({required this.transactionId})
      : super(type: PtpIpPacketType.cancel);
  final int transactionId;
}

/// 13/14: Probe Request / Response:均无负载(心跳保活用)。
final class ProbeRequestPacket extends PtpIpPacket {
  const ProbeRequestPacket() : super(type: PtpIpPacketType.probeRequest);
}

final class ProbeResponsePacket extends PtpIpPacket {
  const ProbeResponsePacket() : super(type: PtpIpPacketType.probeResponse);
}

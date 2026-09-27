/// PTP-IP 包 <-> 字节的编解码器。
///
/// 布局备忘(全部小端,长度字段含 8 字节包头):
/// - InitCommandRequest : GUID(16B) + 主机名长度(u32) + UTF-16LE 主机名
/// - OperationRequest   : DataPhaseInfo(u32) + opcode(u16) + transactionId(u32) + params(变长 u32)
/// - OperationResponse  : 响应码(u16) + transactionId(u32) + params
/// - StartData          : transactionId(u32) + 总长度(u64)
/// - Data / EndData     : transactionId(u32) + 负载
/// - Probe Request/Resp : 无负载
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'packet.dart';

abstract interface class PtpIpCodec {
  /// 编包:补 8 字节包头(类型 + 总长度)。
  Uint8List encode(PtpIpPacket packet);

  /// 解包:输入为去头后的 body。
  PtpIpPacket decode(PtpIpFrame frame);
}

/// TODO(P0): 实现;先用 tools/ptpip_probe 对真机跑通握手、
/// 核对字节布局后再落此实现(TODO.md §一「协议验证脚本」)。
final class PtpIpCodecImpl implements PtpIpCodec {
  @override
  Uint8List encode(PtpIpPacket packet) {
    final body = ByteWriter();
    switch (packet) {
      case InitCommandRequestPacket(:final guid, :final hostname):
        // TODO(P0): guid(16B) + u32 长度 + UTF-16LE 主机名
        body.raw(guid);
        body.utf16le(hostname);
      case OperationRequestPacket():
        // TODO(P0): dataPhaseInfo(u32) + opcode(u16) + tid(u32) + params
        break;
      case StartDataPacket():
      case DataPacket():
      case EndDataPacket():
      case CancelPacket():
      case ProbeRequestPacket():
        break;
      default:
        break;
    }
    throw UnimplementedError('TODO(P0): 实现 ${packet.runtimeType} 编码(小端)');
  }

  @override
  PtpIpPacket decode(PtpIpFrame frame) {
    final r = ByteReader(frame.body);
    // TODO(P0): 按 frame.type 分派解出具体包;
    // 每种包配字节级单测(test/core/ptpip/)。
    throw UnimplementedError('TODO(P0): 实现 type=${frame.type} 解码');
  }
}

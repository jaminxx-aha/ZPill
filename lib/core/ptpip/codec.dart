/// PTP-IP 包 <-> 字节的编解码器(全部小端)。
///
/// 布局备忘(包头均为 **长度(u32)在前、类型(u32)在后**,长度含 8B 包头):
/// - InitCommandRequest(尼康方言): GUID(16B) + UTF-16LE 主机名(NUL 结尾,
///   无长度前缀) + u32 版本 —— Zf「连接至智能设备」模式只认这个布局,
///   规范 PTP/IP 布局(GUID + u32 长度 + 主机名)被当乱码丢弃
/// - InitCommandResponse     : u32 连接号 + 16B 相机 GUID + NUL 终止 UTF-16LE
///   相机名 + u32 版本
/// - InitEventRequest/Response: u32 连接号 / 空负载
/// - OperationRequest        : DataPhaseInfo(u32) + opcode(u16) + tid(u32) + params(变长 u32)
/// - OperationResponse/Event : 响应/事件码(u16) + tid(u32) + params
/// - StartData               : tid(u32) + 总长度(u64)
/// - Data / EndData          : tid(u32) + 负载(EndData 携带尾段)
/// - Cancel                  : tid(u32);Probe Request/Response: 空负载
///
/// 字节真值依据:tools/ptpip_probe/probe.py(与本项目互为 golden)与
/// Camera_Bridge(github.com/HuiLiYiImpl/Camera_Bridge,小米 14 + Zf
/// Wi-Fi 实测通过)。
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'packet.dart';

abstract interface class PtpIpCodec {
  /// 编包:补 8 字节包头(长度 + 类型)。
  ///
  /// 两个方向都支持 —— 相机方向包(InitCommandResponse/OperationResponse/
  /// Event…)app 本身不发,但测试构造回放脚本需要。
  Uint8List encode(PtpIpPacket packet);

  /// 解包:输入为去头后的 body。
  PtpIpPacket decode(PtpIpFrame frame);
}

/// 尼康安卓客户端(SnapBridge 生态)在 Wi-Fi 上使用的固定 GUID。
///
/// Zf 的「连接至智能设备」模式按此识别客户端(Camera_Bridge 实证);
/// 随机 GUID + 规范 PTP/IP 布局会被相机在读完 Init 后直接 FIN。
const List<int> kNikonAndroidGuid = [
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
];

/// PTP-IP 协议版本 1.0(u32,高 16 位为主版本),附在 Init 包末尾。
const int kPtpIpProtocolVersion = 0x00010000;

/// PTP 操作与事件参数上限。规范常见上限为 5;保留 16 给厂商扩展,
/// 同时阻止畸形控制包展开成超大 List。
const int kMaxPtpIpParamCount = 16;

final class PtpIpCodecImpl implements PtpIpCodec {
  @override
  Uint8List encode(PtpIpPacket packet) {
    final w = ByteWriter();
    switch (packet) {
      case InitCommandRequestPacket(:final guid, :final hostname):
        w.raw(guid);
        w.utf16le(hostname);
        w.u16(0); // 主机名 NUL 终止符(方言:无长度前缀)
        w.u32(kPtpIpProtocolVersion);
      case InitEventRequestPacket(:final connectionNumber):
        w.u32(connectionNumber);
      case OperationRequestPacket(
          :final dataPhaseInfo,
          :final opcode,
          :final transactionId,
          :final params,
        ):
        w.u32(dataPhaseInfo);
        w.u16(opcode);
        w.u32(transactionId);
        for (final p in params) {
          w.u32(p);
        }
      case StartDataPacket(:final transactionId, :final totalLength):
        w.u32(transactionId);
        w.u64(totalLength);
      case DataPacket(:final transactionId, :final payload):
        w.u32(transactionId);
        w.raw(payload);
      case EndDataPacket(:final transactionId, :final payload):
        w.u32(transactionId);
        w.raw(payload);
      case CancelPacket(:final transactionId):
        w.u32(transactionId);
      case ProbeRequestPacket():
      case ProbeResponsePacket():
        break; // 空负载
      // ↓ 相机 → 主机方向:app 不发,仅供测试构造回放脚本(对称编解码)。
      case InitCommandResponsePacket(
          :final connectionNumber,
          :final cameraGuid,
          :final cameraName,
          :final protocolVersion,
        ):
        w.u32(connectionNumber);
        w.raw(cameraGuid);
        w.utf16le(cameraName);
        w.u16(0); // 相机名 NUL 终止符
        w.u32(protocolVersion);
      case InitEventResponsePacket():
        break; // 空负载
      case InitFailPacket(:final reason):
        w.u32(reason);
      case OperationResponsePacket(
          :final responseCode,
          :final transactionId,
          :final params,
        ):
        w.u16(responseCode);
        w.u32(transactionId);
        for (final p in params) {
          w.u32(p);
        }
      case EventPacket(
          :final eventCode,
          :final transactionId,
          :final params,
        ):
        w.u16(eventCode);
        w.u32(transactionId);
        for (final p in params) {
          w.u32(p);
        }
    }
    final body = w.takeBytes();
    return (ByteWriter()
          ..u32(body.length + kPtpIpHeaderLength) // 长度在前
          ..u32(packet.type)
          ..raw(body))
        .takeBytes();
  }

  @override
  PtpIpPacket decode(PtpIpFrame frame) {
    try {
      return _decode(frame);
    } on FormatException {
      rethrow;
    } on RangeError catch (e) {
      throw FormatException('PTP-IP body 长度不足或字段未对齐: $e');
    }
  }

  PtpIpPacket _decode(PtpIpFrame frame) {
    final r = ByteReader(frame.body);
    switch (frame.type) {
      // ↓ 主机 → 相机方向:相机不回这些,decode 供测试解析已发帧
      //   (协议版本字段是常量,解码时消费但不回填)。
      case PtpIpPacketType.initCommandRequest:
        final guid = r.raw(16);
        final hostname = r.utf16z();
        if (!r.eof) r.u32();
        return InitCommandRequestPacket(guid: guid, hostname: hostname);
      case PtpIpPacketType.initEventRequest:
        return InitEventRequestPacket(connectionNumber: r.u32());
      case PtpIpPacketType.operationRequest:
        final dp = r.u32();
        final opcode = r.u16();
        final tid = r.u32();
        final params = _readParams(r);
        return OperationRequestPacket(
            dataPhaseInfo: dp,
            opcode: opcode,
            transactionId: tid,
            params: params);
      case PtpIpPacketType.initCommandResponse:
        final connectionNumber = r.u32();
        final cameraGuid = r.raw(16);
        final cameraName = r.utf16z();
        final protocolVersion = r.eof ? 0 : r.u32(); // 截断宽容
        return InitCommandResponsePacket(
          connectionNumber: connectionNumber,
          cameraGuid: cameraGuid,
          cameraName: cameraName,
          protocolVersion: protocolVersion,
        );
      case PtpIpPacketType.initEventResponse:
        return const InitEventResponsePacket();
      case PtpIpPacketType.initFail:
        return InitFailPacket(reason: r.u32());
      case PtpIpPacketType.operationResponse:
        final code = r.u16();
        final tid = r.u32();
        final params = _readParams(r);
        return OperationResponsePacket(
            responseCode: code, transactionId: tid, params: params);
      case PtpIpPacketType.event:
        final code = r.u16();
        final tid = r.u32();
        final params = _readParams(r);
        return EventPacket(eventCode: code, transactionId: tid, params: params);
      case PtpIpPacketType.startData:
        final tid = r.u32();
        final total = r.u64();
        return StartDataPacket(transactionId: tid, totalLength: total);
      case PtpIpPacketType.data:
        final tid = r.u32();
        // 载荷视图(帧 body 本就是 splitter 的视图,链路到槽位全程
        // 零拷贝);raw 的防御副本是取景帧流每帧一遍无谓整帧拷贝。
        return DataPacket(transactionId: tid, payload: r.rawView(r.remaining));
      case PtpIpPacketType.endData:
        final tid = r.u32();
        return EndDataPacket(
            transactionId: tid, payload: r.rawView(r.remaining));
      case PtpIpPacketType.cancel:
        return CancelPacket(transactionId: r.u32());
      case PtpIpPacketType.probeRequest:
        return const ProbeRequestPacket();
      case PtpIpPacketType.probeResponse:
        return const ProbeResponsePacket();
      default:
        throw FormatException('未知 PTP-IP 包类型 ${frame.type}');
    }
  }

  static List<int> _readParams(ByteReader r) {
    if (r.remaining % 4 != 0) {
      throw FormatException('PTP-IP 参数区未按 u32 对齐(${r.remaining}B)');
    }
    final count = r.remaining ~/ 4;
    if (count > kMaxPtpIpParamCount) {
      throw FormatException('PTP-IP 参数 $count 个,超过上限 $kMaxPtpIpParamCount');
    }
    return [for (var i = 0; i < count; i++) r.u32()];
  }
}

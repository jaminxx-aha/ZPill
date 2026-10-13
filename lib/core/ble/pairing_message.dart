/// Nikon 智能设备模式配对帧:17 字节定长,小端。
///
/// 布局:stage(u8)+ timestamp(u64 LE)+ device(u32 LE)+ nonce(u32 LE)。
/// Dart int 原生 64 位,u64 时间戳无精度损失。
library;

import 'dart:typed_data';

final class PairingMessage {
  static const int length = 17;

  final int stage;
  final int timestamp;
  final int device;
  final int nonce;

  const PairingMessage({
    required this.stage,
    required this.timestamp,
    required this.device,
    required this.nonce,
  });

  Uint8List encode() {
    final data = ByteData(length)
      ..setUint8(0, stage & 0xFF)
      ..setUint64(1, timestamp, Endian.little)
      ..setUint32(9, device & 0xFFFFFFFF, Endian.little)
      ..setUint32(13, nonce & 0xFFFFFFFF, Endian.little);
    return data.buffer.asUint8List();
  }

  factory PairingMessage.decode(Uint8List raw) {
    if (raw.length != length) {
      throw FormatException('配对帧须为 $length 字节,实得 ${raw.length}');
    }
    final data = ByteData.sublistView(raw);
    return PairingMessage(
      stage: data.getUint8(0),
      timestamp: data.getUint64(1, Endian.little),
      device: data.getUint32(9, Endian.little),
      nonce: data.getUint32(13, Endian.little),
    );
  }
}

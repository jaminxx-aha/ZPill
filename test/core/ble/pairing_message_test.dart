import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/pairing_message.dart';

void main() {
  group('PairingMessage', () {
    test('encode:Z50_2 stage1 向量逐字节', () {
      const msg = PairingMessage(
        stage: 0x01,
        timestamp: 0x677da144ec13e1db,
        device: 0x3c3ae501,
        nonce: 0x3fdaa451,
      );
      expect(
        msg.encode(),
        <int>[
          0x01, // stage
          0xdb, 0xe1, 0x13, 0xec, 0x44, 0xa1, 0x7d, 0x67, // ts u64 LE
          0x01, 0xe5, 0x3a, 0x3c, // device u32 LE
          0x51, 0xa4, 0xda, 0x3f, // nonce u32 LE
        ],
      );
    });

    test('decode ↔ encode 往返(u64 时间戳无精度损失)', () {
      const msg = PairingMessage(
        stage: 0x02,
        timestamp: 0xb9943d5e8026fa29,
        device: 0xa8b3f2e4,
        nonce: 0x16d56a13,
      );
      final decoded = PairingMessage.decode(msg.encode());
      expect(decoded.stage, msg.stage);
      expect(decoded.timestamp, msg.timestamp);
      expect(decoded.device, msg.device);
      expect(decoded.nonce, msg.nonce);
    });

    test('长度非 17 拒绝', () {
      expect(() => PairingMessage.decode(Uint8List(16)), throwsFormatException);
      expect(() => PairingMessage.decode(Uint8List(18)), throwsFormatException);
    });
  });
}

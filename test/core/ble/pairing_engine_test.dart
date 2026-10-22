import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/pairing_engine.dart';
import 'package:z_pill/core/ble/pairing_message.dart';

void main() {
  // Z50_2 真机向量(HarmoNiLink NikonPairingEngine.ets 头注,博文同源)。
  const stage1 = PairingMessage(
    stage: 0x01,
    timestamp: 0x677da144ec13e1db,
    device: 0x3c3ae501,
    nonce: 0x3fdaa451,
  );
  const stage2 = PairingMessage(
    stage: 0x02,
    timestamp: 0xb9943d5e8026fa29,
    device: 0xa8b3f2e4,
    nonce: 0x16d56a13,
  );

  group('NikonPairingEngine', () {
    test('Z50_2 握手:stage2 校验通过,stage3 逐字节', () {
      final engine = NikonPairingEngine();
      final stage3 = engine.verifyStage2AndBuildStage3(stage1, stage2);
      expect(stage3, isNotNull);
      expect(stage3!.stage, 0x03);
      expect(stage3.timestamp, stage1.timestamp);
      expect(stage3.device, 0x79f1ad53);
      expect(stage3.nonce, 0x23838a35);
      expect(
        stage3.encode(),
        <int>[
          0x03,
          0xdb, 0xe1, 0x13, 0xec, 0x44, 0xa1, 0x7d, 0x67,
          0x53, 0xad, 0xf1, 0x79,
          0x35, 0x8a, 0x83, 0x23,
        ],
      );
    });

    test('stage2 挑战被篡改则无 salt 命中,返回 null', () {
      final engine = NikonPairingEngine();
      final tampered = PairingMessage(
        stage: 0x02,
        timestamp: stage2.timestamp,
        device: stage2.device ^ 0x01,
        nonce: stage2.nonce,
      );
      expect(engine.verifyStage2AndBuildStage3(stage1, tampered), isNull);
    });

    test('createStage1:deviceId 最低位字节恒 0x01,复用身份原样透传', () {
      final engine = NikonPairingEngine();
      for (var i = 0; i < 32; i++) {
        final msg = engine.createStage1();
        expect(msg.stage, 0x01);
        expect(msg.device & 0xFF, 0x01, reason: 'device=${msg.device.toRadixString(16)}');
        expect(msg.nonce, isNot(0));
      }
      final reused = engine.createStage1(savedDevice: 0x3c3ae501, savedNonce: 0x3fdaa451);
      expect(reused.device, 0x3c3ae501);
      expect(reused.nonce, 0x3fdaa451);
    });

    test('extractSerial:字节 9-16 = 序列号 ASCII,NUL 截止', () {
      final raw = Uint8List(17)
        ..[0] = 0x04
        ..setRange(9, 16, 'B123456'.codeUnits) // 第 16 字节留 NUL
        ..[16] = 0x00;
      final engine = NikonPairingEngine();
      expect(engine.extractSerial(PairingMessage.decode(raw)), 'B123456');

      final full = Uint8List(17)
        ..[0] = 0x04
        ..setRange(9, 17, 'B1234567'.codeUnits); // 8 字符无 NUL
      expect(engine.extractSerial(PairingMessage.decode(full)), 'B1234567');
    });
  });
}

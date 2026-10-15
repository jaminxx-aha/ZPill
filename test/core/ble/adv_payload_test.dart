import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/adv_payload.dart';

/// 0x0399 广播解析:全分支 + 与 native 重连过滤器的字节口径互证
/// (布局 [99 03][u32 LE deviceId],≥6B,尾随字节忽略)。
void main() {
  Uint8List mfgOf(int deviceId) => Uint8List.fromList(<int>[
        0x99,
        0x03,
        deviceId & 0xFF,
        (deviceId >> 8) & 0xFF,
        (deviceId >> 16) & 0xFF,
        (deviceId >> 24) & 0xFF,
      ]);

  group('expectedControllerDeviceId', () {
    test('正常:公司 ID 0x0399 + u32 LE deviceId(引擎款低位 0x01)', () {
      expect(expectedControllerDeviceId(mfgOf(0x11223301)), 0x11223301);
      expect(expectedControllerDeviceId(mfgOf(0x56781234)), 0x56781234);
    });

    test('高位字节 ≥ 0x80:按无符号 u32 解读(与引擎全 32 位取值域一致)', () {
      expect(expectedControllerDeviceId(mfgOf(0x80000001)), 0x80000001);
      expect(expectedControllerDeviceId(mfgOf(0xFFFFFFFF)), 0xFFFFFFFF);
    });

    test('尾随字节忽略(广播可在 6B 之外带余量)', () {
      final mfg = Uint8List.fromList(<int>[...mfgOf(0x11223301), 0xAB, 0xCD]);
      expect(expectedControllerDeviceId(mfg), 0x11223301);
    });

    test('短包/空:一概 null(<6B 凑不出公司 ID + 4B deviceId)', () {
      expect(expectedControllerDeviceId(null), isNull);
      expect(expectedControllerDeviceId(Uint8List(0)), isNull);
      expect(expectedControllerDeviceId(mfgOf(0x11223301).sublist(0, 5)),
          isNull);
      expect(
          expectedControllerDeviceId(Uint8List.fromList(<int>[0x99, 0x03])),
          isNull);
    });

    test('公司 ID 不符:null(0x0399 之外的非尼康厂商数据)', () {
      expect(
          expectedControllerDeviceId(
              Uint8List.fromList(<int>[0x98, 0x03, 1, 2, 3, 4])),
          isNull);
      expect(
          expectedControllerDeviceId(
              Uint8List.fromList(<int>[0x99, 0x04, 1, 2, 3, 4])),
          isNull);
      // 大端公司 ID(03 99)= 拼错方向的 0x9903,同样不认。
      expect(
          expectedControllerDeviceId(
              Uint8List.fromList(<int>[0x03, 0x99, 1, 2, 3, 4])),
          isNull);
    });
  });

  group('cameraWaitsForOtherController(冲突判定)', () {
    test('有注册身份 + 异 ID:在等别的手机', () {
      expect(cameraWaitsForOtherController(mfgOf(0x56781234), 0x11223301),
          isTrue);
    });

    test('同 ID:相机在等我们自己,不算冲突', () {
      expect(
          cameraWaitsForOtherController(mfgOf(0x11223301), 0x11223301),
          isFalse);
    });

    test('无注册身份:首次配对无从比较,恒不判冲突', () {
      expect(cameraWaitsForOtherController(mfgOf(0x56781234), null), isFalse);
    });

    test('广播不可解析(配对菜单态无 0x0399):无从比较,不判冲突', () {
      expect(
          cameraWaitsForOtherController(
              Uint8List.fromList(<int>[0x99, 0x03, 0x01]), 0x11223301),
          isFalse);
      expect(cameraWaitsForOtherController(null, 0x11223301), isFalse);
      expect(
          cameraWaitsForOtherController(
              Uint8List.fromList(<int>[0x98, 0x03, 1, 2, 3, 4]), 0x11223301),
          isFalse);
    });
  });
}

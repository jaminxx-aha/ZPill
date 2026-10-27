import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/snapbridge_id_solver.dart';

/// SnapBridge LCG 反解器:对拍 photools 的 JVM 实证向量(其测试注明
/// 「Verified on a JVM」),另加自洽性断言。Dart VM int 64 位二补环,
/// `&*` 截断后取低 48 位与模运算同余 —— 语义与 Java/真机一致。
void main() {
  group('nextBytes(对拍 JVM 实证输出)', () {
    test('Random(1785587115763).nextBytes(8) == 48ee2fc1f03fcf17', () {
      final bytes = nextBytes(1785587115763, 8);
      expect(
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '48ee2fc1f03fcf17');
    });

    test('count 非 4 倍数:按 4B 一组低字节在前截断', () {
      final bytes = nextBytes(1785587115763, 5);
      expect(bytes.sublist(0, 4),
          Uint8List.fromList(<int>[0x48, 0xee, 0x2f, 0xc1]));
      expect(bytes[4], 0xf0);
    });
  });

  group('solveSeeds', () {
    test('含 photools 真机配对的两个实证种子(0x244B5D44)', () {
      final seeds = solveSeeds(0x244B5D44);
      expect(seeds, contains(1777120641934));
      expect(seeds, contains(1782432516591));
    });

    test('含 JVM 向量种子的反解(0x48ee2fc1 → 1785587115763)', () {
      // JVM 向量前 4 字节 48 ee 2f c1 按 LE 读即 0xC12FEE48。
      expect(solveSeeds(0xC12FEE48), contains(1785587115763));
    });

    test('恒 65536 条(低 16 位自由度)', () {
      expect(solveSeeds(0x244B5D44).length, 1 << 16);
    });
  });

  group('candidatesFor(窗口过滤 + 凭据重构)', () {
    test('photools 真机案例:±1s 窗收敛到单候选,nonce 重构正确', () {
      final candidates = candidatesFor(
        0x244B5D44,
        windowStartMs: 1777120641934 - 1000,
        windowEndMs: 1777120641934 + 1000,
      );
      expect(candidates.map((c) => c.seed).toList(), <int>[1777120641934]);
      final c = candidates.single;
      expect(c.fullHex, '445d4b24981064f7');
      expect(c.deviceId, 0x244B5D44);
      expect(c.nonce, 0xF7641098);
    });

    test('默认窗(2016 至今+1d)非空、按种子升序、deviceId 恒等输入', () {
      final candidates = candidatesFor(0x244B5D44);
      expect(candidates, isNotEmpty);
      final seeds = candidates.map((c) => c.seed).toList();
      expect(seeds, equals([...seeds]..sort()));
      for (final c in candidates) {
        expect(c.deviceId, 0x244B5D44);
      }
    });

    test('窗外种子全滤(窄窗不覆盖任何实证种子时空)', () {
      expect(
          candidatesFor(0x244B5D44,
              windowStartMs: 1000, windowEndMs: 2000),
          isEmpty);
    });
  });
}

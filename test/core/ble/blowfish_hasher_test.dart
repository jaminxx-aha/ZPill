import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/blowfish_hasher.dart';

void main() {
  group('BlowfishHasher', () {
    test('标准 ECB 向量:零密钥加密全零块 = 4EF997456198DD78', () {
      // hash 的初值 0x01020304/0x05060708 与首块异或后恰为全零块,
      // 单块输入的返回值即裸 ECB 结果 —— 用公开标准向量钉死加密核。
      final hasher = BlowfishHasher(key: List<int>.filled(8, 0));
      final (l, r) = hasher.hash(<int>[0x01020304, 0x05060708]);
      expect(l, 0x4EF99745);
      expect(r, 0x6198DD78);
    });

    test('Nikon 定键构造不抛错,hash 结果稳定', () {
      final hasher = BlowfishHasher();
      final (l1, r1) = hasher.hash(<int>[1, 2, 3, 4]);
      final (l2, r2) = hasher.hash(<int>[1, 2, 3, 4]);
      expect(l1, l2);
      expect(r1, r2);
      // 链式推进:追加块必须改变输出(排除「只看首块」的假实现)。
      final (l3, r3) = hasher.hash(<int>[1, 2, 3, 4, 5, 6]);
      expect(l3 == l1 && r3 == r1, isFalse);
    });

    test('奇数个 u32 块拒绝', () {
      final hasher = BlowfishHasher();
      expect(() => hasher.hash(<int>[1, 2, 3]), throwsArgumentError);
    });
  });
}

/// 标准 Blowfish(公开算法)+ Nikon 智能设备模式的 CBC-MAC 式 hash。
///
/// 密钥定死 8 字节 `FF FF AA 55 11 22 33 00`(协议方言定案,2026-10-13);
/// hash 把输入按 u32 对分组:inL = 块 ^ 上轮左半,inR = 块 ^ 上轮右半,
/// ECB 加密后作为下一轮左右半 —— 初值 0x01020304/0x05060708,输出即最后
/// 一对密文(等价 CBC-MAC,块长恒为 2 个 u32 的倍数)。
library;

import 'dart:typed_data';

import 'blowfish_tables.dart';

class BlowfishHasher {
  static const List<int> nikonKey = <int>[
    0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00,
  ];

  final Uint32List _p;
  final List<Uint32List> _s;

  BlowfishHasher({List<int> key = nikonKey})
      : _p = Uint32List.fromList(kBfPInit),
        _s = List<Uint32List>.generate(
            4,
            (i) => Uint32List.fromList(
                <List<int>>[kBfS0, kBfS1, kBfS2, kBfS3][i])) {
    _expandKey(key);
  }

  static const int _mask = 0xFFFFFFFF;

  int _f(int x) {
    final a = _s[0][(x >>> 24) & 0xFF];
    final b = _s[1][(x >>> 16) & 0xFF];
    final c = _s[2][(x >>> 8) & 0xFF];
    final d = _s[3][x & 0xFF];
    return (((a + b) & _mask) ^ c) + d & _mask;
  }

  /// ECB 加密一个 64 位块,返回 (L, R)。
  (int, int) _encryptBlock(int l, int r) {
    var xL = l & _mask;
    var xR = r & _mask;
    for (var i = 0; i < 16; i++) {
      xL ^= _p[i];
      xR = (xR ^ _f(xL)) & _mask;
      final t = xL;
      xL = xR;
      xR = t;
    }
    final t = xL;
    xL = xR;
    xR = t;
    xR ^= _p[16];
    xL ^= _p[17];
    return (xL & _mask, xR & _mask);
  }

  /// ECB 加密一个 64 位块,返回 (L, R)。0x2004 凭据解密与向量测试用
  /// (协议 hash 走 [hash],块密码本体在此)。
  (int, int) encryptBlock(int l, int r) => _encryptBlock(l, r);

  /// ECB 解密一个 64 位块,返回 (L, R):Feistel 结构对称,轮密钥逆序
  /// (P[17]→P[2])走同形轮,末轮外异或 P[1]/P[0]。
  (int, int) decryptBlock(int l, int r) {
    var xL = l & _mask;
    var xR = r & _mask;
    for (var i = 17; i >= 2; i--) {
      xL ^= _p[i];
      xR = (xR ^ _f(xL)) & _mask;
      final t = xL;
      xL = xR;
      xR = t;
    }
    final t = xL;
    xL = xR;
    xR = t;
    xR ^= _p[1];
    xL ^= _p[0];
    return (xL & _mask, xR & _mask);
  }

  void _expandKey(List<int> key) {
    var k = 0;
    for (var i = 0; i < 18; i++) {
      var word = 0;
      for (var j = 0; j < 4; j++) {
        word = ((word << 8) | key[k]) & _mask;
        k = (k + 1) % key.length;
      }
      _p[i] ^= word;
    }
    var (bl, br) = (0, 0);
    for (var i = 0; i < 18; i += 2) {
      (bl, br) = _encryptBlock(bl, br);
      _p[i] = bl;
      _p[i + 1] = br;
    }
    for (var box = 0; box < 4; box++) {
      for (var j = 0; j < 256; j += 2) {
        (bl, br) = _encryptBlock(bl, br);
        _s[box][j] = bl;
        _s[box][j + 1] = br;
      }
    }
  }

  /// CBC-MAC 式 hash:`blocks` 为 u32 序列(长度须为偶数),返回 (L, R)。
  (int, int) hash(List<int> blocks) {
    if (blocks.length.isOdd) {
      throw ArgumentError.value(blocks.length, 'blocks', 'u32 块数须为偶数');
    }
    var left = 0x01020304;
    var right = 0x05060708;
    for (var i = 0; i < blocks.length; i += 2) {
      final (l, r) = _encryptBlock(blocks[i] ^ left, blocks[i + 1] ^ right);
      left = l;
      right = r;
    }
    return (left, right);
  }
}

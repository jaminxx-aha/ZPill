/// Nikon 智能设备模式 4 步配对握手(stage1→2→3→4)。
///
/// - stage1:我方发 (随机 ts, deviceId, nonce);新配对 deviceId 低位字节
///   须为 0x01(线上小端最低位),重连复用已存 device/nonce。
/// - stage2:相机挑战帧。用 8 组固定 salt 逐一试
///   `hash(salt ‖ BE(相机 ts 低半) ‖ BE(相机 ts 高半) ‖ BE(我方 ts 低半) ‖ BE(我方 ts 高半))`,
///   结果等于相机 device/nonce 的字节反转(大端解读)即中。
/// - stage3:同一 salt,块序换成我方 ts 在前,hash 结果两字反转回小端
///   作 device/nonce,时间戳沿用 stage1。
/// - stage4:帧内字节 9-16 为相机序列号 ASCII(NUL 截止)。
library;

import 'dart:math';
import 'dart:typed_data';

import 'blowfish_hasher.dart';
import 'pairing_message.dart';

final class NikonPairingEngine {
  /// 8 组挑战 salt(每组两个 u32),协议方言定案。
  static const List<List<int>> salts = <List<int>>[
    <int>[0x704066e4, 0x0433d552],
    <int>[0xed4b8fac, 0x15f7e47b],
    <int>[0x24471f11, 0x8b5ea1fc],
    <int>[0x05960c31, 0x2b8c7f41],
    <int>[0xfda588c1, 0xeba8b1f3],
    <int>[0x99166056, 0x1bd3d550],
    <int>[0xcd32687f, 0xa9e28a30],
    <int>[0x2a8fe834, 0xdec7ebf4],
  ];

  final BlowfishHasher _hasher;
  final Random _random;

  NikonPairingEngine({Random? random})
      : _hasher = BlowfishHasher(),
        _random = random ?? Random.secure();

  /// stage1 帧。已有配对身份时传入复用的 device/nonce。
  PairingMessage createStage1({int? savedDevice, int? savedNonce}) {
    final device = savedDevice ?? _newDeviceId();
    final nonce = savedNonce ?? _random.nextInt(1 << 32);
    return PairingMessage(
      stage: 0x01,
      timestamp: _randomTimestamp(),
      device: device,
      nonce: nonce,
    );
  }

  /// 校验 stage2 并构建 stage3;无 salt 命中返回 null(握手失败)。
  PairingMessage? verifyStage2AndBuildStage3(
    PairingMessage stage1,
    PairingMessage stage2,
  ) {
    final saltIndex = _findSalt(stage1, stage2);
    if (saltIndex == null) return null;
    final salt = salts[saltIndex];

    final ourLo = _tsLowBe(stage1.timestamp);
    final ourHi = _tsHighBe(stage1.timestamp);
    final camLo = _tsLowBe(stage2.timestamp);
    final camHi = _tsHighBe(stage2.timestamp);

    // stage3 与 stage2 块序相反:我方时间戳在前。
    final (r0, r1) = _hasher
        .hash(<int>[salt[0], salt[1], ourLo, ourHi, camLo, camHi]);
    return PairingMessage(
      stage: 0x03,
      timestamp: stage1.timestamp,
      device: _reverseU32(r0),
      nonce: _reverseU32(r1),
    );
  }

  /// stage4 帧字节 9-16 = 相机序列号 ASCII,NUL 截止。
  String extractSerial(PairingMessage stage4) {
    final raw = stage4.encode();
    final units = <int>[];
    for (var i = 9; i < 17; i++) {
      if (raw[i] == 0) break;
      units.add(raw[i]);
    }
    return String.fromCharCodes(units);
  }

  int? _findSalt(PairingMessage stage1, PairingMessage stage2) {
    final ourLo = _tsLowBe(stage1.timestamp);
    final ourHi = _tsHighBe(stage1.timestamp);
    final camLo = _tsLowBe(stage2.timestamp);
    final camHi = _tsHighBe(stage2.timestamp);
    final expectDevice = _reverseU32(stage2.device);
    final expectNonce = _reverseU32(stage2.nonce);
    for (final salt in salts) {
      final (h0, h1) =
          _hasher.hash(<int>[salt[0], salt[1], camLo, camHi, ourLo, ourHi]);
      if (h0 == expectDevice && h1 == expectNonce) return salts.indexOf(salt);
    }
    return null;
  }

  int _newDeviceId() => (_random.nextInt(1 << 32) & 0xFFFFFF00) | 0x01;

  int _randomTimestamp() {
    final hi = _random.nextInt(1 << 32);
    final lo = _random.nextInt(1 << 32);
    return (hi << 32) | lo;
  }

  /// u64 时间戳低 32 位取字节反转(小端解析 → 大端数值),作 hash 块。
  static int _tsLowBe(int timestamp) =>
      _reverseU32(timestamp & 0xFFFFFFFF);

  static int _tsHighBe(int timestamp) =>
      _reverseU32((timestamp >>> 32) & 0xFFFFFFFF);

  static int _reverseU32(int value) {
    final v = value & 0xFFFFFFFF;
    return ((v & 0x000000FF) << 24) |
        ((v & 0x0000FF00) << 8) |
        ((v & 0x00FF0000) >>> 8) |
        ((v & 0xFF000000) >>> 24);
  }
}

/// 便于测试注入:按字节读帧(ByteData 视图)。
extension PairingMessageBytes on PairingMessage {
  int byteAt(int index) =>
      ByteData.sublistView(encode()).getUint8(index);
}

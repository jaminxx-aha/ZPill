/// SnapBridge 配对凭据反解器(photools/SnapBridgeIdSolver 口径的数学
/// 移植,源头谱系 HowenXu/snapbridge-id-extractor,2026-10-17,只借
/// 思路不搬码):官方 SnapBridge 首次配对时以
/// `new Random(当前 Unix 毫秒)` 生成 8B 凭据(Java 48-bit LCG),相机
/// 在 0x0399 广播里暴露前 4B(deviceID);对 LCG 求模逆元可反解种子
/// 候选,时间窗过滤后重构后 4B(nonce)—— 理论上可**跳过相机配对
/// 菜单**直接接管已配 SnapBridge 的相机。
///
/// 现状:**仅数学层 + JVM 实证向量测试**(见
/// test/core/ble/snapbridge_id_solver_test.dart),未接握手流程。
/// 待真机实验定案的两件事:
/// ① Zf 是否吃这套接管(photools 只在 Z6 III 实证);
/// ② 多候选消歧 —— 同一 deviceID 在时间窗内可反解出多个种子/nonce,
///    相机只认配对时的那个;photools 取排序后 .first(最早种子),其
///    作者真机恰为最早候选,是否普遍成立未证。
library;

import 'dart:typed_data';

/// Java Random 的 LCG 常量,运算全在模 2^48 上(Dart VM int 为 64 位
/// 二补环,乘加溢出静默回绕,末尾 `& _mask48` 截断即模 2^48;仅 VM/
/// 移动端语义成立,web 编译目标不适用)。
const int _mask48 = (1 << 48) - 1;
const int _multiplier = 0x5DEECE66D;
const int _addend = 0xB;

/// _multiplier 在模 2^48 下的乘法逆元(扩展欧几里得定值)。
const int _invMultiplier = 0xdfe05bcb1365;

/// 默认种子窗口下界:2016-01-01(SnapBridge 面世年);种子即配对时刻
/// 的 Unix 毫秒,窗口滤掉绝大多数随机低 16 位凑出的伪种子。
const int kSnapBridgeSeedWindowStartMs = 1451606400000;

/// 一条反解出的候选凭据:种子(≈配对时刻 Unix 毫秒)、deviceID(恒等
/// 于反解输入)、重构的 nonce、8B 凭据 hex。
class SnapBridgeCredential {
  final int seed;
  final int deviceId;
  final int nonce;
  final String fullHex;

  const SnapBridgeCredential({
    required this.seed,
    required this.deviceId,
    required this.nonce,
    required this.fullHex,
  });
}

/// 反解所有使 Java Random 首个 next(32) 等于 [targetDevice](无符号
/// u32,即广播暴露的 deviceId)的 48 位种子,恒 65536 条(低 16 位
/// 自由度),调用方再按时间窗过滤。
List<int> solveSeeds(int targetDevice) {
  final seeds = List<int>.filled(1 << 16, 0);
  for (var low16 = 0; low16 < 1 << 16; low16++) {
    final state = (targetDevice << 16) | low16;
    final x = (((state - _addend) & _mask48) * _invMultiplier) & _mask48;
    seeds[low16] = x ^ _multiplier;
  }
  return seeds;
}

/// 模拟 Java `Random(seed).nextBytes(n)`:每 4 字节走一次 next(32),
/// 字节序为取值的低字节在前。
Uint8List nextBytes(int seed, int count) {
  var state = (seed ^ _multiplier) & _mask48;
  final out = Uint8List(count);
  var i = 0;
  while (i < count) {
    state = ((state * _multiplier) + _addend) & _mask48;
    final rnd = state >> 16;
    final step = count - i < 4 ? count - i : 4;
    for (var j = 0; j < step; j++) {
      out[i + j] = (rnd >> (8 * j)) & 0xFF;
    }
    i += step;
  }
  return out;
}

/// 反解时间窗内的候选凭据(按种子升序)。默认窗 2016-01-01 至今+1 天。
List<SnapBridgeCredential> candidatesFor(
  int targetDevice, {
  int? windowStartMs,
  int? windowEndMs,
}) {
  final start = windowStartMs ?? kSnapBridgeSeedWindowStartMs;
  final end =
      windowEndMs ?? DateTime.now().millisecondsSinceEpoch + 86400000;
  final out = <SnapBridgeCredential>[];
  for (final seed in solveSeeds(targetDevice)) {
    if (seed < start || seed > end) continue;
    final bytes = nextBytes(seed, 8);
    final dev = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
    final nonce =
        bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
    out.add(SnapBridgeCredential(
      seed: seed,
      deviceId: dev,
      nonce: nonce,
      fullHex: bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    ));
  }
  out.sort((a, b) => a.seed.compareTo(b.seed));
  return out;
}

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/transfer/aimd_chunk.dart';

void main() {
  const fast = Duration(milliseconds: 100); // < 400ms 阈值 = 快
  const slow = Duration(milliseconds: 500); // > 400ms 阈值 = 慢

  test('起步 = 64KB;口径常量齐备(下限/上限/步长/阈值)', () {
    expect(AimdChunkPolicy().currentBytes, 64 * 1024);
    expect(AimdChunkPolicy.minChunkBytes, 64 * 1024);
    expect(AimdChunkPolicy.hardMaxChunkBytes, 1024 * 1024);
    expect(AimdChunkPolicy.additiveStepBytes, 32 * 1024);
    expect(
        AimdChunkPolicy.fastChunkThreshold, const Duration(milliseconds: 400));
  });

  test('快块加性升:演化序列 64K→96K→128K→…(整序列断言)', () {
    final p = AimdChunkPolicy();
    final sizes = <int>[p.currentBytes];
    for (var i = 0; i < 32; i++) {
      p.reportSuccess(fast);
      sizes.add(p.currentBytes);
    }
    // +32KB/次:第 n 次后 = 64KB + n*32KB,直到封顶。
    expect(sizes.take(4), [64 * 1024, 96 * 1024, 128 * 1024, 160 * 1024]);
    expect(sizes[29], 64 * 1024 + 29 * 32 * 1024); // 封顶前最后一级
    expect(sizes[30], 1024 * 1024); // 第 30 次恰好到位
    expect(sizes[31], 1024 * 1024); // 封顶后走平
    expect(sizes[32], 1024 * 1024);
  });

  test('成功但慢(> 400ms):块大小不动', () {
    final p = AimdChunkPolicy();
    p.reportSuccess(slow);
    p.reportSuccess(slow);
    p.reportSuccess(const Duration(milliseconds: 401));
    expect(p.currentBytes, 64 * 1024);
  });

  test('快慢交替:慢块只 Hold,不清累进也不回退', () {
    final p = AimdChunkPolicy();
    p.reportSuccess(fast); // → 96K
    p.reportSuccess(slow); // hold
    expect(p.currentBytes, 96 * 1024);
    p.reportSuccess(fast); // → 128K
    expect(p.currentBytes, 128 * 1024);
  });

  test('超时减半;连续超时降到 floor 64KB 不降穿', () {
    final p = AimdChunkPolicy();
    for (var i = 0; i < 8; i++) {
      p.reportSuccess(fast); // 升到 320KB
    }
    expect(p.currentBytes, 320 * 1024);
    p.reportTimeout();
    expect(p.currentBytes, 160 * 1024);
    p.reportTimeout();
    expect(p.currentBytes, 80 * 1024);
    p.reportTimeout();
    expect(p.currentBytes, 64 * 1024); // 40K 钳回下限
    p.reportTimeout();
    expect(p.currentBytes, 64 * 1024); // 不降穿
  });

  test('传输错误减半(与超时同口径)', () {
    final p = AimdChunkPolicy();
    for (var i = 0; i < 16; i++) {
      p.reportSuccess(fast); // 升到 576KB
    }
    expect(p.currentBytes, 576 * 1024);
    p.reportError();
    expect(p.currentBytes, 288 * 1024);
    p.reportError();
    expect(p.currentBytes, 144 * 1024);
  });

  test('减半后从降后大小续升(降-升演化序列)', () {
    final p = AimdChunkPolicy();
    for (var i = 0; i < 14; i++) {
      p.reportSuccess(fast); // 升到 512KB
    }
    expect(p.currentBytes, 512 * 1024);
    p.reportTimeout(); // → 256K
    p.reportSuccess(fast); // → 288K
    p.reportSuccess(fast); // → 320K
    expect(p.currentBytes, 320 * 1024);
  });

  test('自定义上界:封顶于 maxBytes(低于 1MB)', () {
    final p = AimdChunkPolicy(maxBytes: 100 * 1024);
    expect(p.currentBytes, 64 * 1024);
    for (var i = 0; i < 10; i++) {
      p.reportSuccess(fast);
    }
    expect(p.currentBytes, 100 * 1024); // 64+10*32 钳到上界
  });

  test('显式上界高于 1MB 被硬顶钳回(0x101B 单块上限勿越)', () {
    final p = AimdChunkPolicy(maxBytes: 8 * 1024 * 1024);
    expect(p.maxBytes, 1024 * 1024);
    for (var i = 0; i < 60; i++) {
      p.reportSuccess(fast);
    }
    expect(p.currentBytes, 1024 * 1024);
  });

  test('退化解:上界低于默认下限时下界随上界收缩(小粒度定值兼容)', () {
    final p = AimdChunkPolicy(maxBytes: 50);
    expect(p.currentBytes, 50);
    expect(p.minBytes, 50);
    p.reportSuccess(fast); // min(50+32K, 50) = 50
    p.reportError(); // max(25, 50) = 50
    expect(p.currentBytes, 50);
  });

  test('initialBytes 注入钳入界内', () {
    expect(AimdChunkPolicy(initialBytes: 512 * 1024).currentBytes, 512 * 1024);
    expect(AimdChunkPolicy(initialBytes: 99 * 1024 * 1024).currentBytes,
        1024 * 1024); // 越上界钳回
    expect(AimdChunkPolicy(initialBytes: 1).currentBytes, 64 * 1024); // 越下界钳回
  });

  test('快照:toJson/fromJson 往返;restore 续用并钳界', () {
    final p = AimdChunkPolicy();
    for (var i = 0; i < 6; i++) {
      p.reportSuccess(fast); // 升到 256KB
    }
    final snap = p.snapshot;
    expect(snap.currentBytes, 256 * 1024);

    final round = AimdChunkSnapshot.fromJson(snap.toJson());
    expect(round, snap);

    // 新实例从快照续用(会话内交接,不持久化)。
    final p2 = AimdChunkPolicy();
    p2.restore(round);
    expect(p2.currentBytes, 256 * 1024);
    p2.reportSuccess(fast);
    expect(p2.currentBytes, 288 * 1024); // 续升不受影响

    // 越界防御:旧快照超本实例界被钳。
    p2.restore(const AimdChunkSnapshot(999 * 1024 * 1024));
    expect(p2.currentBytes, 1024 * 1024);
    p2.restore(const AimdChunkSnapshot(1));
    expect(p2.currentBytes, 64 * 1024);
  });
}

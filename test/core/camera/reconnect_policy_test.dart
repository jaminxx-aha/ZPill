import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/reconnect_policy.dart';

void main() {
  group('ReconnectPolicy normal 退避', () {
    test('第 0 拍零延迟(立即重试),后续翻倍封顶;jitter=0 确定性节拍', () {
      final policy = ReconnectPolicy(
        baseDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 8),
        jitterRatio: 0,
      );
      expect(policy.nextDelay(ReconnectFailureKind.normal), Duration.zero);
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(milliseconds: 500));
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(seconds: 1));
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(seconds: 2));
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(seconds: 4));
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(seconds: 8));
      expect(policy.nextDelay(ReconnectFailureKind.normal),
          const Duration(seconds: 8), reason: '封顶后恒 maxDelay');
    });

    test('jitter 界内(±30%,夹到 [0, maxDelay])', () {
      final policy = ReconnectPolicy(
        baseDelay: const Duration(milliseconds: 1000),
        maxDelay: const Duration(seconds: 8),
        jitterRatio: 0.30,
        random: Random(7),
      );
      policy.nextDelay(ReconnectFailureKind.normal); // 第 0 拍零延迟
      // 后续 7 拍(1000×2^n 封顶 8000):全部落在 ±30% 内
      final seen = <Duration>[];
      for (var i = 0; i < 7; i++) {
        final d = policy.nextDelay(ReconnectFailureKind.normal)!;
        final base = 1000 * (1 << i);
        final capped = base > 8000 ? 8000 : base;
        expect(d.inMilliseconds,
            inInclusiveRange((capped * 0.7).floor(), (capped * 1.3).ceil()));
        seen.add(d);
      }
      expect(seen.toSet().length, greaterThan(1), reason: '随机源在动(非恒值)');
    });

    test('normal 预算耗尽返 null(终态)', () {
      final policy = ReconnectPolicy(maxAttempts: 3, jitterRatio: 0);
      var delays = 0;
      while (policy.nextDelay(ReconnectFailureKind.normal) != null) {
        delays++;
      }
      expect(delays, 3);
      // 再问仍 null(粘住,直到 resetLedger)
      expect(policy.nextDelay(ReconnectFailureKind.normal), isNull);
    });
  });

  group('busy / cameraAbsent 慢拍', () {
    test('busy 恒 5s、不耗 normal 预算、busyStreak 累计;normal 清 streak',
        () {
      final policy = ReconnectPolicy(jitterRatio: 0);
      for (var i = 0; i < 10; i++) {
        expect(policy.nextDelay(ReconnectFailureKind.busy),
            const Duration(seconds: 5));
      }
      expect(policy.busyStreak, 10);
      // normal 预算分文未动:仍是第 0 拍零延迟
      expect(policy.nextDelay(ReconnectFailureKind.normal), Duration.zero);
      expect(policy.busyStreak, 0, reason: 'normal 拍打断 busy 连击');
    });

    test('cameraAbsent 退避节拍、不耗 normal 预算、独立上限拍后 null', () {
      final policy = ReconnectPolicy(
          absentMaxAttempts: 3, jitterRatio: 0);
      expect(policy.nextDelay(ReconnectFailureKind.cameraAbsent),
          const Duration(milliseconds: 500));
      expect(policy.nextDelay(ReconnectFailureKind.cameraAbsent),
          const Duration(seconds: 1));
      expect(policy.nextDelay(ReconnectFailureKind.cameraAbsent),
          const Duration(seconds: 2));
      expect(policy.nextDelay(ReconnectFailureKind.cameraAbsent), isNull);
      // normal 预算未动
      final fresh = ReconnectPolicy(maxAttempts: 1, jitterRatio: 0);
      fresh.nextDelay(ReconnectFailureKind.cameraAbsent);
      expect(fresh.nextDelay(ReconnectFailureKind.normal), Duration.zero);
    });
  });

  group('风暴账本(DROP)', () {
    final t0 = DateTime(2026, 10, 10, 12);

    test('stormWindow 内 3 次 DROP 粘住暂停', () {
      final policy = ReconnectPolicy(stormWindow: const Duration(seconds: 120));
      policy.noteDrop(t0);
      expect(policy.stormPaused, isFalse);
      policy.noteDrop(t0.add(const Duration(seconds: 60)));
      expect(policy.stormPaused, isFalse);
      policy.noteDrop(t0.add(const Duration(seconds: 119)));
      expect(policy.stormPaused, isTrue);
    });

    test('窗口滑出的旧 DROP 不计', () {
      final policy = ReconnectPolicy(stormWindow: const Duration(seconds: 120));
      policy.noteDrop(t0);
      policy.noteDrop(t0.add(const Duration(seconds: 121))); // 旧的被清
      policy.noteDrop(t0.add(const Duration(seconds: 122)));
      expect(policy.stormPaused, isFalse, reason: '窗内只剩 2 次');
      policy.noteDrop(t0.add(const Duration(seconds: 130)));
      expect(policy.stormPaused, isTrue);
    });

    test('resetLedger 全清(操作员动作口径)', () {
      final policy = ReconnectPolicy(
          stormWindow: const Duration(seconds: 120), maxAttempts: 1);
      policy.nextDelay(ReconnectFailureKind.normal);
      policy.noteDrop(t0);
      policy.noteDrop(t0);
      policy.noteDrop(t0);
      expect(policy.stormPaused, isTrue);
      policy.resetLedger();
      expect(policy.stormPaused, isFalse);
      expect(policy.nextDelay(ReconnectFailureKind.normal), Duration.zero,
          reason: '预算账本同步清零');
      // 风暴后新 DROP 重新起算
      policy.noteDrop(t0);
      expect(policy.stormPaused, isFalse);
    });
  });
}

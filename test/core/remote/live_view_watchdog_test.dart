import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/remote/live_view_watchdog.dart';

void main() {
  final t0 = DateTime(2026, 10, 10, 12);
  final frameA =
      Uint8List.fromList(List.generate(2048, (i) => i & 0xFF));
  final frameB = Uint8List.fromList(
      List.generate(2048, (i) => (i * 7 + 3) & 0xFF));

  group('liveViewFrameSignature', () {
    test('同字节同签名;采样点内单字节差即变;长度折叠', () {
      final a = liveViewFrameSignature(frameA);
      expect(liveViewFrameSignature(frameA), a);
      // 单字节差(恰好落在采样步长 2048/512=4 上必被采到)
      final mutated = Uint8List.fromList(frameA)..[100] ^= 0x01;
      expect(liveViewFrameSignature(mutated), isNot(a));
      // 同内容不同长度:长度折叠进哈希
      final padded = Uint8List.fromList([...frameA, 0x00]);
      expect(liveViewFrameSignature(padded), isNot(a));
      // 长度差落在采样间隙也不漏:两个同尾字节、长度差 1 的帧
      final x = Uint8List.fromList(List.filled(4096, 0xAB));
      final y = Uint8List.fromList([...List.filled(4095, 0xAB), 0xAB, 0xAB]);
      expect(liveViewFrameSignature(x), isNot(liveViewFrameSignature(y)));
    });
  });

  group('LiveViewWatchdog 冻结检测(合成时钟)', () {
    test('新签名 self-heal:一切清零;重复窗口内不报', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4));
      expect(w.inspect(frameA, t0), isNull);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 3))), isNull,
          reason: '未到 repeatTimeout 不判');
      // 新内容:重置后重新起算
      expect(w.inspect(frameB, t0.add(const Duration(seconds: 3, milliseconds: 1))),
          isNull);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 10))), isNull,
          reason: '换回 A 也是新签名序列(首见重新起算)');
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 13))), isNull);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 14))), isNotNull,
          reason: '持续 4s 判冻结');
    });

    test('探测忙 → busyHold:保持不重启,按 busyProbeInterval 复查', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4),
          busyProbeInterval: const Duration(seconds: 2));
      w.inspect(frameA, t0);
      final tFrozen = t0.add(const Duration(seconds: 4, milliseconds: 1));
      expect(w.inspect(frameA, tFrozen), LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: true, now: tFrozen),
          LiveViewWatchdogSignal.busyHold);
      expect(w.frozen(tFrozen), isTrue, reason: '忙保持期仍在冻结态');
      // 1s 后:未到复查节拍,不再探测
      expect(w.inspect(frameA, tFrozen.add(const Duration(seconds: 1))), isNull);
      // 2s 后:复查探测
      expect(w.inspect(frameA, tFrozen.add(const Duration(seconds: 2))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: true, now: tFrozen.add(const Duration(seconds: 2))),
          LiveViewWatchdogSignal.busyHold);
    });

    test('BUSY 保持超窗(busyHoldTimeout)→ busyHoldExpired 真楔死收口', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4),
          busyHoldTimeout: const Duration(seconds: 60));
      w.inspect(frameA, t0);
      final tFrozen = t0.add(const Duration(seconds: 5));
      expect(w.inspect(frameA, tFrozen), LiveViewWatchdogSignal.probe);
      w.noteProbeResult(busy: true, now: tFrozen);
      // 4s 判死 + 59.9s 忙保持:未过窗,仍按复查探测
      final tEdge = t0
          .add(const Duration(seconds: 4))
          .add(const Duration(seconds: 59, milliseconds: 900));
      expect(w.inspect(frameA, tEdge), isNotNull);
      w.noteProbeResult(busy: true, now: tEdge);
      // 过窗:真楔死
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 65))),
          LiveViewWatchdogSignal.busyHoldExpired);
      // 判死清态:签名重新评估
      expect(w.frozen(t0.add(const Duration(seconds: 65))), isFalse);
    });

    test('探测不忙 → 重启礼让:未满窗不动用重启,按节拍复查,满窗才收口', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4),
          busyProbeInterval: const Duration(seconds: 2),
          restartGraceTimeout: const Duration(seconds: 30));
      w.inspect(frameA, t0);
      final tFrozen = t0.add(const Duration(seconds: 5));
      expect(w.inspect(frameA, tFrozen), LiveViewWatchdogSignal.probe);
      expect(w.noteProbeResult(busy: false, now: tFrozen), isNull,
          reason: '进菜单/回放同款冻结且不忙:礼让,不把机身摁回拍摄屏');
      expect(w.frozen(tFrozen), isTrue, reason: '礼让期仍在冻结态');
      // 节拍内(1s)不复查;满节拍(2s)再探,仍未满窗 → 继续礼让
      expect(
          w.inspect(frameA, tFrozen.add(const Duration(seconds: 1))), isNull);
      expect(w.inspect(frameA, tFrozen.add(const Duration(seconds: 2))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(
              busy: false, now: tFrozen.add(const Duration(seconds: 2))),
          isNull);
      // 冻结满 30s(礼让窗)复查仍不忙 → 动用重启;判死后签名重新评估
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 31))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: false, now: t0.add(const Duration(seconds: 31))),
          LiveViewWatchdogSignal.restart);
      expect(w.frozen(t0.add(const Duration(seconds: 31))), isFalse);
    });

    test('礼让期内新帧到达 → 自我纠错一切清零,旧判决不压新序列', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4),
          restartGraceTimeout: const Duration(seconds: 30));
      w.inspect(frameA, t0);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 5))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: false, now: t0.add(const Duration(seconds: 5))),
          isNull);
      // 礼让等待期机身自己恢复(如退出菜单回拍摄屏):新签名清零
      expect(w.inspect(frameB, t0.add(const Duration(seconds: 10))), isNull);
      expect(w.frozen(t0.add(const Duration(seconds: 10))), isFalse);
      // 同帧再重放:从首见重新起算,另起一案
      expect(w.inspect(frameB, t0.add(const Duration(seconds: 13))), isNull);
      expect(w.inspect(frameB, t0.add(const Duration(seconds: 15))), isNotNull,
          reason: '重新判冻另起一案');
    });

    test('忙保持期内转不忙:未满礼让窗不重启(继续忙保持口径),满窗收口', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4),
          busyHoldTimeout: const Duration(seconds: 60),
          busyProbeInterval: const Duration(seconds: 2),
          restartGraceTimeout: const Duration(seconds: 30));
      w.inspect(frameA, t0);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 5))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: true, now: t0.add(const Duration(seconds: 5))),
          LiveViewWatchdogSignal.busyHold);
      // 忙保持中复查转不忙,但冻结仅 10s(< 礼让窗)→ 礼让,不重启
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 10))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: false, now: t0.add(const Duration(seconds: 10))),
          isNull);
      // 满礼让窗(30s)复查仍不忙 → 重启
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 31))),
          LiveViewWatchdogSignal.probe);
      expect(
          w.noteProbeResult(busy: false, now: t0.add(const Duration(seconds: 31))),
          LiveViewWatchdogSignal.restart);
    });

    test('重启预算:窗口内 3 次耗尽;窗口滑出不累', () {
      final w = LiveViewWatchdog(maxRestarts: 3,
          restartWindow: const Duration(minutes: 5));
      w.noteRestarted(t0);
      w.noteRestarted(t0.add(const Duration(minutes: 1)));
      expect(w.restartBudgetExhausted, isFalse);
      w.noteRestarted(t0.add(const Duration(minutes: 2)));
      expect(w.restartBudgetExhausted, isTrue);
      // 静默 7 分钟后再次重启:0/1 分双双滑出窗(>5min),窗内只剩
      // 2/7 两次 → 预算回充不耗尽
      w.noteRestarted(t0.add(const Duration(minutes: 7)));
      expect(w.restartBudgetExhausted, isFalse);
    });

    test('reset 全清(stop/start/新连接口径)', () {
      final w = LiveViewWatchdog(
          repeatTimeout: const Duration(seconds: 4));
      w.inspect(frameA, t0);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 5))),
          LiveViewWatchdogSignal.probe);
      w.noteRestarted(t0);
      w.reset();
      expect(w.restartBudgetExhausted, isFalse);
      expect(w.frozen(t0), isFalse);
      // reset 后同一帧序列从头评估(首见重新起算)
      expect(w.inspect(frameA, t0), isNull);
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 3))), isNull,
          reason: '4s 窗口从 reset 后重新起算');
      expect(w.inspect(frameA, t0.add(const Duration(seconds: 4))),
          isNotNull);
    });
  });
}

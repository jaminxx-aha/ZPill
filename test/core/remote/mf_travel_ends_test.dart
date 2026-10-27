import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/remote/mf_travel_ends.dart';

void main() {
  group('MfTravelEnds 端点状态机(nico MfDriveResult 语义)', () {
    test('方向归因:0xA00C 按当次请求方向置本向旗、清反向旗', () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: true, outcome: MfDriveOutcome.endOfTravel);
      expect(ends.nearEnd, isTrue, reason: '向近请求 0xA00C → 近端已到');
      expect(ends.farEnd, isFalse, reason: '镜头不可能同时顶在两端');

      ends.apply(towardNear: false, outcome: MfDriveOutcome.endOfTravel);
      expect(ends.nearEnd, isFalse, reason: '向远 0xA00C 覆盖近端旗');
      expect(ends.farEnd, isTrue);
    });

    test('反转解锁:反向请求即清对应旗(nico 靠驱动成功双清,本仓提前到'
        '请求沿),且不误置对向旗', () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: true, outcome: MfDriveOutcome.endOfTravel);
      ends.noteDrive(false); // 反向(向远)请求:近端旗作废
      expect(ends.nearEnd, isFalse, reason: '反向请求解锁近端');
      expect(ends.farEnd, isFalse, reason: 'noteDrive 只清不置');

      ends.apply(towardNear: false, outcome: MfDriveOutcome.endOfTravel);
      ends.noteDrive(true); // 反向(向近)请求:远端旗作废
      expect(ends.farEnd, isFalse, reason: '反向请求解锁远端');
      expect(ends.nearEnd, isFalse);
    });

    test('反转解锁先于结果落账:0xA00E(镜头未动)不清反向旗外的东西'
        ' —— 已解锁旗不复活', () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: true, outcome: MfDriveOutcome.endOfTravel);
      ends.noteDrive(false); // 解锁近端
      // 反向请求步进过小(镜头未动):端点态不变 —— 近端已解锁不复活。
      ends.apply(towardNear: false, outcome: MfDriveOutcome.stepTooSmall);
      expect(ends.nearEnd, isFalse);
      expect(ends.farEnd, isFalse);
    });

    test('两端独立:近端旗不牵连远端方向的可用性(旗各自记账)', () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: true, outcome: MfDriveOutcome.endOfTravel);
      expect(ends.nearEnd, isTrue);
      // 远端从未被归因:旗恒 false;向远请求只清近端旗,不置远端旗。
      ends.noteDrive(false);
      expect(ends.farEnd, isFalse);
      expect(ends.anyEnd, isFalse, reason: '近端已解锁后无端点态');
    });

    test('驱动成功双清(nico MOVED);0xA00E/拒答不动旗(nico NO_MOVE)',
        () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: true, outcome: MfDriveOutcome.endOfTravel);
      ends.apply(towardNear: true, outcome: MfDriveOutcome.stepTooSmall);
      expect(ends.nearEnd, isTrue, reason: '0xA00E 镜头未动,旗保留');
      ends.apply(towardNear: true, outcome: MfDriveOutcome.refused);
      expect(ends.nearEnd, isTrue, reason: '链路类拒答不动旗');

      ends.apply(towardNear: false, outcome: MfDriveOutcome.complete);
      expect(ends.anyEnd, isFalse, reason: '镜头动了:双清');
    });

    test('clear:AF 移焦后端点态整体作废(nico clearMfLimits)', () {
      final ends = MfTravelEnds();
      ends.apply(towardNear: false, outcome: MfDriveOutcome.endOfTravel);
      expect(ends.farEnd, isTrue);
      ends.clear();
      expect(ends.anyEnd, isFalse);
    });
  });
}

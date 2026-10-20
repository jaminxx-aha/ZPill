import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/features/remote/bulb_close_policy.dart';

/// B 门收门策略(纯值类 + 合成时钟口径:只产出延迟,零真实挂钟 ——
/// 仓内 ReconnectPolicy 同款先例形态)。退避序列/预算/忙等码集全覆盖。
void main() {
  group('BulbClosePolicy', () {
    test('退避序列:500ms 起步指数翻倍,3 拍后预算耗尽(null)', () {
      final p = BulbClosePolicy();
      expect(p.exhausted, isFalse);
      expect(p.nextBusyDelay(), const Duration(milliseconds: 500));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 1000));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 2000));
      expect(p.nextBusyDelay(), isNull, reason: '预算耗尽 = 终态');
      expect(p.exhausted, isTrue);
      expect(p.nextBusyDelay(), isNull, reason: '耗尽后恒 null(粘住)');
      expect(p.busyFailures, 3);
    });

    test('封顶:指数超过 maxDelay 后恒 maxDelay(预算 5 拍验证)', () {
      final p = BulbClosePolicy(maxBusyRetries: 5);
      expect(p.nextBusyDelay(), const Duration(milliseconds: 500));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 1000));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 2000));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 2000),
          reason: '4000ms 封顶回 2000ms');
      expect(p.nextBusyDelay(), const Duration(milliseconds: 2000));
      expect(p.nextBusyDelay(), isNull);
    });

    test('自定义起点:baseDelay 注入(真机标定只改构造默认值)', () {
      final p = BulbClosePolicy(
          maxBusyRetries: 2,
          baseDelay: const Duration(milliseconds: 250),
          maxDelay: const Duration(seconds: 1));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 250));
      expect(p.nextBusyDelay(), const Duration(milliseconds: 500));
      expect(p.nextBusyDelay(), isNull);
    });

    test('忙等码集:0x2019/0xA200/0xA201 可重试;其余(含 0xA202 录像'
        '静照族、0x2005 不支持、0x201D 参数域)不重试', () {
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.deviceBusy), isTrue);
      expect(BulbClosePolicy.isBusyCode(NikonResponseCode.bulbReleaseBusy),
          isTrue);
      expect(BulbClosePolicy.isBusyCode(NikonResponseCode.silentReleaseBusy),
          isTrue);
      // 0xA202 MovieFrame_Release_Busy:录像中静照族,收门链不对录像态
      // 重试(官方 MTP 规格书定名:与拨杆拒不同族)。
      expect(
          BulbClosePolicy.isBusyCode(NikonResponseCode.movieFrameReleaseBusy),
          isFalse);
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.generalError), isFalse);
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.operationNotSupported),
          isFalse);
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.invalidParameter),
          isFalse);
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.accessDenied), isFalse);
      expect(BulbClosePolicy.isBusyCode(PtpResponseCode.ok), isFalse);
    });
  });
}

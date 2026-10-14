/// B 门收门策略(纯值类,2026-10-15 收门鲁棒性强化)。
///
/// 结构借鉴 N-link BulbPolicy(该仓无 LICENSE,只借链路结构不搬码):
/// 收门链 = [恢复原快门值(应用写过 Bulb/Time 哨兵时)] →
/// 0x920C TerminateCapture → 忙等码有界指数退避重试。其两处步骤
/// **不采纳**:① 0x1010 TerminateOpenCapture 降级步 —— 它服务于其
/// 0x100F OpenCapture 开拍路径,本仓开拍走 0x9207 InitiateCaptureRecInMedia,
/// 官方 §2.8.4 B 门序列的配套收门即 0x920C,无该路径;② 「改快门值
/// 即结束曝光」作为收门机制 —— 与 TODO 已证口径(抬起 0x920C 结束)
/// 冲突,恢复快门值在本仓只作收门链的还原步,不承担终止语义。
///
/// 忙等码集 =「稍等即可恢复」(官方定名见 TODO「二·b」):0x2019
/// DeviceBusy(标准)/ 0xA200 Bulb_Release_Busy / 0xA201
/// Silent_Release_Busy。0xA202 MovieFrame_Release_Busy(录像中静照)
/// 不列 —— 不同族,收门链不对录像态重试。非忙码不重试:0x920C 对已
/// 自行结束的运行被拒是预期形态(调用方容忍)。
///
/// 退避:500ms 起步指数翻倍、封顶 [maxDelay],共 [maxBusyRetries] 次
/// 重试预算(默认总窗 ≈3.5s;起步值借 N-link 口径,verify-on-HW ——
/// 真机标定后只改构造默认值,不动结构)。时钟零依赖:只产出延迟,
/// 睡眠由调用方注入的 delay 执行(仓内 ReconnectPolicy 同款口径,
/// 单测零真实挂钟)。
library;

import '../../core/ptp/operation_codes.dart';

final class BulbClosePolicy {
  BulbClosePolicy({
    this.maxBusyRetries = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(milliseconds: 2000),
  });

  /// 忙等码重试预算(首次失败后最多再发 [maxBusyRetries] 次)。
  final int maxBusyRetries;

  final Duration baseDelay;

  final Duration maxDelay;

  int _busyFailures = 0;

  /// 已消耗的忙等拍数(诊断/测试)。
  int get busyFailures => _busyFailures;

  /// 预算是否已耗尽(终态,调用方如实上报)。
  bool get exhausted => _busyFailures >= maxBusyRetries;

  /// [code] 是否忙等码(可退避重试)。
  static bool isBusyCode(int code) =>
      code == PtpResponseCode.deviceBusy ||
      code == NikonResponseCode.bulbReleaseBusy ||
      code == NikonResponseCode.silentReleaseBusy;

  /// 忙等一拍后取下一拍延迟;null = 预算耗尽。
  Duration? nextBusyDelay() {
    if (_busyFailures >= maxBusyRetries) return null;
    final attempt = ++_busyFailures; // 1..maxBusyRetries
    final ms = baseDelay.inMilliseconds << (attempt - 1);
    return Duration(
        milliseconds:
            ms < maxDelay.inMilliseconds ? ms : maxDelay.inMilliseconds);
  }
}

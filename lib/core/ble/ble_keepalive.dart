/// BLE 保活与 GEO 去重策略(纯 Dart 可测单元:零 Timer、零平台依赖,
/// 时钟与写入由持有方 [BleCameraSession] 注入驱动)。
///
/// 相机 2min 无 BLE 流量即掐链(HarmoNiLink 实证口径,借思路不搬码):
/// 其 TIME 保活 ticker 前台 1.5s/后台 5s —— GPS 常驻需求故激进。我方
/// 保守降频:前台 45s/后台 90s(均 <120s 断链阈值留裕量),写 0x2006
/// TIME 内容=当前时刻,顺带持续校时。
///
/// 本单元只做「到点/过门」判定与档位持有,不起 Timer ——「连接建立
/// 起拍、断链停」落在会话状态机上(非 ready 态会话 tick 零动作),由
/// 会话的 tick/onFix 外部驱动。测试注入假时钟即可快进档位与到点,
/// 不真等 45s。
///
/// GEO 去重门与 HarmoNiLink 同构:距上次成功注入 <3s 且位移 <1.1m 才
/// 跳过(两者须同时不足;≥3s 或 ≥1.1m 即发)。阈值借 HarmoNiLink 口径,
/// 真机标定待。
library;

import 'dart:math';

import 'geo_payload.dart';

final class BleKeepalive {
  /// 前台保活间隔(<120s 断链阈值留裕量)。
  static const Duration foregroundInterval = Duration(seconds: 45);

  /// 后台保活间隔。
  static const Duration backgroundInterval = Duration(seconds: 90);

  /// GEO 去重门时间阈:距上次成功注入不足此值且位移不足
  /// [geoDedupDistanceM] 才跳过(真机标定待)。
  static const Duration geoDedupInterval = Duration(seconds: 3);

  /// GEO 去重门位移阈(米;真机标定待)。
  static const double geoDedupDistanceM = 1.1;

  bool _foreground = true;

  /// 档位缺省前台;上层生命周期观察注入(切档只改下一拍到点判定,
  /// 不立即补写)。
  bool get isForeground => _foreground;
  set foreground(bool value) => _foreground = value;

  /// 当前档位保活间隔。
  Duration get interval =>
      _foreground ? foregroundInterval : backgroundInterval;

  /// TIME 是否到点:Ready 后首笔([lastOkAt] 空,含收口校时)恒到点;
  /// 此后距上次成功写 ≥ 当前档位间隔。
  bool timeDue(DateTime now, DateTime? lastOkAt) =>
      lastOkAt == null || now.difference(lastOkAt) >= interval;

  /// GEO 是否过去重门:无成功记录(首笔)恒过;距上次成功注入
  /// ≥[geoDedupInterval] 或位移 ≥[geoDedupDistanceM] 即过。
  bool geoPassesDedup(
      DateTime now, GeoFix fix, GeoFix? lastOk, DateTime? lastOkAt) {
    if (lastOk == null || lastOkAt == null) return true;
    return now.difference(lastOkAt) >= geoDedupInterval ||
        distanceM(lastOk, fix) >= geoDedupDistanceM;
  }

  /// 球面距离(米;haversine,去重门精度足够)。
  static double distanceM(GeoFix a, GeoFix b) {
    const r = 6371000.0;
    double rad(double d) => d * pi / 180;
    final dLat = rad(b.latitude - a.latitude);
    final dLon = rad(b.longitude - a.longitude);
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(rad(a.latitude)) *
            cos(rad(b.latitude)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return 2 * r * atan2(sqrt(h), sqrt(1 - h));
  }
}

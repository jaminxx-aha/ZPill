import 'package:flutter/foundation.dart';

import '../../data/settings_store.dart';

/// 监看开关组(2026-10-12 十二轮起入持久化设置:AppSettings
/// monitor* 七字段,经 [monitorTogglesFromSettings]/[applyMonitorToggles]
/// 桥接拆装;此前是页面级会话态,重进拍摄页即丢)。斑马纹/直方图/
/// 伪色/峰值四项共享同一份帧分析 —— 开关落定后由页面同步
/// RemoteController.analyzer 启停(见 RemotePage._syncAnalyzerEnabled)。
@immutable
class MonitorToggles {
  const MonitorToggles({
    this.grid = false,
    this.zebra = false,
    this.histogram = false,
    this.level = false,
    this.falseColor = false,
    this.peaking = false,
    this.focusDial = false,
  });

  final bool grid;
  final bool zebra;
  final bool histogram;
  final bool level;
  final bool falseColor;
  final bool peaking;

  /// 屏上对焦滚轮(取景画面右缘竖条,拖动 = 0x9204 连续拉焦)。
  final bool focusDial;

  MonitorToggles copyWith({
    bool? grid,
    bool? zebra,
    bool? histogram,
    bool? level,
    bool? falseColor,
    bool? peaking,
    bool? focusDial,
  }) =>
      MonitorToggles(
        grid: grid ?? this.grid,
        zebra: zebra ?? this.zebra,
        histogram: histogram ?? this.histogram,
        level: level ?? this.level,
        falseColor: falseColor ?? this.falseColor,
        peaking: peaking ?? this.peaking,
        focusDial: focusDial ?? this.focusDial,
      );

  // 值相等:设置监听沿用它做「外部改了设置 → 是否真变」的差分
  // (AppSettings 有 ==,桥接后两边可互相对账)。
  @override
  bool operator ==(Object other) =>
      other is MonitorToggles &&
      other.grid == grid &&
      other.zebra == zebra &&
      other.histogram == histogram &&
      other.level == level &&
      other.falseColor == falseColor &&
      other.peaking == peaking &&
      other.focusDial == focusDial;

  @override
  int get hashCode => Object.hash(
      grid, zebra, histogram, level, falseColor, peaking, focusDial);
}

/// [AppSettings] → 页面开关组:进页/设置变更沿对账用。
MonitorToggles monitorTogglesFromSettings(AppSettings s) => MonitorToggles(
    grid: s.monitorGrid,
    zebra: s.monitorZebra,
    histogram: s.monitorHistogram,
    level: s.monitorLevel,
    falseColor: s.monitorFalseColor,
    peaking: s.monitorPeaking,
    focusDial: s.monitorFocusDial);

/// 页面开关组 → 写回 [AppSettings](其余字段原样保留,由 copyWith 带)。
AppSettings applyMonitorToggles(AppSettings s, MonitorToggles t) =>
    s.copyWith(
        monitorGrid: t.grid,
        monitorZebra: t.zebra,
        monitorHistogram: t.histogram,
        monitorLevel: t.level,
        monitorFalseColor: t.falseColor,
        monitorPeaking: t.peaking,
        monitorFocusDial: t.focusDial);

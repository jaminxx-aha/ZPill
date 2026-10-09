import 'package:flutter/foundation.dart';

/// 监看开关组(页面级视图偏好,不入持久化设置)。斑马纹/直方图/
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
}

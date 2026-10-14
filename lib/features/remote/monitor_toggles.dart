import 'package:flutter/foundation.dart';

import '../../core/media/cube_lut.dart';
import '../../data/settings_store.dart';
import '../edit/lut_presets.dart';

/// 监看开关组(2026-10-12 十二轮起入持久化设置:AppSettings monitor*
/// 字段族,经 [monitorTogglesFromSettings]/[applyMonitorToggles]
/// 桥接拆装;此前是页面级会话态,重进拍摄页即丢)。
///
/// 斑马纹/直方图/伪色/峰值/波形五项共享同一份帧分析 —— 开关落定后由
/// 页面同步 RemoteController.analyzer 启停(见 RemotePage
/// ._syncAnalyzerEnabled)。构图框三件与 LUT 索引是纯显示层,不占
/// 分析器。
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
    this.framingAspect = FramingAspect.off,
    this.framingSafeArea = false,
    this.framingCenterMark = false,
    this.waveform = false,
    this.lutIndex = -1,
  });

  final bool grid;
  final bool zebra;
  final bool histogram;
  final bool level;
  final bool falseColor;
  final bool peaking;

  /// 屏上对焦滚轮(取景画面右缘竖条,拖动 = 0x9204 连续拉焦)。
  final bool focusDial;

  /// 构图遮幅画幅(2.39/2.35/1.85;off = 关)。
  final FramingAspect framingAspect;

  /// 安全框(门框内 5%/10% 内缩双矩形)。
  final bool framingSafeArea;

  /// 中心标(十字 + 圆环)。
  final bool framingCenterMark;

  /// 波形示波器(屏幕坐标层,直方图上方)。
  final bool waveform;

  /// 监看 LUT 索引(-1 = 关;0..n = [builtinLuts] 表序,越界按关)。
  final int lutIndex;

  MonitorToggles copyWith({
    bool? grid,
    bool? zebra,
    bool? histogram,
    bool? level,
    bool? falseColor,
    bool? peaking,
    bool? focusDial,
    FramingAspect? framingAspect,
    bool? framingSafeArea,
    bool? framingCenterMark,
    bool? waveform,
    int? lutIndex,
  }) =>
      MonitorToggles(
        grid: grid ?? this.grid,
        zebra: zebra ?? this.zebra,
        histogram: histogram ?? this.histogram,
        level: level ?? this.level,
        falseColor: falseColor ?? this.falseColor,
        peaking: peaking ?? this.peaking,
        focusDial: focusDial ?? this.focusDial,
        framingAspect: framingAspect ?? this.framingAspect,
        framingSafeArea: framingSafeArea ?? this.framingSafeArea,
        framingCenterMark: framingCenterMark ?? this.framingCenterMark,
        waveform: waveform ?? this.waveform,
        lutIndex: lutIndex ?? this.lutIndex,
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
      other.focusDial == focusDial &&
      other.framingAspect == framingAspect &&
      other.framingSafeArea == framingSafeArea &&
      other.framingCenterMark == framingCenterMark &&
      other.waveform == waveform &&
      other.lutIndex == lutIndex;

  @override
  int get hashCode => Object.hash(
      grid,
      zebra,
      histogram,
      level,
      falseColor,
      peaking,
      focusDial,
      framingAspect,
      framingSafeArea,
      framingCenterMark,
      waveform,
      lutIndex);
}

/// [AppSettings] → 页面开关组:进页/设置变更沿对账用。
MonitorToggles monitorTogglesFromSettings(AppSettings s) => MonitorToggles(
    grid: s.monitorGrid,
    zebra: s.monitorZebra,
    histogram: s.monitorHistogram,
    level: s.monitorLevel,
    falseColor: s.monitorFalseColor,
    peaking: s.monitorPeaking,
    focusDial: s.monitorFocusDial,
    framingAspect: s.framingAspect,
    framingSafeArea: s.framingSafeArea,
    framingCenterMark: s.framingCenterMark,
    waveform: s.monitorWaveform,
    lutIndex: s.monitorLutIndex);

/// 页面开关组 → 写回 [AppSettings](其余字段原样保留,由 copyWith 带)。
AppSettings applyMonitorToggles(AppSettings s, MonitorToggles t) =>
    s.copyWith(
        monitorGrid: t.grid,
        monitorZebra: t.zebra,
        monitorHistogram: t.histogram,
        monitorLevel: t.level,
        monitorFalseColor: t.falseColor,
        monitorPeaking: t.peaking,
        monitorFocusDial: t.focusDial,
        framingAspect: t.framingAspect,
        framingSafeArea: t.framingSafeArea,
        framingCenterMark: t.framingCenterMark,
        monitorWaveform: t.waveform,
        monitorLutIndex: t.lutIndex);

/// 当前监看 LUT(设置索引 → 内置风格表):表外/越界索引 = null = 关
/// (旧档/手改文件不做范围钳制,消费侧按关,面板芯片亦无选中态)。
CubeLut? monitorLutOf(AppSettings s) {
  final i = s.monitorLutIndex;
  if (i < 0 || i >= builtinLuts.length) return null;
  return builtinLuts[i];
}

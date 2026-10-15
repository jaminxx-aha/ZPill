import 'package:flutter/foundation.dart';

import '../../core/media/cube_lut.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/peaking_engines.dart';
import '../../data/settings_store.dart';
import '../edit/lut_presets.dart';

/// 示波器档(2026-10-15 示波器族):关 / 波形 / RGB Parade / 矢量 /
/// 红绿灯,面板芯片循环切换(遮幅同款);持久化为设置索引
/// ([AppSettings.monitorScope])。四示波器共享一份帧分析,与直方图
/// 可同开(左下同锚,示波器上移让位)。
enum ScopeKind { off, waveform, parade, vector, traffic }

extension ScopeKindX on ScopeKind {
  /// 循环下一档(off → 波形 → RGB → 矢量 → 红绿灯 → off)。
  ScopeKind get next =>
      ScopeKind.values[(index + 1) % ScopeKind.values.length];
}

/// 设置索引 → 示波器档:表外值(负数/手改文件)回落关。
ScopeKind scopeKindOf(int index) =>
    index >= 0 && index < ScopeKind.values.length
        ? ScopeKind.values[index]
        : ScopeKind.off;

/// 监看开关组(2026-10-12 十二轮起入持久化设置:AppSettings monitor*
/// 字段族,经 [monitorTogglesFromSettings]/[applyMonitorToggles]
/// 桥接拆装;此前是页面级会话态,重进拍摄页即丢)。
///
/// 斑马纹/直方图/伪色/峰值/示波器共享同一份帧分析 —— 开关落定后由
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
    this.peakingLevel = 1,
    this.peakingColor = 0,
    this.peakingEngine = 0,
    this.focusDial = false,
    this.framingAspect = FramingAspect.off,
    this.framingSafeArea = false,
    this.framingCenterMark = false,
    this.scope = ScopeKind.off,
    this.scopeNLog = false,
    this.lutIndex = -1,
  });

  final bool grid;
  final bool zebra;
  final bool histogram;
  final bool level;
  final bool falseColor;
  final bool peaking;

  /// 峰值灵敏度档(0=低/1=中/2=高;默认中 = 旧行为,映射见
  /// [monitorPeakingThresholdOf])。
  final int peakingLevel;

  /// 峰值高亮色档(0=金/1=白/2=红;默认金 = 旧行为,取色见
  /// live_view_overlays.dart 的 peakingColorOf)。
  final int peakingColor;

  /// 峰值算法档(0=双尺度比值,默认;1=经典单尺度梯度,回退):
  /// 引擎取值见 [peakingEngineOf],算法见 core/remote/peaking_engines.dart。
  final int peakingEngine;

  /// 屏上对焦滚轮(取景画面右缘竖条,拖动 = 0x9204 连续拉焦)。
  final bool focusDial;

  /// 构图遮幅画幅(2.39/2.35/1.85;off = 关)。
  final FramingAspect framingAspect;

  /// 安全框(门框内 5%/10% 内缩双矩形)。
  final bool framingSafeArea;

  /// 中心标(十字 + 圆环)。
  final bool framingCenterMark;

  /// 示波器档(波形/RGB Parade/矢量/红绿灯四选一;off = 关)。
  final ScopeKind scope;

  /// 示波器 Y 轴 N-Log 刻度(仅波形/Parade 消费):**手动档,常闭** ——
  /// 相机 N-Log 态(0xD0BB 只读,D0Bx 族不推事件须轮询)的自动跟随
  /// 留账,数学见 core/remote/scopes.dart。
  final bool scopeNLog;

  /// 监看 LUT 索引(-1 = 关;0..n = [builtinLuts] 表序,越界按关)。
  final int lutIndex;

  MonitorToggles copyWith({
    bool? grid,
    bool? zebra,
    bool? histogram,
    bool? level,
    bool? falseColor,
    bool? peaking,
    int? peakingLevel,
    int? peakingColor,
    int? peakingEngine,
    bool? focusDial,
    FramingAspect? framingAspect,
    bool? framingSafeArea,
    bool? framingCenterMark,
    ScopeKind? scope,
    bool? scopeNLog,
    int? lutIndex,
  }) =>
      MonitorToggles(
        grid: grid ?? this.grid,
        zebra: zebra ?? this.zebra,
        histogram: histogram ?? this.histogram,
        level: level ?? this.level,
        falseColor: falseColor ?? this.falseColor,
        peaking: peaking ?? this.peaking,
        peakingLevel: peakingLevel ?? this.peakingLevel,
        peakingColor: peakingColor ?? this.peakingColor,
        peakingEngine: peakingEngine ?? this.peakingEngine,
        focusDial: focusDial ?? this.focusDial,
        framingAspect: framingAspect ?? this.framingAspect,
        framingSafeArea: framingSafeArea ?? this.framingSafeArea,
        framingCenterMark: framingCenterMark ?? this.framingCenterMark,
        scope: scope ?? this.scope,
        scopeNLog: scopeNLog ?? this.scopeNLog,
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
      other.peakingLevel == peakingLevel &&
      other.peakingColor == peakingColor &&
      other.peakingEngine == peakingEngine &&
      other.focusDial == focusDial &&
      other.framingAspect == framingAspect &&
      other.framingSafeArea == framingSafeArea &&
      other.framingCenterMark == framingCenterMark &&
      other.scope == scope &&
      other.scopeNLog == scopeNLog &&
      other.lutIndex == lutIndex;

  @override
  int get hashCode => Object.hash(
      grid,
      zebra,
      histogram,
      level,
      falseColor,
      peaking,
      peakingLevel,
      peakingColor,
      peakingEngine,
      focusDial,
      framingAspect,
      framingSafeArea,
      framingCenterMark,
      scope,
      scopeNLog,
      lutIndex);
}

/// [AppSettings] → 页面开关组:进页/设置变更沿对账用。
///
/// 示波器迁移:2026-10-15 前的旧档只有 [AppSettings.monitorWaveform]
/// 布尔(波形一件);scope 缺省 off 且旧波形开关开 → 升格为波形档
/// (写回沿 applyMonitorToggles 会把 monitorScope 一并落盘,迁移
/// 一次性收敛)。
MonitorToggles monitorTogglesFromSettings(AppSettings s) {
  final legacyWaveform =
      s.monitorWaveform && s.monitorScope == ScopeKind.off.index;
  return MonitorToggles(
    grid: s.monitorGrid,
    zebra: s.monitorZebra,
    histogram: s.monitorHistogram,
    level: s.monitorLevel,
    falseColor: s.monitorFalseColor,
    peaking: s.monitorPeaking,
    peakingLevel: s.monitorPeakingLevel,
    peakingColor: s.monitorPeakingColor,
    peakingEngine: s.monitorPeakingEngine,
    focusDial: s.monitorFocusDial,
    framingAspect: s.framingAspect,
    framingSafeArea: s.framingSafeArea,
    framingCenterMark: s.framingCenterMark,
    scope: legacyWaveform ? ScopeKind.waveform : scopeKindOf(s.monitorScope),
    scopeNLog: s.monitorScopeNLog,
    lutIndex: s.monitorLutIndex);
}

/// 页面开关组 → 写回 [AppSettings](其余字段原样保留,由 copyWith 带)。
/// [AppSettings.monitorWaveform] 旧字段随 scope 保连贯
/// (= scope == 波形档),与读侧迁移互逆。
AppSettings applyMonitorToggles(AppSettings s, MonitorToggles t) =>
    s.copyWith(
        monitorGrid: t.grid,
        monitorZebra: t.zebra,
        monitorHistogram: t.histogram,
        monitorLevel: t.level,
        monitorFalseColor: t.falseColor,
        monitorPeaking: t.peaking,
        monitorPeakingLevel: t.peakingLevel,
        monitorPeakingColor: t.peakingColor,
        monitorPeakingEngine: t.peakingEngine,
        monitorFocusDial: t.focusDial,
        framingAspect: t.framingAspect,
        framingSafeArea: t.framingSafeArea,
        framingCenterMark: t.framingCenterMark,
        monitorScope: t.scope.index,
        monitorWaveform: t.scope == ScopeKind.waveform,
        monitorScopeNLog: t.scopeNLog,
        monitorLutIndex: t.lutIndex);

/// 峰值灵敏度档 → 相邻峰格亮度梯度阈值(0-255)。**调优档非协议常量**:
/// 低 24(微细纹理也圈,弱光噪点下偏多报)/ 中 40(旧写死值,默认档)/
/// 高 64(只圈最陡边缘);表外档回落中档(手改文件/旧档的兜底口径)。
int monitorPeakingThresholdOf(int level) => switch (level) {
      0 => 24,
      2 => 64,
      _ => FrameAnalysis.peakingGradientThreshold,
    };

/// 峰值算法档 → 引擎:0 = 双尺度比值(默认,散景/失焦不亮)/
/// 1 = 经典单尺度梯度(2026-10-14 前唯一路径,手感回退);表外档
/// 回落双尺度(旧档/手改文件兜底)。
PeakingEngine peakingEngineOf(int tier) =>
    tier == 1 ? PeakingEngine.gradient : PeakingEngine.dualScale;

/// 当前监看 LUT(设置索引 → 内置风格表):表外/越界索引 = null = 关
/// (旧档/手改文件不做范围钳制,消费侧按关,面板芯片亦无选中态)。
CubeLut? monitorLutOf(AppSettings s) {
  final i = s.monitorLutIndex;
  if (i < 0 || i >= builtinLuts.length) return null;
  return builtinLuts[i];
}

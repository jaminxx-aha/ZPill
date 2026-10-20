/// 示波器族纯计算(监看差集,2026-10-15):RGB Parade /
/// 矢量 CbCr / 红绿灯三横带 + N-Log ExposureScale 刻度数学。
///
/// 语义参考 OpenZCine(Apache-2.0;Sources/OpenZCineCore 的
/// ScopeSampler / TrafficLightsMeter / ExposureScale.swift 与
/// ScopeDisplayScale.swift —— 算法语义借鉴,Dart 重写非逐行搬运)。
/// 波形(列-亮度桶密度)已在 frame_analysis.dart,本件补齐示波器族
/// 其余三件的**数学与派生**;数据积累挂 [analyzeJpegFrame] 的采样环
/// (与直方图/波形同一批采样、共享 FrameAnalyzer 的 everyNth 节流,
/// 不另起 Timer)。纯 Dart,链路/UI 无关可测。
///
/// N-Log 说明:还原传输函数(码值 → 反射率)在 features/edit/
/// lut_presets.dart 的 _nLogToLinear,本件**不重复**;此处只放刻度
/// 换算(legal-range IRE、真黑→白归一)与官方锚点常量。相机 N-Log
/// 态(0xD0BB,只读)在监看会话的自动跟随**留账** —— D0Bx 族不推
/// 0x4006 事件、须主动轮询,当前按手动开关消费(monitorScopeNLog)。
library;

import 'dart:typed_data';

// ── 红绿灯:画面三横带(上/中/下)欠曝/合式/过曝 ─────────────────────

/// 单横带的灯态:欠曝(底脊)/ 合式 / 过曝(削顶)。
enum ScopeTrafficState { under, ok, over }

/// 欠曝判定线:8-bit 合法黑(SMPTE studio-swing 黑 16)—— 低于它的
/// 采样 = 黑下(挤压/黑位裁切)。
const int scopeTrafficUnderLuma = 16;

/// 过曝判定线:与斑马纹同阈值(luma ≥ 250 = 削顶,同一帧分析口径)。
const int scopeTrafficOverLuma = 250;

/// 单带点灯阈值:带内欠/过曝采样占比须**超过**该分数才判欠/过
/// (OpenZCine TrafficLights 缺省 0.10)。
const double scopeTrafficFractionThreshold = 0.10;

/// 一条横带的采样计数与读数(纯数据,派生属性惰性算)。
final class ScopeTrafficBand {
  const ScopeTrafficBand({
    required this.under,
    required this.ok,
    required this.over,
  });

  /// 欠(< [scopeTrafficUnderLuma])/ 合式 / 过(≥ [scopeTrafficOverLuma])
  /// 的采样像素数。
  final int under;
  final int ok;
  final int over;

  int get samples => under + ok + over;

  double get underFraction => samples > 0 ? under / samples : 0;
  double get okFraction => samples > 0 ? ok / samples : 0;
  double get overFraction => samples > 0 ? over / samples : 0;

  /// 灯态:过曝优先于欠曝(削顶不可救,同带双超先看过)—— 两侧都
  /// 不超阈值即合式;无采样(空带)按合式(不误报)。
  ScopeTrafficState get state {
    if (samples == 0) return ScopeTrafficState.ok;
    if (overFraction > scopeTrafficFractionThreshold) {
      return ScopeTrafficState.over;
    }
    if (underFraction > scopeTrafficFractionThreshold) {
      return ScopeTrafficState.under;
    }
    return ScopeTrafficState.ok;
  }
}

/// 三横带计数([FrameAnalysis.trafficBandCounts]:带 0 上/1 中/2 下 ×
/// [欠, 合, 过],行主序)→ 三带读数。长度不足 9 的输入按 0 补(手拼
/// 数据防御,不抛)。
List<ScopeTrafficBand> trafficLightsOf(Uint32List counts) {
  int at(int i) => i < counts.length ? counts[i] : 0;
  return [
    for (var b = 0; b < 3; b++)
      ScopeTrafficBand(under: at(b * 3), ok: at(b * 3 + 1), over: at(b * 3 + 2)),
  ];
}

// ── 矢量:Cb/Cr 平面密度(角度 = 色相,半径 = 饱和度)────────────────

/// Rec.601 色度式(ITU-R BT.601-7 全量程,与帧分析的 Rec.601 luma
/// 同族):Cb = 128 − 0.168736R − 0.331264G + 0.5B。
double rec601Cb(num r, num g, num b) =>
    128 - 0.168736 * r - 0.331264 * g + 0.5 * b;

/// Cr = 128 + 0.5R − 0.418688G − 0.081312B。
double rec601Cr(num r, num g, num b) =>
    128 + 0.5 * r - 0.418688 * g - 0.081312 * b;

/// 矢量盘缺省网格边长(48×48:90px 盘上 ≈1.9px/格,密度够读又省)。
const int scopeVectorGridN = 48;

/// 归一盘坐标 → 密度网格索引(n×n 行主序;越盘钳边)。x = Cr 偏移
/// (右正)、y = Cb 偏移(上正 = 蓝),各自除以全饱和幅 127.5 归一
/// (纯原色落盘缘)。
int vectorCellOf(double nx, double ny, int n) {
  final col =
      (((nx + 1) / 2) * (n - 1)).round().clamp(0, n - 1);
  final row =
      (((1 - ny) / 2) * (n - 1)).round().clamp(0, n - 1);
  return row * n + col;
}

/// RGB 采样一步到矢量盘格索引(采样环直调,数学与目标框同源)。
int vectorCellIndexOf(num r, num g, num b, int n) {
  final cb = rec601Cb(r, g, b);
  final cr = rec601Cr(r, g, b);
  return vectorCellOf((cr - 128) / 127.5, (cb - 128) / 127.5, n);
}

/// 75% 幅度六目标(R/Mg/B/Cy/G/Yl)的盘面坐标 —— 与采样同一
/// Rec.601 色度式从 75% 彩条(通道值 191)推得,目标框与数据**自洽**:
/// 75% 饱和的红恰好落进 R 框。经典 SMPTE 刻度盘按复合域轴权
/// (B-Y 2.03 / R-Y 1.14)拉出不等的六目标半径,盘面观感有轴向差;
/// 本盘用分量 CbCr 正交归一,角度/半径语义一致(真机对照留账)。
final List<(double, double)> vectorTargets75 = [
  for (final (r, g, b) in [
    (191, 0, 0), // R 红
    (191, 0, 191), // Mg 品
    (0, 0, 191), // B 蓝
    (0, 191, 191), // Cy 青
    (0, 191, 0), // G 绿
    (191, 191, 0), // Yl 黄
  ])
    ((rec601Cr(r, g, b) - 128) / 127.5, (rec601Cb(r, g, b) - 128) / 127.5),
];

/// 六目标的盘面标字(与 [vectorTargets75] 同序,绘制用拉丁缩写)。
const List<String> vectorTargetLabels = ['R', 'Mg', 'B', 'Cy', 'G', 'Yl'];

// ── ExposureScale:N-Log 编码值 ↔ IRE / 归一(OpenZCine 同语义)──────

/// N-Log 10-bit 合法量程(legal range)黑码(SMPTE 型视频域:
/// 64-940 映 0-100 IRE)。
const double nLogLegalBlackCode10 = 64;

/// 合法量程白码。
const double nLogLegalWhiteCode10 = 940;

/// 官方锚点(《N-Log Specification Document》v1.0.0 pp.4-5;还原式
/// 同源落在 features/edit/lut_presets.dart,此处只取刻度锚点):
/// 真黑(反射率 0)码值。
const double nLogTrueBlackCode10 = 127.2;

/// 18% 中灰码值(Stop 0)。
const double nLogMidGrayCode10 = 372.0;

/// 10-bit 码 → 信号 IRE(64 → 0、940 → 100、502 → 50;线性 legal-range
/// 换算,域外不钳 —— 调用方自便)。
double nLogIreOfCode10(double code) =>
    (code - nLogLegalBlackCode10) /
    (nLogLegalWhiteCode10 - nLogLegalBlackCode10) *
    100;

/// 信号 IRE → 10-bit 码(逆换算;IRE 负/超 100 线性外延)。
double nLogCode10OfIre(double ire) =>
    nLogLegalBlackCode10 +
    ire / 100 * (nLogLegalWhiteCode10 - nLogLegalBlackCode10);

/// 真黑→合法白归一(127.2 → 0、940 → 1;OpenZCine black→clip 口径,
/// 18% 灰 372 → 0.300)。
double nLogNormalizedOfCode10(double code) =>
    (code - nLogTrueBlackCode10) /
    (nLogLegalWhiteCode10 - nLogTrueBlackCode10);

/// 8-bit 监看帧 luma → 10-bit 码(全量程等比 ×1023/255)。
double nLogCode10OfLuma8(int luma) => luma * 1023 / 255;

/// 10-bit 码 → 8-bit 监看帧 luma(逆换算,波形图刻度反投用)。
double nLogLuma8OfCode10(double code) => code * 255 / 1023;

/// 8-bit 监看帧 luma → 信号 IRE(一步换算:16 → ≈0、235 → ≈100.3)。
double nLogIreOfLuma8(int luma) => nLogIreOfCode10(nLogCode10OfLuma8(luma));

/// 信号 IRE → 8-bit 监看帧 luma(波形图 Y 轴刻度落位用)。
double nLogLuma8OfIre(double ire) => nLogLuma8OfCode10(nLogCode10OfIre(ire));

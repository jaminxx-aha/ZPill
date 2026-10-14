/// 监看辅助覆盖层(TODO §二 Live View 监看辅助):三分网格 / 斑马纹 /
/// 直方图 / 水平仪 / 伪色 / 对焦峰值,全部画在取景画面上,随开关增减,
/// 不改帧数据。另有录制读出(时间码 + 声音电平表 + 过热警告)—— 屏幕
/// 坐标层,取景画面右上角(见 [recordingReadoutOf] 的可见性口径)。
///
/// 网格与斑马纹对齐**画面实际包含矩形**(BoxFit.contain 的 letterbox
/// 数学),不是整个取景框 —— 斑马纹错位会误导曝光判断。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_header.dart';
import '../../platform/motion_host.dart';
import 'live_design.dart';

/// 伪色带色表(索引 = [FrameAnalysis.falseColorBandOf];OpenZCine
/// ExposureScale 的视频监看惯例:紫=极暗,蓝=欠,绿=中灰附近,
/// 黄/橙=高亮,红=过曝)。
const kFalseColorBandColors = <Color>[
  Color(0xFF7A1FA2), // < 16 紫:极暗(欠曝风险)
  Color(0xFF1E88E5), // < 48 蓝:暗部
  Color(0xFF00BCD4), // < 96 青:中暗
  Color(0xFF43A047), // < 160 绿:中灰带
  Color(0xFFFBC02D), // < 216 黄:高亮
  Color(0xFFF57C00), // < 250 橙:接近削顶
  Color(0xFFE53935), // ≥ 250 红:过曝
];

/// BoxFit.contain 的画面矩形(aspect = 帧宽高比;null = 未知,铺满)。
Rect containRect(Size box, double? aspect) {
  if (aspect == null || aspect <= 0 || !aspect.isFinite) {
    return Offset.zero & box;
  }
  final boxAspect = box.isEmpty ? aspect : box.width / box.height;
  double w, h;
  if (boxAspect > aspect) {
    h = box.height;
    w = h * aspect;
  } else {
    w = box.width;
    h = w / aspect;
  }
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// 三分构图网格。
class GridOverlay extends StatelessWidget {
  const GridOverlay({super.key, this.aspect});

  /// 帧宽高比(null = 未知,按全框画)。
  final double? aspect;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _GridPainter(aspect),
        size: Size.infinite,
      ),
    );
  }
}

final class _GridPainter extends CustomPainter {
  const _GridPainter(this.aspect);

  final double? aspect;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = containRect(size, aspect);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (final i in const [1, 2]) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.aspect != aspect;
}

/// 过曝斑马纹(基于 [FrameAnalysis] 掩码,格间铺斜纹)。
class ZebraOverlay extends StatelessWidget {  const ZebraOverlay({super.key, required this.analysis});

  final FrameAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _ZebraPainter(analysis),
        size: Size.infinite,
      ),
    );
  }
}

final class _ZebraPainter extends CustomPainter {
  const _ZebraPainter(this.analysis);

  final FrameAnalysis? analysis;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null) return;
    final rect = containRect(size, a.width / a.height);
    final cellW = rect.width / a.maskCols;
    final cellH = rect.height / a.maskRows;
    final stripePitch = math.max(4.0, math.min(cellW, cellH) / 3);
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.75)
      ..strokeWidth = 1.5;
    for (var row = 0; row < a.maskRows; row++) {
      for (var col = 0; col < a.maskCols; col++) {
        if (a.overexposedMask[row * a.maskCols + col] == 0) continue;
        final cell = Rect.fromLTWH(
            rect.left + col * cellW, rect.top + row * cellH, cellW, cellH);
        // 格内 45° 斜纹,间距 stripePitch
        for (var d = -cell.height; d < cell.width + cell.height;
            d += stripePitch) {
          canvas.drawLine(
            Offset(cell.left + d, cell.bottom),
            Offset(cell.left + d + cell.height, cell.top),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ZebraPainter old) => old.analysis != analysis;
}

/// 伪色(False Color):按格均值亮度带整格铺色(带图见
/// [kFalseColorBandColors]),亮度分布一眼可读 —— 中灰该落在绿带,
/// 大面积紫/红即欠/过曝。
class FalseColorOverlay extends StatelessWidget {
  const FalseColorOverlay({super.key, required this.analysis});

  final FrameAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _FalseColorPainter(analysis),
        size: Size.infinite,
      ),
    );
  }
}

final class _FalseColorPainter extends CustomPainter {
  const _FalseColorPainter(this.analysis);

  final FrameAnalysis? analysis;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null) return;
    final rect = containRect(size, a.width / a.height);
    final cellW = rect.width / a.maskCols;
    final cellH = rect.height / a.maskRows;
    for (var row = 0; row < a.maskRows; row++) {
      for (var col = 0; col < a.maskCols; col++) {
        final band = a.falseColorCells[row * a.maskCols + col];
        final color = band < kFalseColorBandColors.length
            ? kFalseColorBandColors[band]
            : kFalseColorBandColors.last;
        canvas.drawRect(
          Rect.fromLTWH(rect.left + col * cellW, rect.top + row * cellH,
              cellW + 0.5, cellH + 0.5),
          Paint()..color = color.withValues(alpha: 0.55),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FalseColorPainter old) => old.analysis != analysis;
}

/// 对焦峰值(Peaking):强亮度梯度的细格描边(色可配,默认金)——
/// 合焦面在画面里通常正是细节最锐的地方,峰值高亮圈出“哪里实了”。
///
/// 灵敏度档(梯度阈值)在分析侧(frame_analysis.dart),色档在绘制侧
/// ([peakingColorOf]);两档都持久化在 AppSettings。
/// 峰值高亮金(默认档色 = 旧行为的写死值)。
const Color kPeakingGold = Color(0xFFE9AC35);

/// 峰值高亮色档表(索引 = AppSettings.monitorPeakingColor:
/// 0=金(默认)/1=白/2=红)。红 = LiveDesign.dark.bad 的值(内容层
/// 警示红,与斑马纹/未合焦 AF 框同族)—— const 列表不能取令牌属性,
/// 以字面量落值,测试侧与令牌对账。
const kPeakingColors = <Color>[
  kPeakingGold,
  Colors.white,
  Color(0xFFD13437),
];

/// 峰值高亮色(档位索引 → 色;表外档回落金 = 旧行为)。纯函数,测试直取。
Color peakingColorOf(int index) =>
    index >= 0 && index < kPeakingColors.length
        ? kPeakingColors[index]
        : kPeakingGold;

class PeakingOverlay extends StatelessWidget {
  const PeakingOverlay(
      {super.key, required this.analysis, this.color = kPeakingGold});

  final FrameAnalysis? analysis;

  /// 高亮色(取景区按设置档经 [peakingColorOf] 传入;缺省金 = 旧行为)。
  final Color color;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _PeakingPainter(analysis, color),
        size: Size.infinite,
      ),
    );
  }
}

final class _PeakingPainter extends CustomPainter {
  const _PeakingPainter(this.analysis, this.color);

  final FrameAnalysis? analysis;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null || !a.hasPeaking) return;
    final rect = containRect(size, a.width / a.height);
    final cellW = rect.width / a.peakingCols;
    final cellH = rect.height / a.peakingRows;
    final paint = Paint()..color = color.withValues(alpha: 0.8);
    for (var row = 0; row < a.peakingRows; row++) {
      for (var col = 0; col < a.peakingCols; col++) {
        if (a.peakingMask[row * a.peakingCols + col] == 0) continue;
        canvas.drawRect(
          Rect.fromLTWH(rect.left + col * cellW, rect.top + row * cellH,
              cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PeakingPainter old) =>
      old.analysis != analysis || old.color != color;
}

/// 直方图(左下角小窗,64 桶亮度)。
class HistogramView extends StatelessWidget {
  const HistogramView({super.key, required this.analysis});

  final FrameAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 128,
        height: 64,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            child: CustomPaint(
              painter: _HistogramPainter(analysis),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

final class _HistogramPainter extends CustomPainter {
  const _HistogramPainter(this.analysis);

  final FrameAnalysis? analysis;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null) return;
    final bars = a.normalizedHistogram;
    final barW = size.width / bars.length;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.9);
    for (var i = 0; i < bars.length; i++) {
      final h = bars[i] * (size.height - 2);
      if (h <= 0) continue;
      canvas.drawRect(
          Rect.fromLTWH(i * barW, size.height - h, barW + 0.5, h), paint);
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.analysis != analysis;
}

/// 构图框(OpenZCine FramingGuides 口径):遮幅画幅(目标画幅外
/// 压暗 + 门框细线)/ 安全框(门框内 5% 动作安全 + 10% 字幕安全双
/// 矩形)/ 中心标(十字 + 圆环),三件可独立开关、同绘一层。
///
/// 画在图像系取景盒上(与网格同层)。变宽还原拉伸发生在显示层,门框
/// 宽比按 [deSqueeze] 预除 —— 屏上观感即目标画幅;[aspect] 为 null
/// (off)时门框 = 全画面,安全框/中心标照画。
class FramingOverlay extends StatelessWidget {
  const FramingOverlay({
    super.key,
    required this.aspect,
    this.deSqueeze = 1.0,
    this.safeArea = false,
    this.centerMark = false,
  });

  /// 目标画幅比(2.39/2.35/1.85;null = 不遮幅)。
  final double? aspect;

  /// 变宽还原倍率(1.0 = 关)。
  final double deSqueeze;

  final bool safeArea;
  final bool centerMark;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter:
            _FramingPainter(aspect, deSqueeze, safeArea, centerMark),
        size: Size.infinite,
      ),
    );
  }
}

final class _FramingPainter extends CustomPainter {
  const _FramingPainter(this.aspect, this.deSqueeze, this.safeArea,
      this.centerMark);

  final double? aspect;
  final double deSqueeze;
  final bool safeArea;
  final bool centerMark;

  @override
  void paint(Canvas canvas, Size size) {
    // 门框矩形:遮幅开按目标画幅(除以变宽倍率)适配,关 = 全画面。
    final ratio = aspect == null || deSqueeze <= 0 ? null : aspect! / deSqueeze;
    final gate = containRect(size, ratio);
    if (ratio != null && (gate.left > 0 || gate.top > 0)) {
      // 遮幅:门框外四条带 even-odd 挖洞一次铺满。
      final mask = Path()
        ..addRect(Offset.zero & size)
        ..addRect(gate)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(
          mask, Paint()..color = Colors.black.withValues(alpha: 0.85));
      canvas.drawRect(
        gate,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.4),
      );
    }
    if (safeArea) {
      for (final inset in const [0.05, 0.10]) {
        canvas.drawRect(
          Rect.fromLTWH(
              gate.left + gate.width * inset,
              gate.top + gate.height * inset,
              gate.width * (1 - 2 * inset),
              gate.height * (1 - 2 * inset)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.35),
        );
      }
    }
    if (centerMark) {
      final c = gate.center;
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(c.dx - 10, c.dy), Offset(c.dx + 10, c.dy), paint);
      canvas.drawLine(Offset(c.dx, c.dy - 10), Offset(c.dx, c.dy + 10), paint);
      canvas.drawCircle(
          c,
          4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.5));
    }
  }

  @override
  bool shouldRepaint(_FramingPainter old) =>
      old.aspect != aspect ||
      old.deSqueeze != deSqueeze ||
      old.safeArea != safeArea ||
      old.centerMark != centerMark;
}

/// 波形示波器(OpenZCine Waveform 口径,左下角直方图上方):x =
/// 画面列、y = 亮度(底黑顶白),点密度 = 亮度分布 —— 过曝亮脊
/// (顶部)、欠曝底脊、对比度分布一眼可读。数据来自帧分析的列-亮度
/// 桶计数(与直方图同一采样环,见 FrameAnalysis.waveform)。
class WaveformView extends StatelessWidget {
  const WaveformView({super.key, required this.analysis});

  final FrameAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 160,
        height: 90,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            child: CustomPaint(
              painter: _WaveformPainter(analysis),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

final class _WaveformPainter extends CustomPainter {
  const _WaveformPainter(this.analysis);

  final FrameAnalysis? analysis;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null || a.waveformCols == 0) return;
    // IRE 刻度线:0/25/50/75/100 五条水平参考。
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = (size.height - 2) * i / 4 + 1;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final max = a.waveform.reduce((x, y) => x > y ? x : y);
    if (max <= 0) return;
    final cellW = size.width / a.waveformCols;
    final cellH = (size.height - 2) / a.waveformBins;
    final paint = Paint();
    for (var col = 0; col < a.waveformCols; col++) {
      for (var bin = 0; bin < a.waveformBins; bin++) {
        final v = a.waveform[col * a.waveformBins + bin];
        if (v <= 0) continue;
        final density = (v / max).clamp(0.0, 1.0);
        paint.color = _waveformColor(density);
        // 桶 0(黑)在底,高端在顶;顶/底各留 1px 给刻度边。
        canvas.drawRect(
          Rect.fromLTWH(
              col * cellW, size.height - 1 - (bin + 1) * cellH,
              cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.analysis != analysis;
}

/// 波形密度色(示波器磷光绿,与电平表绿区同族):越密越实。
Color _waveformColor(double density) =>
    const Color(0xFF56EB84).withValues(alpha: 0.25 + 0.75 * density);

/// 相机自报的 AF 框组(帧头 display-info):框 0 = 当前 AF 区域
/// (**真实尺寸** —— 单点小框/动态 L 大框随相机设置),主体检测开着时
/// 后续框 = 人脸/眼睛。**框色跟机身屏对齐,只有红绿两色**(2026-10-12
/// 用户定案「应该只有红的和绿色两种颜色」):合焦绿、其余(未合焦/
/// 对焦中/未知)一律红。框在 whole-size 坐标系,按归一化坐标投到画面
/// 实际包含矩形(与触控对焦同一份映射)。
class AfAreasOverlay extends StatelessWidget {
  const AfAreasOverlay({
    super.key,
    required this.header,
    required this.imageRect,
  });

  final LiveViewHeader header;
  final Rect imageRect;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _AfAreasPainter(header, imageRect),
        size: Size.infinite,
      ),
    );
  }
}

final class _AfAreasPainter extends CustomPainter {
  const _AfAreasPainter(this.header, this.imageRect);

  final LiveViewHeader header;
  final Rect imageRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (header.coordinateWidth <= 0 || header.coordinateHeight <= 0) return;
    final sx = imageRect.width / header.coordinateWidth;
    final sy = imageRect.height / header.coordinateHeight;
    for (var i = 0; i < header.boxes.length; i++) {
      final b = header.boxes[i];
      final isAfPoint = i == 0;
      final color = afPointBoxColor(header.focusResult);
      final paint = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isAfPoint ? 2 : 1.5;
      final rect = Rect.fromCenter(
        center: Offset(
            imageRect.left + b.centerX * sx, imageRect.top + b.centerY * sy),
        width: b.width * sx,
        height: b.height * sy,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AfAreasPainter old) =>
      old.header != header || old.imageRect != imageRect;
}

/// AF 框颜色,跟机身屏对齐(2026-10-12 用户定案「只有红绿两色」):
/// 合焦绿、其余(未合焦/对焦中/未知)一律红。纯函数,测试直取。
Color afPointBoxColor(LiveViewFocusResult result) =>
    result == LiveViewFocusResult.focused
        ? const Color(0xFF2EC76B)
        : LiveDesign.dark.bad;

/// 水平仪:固定参考线 + 随姿态转动的地平线(pitch 平移,roll 旋转)。
class LevelOverlay extends StatelessWidget {
  const LevelOverlay({super.key, required this.orientation});

  final MotionOrientation orientation;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _LevelPainter(orientation),
        size: Size.infinite,
      ),
    );
  }
}

final class _LevelPainter extends CustomPainter {
  const _LevelPainter(this.orientation);

  final MotionOrientation orientation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const halfLen = 90.0;
    final pitchShift = orientation.pitchRad * 120; // 弧度 → 像素(显示尺度)
    final roll = -orientation.rollRad; // 设备右倾 → 地平线左高右低
    final cx = center.dx;
    final cy = center.dy + pitchShift;
    final dx = math.cos(roll) * halfLen;
    final dy = math.sin(roll) * halfLen;
    final horizon = Offset(cx - dx, cy - dy);
    final horizonEnd = Offset(cx + dx, cy + dy);
    final ref = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final horizonPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.9)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(center.dx - halfLen, center.dy),
        Offset(center.dx + halfLen, center.dy), ref);
    canvas.drawLine(horizon, horizonEnd, horizonPaint);

    final textStyle = TextStyle(
      color: Colors.green.withValues(alpha: 0.9),
      fontSize: 10,
    );
    TextPainter(
      text: TextSpan(
          text: '${orientation.pitchText} / ${orientation.rollText}',
          style: textStyle),
      textDirection: TextDirection.ltr,
    )
      ..layout()
      ..paint(canvas, Offset(center.dx - halfLen, center.dy + 6));
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      old.orientation.pitchRad != orientation.pitchRad ||
      old.orientation.rollRad != orientation.rollRad;
}

// ── 录制读出:时间码 + 声音电平表(OpenZCine 差集⑤)────────────────

/// 录制读出可见性(纯决策,取景区接线用):
/// - 时间码随机身「时间码显示」开关(@831)—— 用户在相机菜单关掉它,
///   监看端同随(相机自家屏同款语义);
/// - 电平表**录制中常驻**(@828;录没录上声一目了然,静音也显示 ——
///   那正是要看见的),待机时相机报了非零电平才现身(拍照取景恒零 →
///   不占屏;影片待机若机身报电平即成开录前的试音表);
/// - 过热警告随机身自报状态(@853 ≥ 1 即现,不限录制 —— 机身屏同样
///   在取景待机就报温),倒计时秒只在「倒计时显示」态(@853 = 4)随
///   @836 现身(官方 §9.7.1:过热 30s 起 —— 机身自家屏同款语义);
/// - 头解析不出 / 取景未开启一律不显示(末帧保留期取景已停,冻结的
///   读出随 AF 框同规退场)。
({bool timecode, bool meters, int? overheat, int? countdownSeconds})
    recordingReadoutOf(LiveViewHeader? header, {required bool liveViewActive}) {
  final h = liveViewActive ? header : null;
  final sound = h?.sound;
  // 未知值(>4)按不告警处理(宁缺不错,域值表来自官方 §9.7.1)。
  final raw = h?.overheatRaw;
  final overheat = (raw != null && raw >= 1 && raw <= 4) ? raw : null;
  return (
    timecode: h?.timecode?.on == true,
    meters: sound != null &&
        (h!.recording || sound.currentLeft > 0 || sound.currentRight > 0),
    overheat: overheat,
    countdownSeconds: overheat == 4 ? h?.recordingCountdownSeconds : null,
  );
}

/// 过热警告等级文案(纯函数,测试直取;官方 §9.7.1 四级,与机身自家
/// 屏的温度提示同语义):[countdownSeconds] 只在「倒计时显示」态(4)
/// 传入,拼进尾句(官方口径过热后 30s 起 —— 倒计时到零机身自动停录)。
String overheatBadgeText(int level, {int? countdownSeconds}) {
  final tail = countdownSeconds != null
      ? ' ${overheatCountdownText(countdownSeconds)}'
      : '';
  return switch (level) {
    1 => '机内温度升高$tail',
    2 => '机内温度较高$tail',
    3 => '机内高温,录制即将停止$tail',
    4 => '即将自动停止录制$tail',
    _ => '机内温度升高$tail',
  };
}

/// 倒计时秒 → m:ss(官方口径 3600s 起;30s → 0:30,3600 → 60:00)。
String overheatCountdownText(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// 过热警告徽章:暗面玻璃胶囊随录制读出挂右上,温和级(1-2)金 accent、
/// 高温级(3-4)红 bad —— 与机身温度提示的严重度对齐。
class OverheatBadge extends StatelessWidget {
  const OverheatBadge({
    super.key,
    required this.level,
    this.countdownSeconds,
  });

  /// 机内过热状态(@853,1-4;见 [recordingReadoutOf])。
  final int level;

  /// 停录倒计时秒(@836;仅「倒计时显示」态非 null)。
  final int? countdownSeconds;

  @override
  Widget build(BuildContext context) {
    final color =
        level >= 3 ? LiveDesign.dark.bad : LiveDesign.dark.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: LiveDesign.dark.glass,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: LiveDesign.dark.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.device_thermostat, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            overheatBadgeText(level, countdownSeconds: countdownSeconds),
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 录制时间码读出:暗面玻璃胶囊 + 等宽数字(监看口径,双位补零)。
class TimecodeView extends StatelessWidget {
  const TimecodeView({super.key, required this.timecode});

  final LiveViewTimecode timecode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: LiveDesign.dark.glass,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: LiveDesign.dark.hairline),
      ),
      child: Text(
        timecode.display,
        style: TextStyle(
          fontSize: 12,
          color: LiveDesign.dark.text,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 声音电平表:机身同款 15 段双声道(L/R)—— 当前电平三区色填充 +
/// 峰值保持随区亮标(段色见 [audioSegmentColor])。值直接来自帧头,
/// 相机侧已做电平动力学,本地不衰减。
class AudioMetersView extends StatelessWidget {
  const AudioMetersView({super.key, required this.sound});

  final LiveViewSound sound;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: LiveDesign.dark.glass,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: LiveDesign.dark.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _channel('L', sound.currentLeft, sound.peakLeft),
          const SizedBox(height: 3),
          _channel('R', sound.currentRight, sound.peakRight),
        ],
      ),
    );
  }

  static Widget _channel(String label, int current, int peak) {
    return Row(
      key: ValueKey('meter-$label'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 10,
          child: Text(label,
              style: TextStyle(fontSize: 9, color: LiveDesign.dark.muted)),
        ),
        for (var i = 0; i <= LiveViewSound.maxSegment; i++)
          Container(
            width: 3.5,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            decoration: BoxDecoration(
              color: audioSegmentColor(i, current: current, peak: peak),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

/// 单段颜色(三区色,OpenZCine MonitorOverlays zoneColor 口径:-18dB 起
/// 黄、-6dB 起红;离散 15 段为计数语义「值 v = 亮 v 段」,边界各下移
/// 一段对齐其连续填充在每个值上的观感 —— current=13 即见红、10-12 顶
/// 段黄):已亮段按所在区着色,段 0-8 绿(正常)/ 9-11 黄(偏大,注意
/// 增益)/ 12-14 红(近削波);未亮段近隐;峰值保持标(当前之上,静音
/// 0 除外)随所在区着色 —— 黄/红标 = 刚才冲进了警告区,绿区保持半亮
/// 白。纯函数,测试直取。
Color audioSegmentColor(int index, {required int current, required int peak}) {
  if (index < current) {
    return _audioZoneColor(index);
  }
  if (index == peak && peak >= current && peak > 0) {
    return index >= _audioYellowFromSegment
        ? _audioZoneColor(index)
        : Colors.white.withValues(alpha: 0.6);
  }
  return Colors.white.withValues(alpha: 0.12);
}

/// 黄区起点段(-18dB 起黄;计数语义下移一段);红区起点段(-6dB 起红)。
const int _audioYellowFromSegment = 9;
const int _audioRedFromSegment = 12;

Color _audioZoneColor(int index) {
  if (index >= _audioRedFromSegment) return const Color(0xFFFF5C52);
  if (index >= _audioYellowFromSegment) return const Color(0xFFF5D052);
  return const Color(0xFF56EB84);
}

/// 监看辅助覆盖层(TODO §二 Live View 监看辅助):三分网格 / 斑马纹 /
/// 直方图 / 水平仪 / 伪色 / 对焦峰值,全部画在取景画面上,随开关增减,
/// 不改帧数据。另有录制读出(时间码 + 声音电平表)—— 屏幕坐标层,
/// 取景画面右上角(见 [recordingReadoutOf] 的可见性口径)。
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

/// 对焦峰值(Peaking):强亮度梯度的细格描金边 —— 合焦面在画面里
/// 通常正是细节最锐的地方,峰值高亮圈出“哪里实了”。
class PeakingOverlay extends StatelessWidget {
  const PeakingOverlay({super.key, required this.analysis});

  final FrameAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _PeakingPainter(analysis),
        size: Size.infinite,
      ),
    );
  }
}

final class _PeakingPainter extends CustomPainter {
  const _PeakingPainter(this.analysis);

  final FrameAnalysis? analysis;

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    if (a == null || !a.hasPeaking) return;
    final rect = containRect(size, a.width / a.height);
    final cellW = rect.width / a.peakingCols;
    final cellH = rect.height / a.peakingRows;
    final paint = Paint()
      ..color = const Color(0xFFE9AC35).withValues(alpha: 0.8);
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
  bool shouldRepaint(_PeakingPainter old) => old.analysis != analysis;
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

/// 相机自报的 AF 框组(帧头 display-info):框 0 = 当前 AF 区域
/// (**真实尺寸** —— 单点小框/动态 L 大框随相机设置),合焦变绿;主体
/// 检测开着时后续框 = 人脸/眼睛(琥珀)。框在 whole-size 坐标系,按
/// 归一化坐标投到画面实际包含矩形(与触控对焦同一份映射)。
class AfAreasOverlay extends StatelessWidget {
  const AfAreasOverlay({super.key, required this.header, required this.imageRect});

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
      // 框 0 = AF 区域:合焦绿、未合焦金;主体检测框(人脸/眼)= 琥珀。
      final color = isAfPoint
          ? (header.focusResult == LiveViewFocusResult.focused
              ? const Color(0xFF2EC76B)
              : const Color(0xFFE9AC35))
          : const Color(0xFFFFC107);
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
/// - 头解析不出 / 取景未开启一律不显示(末帧保留期取景已停,冻结的
///   读出随 AF 框同规退场)。
({bool timecode, bool meters}) recordingReadoutOf(
    LiveViewHeader? header, {required bool liveViewActive}) {
  final h = liveViewActive ? header : null;
  final sound = h?.sound;
  return (
    timecode: h?.timecode?.on == true,
    meters: sound != null &&
        (h!.recording || sound.currentLeft > 0 || sound.currentRight > 0),
  );
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

/// 声音电平表:机身同款 15 段双声道(L/R)—— 当前电平填色 + 峰值保持
/// 亮标(段色见 [audioSegmentColor])。值直接来自帧头,相机侧已做电平
/// 动力学,本地不衰减。
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

/// 单段颜色:已亮段绿(顶部两段 ≥13 红 —— 广播表惯例:近削波);未亮
/// 段近隐;峰值保持标(当前之上,静音 0 除外)半亮白。纯函数,测试直取。
Color audioSegmentColor(int index, {required int current, required int peak}) {
  if (index < current) {
    return index >= 13 ? const Color(0xFFE53935) : const Color(0xFF2EC76B);
  }
  if (index == peak && peak >= current && peak > 0) {
    return Colors.white.withValues(alpha: 0.6);
  }
  return Colors.white.withValues(alpha: 0.12);
}

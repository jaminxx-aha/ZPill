/// 监看辅助覆盖层(TODO §二 Live View 监看辅助):三分网格 / 斑马纹 /
/// 直方图 / 水平仪 / 伪色 / 对焦峰值,全部画在取景画面上,随开关增减,
/// 不改帧数据。
///
/// 网格与斑马纹对齐**画面实际包含矩形**(BoxFit.contain 的 letterbox
/// 数学),不是整个取景框 —— 斑马纹错位会误导曝光判断。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/remote/frame_analysis.dart';
import '../../platform/motion_host.dart';

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

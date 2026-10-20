import 'package:flutter/material.dart';

/// STA 方式图标:自绘复刻机身 Wi-Fi 菜单的天线图形(实心漏斗+平切杆+
/// 两侧同心双弧波,2026-10-20 与用户以 SVG 逐轮比对定稿,源
/// /tmp/sta_icon/camera_sta.svg viewBox 0 0 186 154)。Material 内置无一
/// 同型,故 [CustomPainter] 按定稿坐标重画;墨迹盒 107×102 归一到框占
/// ~76%(对齐 Material 字形观感),颜色/字号语义同 [Icon]。
class StaAntennaIcon extends StatelessWidget {
  const StaAntennaIcon({super.key, this.size, this.color});

  /// 语义同 [Icon.size]:缺省吃 IconTheme 字号。
  final double? size;

  /// 语义同 [Icon.color]:缺省吃 IconTheme 色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final px = size ?? iconTheme.size ?? 24.0;
    return SizedBox(
      width: px,
      height: px,
      child: CustomPaint(
        painter: _StaAntennaPainter(
          color: color ??
              iconTheme.color ??
              Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _StaAntennaPainter extends CustomPainter {
  const _StaAntennaPainter({required this.color});

  final Color color;

  /// 定稿坐标(SVG 系)常量:墨迹盒 x[31.5,138.5] y[28.6,131],中心
  /// (85,79.8);弧同心圆心 (85,61),内 r37.5 外 r53.5,笔宽 8。
  static const _cx = 85.0;
  static const _rInner = 37.5, _rOuter = 53.5, _stroke = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    // 归一:墨迹盒映射到框内 ~76% 并居中(与 Material 字形观感一致)。
    final k = size.shortestSide / 140;
    canvas
      ..translate(size.width / 2 - _cx * k, size.height / 2 - 79.8 * k)
      ..scale(k);

    // 漏斗+杆:单一实心路径 —— 顶边平、顶角尖;坡面与杆侧交于 y≈80.7,
    // 凹角 r1.5 近尖过渡;杆底平切 r2。
    canvas.drawPath(
      Path()
        ..moveTo(56, 57)
        ..lineTo(114, 57)
        ..lineTo(93.5, 79.6)
        ..quadraticBezierTo(92.5, 80.7, 92.5, 82.2)
        ..lineTo(92.5, 129)
        ..quadraticBezierTo(92.5, 131, 90.5, 131)
        ..lineTo(79.5, 131)
        ..quadraticBezierTo(77.5, 131, 77.5, 129)
        ..lineTo(77.5, 82.2)
        ..quadraticBezierTo(77.5, 80.7, 76.5, 79.6)
        ..lineTo(56, 57)
        ..close(),
      Paint()..color = color,
    );

    // 两侧双弧:同心(butt 平切,端点已含切向半笔宽外延),缝宽恒定。
    final wave = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    Path arc(double radius, double xStart, double yStart, double xEnd,
            double yEnd, {required bool bulgeRight}) =>
        Path()
          ..moveTo(xStart, yStart)
          ..arcToPoint(Offset(xEnd, yEnd),
              radius: Radius.circular(radius), clockwise: bulgeRight);
    canvas.drawPath(
      arc(_rInner, 56.8, 36.3, 56.8, 85.7, bulgeRight: false), wave); // 左内
    canvas.drawPath(
      arc(_rOuter, 42.4, 28.6, 42.4, 93.4, bulgeRight: false), wave); // 左外
    canvas.drawPath(
      arc(_rInner, 113.2, 36.3, 113.2, 85.7, bulgeRight: true), wave); // 右内
    canvas.drawPath(
      arc(_rOuter, 127.6, 28.6, 127.6, 93.4, bulgeRight: true), wave); // 右外
  }

  @override
  bool shouldRepaint(_StaAntennaPainter old) => old.color != color;
}

/// 排序图标(用户定稿 2026-10-23,参照系统排序双向图标):左侧竖箭头
///([desc] 朝下 / 升序朝上)+ 右侧三条**上长下短**横线 —— 横线两向
/// 同形,仅箭头朝向翻转(整体旋转会把横线一并翻掉,故自绘)。
library;

import 'package:flutter/material.dart';

/// 排序双向图标:归一 0-100 坐标系按 [size] 缩放。
class SortBarsIcon extends StatelessWidget {
  const SortBarsIcon(
      {super.key, this.size = 20, this.color, required this.desc});

  final double size;
  final Color? color;

  /// true = 降序(箭头朝下);false = 升序(箭头朝上)。
  final bool desc;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _SortBarsPainter(
            color: color ?? Theme.of(context).colorScheme.primary, desc: desc),
      );
}

class _SortBarsPainter extends CustomPainter {
  _SortBarsPainter({required this.color, required this.desc});

  final Color color;
  final bool desc;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 9 * u
      ..strokeCap = StrokeCap.butt;

    // 右侧三条横线:上长下短,两向同形。
    const barYs = [26.0, 50.0, 74.0];
    const barEnds = [94.0, 74.0, 58.0]; // x 终点(起点 40)
    for (var i = 0; i < 3; i++) {
      canvas.drawLine(Offset(40 * u, barYs[i] * u),
          Offset(barEnds[i] * u, barYs[i] * u), stroke);
    }

    // 左侧竖箭头: shaft + 三角头(desc 头在下;asc 头在上)。
    final head = Path();
    const shaftX = 18.0;
    if (desc) {
      canvas.drawLine(Offset(shaftX * u, 14 * u), Offset(shaftX * u, 70 * u),
          stroke);
      head
        ..moveTo(shaftX * u, 88 * u)
        ..lineTo((shaftX - 14) * u, 62 * u)
        ..lineTo((shaftX + 14) * u, 62 * u)
        ..close();
    } else {
      canvas.drawLine(Offset(shaftX * u, 30 * u), Offset(shaftX * u, 86 * u),
          stroke);
      head
        ..moveTo(shaftX * u, 12 * u)
        ..lineTo((shaftX - 14) * u, 38 * u)
        ..lineTo((shaftX + 14) * u, 38 * u)
        ..close();
    }
    canvas.drawPath(head, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SortBarsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.desc != desc;
}

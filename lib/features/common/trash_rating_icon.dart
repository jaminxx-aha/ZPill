/// 删除候选图标:黄桶黑星(机身评级「垃圾桶」同形)。2026-10-23 用户
/// 定稿:深底胶囊上黄桶(brandYellow)+ 黑五角星(星在深底上读作桶身
/// 镂空,同尼康机身图标);几何与 PIL 确认稿一致 —— 盖微开斜 6°、桶身
/// 梯形、五角星居中桶身。图形归一 0-100 坐标系按 [size] 缩放。
///
/// 浅色底(筛选弹层行)上星用深字色(onBrandYellow);深底胶囊上星用
/// 底色([TrashRatingIcon.onDarkChip] = 镂空观感)。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/app_colors.dart';

/// 删除候选角标的深底色(黄桶需要深底才可见;onBrandYellow 同系略深)。
const Color trashChipColor = Color(0xE61A1600);

class TrashRatingIcon extends StatelessWidget {
  const TrashRatingIcon(
      {super.key,
      this.size = 16,
      this.onDarkChip = false,
      this.color,
      this.holeColor});

  final double size;

  /// 深底胶囊上:星用底色(镂空);浅色底:星用深字色。
  final bool onDarkChip;

  /// 覆写桶身颜色(默认 brandYellow;单色语境传 IconTheme 色)。
  final Color? color;

  /// 覆写镂空星颜色(默认 trashChipColor / onBrandYellow;单色语境传
  /// 所在面板底色)。
  final Color? holeColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _TrashBinPainter(onDarkChip,
            color: color, holeColor: holeColor),
      );
}

class _TrashBinPainter extends CustomPainter {
  _TrashBinPainter(this.onDarkChip, {this.color, this.holeColor});

  final bool onDarkChip;
  final Color? color;
  final Color? holeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    final bin = Paint()..color = color ?? AppColors.brandYellow;
    final star = Paint()
      ..color = holeColor ??
          (onDarkChip ? trashChipColor : AppColors.onBrandYellow);

    Path tf(List<List<double>> pts, {double deg = 0, (int, int)? rc}) {
      final path = Path();
      var first = true;
      for (final pt in pts) {
        var p = Offset(pt[0] * u, pt[1] * u);
        if (deg != 0) {
          final a = deg * math.pi / 180;
          final c = Offset(rc!.$1 * u, rc.$2 * u);
          final dx = p.dx - c.dx;
          final dy = p.dy - c.dy;
          p = Offset(c.dx + dx * math.cos(a) - dy * math.sin(a),
              c.dy + dx * math.sin(a) + dy * math.cos(a));
        }
        if (first) {
          path.moveTo(p.dx, p.dy);
          first = false;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path..close();
    }

    // 盖(斜 6° 微开)+ 提手 + 桶身。
    canvas.drawPath(
        tf([
          [14, 24],
          [72, 24],
          [76, 33],
          [10, 33],
        ], deg: -6, rc: (43, 28)),
        bin);
    canvas.drawPath(
        tf([
          [34, 16],
          [52, 16],
          [55, 24],
          [31, 24],
        ], deg: -6, rc: (43, 20)),
        bin);
    canvas.drawPath(
        tf([
          [18, 38],
          [68, 38],
          [62, 95],
          [24, 95],
        ]),
        bin);

    // 五角星(桶身中央)。
    final cx = 43 * u;
    final cy = 63 * u;
    final r1 = 19 * u;
    final r2 = 7.6 * u;
    final starPath = Path();
    for (var i = 0; i < 10; i++) {
      final ang = (-90 + i * 36) * math.pi / 180;
      final rad = i.isEven ? r1 : r2;
      final p = Offset(cx + rad * math.cos(ang), cy + rad * math.sin(ang));
      if (i == 0) {
        starPath.moveTo(p.dx, p.dy);
      } else {
        starPath.lineTo(p.dx, p.dy);
      }
    }
    starPath.close();
    canvas.drawPath(starPath, star);
  }

  @override
  bool shouldRepaint(_TrashBinPainter oldDelegate) =>
      oldDelegate.onDarkChip != onDarkChip ||
      oldDelegate.color != color ||
      oldDelegate.holeColor != holeColor;
}

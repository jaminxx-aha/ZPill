/// 取景画面的显示变换链(OpenZCine 监看变换口径,显示层不动帧数据):
/// contain 适配(缩放 + 居中)→ 变宽还原(水平拉伸)→ 持机旋转(帧头
/// @839)→ 双指缩放/拖移。
///
/// 矩阵管线(图像像素 → 屏幕;调用序即作用序):
/// ```
/// screen = T(boxCenter + pan) · S(zoom) · T(-boxCenter)      ← 缩放平移
///        · T(displayRect.center) · S(fitScale)                ← contain 适配
///        · R(quarter · 90°) · S(deSqueeze, 1)                 ← 旋转/变宽
///        · T(-imageSize / 2)                                  ← 图像中心对齐
/// ```
/// 取景页的用法:帧与监看叠层(网格/斑马纹/伪色/峰值/AF 框)全部画在
/// **图像坐标系**的盒子里([imageSize]),外层一个 [Transform] 应用
/// [imageToScreen] —— 叠层件零改动即随画面旋转/拉伸/缩放;点按对焦
/// 坐标经 [screenToNorm] 逆映射回归一化图像坐标(缩放/旋转/变宽一次
/// 收口)。
///
/// 旋转符号口径(待真机核对,同水平仪符号注):帧头 @839 的
/// 1=左转竖/2=右转竖按「相机转左 → 画面顺时针转正」换算 —— 左转竖
/// (摄影师视角相机逆时针转)时景物上方落在原始横幅的右缘,转正 =
/// 图像逆时针 90°。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/material.dart' show Matrix4, MatrixUtils;

/// 帧头 @839 持机旋转(raw)→ 显示旋转的顺时针四分之一圈数。
/// [FeedTransform.quarter] 的语义:0 不转;1 顺时针 90°;2 180°;
/// 3 逆时针 90°。
int feedQuarterFromRotationRaw(int rotationRaw) => switch (rotationRaw) {
      1 => 3, // 左转竖:图像逆时针 90°(符号待真机核对)
      2 => 1, // 右转竖:图像顺时针 90°
      3 => 2, // 倒置:180°
      _ => 0,
    };

/// 不可变取景变换(每帧/每手势重建;[boxSize] 来自 LayoutBuilder,
/// 其余来自帧尺寸/帧头/设置/缩放手势态)。
final class FeedTransform {
  FeedTransform({
    required this.imageSize,
    required this.boxSize,
    this.quarter = 0,
    this.deSqueeze = 1.0,
    this.zoom = 1.0,
    this.pan = Offset.zero,
  })  : assert(quarter >= 0 && quarter < 4),
        assert(deSqueeze >= 1.0);

  /// 取景帧像素尺寸(SOF 嗅探;空/零尺寸 = 无画面,变换恒等)。
  final Size imageSize;

  /// 取景区盒尺寸。
  final Size boxSize;

  /// 显示旋转(顺时针四分之一圈数;见 [feedQuarterFromRotationRaw])。
  final int quarter;

  /// 变宽还原倍率(1.0 = 关;作用于**旋转前**的图像水平轴 —— 传感器
  /// 挤压轴,竖持时拉伸随旋转落在屏幕竖向)。
  final double deSqueeze;

  /// 双指缩放倍率(1.0 = 适配;最小 1 不缩小出 letterbox)。
  final double zoom;

  /// 缩放平移(屏幕系;zoom 为 1 时恒零)。
  final Offset pan;

  bool get hasImage =>
      imageSize.width > 0 && imageSize.height > 0 && !boxSize.isEmpty;

  /// 旋转 + 变宽后的内容尺寸(contain 适配的输入)。
  Size get contentSize {
    if (!hasImage) return boxSize;
    // 先水平拉伸再旋转:偶数圈 (ds·w, h);奇数圈 (h, ds·w)。
    return quarter.isEven
        ? Size(deSqueeze * imageSize.width, imageSize.height)
        : Size(imageSize.height, deSqueeze * imageSize.width);
  }

  /// contain 适配倍率(zoom=1/pan=0 时图像边长 = imageSize 边长 × 此值)。
  double get fitScale {
    final c = contentSize;
    if (c.isEmpty || boxSize.isEmpty) return 1.0;
    return math.min(boxSize.width / c.width, boxSize.height / c.height);
  }

  /// zoom=1/pan=0 时的 contain 矩形(旋转/变宽已计入 aspect)。
  Rect get displayRect {
    final c = contentSize;
    if (c.isEmpty || boxSize.isEmpty) return Offset.zero & boxSize;
    final s = fitScale;
    final size = c * s;
    return Rect.fromLTWH((boxSize.width - size.width) / 2,
        (boxSize.height - size.height) / 2, size.width, size.height);
  }

  /// 图像像素 → 屏幕的全变换(外层 Transform 直接消费)。
  Matrix4 get imageToScreen {
    final m = Matrix4.identity();
    if (!hasImage) return m;
    final c = boxSize.center(Offset.zero);
    // 缩放平移:绕取景区中心。
    m.translateByDouble(c.dx + pan.dx, c.dy + pan.dy, 0, 1);
    m.scaleByDouble(zoom, zoom, 1, 1);
    m.translateByDouble(-c.dx, -c.dy, 0, 1);
    // contain 适配:内容中心对到 displayRect 中心,再缩到 contain 尺寸。
    final dc = displayRect.center;
    m.translateByDouble(dc.dx, dc.dy, 0, 1);
    final s = fitScale;
    m.scaleByDouble(s, s, 1, 1);
    // 旋转(顺时针为正)→ 变宽水平拉伸 → 图像中心对齐原点。
    m.rotateZ(quarter * math.pi / 2);
    m.scaleByDouble(deSqueeze, 1.0, 1.0, 1);
    m.translateByDouble(-imageSize.width / 2, -imageSize.height / 2, 0, 1);
    return m;
  }

  Matrix4? _inverse;

  /// 屏幕 → 图像像素(缓存逆矩阵)。
  Matrix4 get screenToImage => _inverse ??= Matrix4.inverted(imageToScreen);

  /// 屏幕点 → 归一化图像坐标(0..1,钳到边;无画面 = null)。
  /// 点按对焦走这里:缩放/旋转/变宽一次逆映射收口。
  Offset? screenToNorm(Offset screen) {
    if (!hasImage) return null;
    final p = MatrixUtils.transformPoint(screenToImage, screen);
    return Offset(
      (p.dx / imageSize.width).clamp(0.0, 1.0),
      (p.dy / imageSize.height).clamp(0.0, 1.0),
    );
  }

  /// 图像系矩形(像素)→ 屏幕矩形(旋转为整 90°,轴对齐保持;变换
  /// 含缩放平移)。AF 框/对焦占位框的回投用它。
  Rect imageRectToScreen(Rect rect) {
    if (!hasImage) return Rect.zero;
    final center = MatrixUtils.transformPoint(imageToScreen, rect.center);
    // 线性部分 = zoom · fitScale · R(quarter) · S(deSqueeze, 1):
    // 偶数圈 (ds·s·w, s·h);奇数圈宽高对调。
    final s = zoom * fitScale;
    final w = rect.width * s;
    final h = rect.height * s;
    return quarter.isEven
        ? Rect.fromCenter(
            center: center, width: deSqueeze * w, height: h)
        : Rect.fromCenter(center: center, width: h, height: deSqueeze * w);
  }
}

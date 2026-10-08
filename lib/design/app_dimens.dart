import 'package:flutter/material.dart';

/// 间距阶梯(替换散落的字面量 EdgeInsets/SizedBox)。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 页面级 ListView/单栏 padding。
  static const EdgeInsets screenPadding = EdgeInsets.all(lg);

  /// 卡片内边距。
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);

  /// 区块纵向间距。
  static const double sectionGap = md;
}

/// 圆角档位:sm 徽标小件 / md 卡片内件 / lg 大块 / pill 胶囊。
/// 拍摄页 LiveDesign 自己的几何(6/9/10/14/16)不在此列,随页面走。
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;
}

abstract final class AppTextStyles {
  /// 等宽数字:取景参数/REC 时长/读出条等读数场景,数值跳动不抖宽。
  static TextStyle tabular(double fontSize,
          {Color? color, FontWeight? weight}) =>
      TextStyle(
        fontSize: fontSize,
        color: color,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

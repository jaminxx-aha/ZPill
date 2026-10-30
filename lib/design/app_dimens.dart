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

/// 交互尺寸契约(2026-10-30 第 3 轮设计稿):
/// - 最小触控 44;拍摄侧键 48;快门 320/360/393/430 = 72/80/88/94;
/// - 横屏快门 72、侧键 44;曝光条 320/360/393/430/横屏 = 44/46/52/50/40。
/// 页面不得再写裸尺寸;特殊画面叠层可读 [AppSizes] 后按宽度分档。
abstract final class AppSizes {
  static const double minTouch = 44;
  static const double iconVisual = 40;
  static const double buttonSm = 36;
  static const double button = 44;
  static const double buttonLg = 52;
  static const double pill = 26;
  static const double switchWidth = 48;
  static const double switchHeight = 28;
  static const double navBarHeight = 56;
  static const double appBarPortrait = 50;
  static const double appBarLandscape = 46;
  static const double cardRadius = 16;
  static const double sheetRadius = 22;
}

/// 设计稿断点:以逻辑宽度分档,不用 orientation 猜设备。
abstract final class AppBreakpoints {
  static const double compact = 360;
  static const double base = 393;
  static const double large = 430;

  /// 320/360 页边距 14,393 起 16(第 3 轮尺寸矩阵)。
  static double pagePadding(double width) => width <= compact ? 14 : 16;

  static bool isCompact(double width) => width <= compact;
  static bool isLarge(double width) => width >= large;
}

/// 第 2 轮确认的排版阶梯。页面优先取这里,不再各自写 fontSize。
abstract final class AppTypography {
  static const display = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 28,
      height: 32 / 28,
      fontWeight: FontWeight.w600);
  static const titleL = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 23,
      height: 28 / 23,
      fontWeight: FontWeight.w600);
  static const titleM = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 19,
      height: 24 / 19,
      fontWeight: FontWeight.w600);
  static const titleS = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 16,
      height: 22 / 16,
      fontWeight: FontWeight.w600);
  static const body = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 15,
      height: 22 / 15);
  static const bodyS = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 13,
      height: 20 / 13);
  static const label = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 10.5,
      height: 14 / 10.5,
      fontWeight: FontWeight.w500);
  static const value = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 17,
      fontWeight: FontWeight.w600);
  static const valueS = TextStyle(
      fontFamily: 'InterBadge',
      fontFamilyFallback: ['NotoSansSC'],
      fontSize: 14,
      fontWeight: FontWeight.w600);
  static const numericXl = TextStyle(
    fontFamily: 'InterBadge',
    fontFamilyFallback: ['NotoSansSC'],
    fontSize: 28,
    height: 32 / 28,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const filename = TextStyle(
    fontFamily: 'InterBadge',
    fontFamilyFallback: ['NotoSansSC'],
    fontSize: 12,
    height: 16 / 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// 动效口径:180–220ms 淡入/位移;系统减弱动效时全部归零。
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;

  static Duration duration(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
          ? Duration.zero
          : normal;
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
        fontFamily: 'InterBadge',
        fontFamilyFallback: const ['NotoSansSC'],
        fontSize: fontSize,
        color: color,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

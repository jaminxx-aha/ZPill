import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 应用主题:浅色 = 白底 + 统一黄按钮/选中态 + 墨色文字;深色 =
/// LiveDesign 暖黑 + 同一统一黄(见 app_colors.dart)。红只做错误/
/// 失败。主题跟随系统(设置页可锁),拍摄页恒定 LiveDesign 深色不随
/// 本主题。
/// CJK 回落族(Inter 无汉字字形):汉字统一走随包 Noto Sans SC 子集
/// (见 pubspec fonts 注),生僻字/动态串缺失字形再走系统回落。
const List<String> _cjkFallback = ['NotoSansSC'];

abstract final class AppTheme {
  static ThemeData get light => _build(
        AppColors.lightScheme,
        // 统一黄按钮:只换 FilledButton 实底/前景,primary 仍是墨色
        // —— TextButton 文字、开关、spinner 不跟着变黄(黄字浅底
        // 不可读)。深色 primary 本身就是黄,无需覆写。
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accentYellow,
            foregroundColor: AppColors.onBrandYellow,
          ),
        ),
      );

  static ThemeData get dark => _build(AppColors.darkScheme);

  static ThemeData _build(ColorScheme scheme,
          {FilledButtonThemeData? filledButtonTheme}) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 全 app 统一随包字体(Inter,见 pubspec fonts 注):默认字体
      // 平台各异(iOS=SF/ohos=HarmonyOS Sans)致同码不同渲染,钉
      // 随包字体后双端逐像素同源;汉字走 NotoSansSC 回落。
      fontFamily: 'InterBadge',
      filledButtonTheme: filledButtonTheme,
      // 选中指示胶囊:亮色 = 黑底(其上图标/文字取 onSecondaryContainer
      // = 品牌黄,图标同款反转),暗色 = 拍摄页金胶囊。导航栏整条
      // surface(亮色即整条品牌黄,拒绝默认 surfaceContainer 淡黄条)。
      // 高度钉 56:对齐 iOS 原生照片 tab 栏胶囊高度(2026-10-24 真机
      // 截图实测,3x 下 2379→2548px ≈ 56pt;M3 默认 80 视觉偏高)。
      // 栏内图标+文字随高度垂直居中,56 恰容胶囊 32 + labelPadding 4
      // + 文字 16 = 52,再低会贴边。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        height: 56,
      ),
      navigationRailTheme:
          NavigationRailThemeData(indicatorColor: scheme.secondaryContainer),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
    // CJK 回落补链:textTheme 全样式补 fontFamilyFallback(组件主题由
    // textTheme 派生,一并带上;独立自建 TextStyle 的角落缺失时走系统
    // 回落,与旧行为一致)。
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamilyFallback: _cjkFallback),
    );
  }
}

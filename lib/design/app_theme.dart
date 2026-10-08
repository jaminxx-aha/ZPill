import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 应用主题:浅色 = 白底 + 统一黄按钮/选中态 + 墨色文字;深色 =
/// LiveDesign 暖黑 + 同一统一黄(见 app_colors.dart)。红只做错误/
/// 失败。主题跟随系统(设置页可锁),拍摄页恒定 LiveDesign 深色不随
/// 本主题。
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
          {FilledButtonThemeData? filledButtonTheme}) =>
      ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        filledButtonTheme: filledButtonTheme,
        // 选中指示胶囊:亮色 = 黑底(其上图标/文字取 onSecondaryContainer
        // = 品牌黄,图标同款反转),暗色 = 拍摄页金胶囊。导航栏整条
        // surface(亮色即整条品牌黄,拒绝默认 surfaceContainer 淡黄条)。
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: scheme.surface,
          indicatorColor: scheme.secondaryContainer,
        ),
        navigationRailTheme:
            NavigationRailThemeData(indicatorColor: scheme.secondaryContainer),
        snackBarTheme:
            const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      );
}

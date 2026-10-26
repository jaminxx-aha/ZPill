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
      // 顶栏高度钉 46(2026-10-24 截图实测 3x 162→301px
      // ≈ 46.3pt,M3 默认 56 偏高);各页一律 46,居中与否仍归各页。
      appBarTheme: const AppBarTheme(toolbarHeight: 46),
      // 选中态不用胶囊(2026-10-26 用户明示撤胶囊):指示器透明,
      // 选中图标+文字直充 secondary —— 亮色 #8C7400 深金(accentYellow
      // 黄禁作白底文字色,见 app_colors),暗色 secondary 本身 = 统一黄
      // #E9AC35。导航栏整条 surface(拒绝默认 surfaceContainer 淡黄
      // 条)。高度钉 53:上下两栏几何(2026-10-24 截图实测底栏带
      // 87.3pt = 内容区 53.3 + 安全区 34)。labelPadding 清零:图标盒
      // 32 + 文字 16 = 48,53 栏内余 2.5/2.5,图标不贴顶、文字不贴底
      // (默认 4 的间隙会把内容顶成 0.5 贴边);胶囊撤除后图标盒仍是
      // 32 高,几何不变。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: Colors.transparent,
        height: 53,
        labelPadding: EdgeInsets.zero,
      ),
      // 横屏侧栏与底栏同款撤胶囊(2026-10-26 用户明示一起改);选中
      // 直充的 icon/label 主题在下方 copyWith 落位 —— 标签样式要等
      // textTheme 补完回落族才能取。
      navigationRailTheme:
          NavigationRailThemeData(indicatorColor: Colors.transparent),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
    // CJK 回落补链:textTheme 全样式补 fontFamilyFallback(组件主题由
    // textTheme 派生,一并带上;独立自建 TextStyle 的角落缺失时走系统
    // 回落,与旧行为一致)。
    final textTheme = base.textTheme.apply(fontFamilyFallback: _cjkFallback);
    return base.copyWith(
      textTheme: textTheme,
      // 选中直充色落位:一旦提供 icon/label 主题即整组接管(M3 不再
      // 对未选态回落默认),未选也须显式给 onSurfaceVariant;选中色 =
      // secondary(亮 #8C7400/暗 #E9AC35,见上注)。标签字号沿用 M3
      // labelMedium(12,InterBadge+CJK 回落已随 textTheme)。底栏
      // NavigationBar 是 state 化 widget 主题,横屏侧栏 NavigationRail
      // 是 selected/unselected 成对主题,各按自家 API 给同一套色。
      navigationBarTheme: base.navigationBarTheme.copyWith(
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.selected)
                  ? scheme.secondary
                  : scheme.onSurfaceVariant,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) =>
            textTheme.labelMedium!.apply(
              color: states.contains(WidgetState.selected)
                  ? scheme.secondary
                  : scheme.onSurfaceVariant,
            )),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        selectedIconTheme: IconThemeData(size: 24, color: scheme.secondary),
        unselectedIconTheme:
            IconThemeData(size: 24, color: scheme.onSurfaceVariant),
        selectedLabelTextStyle:
            textTheme.labelMedium!.copyWith(color: scheme.secondary),
        unselectedLabelTextStyle:
            textTheme.labelMedium!.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

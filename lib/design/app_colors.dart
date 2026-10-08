import 'package:flutter/material.dart';

/// 品牌与语义色。
///
/// 品牌双色取自应用图标:红 [brandRed] 与黄 [brandYellow](原值只保留
/// 在盖照片/纯黑上的角标与星标,以及 [AppMedia] 层)。界面现行 v8
/// 「统一令」(2026-10-08 用户终版):浅色 = 白底,深色 = LiveDesign
/// 暖黑;**两套的按钮与选中态统一为 [accentYellow] #E9AC35 配
/// [onBrandYellow] 深字**(= 深色现行黄 / LiveDesign.accent,用户
/// 认可值,改一处须同步);红只做错误/失败提示,**亮暗同号 #D24B33**
/// (用户点名统一,弃 M3 亮暗分色的 salmon/brick 惯例)。
abstract final class AppColors {
  static const brandRed = Color(0xFFE8160F);
  static const brandYellow = Color(0xFFFDE902);

  /// 黄底上的深字(= 亮色 onSecondaryContainer):不随主题的固定配对,
  /// 评分角标一类「盖在内容上」的黄底元素用。
  static const onBrandYellow = Color(0xFF3A3000);

  /// 统一黄(2026-10-08 用户定案):按钮实底与选中态,浅深两套同值
  /// (= 深色现行黄 = LiveDesign.accent)。配 [onBrandYellow] 深字;
  /// 亮色下禁作文字色(黄字白底对比不足)。
  static const accentYellow = Color(0xFFE9AC35);

  /// 成功态(已连接/传输完成):亮暗各一;暗色对齐拍摄页
  /// LiveDesign.good(#2EC76B)。
  static const successLight = Color(0xFF1B7A45);
  static const successDark = Color(0xFF2EC76B);

  static Color success(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? successDark
          : successLight;

  /// 亮色 ColorScheme(v8 统一令):白底 + 墨色 primary(文字/开关/
  /// spinner;主按钮实底由 AppTheme 覆写成统一黄)+ 黄色选中
  /// (secondaryContainer = [accentYellow] 配 [onBrandYellow] 深字,
  /// 导航胶囊/选中段/tonal 钮,与按钮同黄)+ 沉红只做错误/失败。
  ///
  /// 手写锁值而非 fromSeed:红黄双色 fromSeed 的 tone 映射无法精确
  /// 就位(单种子只能推导整套色轮)。全部 container 角色显式给出,
  /// 不依赖构造器回退。
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF33301C),
    onPrimary: Color(0xFFFFF9EC),
    primaryContainer: Color(0xFF4B4629),
    onPrimaryContainer: Color(0xFFF1EBD2),
    secondary: Color(0xFF8C7400),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: accentYellow,
    onSecondaryContainer: onBrandYellow,
    tertiary: Color(0xFF6D6759),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFF1EEE5),
    onTertiaryContainer: Color(0xFF26231B),
    error: Color(0xFFD24B33),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF8DCD4),
    onErrorContainer: Color(0xFF4A130B),
    surface: Color(0xFFFFFEFB),
    onSurface: Color(0xFF1F1B16),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFAF8F4),
    surfaceContainer: Color(0xFFF4F2ED),
    surfaceContainerHigh: Color(0xFFEDEAE3),
    surfaceContainerHighest: Color(0xFFE7E4DC),
    surfaceDim: Color(0xFFE9E5DC),
    surfaceBright: Color(0xFFFFFEFB),
    onSurfaceVariant: Color(0xFF57534A),
    outline: Color(0xFF7E7970),
    outlineVariant: Color(0xFFDFDAD0),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF2B2722),
    onInverseSurface: Color(0xFFF8F5EF),
    inversePrimary: Color(0xFFE8D18C),
    surfaceTint: Color(0xFF33301C),
  );

  /// 暗色 ColorScheme:LiveDesign 暖黑同源(surface = LiveDesign.
  /// background #12100E 一族),按钮与选中态统一黄 #E9AC35(=
  /// [accentYellow] = LiveDesign.accent,用户认可的现状值,整套未动);
  /// 沉红只做错误/失败。
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFE9AC35),
    onPrimary: Color(0xFF201A00),
    primaryContainer: Color(0xFF4E3F1C),
    onPrimaryContainer: Color(0xFFF5E2B4),
    secondary: Color(0xFFE9AC35),
    onSecondary: Color(0xFF201A00),
    secondaryContainer: Color(0xFFE9AC35),
    onSecondaryContainer: Color(0xFF2B2300),
    tertiary: Color(0xFFD8C4A0),
    onTertiary: Color(0xFF3A2F16),
    tertiaryContainer: Color(0xFF52462B),
    onTertiaryContainer: Color(0xFFF5E0BE),
    error: Color(0xFFD24B33),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFF4F2119),
    onErrorContainer: Color(0xFFF8D9D0),
    surface: Color(0xFF12100E),
    onSurface: Color(0xFFF4EEE2),
    surfaceContainerLowest: Color(0xFF0C0A09),
    surfaceContainerLow: Color(0xFF1D1915),
    surfaceContainer: Color(0xFF25211A),
    surfaceContainerHigh: Color(0xFF2B2620),
    surfaceContainerHighest: Color(0xFF332D25),
    surfaceDim: Color(0xFF0A0908),
    surfaceBright: Color(0xFF3A342C),
    onSurfaceVariant: Color(0xFFA49988),
    outline: Color(0xFF8C8172),
    outlineVariant: Color(0xFF464037),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFF4EEE2),
    onInverseSurface: Color(0xFF201B16),
    inversePrimary: Color(0xFF7A5A10),
    surfaceTint: Color(0xFFE9AC35),
  );
}

/// 媒体查看黑 chrome:查看器/编辑页的纯黑底与白字层,主题无关
/// (内容叠层不随深浅模式,收编原先散落的 Colors.black/black87/
/// white/white70/white38)。
abstract final class AppMedia {
  static const background = Color(0xFF000000);
  static const chrome = Color(0xDD000000);
  static const onMedia = Color(0xFFFFFFFF);
  static const onMediaMuted = Color(0xB3FFFFFF);
  static const onMediaFaint = Color(0x61FFFFFF);
  static const onMediaSubtle = Color(0x8AFFFFFF); // 54%
  static const onMediaDim = Color(0x1FFFFFFF); // 12%(黑底 tonal 钮底)
}

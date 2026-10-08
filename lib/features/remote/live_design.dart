import 'package:flutter/material.dart';

/// 拍摄页调色板实例(OpenZCine LiveDesign 的 Flutter 移植口径):
/// 暖黑一套([LiveDesign.dark])+ 浅色一套([LiveDesign.light])。
/// 外围 chrome 经 [LiveDesign.of] 随应用主题取值;叠在取景画面上的
/// 内容层(横幅/即拍即览/监看叠层)恒用 [dark] —— 看图的内容层不随
/// 主题,同相册查看器的 AppMedia 口径(2026-10-08 用户拍板「改成跟随
/// 主题」)。
@immutable
class LivePalette {
  const LivePalette({
    required this.background,
    required this.surface,
    required this.glass,
    required this.hairline,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentDim,
    required this.onAccent,
    required this.good,
    required this.bad,
    required this.shutterRing,
    required this.shutterCore,
    required this.shutterCoreBusy,
  });

  /// 页面底色。
  final Color background;

  /// 实底面(参数面板/弹出菜单)。
  final Color surface;

  /// 浮层玻璃底 @72%。
  final Color glass;

  /// 玻璃描边 @14%。
  final Color hairline;

  /// 主文字。
  final Color text;

  /// 次文字(标签/自动值)。
  final Color muted;

  /// 弱文字(占位提示/禁用)。
  final Color faint;

  /// 金 accent:按钮/选中/进度,两套同值(= AppColors.accentYellow,
  /// v8「统一令」)。
  final Color accent;

  /// 金 @16%(选中底/按下态)。
  final Color accentDim;

  /// accent 实底上的前景(深字)。
  final Color onAccent;

  /// 成功/链路通。
  final Color good;

  /// 错误/失败/REC。
  final Color bad;

  /// 快门钮:外圈 / 芯(按下变 [shutterCoreBusy])/ 芯上文字与 spinner。
  final Color shutterRing;
  final Color shutterCore;
  final Color shutterCoreBusy;
}

abstract final class LiveDesign {
  /// 暖黑监看面(2026-10-08 用户认可的现状,值不另动):既是深色主题
  /// 下整页 chrome 的取值,也是**任何主题下**取景画面上内容层的取值。
  static const LivePalette dark = LivePalette(
    background: Color(0xFF12100E),
    surface: Color(0xFF25211A),
    glass: Color(0xB81B1713), // 暖黑玻璃 @72%
    hairline: Color(0x24F7EFE1), // 暖白描边 @14%
    text: Color(0xFFF4EEE2),
    muted: Color(0xFFA49988),
    faint: Color(0xFF746B5D),
    accent: Color(0xFFE9AC35),
    accentDim: Color(0x29E9AC35), // 金 @16%
    onAccent: Color(0xFF12100E),
    good: Color(0xFF2EC76B),
    bad: Color(0xFFD13437),
    shutterRing: Color(0xFFFFFFFF), // 用点 @92%
    shutterCore: Color(0xFFFFFFFF),
    shutterCoreBusy: Color(0x80FFFFFF), // 白 @50%
  );

  /// 浅色 chrome(v8「统一令」映射,与 AppColors.lightScheme 同源):
  /// 白底 + 墨字/次字 + 同一枚统一黄(按钮/选中/快门芯);红只做错误/
  /// REC(= 统一红 #D24B33);好 = successLight。
  static const LivePalette light = LivePalette(
    background: Color(0xFFFFFEFB), // = lightScheme.surface
    surface: Color(0xFFF4F2ED), // = lightScheme.surfaceContainer
    glass: Color(0xB8FFFFFF), // 白玻璃 @72%
    hairline: Color(0x241F1B16), // 墨描边 @14%
    text: Color(0xFF1F1B16), // = lightScheme.onSurface
    muted: Color(0xFF57534A), // = lightScheme.onSurfaceVariant
    faint: Color(0xFF8C8172),
    accent: Color(0xFFE9AC35), // 统一黄(两套同值)
    accentDim: Color(0x29E9AC35),
    onAccent: Color(0xFF3A3000), // = AppColors.onBrandYellow
    good: Color(0xFF1B7A45),
    bad: Color(0xFFD24B33),
    shutterRing: Color(0xFF1F1B16), // 墨圈(用点 @92%)
    shutterCore: Color(0xFFE9AC35), // 统一黄芯
    shutterCoreBusy: Color(0x29E9AC35), // 金 @16%
  );

  /// 外围 chrome 取值:随应用主题;内容层不随(恒 [dark])。
  static LivePalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 横屏侧栏监看几何:顶栏一条(高 48)+ 左参数栏(宽 [kParamRailWidth])
/// /右动作栏(宽 72)分贴两侧;贴边元素(横幅/直方图/即拍即览)经
/// RemoteFeedArea 的 inset 让位。
const kLandscapeTopBarHeight = 48.0;
const kParamRailWidth = 116.0;
/// 顶栏下沿的纵深(8 边距 + 48 栏高):侧栏/贴顶叠层由此起让位。
const kLandscapeTopInset = 56.0;
/// 左栏右沿(10 边距 + 116 栏宽 + 8 间隙):左下角叠层(直方图/即拍
/// 即览)由此起让位。栏宽 116 让常见档位(1/1000s、f/2.8、ISO 3200)
/// 完整显示(dense 值 14px)。
const kLandscapeLeftInset = 134.0;
/// 贴底动作行上沿(行高 72 + 8 间隙):横幅/直方图等贴底叠层由此起
/// 让位(2026-10-08 横屏动作行贴底起);右缘快门柱的居中区也以此为
/// 下界。
const kLandscapeBottomInset = 80.0;

/// 竖屏浮层纵深(8 边距 + ~44 信息胶囊高 + 4 呼吸):信息胶囊浮在
/// 取景画面上,贴顶叠层(即拍即览)由此起让位;辅助浮层锚在胶囊
/// 下方(2026-10-08 手机相机式竖屏排版)。
const kPortraitTopInset = 56.0;

/// 辅助浮层宽(监看开关 + 芯片组,两列 Wrap 的舒适宽;竖屏锚在胶囊
/// 下方 / 横屏让位右动作栏,共用)。
const kAssistPanelWidth = 300.0;

/// 参数面板列表条目高(ListTile 单行 = 48;itemExtent 固定后
/// 「打开定位到当前值」的偏移量才可计算)。
const kParamSheetItemExtent = 48.0;

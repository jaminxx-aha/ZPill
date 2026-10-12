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

/// 横屏监看几何:顶栏一条(高 48)/贴右快门柱(宽 78)分居上下右;
/// 贴边元素(横幅/直方图/即拍即览/录制读出)经 RemoteFeedArea 的
/// inset 让位。
const kLandscapeTopBarHeight = 48.0;
/// 顶栏下沿的纵深(8 边距 + 48 栏高):侧栏/贴顶叠层由此起让位。
const kLandscapeTopInset = 56.0;
/// 贴底条上沿(模式条 38/旋转钮 54 取大 + 6 边距 ≈ 60,再留 4 呼吸):
/// 横幅/直方图等贴底叠层由此起让位;右缘快门柱的居中区也以此为下界
/// (2026-10-10 手机相机式重排:动作行撤除,底条 = 模式条 + 旋转钮)。
const kLandscapeBottomInset = 64.0;

/// 竖屏浮层纵深(8 边距 + ~44 信息胶囊高 + 4 呼吸):信息胶囊浮在
/// 取景画面上,贴顶叠层(即拍即览)由此起让位;辅助浮层锚在胶囊
/// 下方(2026-10-08 手机相机式竖屏排版)。
const kPortraitTopInset = 56.0;

/// 竖屏底部两行 chrome 的高度账(控制行 6+78+2=86 + 底行 2+54=56):
/// 底部两行改**浮层压画面下沿**(2026-10-12 用户「按钮整体往下移」,
/// 取景画面全幅铺底恒满宽)后,设置浮层/横幅/直方图等贴底元素由此让位。
/// 六轮(同日):左右边距回 12、底距改**物理屏缘 20**(破手势条安全区,
/// 见 [kScreenEdgePadding],用户参照 iOS 相机底部按钮距离)。
const kPortraitBottomChromeHeight = 142.0;

/// **破安全区**的物理屏缘边距(2026-10-12 六轮用户定案,参照 iOS 相机
/// 底部按钮距屏底的距离):竖屏底区两行距物理屏底 / 横屏快门柱距物理
/// 屏右缘都用 20 —— 页面不再包 SafeArea(顶部 notch 经
/// MediaQuery.padding 手动补偿),这 20 里已含手势条/圆角区。代价见
/// 横屏:灵动岛在侧缘中点,岛侧方向快门右段会藏进岛里。
const kScreenEdgePadding = 20.0;

/// 拍摄浮层宽(设置面板三段/对焦面板的舒适宽;竖屏底锚居中 / 横屏
/// 让位右缘快门柱,共用。2026-10-10 辅助浮层改拍摄设置面板沿此宽)。
const kCapturePanelWidth = 300.0;

/// 参数面板列表条目高(ListTile 单行 = 48;itemExtent 固定后
/// 「打开定位到当前值」的偏移量才可计算)。
const kParamSheetItemExtent = 48.0;

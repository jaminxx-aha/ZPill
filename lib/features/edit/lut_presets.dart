/// 内置 LUT 风格(TODO §五 T4):程序化采样生成 3D LUT,免随包携带
/// .cube 文件;用户自备的 .cube 经剪贴板导入(编辑页 LUT 面板)。
library;

import 'dart:math' as math;

import '../../core/media/cube_lut.dart';

List<double> _clamp3(List<double> rgb) => [
      for (final v in rgb) v.clamp(0.0, 1.0),
    ];

List<double> _mixSat(List<double> rgb, double lum, double keep) =>
    [for (var i = 0; i < 3; i++) lum + (rgb[i] - lum) * keep];

double _lum(double r, double g, double b) =>
    0.2125 * r + 0.7154 * g + 0.0721 * b;

/// S 曲线:中段提对比、两端护住不裁切。
double _sCurve(double v, double strength) =>
    (v + strength * math.sin((v - 0.5) * math.pi)).clamp(0.0, 1.0);

/// 青橙(电影感):阴影偏青、高光/肤色偏橙,中段 S 曲线,轻降饱和。
List<double> _tealOrange(double r, double g, double b) {
  final lum = _lum(r, g, b);
  final shadow = 1 - lum, hi = lum;
  return _clamp3(_mixSat([
    _sCurve(r, 0.06) + 0.10 * hi - 0.05 * shadow,
    _sCurve(g, 0.06) + 0.02 * hi + 0.01 * shadow,
    _sCurve(b, 0.06) - 0.05 * hi + 0.05 * shadow,
  ], lum, 0.88));
}

/// 褪色胶片:黑位抬升(不纯黑)、轻降饱和、阴影偏黄绿。
List<double> _fadedFilm(double r, double g, double b) {
  const lift = 0.055, gain = 0.90;
  final lum = _lum(r, g, b);
  final shadow = 1 - lum;
  return _clamp3(_mixSat([
    lift + gain * r + 0.012 * shadow,
    lift + gain * g + 0.020 * shadow,
    lift * 0.9 + gain * b,
  ], lum, 0.80));
}

/// 冷调静谧:整体偏蓝、高光压一点、降饱和留对比。
List<double> _coolMatte(double r, double g, double b) {
  final lum = _lum(r, g, b);
  return _clamp3(_mixSat([
    _sCurve(r, 0.04) * 0.96,
    _sCurve(g, 0.04) * 0.97 + 0.01,
    _sCurve(b, 0.04) * 0.99 + 0.045,
  ], lum, 0.85));
}

// ---------------------------------------------------------------------------
// N-Log 还原(技术转换 LUT,非风格化)
// ---------------------------------------------------------------------------

/// N-Log 反传输函数(尼康官方逆向式,出处见 [_nLogToRec709]):
/// n = N-Log 10-bit 码值 / 1023(全量程归一)→ 线性反射率 y。
/// x < 127.23(反射率 0 的码值)解出负 y,截 0(超黑保护)。
double _nLogToLinear(double n) {
  final x = n * 1023.0;
  if (x < 452.0) {
    final t = x / 650.0;
    final y = t * t * t - 0.0075;
    return y < 0 ? 0.0 : y;
  }
  return math.exp((x - 619.0) / 150.0);
}

/// Rec.709 OETF(ITU-R BT.709-6):线性光 → 显示码值。
double _rec709Oetf(double l) =>
    l < 0.018 ? 4.5 * l : 1.099 * math.pow(l, 0.45).toDouble() - 0.099;

/// BT.2020 → BT.709 线性色域矩阵(ITU-R BT.2087-0 公布值,行主序;
/// 行和 = 1 白点守恒,与按两域 D65 原色坐标自行推导的结果吻合至 5e-5)。
const List<double> _bt2020ToBt709 = [
  1.6605, -0.5876, -0.0728, //
  -0.1246, 1.1329, -0.0083, //
  -0.0182, -0.1006, 1.1187, //
];

/// N-Log → Rec.709 还原:N-Log 归一码值(全量程 10-bit 码值 / 1023)
/// → 官方逆向传输函数 → 线性反射率(BT.2020 域)→ BT.2087 色域矩阵 →
/// Rec.709 OETF 显示。对数监看画面经此 LUT 回到标准对比度/色彩。
///
/// 公式出处(2026-10-14 检索,三源交叉一致):
/// ① 尼康官方《N-Log Specification Document》v1.0.0(2018-09-01)pp.4-5,
///    download.nikonimglib.com/archive3/hDCmK00m9JDI03RPruD74xpoU905/
///    N-Log_Specification_(En)01.pdf。逆向式官方原文:
///    `if (x < 452) y = (x/650)^3 − 0.0075; else y = exp[(x−619)/150]`
///    (x = 10-bit 码值,y = 反射率,y = 0.18 即 Stop 0);并载明色域 =
///    ITU-R BT.2020 原色 (0.708,0.292)/(0.170,0.797)/(0.131,0.046)、
///    白点 D65,故色域矩阵一并转换(BT.2020→BT.709,ITU-R BT.2087-0)。
/// ② colour-science 库 nikon_n_log.py(BSD-3):常数 650/1023、150/1023、
///    619/1023、452/1023、0.0075 与官方 PDF 逐项一致。
/// ③ EaryChow/Nikon-N-Log-EOTF-LUT-Generator(GitHub):同式独立实现。
///
/// 官方正变换锚点(反射率 → 码值):0% 黑 → 127.2、18% 灰 → 372.0、
/// 90% 白 → 603.2、分段点 y=0.328 → x=452(两段在此连续,偏差 <1e-3)、
/// 反射率 1.0 → 619。经本函数(灰轴,矩阵行和 = 1):
/// 18% 灰(n=0.36367)→ 0.409、90% 白(n=0.58963)→ 0.949
/// (= Rec.709 OETF 标准位约 41/95 IRE;对账见 lut_presets_test)。
///
/// 域外保护:超黑(负反射率)截 0;BT.709 域外负线性值截 0(硬裁,不做
/// 色域压缩);超白(反射率 > 1.0,即 n > 0.605)钳 1.0 —— 纯传输函数 +
/// 矩阵版,无高光软肩(官方还原 LUT 的滚降数据未公开,不臆造)。
///
/// 网格取 33³(其余风格 LUT 为 17³):色域矩阵是通道耦合的,3D 三线性
/// 插值下 17³ 的官方锚点误差最大 −6.7%(90% 白,矩阵负项偏角点拖累),
/// 33³ 收敛到 ±0.3% 以内;35937 格点生成/纹理开销可忽略。
List<double> _nLogToRec709(double r, double g, double b) {
  final lr = _nLogToLinear(r), lg = _nLogToLinear(g), lb = _nLogToLinear(b);
  double row(int i) {
    final v = _bt2020ToBt709[i] * lr +
        _bt2020ToBt709[i + 1] * lg +
        _bt2020ToBt709[i + 2] * lb;
    // 负线性值(709 域外)截 0 防负数开方,超白由 _clamp3 收口。
    return _rec709Oetf(v < 0 ? 0.0 : v);
  }

  return _clamp3([row(0), row(3), row(6)]);
}

/// 内置风格表(顺序即 UI 展示序)。监看 LUT 索引按本表序持久化
/// (monitor_toggles 的 monitorLutOf),**只可尾部追加、不得插中间**,
/// 否则老用户持久化索引会指到错误 LUT。
final List<CubeLut> builtinLuts = [
  CubeLut.fromFunction('青橙', 17, _tealOrange),
  CubeLut.fromFunction('褪色胶片', 17, _fadedFilm),
  CubeLut.fromFunction('冷调', 17, _coolMatte),
  CubeLut.fromFunction('N-Log 还原', 33, _nLogToRec709),
];

/// builtinLuts 标题的 UI 显示键边车表:title 本身是数据(进 .cube 导出
/// 管线与 edit 页 name→lut 映射,不键化),显示点经 [lutTitleKey] 转键;
/// 运行期导入的 .cube TITLE 原样透传,t() 两表未命中即直通。
const Map<String, String> _lutTitleKeys = {
  '青橙': 'lut.tealOrange',
  '褪色胶片': 'lut.fadedFilm',
  '冷调': 'lut.coolMatte',
  'N-Log 还原': 'lut.nlogConvert',
};

String lutTitleKey(String title) => _lutTitleKeys[title] ?? title;

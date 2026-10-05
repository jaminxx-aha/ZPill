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

/// 内置风格表(顺序即 UI 展示序)。
final List<CubeLut> builtinLuts = [
  CubeLut.fromFunction('青橙', 17, _tealOrange),
  CubeLut.fromFunction('褪色胶片', 17, _fadedFilm),
  CubeLut.fromFunction('冷调', 17, _coolMatte),
];

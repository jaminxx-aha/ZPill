/// 3D LUT(.cube 格式)解析与应用(TODO §五 T4:图库编辑 + 预览风格)。
///
/// Adobe SpeedGrade .cube 公开规范:
/// - `TITLE "..."` 可选标题
/// - `LUT_3D_SIZE N` 必需(N ≥ 2,表共 N³ 行)
/// - `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` 可选,默认 0..1
/// - 数据行 `r g b` 浮点,红通道索引变化最快(第 j 行:r = j%N、
///   g = (j/N)%N、b = j/N²)
///
/// 应用走三线性插值(8 角点按分数距离加权),输入钳在域内。解析
/// 容错:注释 `#` 与空行跳过、关键字大小写不敏感;缺 LUT_3D_SIZE、
/// 行数与 N³ 不符、非三列浮点、LUT_1D_SIZE(一维表)→ FormatException
/// 带行号,调用方按导入失败提示。
library;

import 'dart:convert';
import 'dart:typed_data';

final class CubeLut {
  CubeLut._(this.title, this.size, this._domainMin, this._domainMax,
      this._table);

  /// 表标题(无 TITLE 行时空串)。
  final String title;

  /// 每轴格点数 N(全表 N³ 项)。
  final int size;

  final List<double> _domainMin; // 3
  final List<double> _domainMax; // 3
  final Float32List _table; // N³ × 3,行序 = 文件序(红最快)

  /// 解析 .cube 文本;格式不符抛 [FormatException](带行号)。
  factory CubeLut.parse(String text) {
    String? title;
    int? size;
    final domainMin = <double>[0, 0, 0];
    final domainMax = <double>[1, 1, 1];
    final values = <double>[];

    var lineNo = 0;
    for (final raw in const LineSplitter().convert(text)) {
      lineNo++;
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final keyword = line.split(RegExp(r'[\s(]')).first.toUpperCase();

      List<double> numbers() {
        final parts = line
            .substring(keyword.length)
            .trim()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
        return [
          for (final p in parts)
            double.tryParse(p) ??
                (throw FormatException('非法数值 "$p"', text, lineNo)),
        ];
      }

      switch (keyword) {
        case 'TITLE':
          final rest = line.substring(5).trim();
          title = rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')
              ? rest.substring(1, rest.length - 1)
              : rest;
        case 'LUT_3D_SIZE':
          final nums = numbers();
          if (nums.length != 1 || nums[0] < 2 || nums[0] > 256) {
            throw FormatException('LUT_3D_SIZE 应为单个 2..256 的整数',
                text, lineNo);
          }
          size = nums[0].round();
        case 'LUT_1D_SIZE':
          throw FormatException('一维 LUT 不支持(需 LUT_3D_SIZE)', text, lineNo);
        case 'DOMAIN_MIN':
          final nums = numbers();
          if (nums.length != 3) {
            throw FormatException('DOMAIN_MIN 应为 3 个数', text, lineNo);
          }
          domainMin
            ..[0] = nums[0]
            ..[1] = nums[1]
            ..[2] = nums[2];
        case 'DOMAIN_MAX':
          final nums = numbers();
          if (nums.length != 3) {
            throw FormatException('DOMAIN_MAX 应为 3 个数', text, lineNo);
          }
          domainMax
            ..[0] = nums[0]
            ..[1] = nums[1]
            ..[2] = nums[2];
        default:
          // 数据行:整行按空白切(首 token 本身就是数值)。
          final parts = line
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .toList();
          if (parts.length != 3) {
            throw FormatException('数据行应为 3 个数(r g b)', text, lineNo);
          }
          for (final p in parts) {
            final v = double.tryParse(p);
            if (v == null) {
              throw FormatException('非法数值 "$p"', text, lineNo);
            }
            values.add(v);
          }
      }
    }

    final n = size;
    if (n == null) {
      throw const FormatException('缺少 LUT_3D_SIZE 行');
    }
    final expected = n * n * n * 3;
    if (values.length < expected) {
      throw FormatException('数据行不足:期望 ${n * n * n} 行,实得 '
          '${values.length ~/ 3} 行');
    }
    if (values.length > expected) {
      throw FormatException('数据行超出:期望 ${n * n * n} 行,实得 '
          '${values.length ~/ 3} 行');
    }
    for (var i = 0; i < 3; i++) {
      if (domainMax[i] <= domainMin[i]) {
        throw const FormatException('DOMAIN_MAX 必须大于 DOMAIN_MIN');
      }
    }
    return CubeLut._(
        title ?? '', n, domainMin, domainMax, Float32List.fromList(values));
  }

  /// 按变换函数采样生成 LUT(内置风格用):对每个格点调 [transform]
  /// (输入输出均为 0..1),返回 N³ 表。
  factory CubeLut.fromFunction(
      String title, int size, List<double> Function(double r, double g, double b) transform) {
    final table = Float32List(size * size * size * 3);
    var i = 0;
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final out = transform(r / (size - 1), g / (size - 1), b / (size - 1));
          table[i++] = out[0];
          table[i++] = out[1];
          table[i++] = out[2];
        }
      }
    }
    return CubeLut._(title, size, [0, 0, 0], [1, 1, 1], table);
  }

  /// 从既有表构造(固定 0..1 域):XMP RGBTable 解码链等内部产出的
  /// 表直接入库,不再经 .cube 文本往返。[table] 为 size³×3(红最快),
  /// 值须有限;尺寸/长度/值不符抛 [FormatException]。
  factory CubeLut.fromTable(String title, int size, List<double> table) {
    if (size < 2 || size > 256) {
      throw FormatException('LUT 尺寸应为 2..256,得 $size');
    }
    final expected = size * size * size * 3;
    if (table.length != expected) {
      throw FormatException('表长应为 $expected($size³×3),得 ${table.length}');
    }
    for (final v in table) {
      if (!v.isFinite) {
        throw const FormatException('表值须为有限数');
      }
    }
    return CubeLut._(title, size, [0, 0, 0], [1, 1, 1],
        Float32List.fromList(table));
  }

  /// 三线性插值:输入输出均为 0..1(RGB 归一化),输入超出按端点取值。
  List<double> apply(double r, double g, double b) {
    final x = _toGrid(r, 0), y = _toGrid(g, 1), z = _toGrid(b, 2);
    final x0 = x.floor(), y0 = y.floor(), z0 = z.floor();
    final x1 = (x0 + 1).clamp(0, size - 1),
        y1 = (y0 + 1).clamp(0, size - 1),
        z1 = (z0 + 1).clamp(0, size - 1);
    final fx = x - x0, fy = y - y0, fz = z - z0;

    List<double> corner(int rx, int gy, int bz) {
      final i = ((bz * size + gy) * size + rx) * 3;
      return [_table[i], _table[i + 1], _table[i + 2]];
    }

    final c000 = corner(x0, y0, z0), c100 = corner(x1, y0, z0);
    final c010 = corner(x0, y1, z0), c110 = corner(x1, y1, z0);
    final c001 = corner(x0, y0, z1), c101 = corner(x1, y0, z1);
    final c011 = corner(x0, y1, z1), c111 = corner(x1, y1, z1);

    double lerp(double a, double b, double t) => a + (b - a) * t;
    return [
      for (var ch = 0; ch < 3; ch++)
        lerp(
          lerp(lerp(c000[ch], c100[ch], fx), lerp(c010[ch], c110[ch], fx), fy),
          lerp(lerp(c001[ch], c101[ch], fx), lerp(c011[ch], c111[ch], fx), fy),
          fz,
        ),
    ];
  }

  /// 输入(0..1)→ 格点坐标([0, size-1]),并钳在域内。
  double _toGrid(double v, int ch) {
    final lo = _domainMin[ch], hi = _domainMax[ch];
    final t = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    return t * (size - 1);
  }

  /// 监看 shader 查表纹理(RGBA8 扁平化):宽 = N²、高 = N,像素按
  /// 行主序展开,纹理坐标 (x = r + g·N, y = b) —— 与 [apply] 的表序
  /// (b 最慢/r 最快)一致,shader 侧按同布局做三线性查表。
  ///
  /// 仅对 0..1 域语义正确(内置风格表即此;带 DOMAIN 偏移的外来表
  /// 纹理化后输入映射会偏移,调用方避免用于非 0..1 域)。
  Uint8List textureRgba() {
    final out = Uint8List(_table.length ~/ 3 * 4);
    var j = 0;
    for (var i = 0; i < _table.length; i += 3) {
      out[j++] = (_table[i] * 255).round().clamp(0, 255);
      out[j++] = (_table[i + 1] * 255).round().clamp(0, 255);
      out[j++] = (_table[i + 2] * 255).round().clamp(0, 255);
      out[j++] = 255;
    }
    return out;
  }
}

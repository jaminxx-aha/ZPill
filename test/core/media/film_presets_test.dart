import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/film_presets.dart';
import 'package:nikon_pill/core/media/image_edit.dart';

FilmPreset _byId(String id) => filmPresets.firstWhere((p) => p.id == id);

/// 表内黑白族(参考仓 creativeStyle 黑白 / 效果 高对比度黑白;
/// leicaMonochrome 是手调亮度矩阵,一并入列)—— 三行等值的严格灰。
/// ACROS 的 Ye/R/G 滤镜款带白平衡折叠(色调单色)、fujiSepia 棕褐是
/// 暖调单色,均在测试里单独断言。
const List<String> _bwIds = [
  'fujiAcros', //
  'kodakTriX400', 'kodakTMax', 'kodakTriX1600', //
  'ricohGRHiBw', 'ricohGRHardBw', 'ricohGRSoftBw', //
  'panaLMonochromeD', //
  'ilfordHP5', 'ilfordFP4', 'ilfordDelta100', 'ilfordDelta3200',
  'ilfordPanF50', //
  'leicaMonochrome',
];

void main() {
  test('applyColorMatrix:单位阵零改动(逐字节相等)', () {
    final rgba = Uint8List.fromList([
      for (var i = 0; i < 32; i++) ...[
        (i * 8) % 256, 255 - (i * 8) % 256, i, 255,
      ],
    ]);
    final copy = Uint8List.fromList(rgba);
    applyColorMatrix(rgba, kIdentityColorMatrix);
    expect(rgba, copy);
  });

  test('applyColorMatrix:已知矩阵手算值、越界钳位、alpha 行参与运算', () {
    // r'=1.1r+0.2g-30,g'=0.9g+5,b'=0.5b+0.5a,a'=0.5a(通道行非单位阵)。
    final m = <double>[
      1.1, 0.2, 0, 0, -30, //
      0, 0.9, 0, 0, 5, //
      0, 0, 0.5, 0.5, 0, //
      0, 0, 0, 0.5, 0, //
    ];
    final rgba = Uint8List.fromList([100, 200, 60, 200, 250, 250, 250, 255]);
    applyColorMatrix(rgba, m);
    // 像素 1:r'=110+40-30=120,g'=180+5=185,b'=30+100=130,a'=100。
    expect(rgba.sublist(0, 4), [120, 185, 130, 100]);
    // 像素 2:r'=295→钳 255,g'=230,b'=252.5→四舍五入 253,a'=127.5→128。
    expect(rgba.sublist(4, 8), [255, 230, 253, 128]);
  });

  test('预设表:87 款与参考仓对账(77 相机配方 + 10 经典精选),id 唯一',
      () {
    expect(filmPresets.length, 87);
    expect(filmPresets.map((p) => p.id).toSet().length, 87);
    // 参考仓手调矩阵 12 款 id 全部在表。
    const handTunedIds = [
      'original', 'fairSkin', 'warmPortrait', 'japanesePure', //
      'shinkaiAnime', 'cityNight', 'forestGreen', 'floralBotanical', //
      'classicChrome', 'leicaMonochrome', 'clearSky', 'cinematic',
    ];
    for (final id in handTunedIds) {
      expect(filmPresets.any((p) => p.id == id), isTrue, reason: id);
    }
  });

  test('预设表:矩阵 20 元素全有限、alpha 行单位阵、分组与双语名齐备', () {
    for (final p in filmPresets) {
      expect(p.matrix.length, 20, reason: p.id);
      expect(p.matrix.every((v) => v.isFinite), isTrue, reason: p.id);
      expect(p.matrix.sublist(15), [0, 0, 0, 1, 0], reason: p.id);
      expect(filmPresetGroups.contains(p.group), isTrue, reason: p.id);
      expect(p.nameZh, isNotEmpty, reason: p.id);
      expect(p.nameEn, isNotEmpty, reason: p.id);
    }
    // 分组目录 7 组每组非空。
    for (final g in filmPresetGroups) {
      expect(filmPresets.any((p) => p.group == g), isTrue, reason: g);
    }
  });

  test('手调矩阵原值对账:Nikon-SnapLink(MIT)数值逐项相等', () {
    expect(_byId('original').matrix, kIdentityColorMatrix);
    expect(_byId('classicChrome').matrix, const [
      1.08, -0.05, -0.03, 0, -2, //
      -0.03, 1.02, -0.02, 0, 1, //
      -0.05, -0.02, 1.12, 0, 4, //
      0, 0, 0, 1, 0, //
    ]);
    expect(_byId('leicaMonochrome').matrix, const [
      0.35, 0.65, 0.15, 0, -10, //
      0.35, 0.65, 0.15, 0, -10, //
      0.35, 0.65, 0.15, 0, -10, //
      0, 0, 0, 1, 0, //
    ]);
    expect(_byId('cinematic').matrix, const [
      1.24, -0.06, -0.12, 0, 6, //
      -0.06, 1.08, 0.06, 0, -4, //
      -0.14, 0.04, 1.28, 0, 8, //
      0, 0, 0, 1, 0, //
    ]);
  });

  test('黑白族:彩色输入映射为等值灰;滤镜款行间等比(sVal 钳 0 行为锁)',
      () {
    // 参考仓 sat/vib 双 -100 折算 sVal=-0.9 会得色相翻转伪彩;本库
    // 钳 0 = 亮度去饱和 —— 任意彩色进出黑白族,三通道必须相等。
    const samples = [(200, 40, 90), (60, 180, 30), (10, 20, 220), (255, 255, 0)];
    for (final id in _bwIds) {
      final m = _byId(id).matrix;
      int ch((int, int, int) px, int row) =>
          (m[row * 5] * px.$1 + m[row * 5 + 1] * px.$2 +
                  m[row * 5 + 2] * px.$3 + m[row * 5 + 4])
              .round()
              .clamp(0, 255);
      for (final px in samples) {
        expect(ch(px, 0), ch(px, 1), reason: '$id $px R==G');
        expect(ch(px, 1), ch(px, 2), reason: '$id $px G==B');
      }
    }
    // ACROS 滤镜款(Ye/R/G,参考仓带 wb 折叠):三行 RGB 系数等比 = 同一
    // 亮度行的逐行曝光缩放(色调单色),不引入逐通道色相混合。
    for (final id in ['fujiAcrosYe', 'fujiAcrosR', 'fujiAcrosG']) {
      final m = _byId(id).matrix;
      final k1 = m[5] / m[0], k2 = m[10] / m[0];
      expect(m[6] / m[1], closeTo(k1, 1e-4), reason: id);
      expect(m[7] / m[2], closeTo(k1, 1e-4), reason: id);
      expect(m[11] / m[1], closeTo(k2, 1e-4), reason: id);
      expect(m[12] / m[2], closeTo(k2, 1e-4), reason: id);
    }
    // 棕褐色是暖调单色:灰输入应得 r > b(高光暖、阴影暖),非纯灰。
    final sepia = _byId('fujiSepia').matrix;
    int sep((int, int, int) px, int row) =>
        (sepia[row * 5] * px.$1 + sepia[row * 5 + 1] * px.$2 +
                sepia[row * 5 + 2] * px.$3 + sepia[row * 5 + 4])
            .round()
            .clamp(0, 255);
    expect(sep((128, 128, 128), 0), greaterThan(sep((128, 128, 128), 2)));
  });

  test('交叉对账:image_edit 像素路径与 applyColorMatrix 字节版同果(87 款全量)',
      () {
    // 合成渐变图(3 通道,与 JPEG 解码形态一致);每款预设分别走
    // applyEditToImage(img.Image)与 applyColorMatrix(Uint8List)两条
    // 实现,结果必须逐通道相等 —— 锁死两条路径的数学一致性。
    const w = 33, h = 17;
    final src = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src.setPixelRgba(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1),
            (x * 13 + y * 29) % 256, 255);
      }
    }
    final packed = Uint8List(w * h * 4);
    var i = 0;
    for (final p in src) {
      packed
        ..[i++] = p.r.toInt()
        ..[i++] = p.g.toInt()
        ..[i++] = p.b.toInt()
        ..[i++] = 255;
    }
    for (final preset in filmPresets) {
      final out = applyEditToImage(src, PhotoEdit(filmPreset: preset));
      final bytes = Uint8List.fromList(packed);
      applyColorMatrix(bytes, preset.matrix);
      var j = 0;
      var mismatches = 0;
      for (final p in out) {
        if (p.r != bytes[j] || p.g != bytes[j + 1] || p.b != bytes[j + 2]) {
          mismatches++;
        }
        j += 4;
      }
      expect(mismatches, 0, reason: preset.id);
    }
  });
}

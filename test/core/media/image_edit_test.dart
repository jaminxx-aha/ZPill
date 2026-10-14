import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/cube_lut.dart';
import 'package:nikon_pill/core/media/image_edit.dart';
import 'package:nikon_pill/core/media/watermark.dart'
    show exifCardDataOf, readJpegExif;

img.Image _gradient(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1), 128, 255);
    }
  }
  return image;
}

Uint8List _jpeg(img.Image image) => Uint8List.fromList(img.encodeJpg(image));

void main() {
  test('decodeForEdit:长边缩放、短边等比;小图不动', () {
    final big = _jpeg(_gradient(400, 200));
    final frame = decodeForEdit(big, maxEdge: 100)!;
    expect(frame.width, 100);
    expect(frame.height, 50);

    final small = _jpeg(_gradient(80, 60));
    expect(decodeForEdit(small, maxEdge: 1600)!.width, 80);
  });

  test('decodeForEdit:非 JPEG 返回 null', () {
    expect(decodeForEdit(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('rotateRect:顺/逆互逆,四次回到原位', () {
    final r = const Rect.fromLTRB(0.1, 0.2, 0.6, 0.7);
    var cw = rotateRectClockwise(r);
    cw = rotateRectClockwise(cw);
    cw = rotateRectClockwise(cw);
    cw = rotateRectClockwise(cw);
    expect(cw.left, closeTo(r.left, 1e-9));
    expect(cw.top, closeTo(r.top, 1e-9));
    expect(cw.right, closeTo(r.right, 1e-9));
    expect(cw.bottom, closeTo(r.bottom, 1e-9));

    // 逆时针两次 = 180°(左上角翻到右下角)
    var ccw = rotateRectCounterClockwise(r);
    ccw = rotateRectCounterClockwise(ccw);
    expect(ccw.left, closeTo(0.4, 1e-9));
    expect(ccw.top, closeTo(0.3, 1e-9));
    expect(ccw.right, closeTo(0.9, 1e-9));
    expect(ccw.bottom, closeTo(0.8, 1e-9));
    ccw = rotateRectCounterClockwise(ccw);
    ccw = rotateRectCounterClockwise(ccw);
    expect(ccw.left, closeTo(r.left, 1e-9));
    expect(ccw.top, closeTo(r.top, 1e-9));

    // 顺一次再逆一次 = 恒等
    final roundTrip =
        rotateRectCounterClockwise(rotateRectClockwise(r));
    expect(roundTrip.left, closeTo(r.left, 1e-9));
    expect(roundTrip.top, closeTo(r.top, 1e-9));
    expect(roundTrip.bottom, closeTo(r.bottom, 1e-9));
  });

  test('旋转 90°:宽高互换,角点像素位置符合顺时针', () {
    // 4×2:左上角红、右上角蓝。顺时针 90° 后红到右上、蓝到右下。
    final image = img.Image(width: 4, height: 2);
    for (var x = 0; x < 4; x++) {
      for (var y = 0; y < 2; y++) {
        image.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }
    image.setPixelRgba(0, 0, 255, 0, 0, 255);
    image.setPixelRgba(3, 0, 0, 0, 255, 255);

    final out = applyEditToImage(
        image, const PhotoEdit(rotationQuarter: 1));
    expect(out.width, 2);
    expect(out.height, 4);
    expect(out.getPixel(1, 0).r, 255); // 红到右上
    expect(out.getPixel(1, 3).b, 255); // 蓝到右下
  });

  test('裁剪:归一化矩形在旋转后坐标系取中带', () {
    final out = applyEditToImage(
      _gradient(100, 50),
      const PhotoEdit(
        rotationQuarter: 1,
        cropRect: Rect.fromLTRB(0.25, 0.25, 0.75, 0.75),
      ),
    );
    // 旋转后画幅 50×100;裁 50% → 25×50
    expect(out.width, 25);
    expect(out.height, 50);
  });

  test('饱和度 0 → 灰度;亮度 > 1 提亮', () {
    final image = img.Image(width: 3, height: 1);
    image.setPixelRgba(0, 0, 200, 100, 50, 255);
    image.setPixelRgba(1, 0, 200, 100, 50, 255);
    image.setPixelRgba(2, 0, 200, 100, 50, 255);

    final gray = applyEditToImage(
      image,
      const PhotoEdit(
          adjustments: EditAdjustments(saturation: 0)),
    );
    final p = gray.getPixel(0, 0);
    expect(p.r, p.g);
    expect(p.g, p.b);

    final bright = applyEditToImage(
      image,
      const PhotoEdit(
          adjustments: EditAdjustments(brightness: 1.5)),
    );
    expect(bright.getPixel(0, 0).r,
        greaterThan(p.r + 10));
  });

  test('暖调:正暖阴影偏暖(红升蓝降),负暖反向', () {
    img.Image mk() {
      final image = img.Image(width: 2, height: 1);
      image.setPixelRgba(0, 0, 60, 60, 60, 255);
      image.setPixelRgba(1, 0, 60, 60, 60, 255);
      return image;
    }
    final warm = applyEditToImage(
        mk(),
        const PhotoEdit(
            adjustments: EditAdjustments(warmth: 1)));
    final cool = applyEditToImage(
        mk(),
        const PhotoEdit(
            adjustments: EditAdjustments(warmth: -1)));
    final w = warm.getPixel(0, 0);
    final c = cool.getPixel(0, 0);
    expect(w.r, greaterThan(w.b));
    expect(c.b, greaterThan(c.r));
  });

  test('LUT:inverts 表插值反色', () {
    final invert = CubeLut.fromFunction(
        'inv', 3, (r, g, b) => [1 - r, 1 - g, 1 - b]);
    final image = img.Image(width: 3, height: 1);
    image.setPixelRgba(0, 0, 255, 0, 0, 255);
    image.setPixelRgba(1, 0, 0, 255, 0, 255);
    image.setPixelRgba(2, 0, 0, 0, 255, 255);
    final out = applyEditToImage(
        image, PhotoEdit(lut: invert));
    expect(out.getPixel(0, 0).r, lessThan(10));
    expect(out.getPixel(0, 0).b, greaterThan(240));
    expect(out.getPixel(1, 0).g, lessThan(10)); // 绿 → 品红
    expect(out.getPixel(1, 0).r, greaterThan(240));
  });

  test('LUT 恒等表:烘焙链逐像素字节相等(零改动语义)', () {
    // 保存链经 applyEditToImage 逐像素查表;恒等表必须原样往返,
    // 锁死「LUT 为 null 时零改动」之外的第二层零改动语义。
    final identity = CubeLut.fromFunction('identity', 2, (r, g, b) => [r, g, b]);
    final src = _gradient(64, 32);
    final out = applyEditToImage(src, PhotoEdit(lut: identity));
    expect(out.width, 64);
    expect(out.height, 32);
    var diff = 0;
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final s = src.getPixel(x, y), d = out.getPixel(x, y);
        if (s.r != d.r || s.g != d.g || s.b != d.b) diff++;
      }
    }
    expect(diff, 0);
  });

  test('管线顺序:先裁剪后调色(裁剪尺寸决定,调节不改尺寸)', () {
    final out = applyEditToImage(
      _gradient(80, 40),
      const PhotoEdit(
        cropRect: Rect.fromLTRB(0, 0, 0.5, 1),
        adjustments: EditAdjustments(brightness: 1.2),
      ),
    );
    expect(out.width, 40);
    expect(out.height, 40);
  });

  test('applyEdit:中性参数原样直返(同一实例)', () {
    final jpeg = _jpeg(_gradient(40, 30));
    final out = applyEdit(jpeg, const PhotoEdit());
    expect(identical(out, jpeg), isTrue);
  });

  test('applyEdit:非 JPEG 原样直返;旋转可解码输出', () {
    final notJpeg = Uint8List.fromList(List.filled(64, 7));
    expect(identical(applyEdit(notJpeg, const PhotoEdit(rotationQuarter: 2)), notJpeg),
        isTrue);

    final rotated =
        applyEdit(_jpeg(_gradient(40, 30)), const PhotoEdit(rotationQuarter: 1));
    final decoded = img.decodeJpg(rotated)!;
    expect(decoded.width, 30);
    expect(decoded.height, 40);
  });

  test('applyEdit:EXIF 随行(旋转重编码后卡片字段仍可读)', () {
    final image = _gradient(60, 40);
    image.exif.imageIfd[0x0132] = '2026:10:05 08:00:00';
    final jpeg = Uint8List.fromList(img.encodeJpg(image));

    final out = applyEdit(jpeg, const PhotoEdit(rotationQuarter: 1));
    final card = exifCardDataOf(readJpegExif(out)!);
    expect(card.takenAt, isNotNull);
  });
}

import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/cube_lut.dart';
import 'package:nikon_pill/core/media/image_edit.dart';
import 'package:nikon_pill/features/edit/edit_controller.dart';

Uint8List _jpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1), 128, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 纯色图:LUT 断言走 JPEG 往返,纯色压缩噪声最小、期望值可手算。
Uint8List _solidJpeg(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  test('初始化:预览渲染就绪、参数中性', () {
    final c = EditController(jpeg: _jpeg(100, 80));
    expect(c.isReady, isTrue);
    expect(c.previewJpeg, isNotNull);
    expect(c.edited, isFalse);
    expect(c.frameSize, const Size(100, 80));
  });

  test('非 JPEG:isReady=false,预览为空,操作不炸', () {
    final c = EditController(
        jpeg: Uint8List.fromList([1, 2, 3]));
    expect(c.isReady, isFalse);
    expect(c.previewJpeg, isNull);
    c
      ..rotateRight()
      ..updateAdjustments(
          const EditAdjustments(brightness: 1.5))
      ..setLut(CubeLut.fromFunction('i', 2, (r, g, b) => [r, g, b]))
      ..setCrop(const Rect.fromLTRB(0, 0, 0.5, 0.5))
      ..reset();
    expect(c.edited, isFalse);
    expect(c.renderCropBackdrop(), isNull);
  });

  test('旋转:frameSize 宽高互换,裁剪框随轴换位', () {
    final c = EditController(jpeg: _jpeg(200, 100));
    c.setCrop(const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6));
    c.rotateRight();
    expect(c.frameSize, const Size(100, 200));
    // CW:x' = 1-b, y' = l → (0.1,0.2,0.5,0.6) → (0.4, 0.1, 0.8, 0.5)
    final crop = c.cropRect!;
    expect(crop.left, closeTo(0.4, 1e-9));
    expect(crop.top, closeTo(0.1, 1e-9));
    expect(crop.right, closeTo(0.8, 1e-9));
    expect(crop.bottom, closeTo(0.5, 1e-9));
    expect(c.edited, isTrue);
  });

  test('renderFull:原分辨率(非预览分辨率)应用参数', () {
    // 原图 80×60,预览上限 40 → 交互帧 40×30;保存必须回 60×80。
    final c = EditController(jpeg: _jpeg(80, 60), maxPreviewEdge: 40);
    expect(c.frameSize, const Size(40, 30));
    c.rotateRight();
    final out = c.renderFull();
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, 60);
    expect(decoded.height, 80);
  });

  test('renderFull:LUT 烘焙进原分辨率输出(反色)', () {
    // 纯色 (200,100,50) → 反色 (55,155,205);走两轮 JPEG 往返,
    // 区间放宽容压缩噪声,但远区别于无 LUT 的原值。
    final c = EditController(
        jpeg: _solidJpeg(80, 60, 200, 100, 50), maxPreviewEdge: 40);
    c.setLut(
        CubeLut.fromFunction('inv', 3, (r, g, b) => [1 - r, 1 - g, 1 - b]));
    final decoded = img.decodeJpg(c.renderFull())!;
    expect(decoded.width, 80); // 原分辨率(预览档是 40×30)
    expect(decoded.height, 60);
    final p = decoded.getPixel(0, 0);
    expect(p.r, inInclusiveRange(40, 70));
    expect(p.g, inInclusiveRange(140, 170));
    expect(p.b, inInclusiveRange(190, 220));
  });

  test('中性时 renderFull 原字节直返', () {
    final jpeg = _jpeg(60, 40);
    final c = EditController(jpeg: jpeg);
    expect(identical(c.renderFull(), jpeg), isTrue);
  });

  test('reset:回到中性,预览重渲染', () {
    final c = EditController(jpeg: _jpeg(100, 80));
    c
      ..rotateRight()
      ..setCrop(const Rect.fromLTRB(0, 0, 0.5, 0.5))
      ..updateAdjustments(const EditAdjustments(saturation: 0))
      ..reset();
    expect(c.edited, isFalse);
    expect(c.frameSize, const Size(100, 80));
    expect(c.cropRect, isNull);
  });

  test('监听:每次操作触发 notifyListeners', () {
    final c = EditController(jpeg: _jpeg(60, 40));
    var notified = 0;
    c.addListener(() => notified++);
    c.rotateLeft();
    c.setCrop(null);
    c.updateAdjustments(const EditAdjustments(brightness: 1.1));
    c.setLut(CubeLut.fromFunction('x', 2, (r, g, b) => [r, g, b]));
    c.reset();
    expect(notified, 5);
  });
}

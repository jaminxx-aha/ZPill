import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/cube_lut.dart';
import 'package:nikon_pill/core/media/film_presets.dart';
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
  test('初始化:引导后预览渲染就绪、参数中性', () async {
    final c = EditController(jpeg: _jpeg(100, 80));
    await c.ready;
    expect(c.isReady, isTrue);
    expect(c.booting, isFalse);
    expect(c.previewJpeg, isNotNull);
    expect(c.edited, isFalse);
    expect(c.frameSize, const Size(100, 80));
  });

  test('引导中:booting=true,ready 后收口', () {
    final c = EditController(jpeg: _jpeg(100, 80));
    expect(c.booting, isTrue); // 引导异步启动,同轮事件循环内必然未落
    return c.ready.then((_) {
      expect(c.booting, isFalse);
      c.dispose();
    });
  });

  test('非 JPEG:引导完成 isReady=false,预览为空,操作不炸', () async {
    final c = EditController(
        jpeg: Uint8List.fromList([1, 2, 3]));
    await c.ready;
    expect(c.isReady, isFalse);
    expect(c.previewJpeg, isNull);
    c
      ..rotateRight()
      ..updateAdjustments(
          const EditAdjustments(brightness: 1.5))
      ..setLut(CubeLut.fromFunction('i', 2, (r, g, b) => [r, g, b]))
      ..setCrop(const Rect.fromLTRB(0, 0, 0.5, 0.5))
      ..reset();
    await c.rendered;
    expect(c.edited, isFalse);
    expect(await c.renderCropBackdrop(), isNull);
    c.dispose();
  });

  test('旋转:frameSize 宽高互换,裁剪框随轴换位', () async {
    final c = EditController(jpeg: _jpeg(200, 100));
    await c.ready;
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
    c.dispose();
  });

  test('renderFull:原分辨率(非预览分辨率)应用参数', () async {
    // 原图 80×60,预览上限 40 → 交互帧 40×30;保存必须回 60×80。
    final c = EditController(jpeg: _jpeg(80, 60), maxPreviewEdge: 40);
    await c.ready;
    expect(c.frameSize, const Size(40, 30));
    c.rotateRight();
    final out = c.renderFull();
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, 60);
    expect(decoded.height, 80);
    c.dispose();
  });

  test('renderFull:LUT 烘焙进原分辨率输出(反色)', () async {
    // 纯色 (200,100,50) → 反色 (55,155,205);走两轮 JPEG 往返,
    // 区间放宽容压缩噪声,但远区别于无 LUT 的原值。
    final c = EditController(
        jpeg: _solidJpeg(80, 60, 200, 100, 50), maxPreviewEdge: 40);
    await c.ready;
    c.setLut(
        CubeLut.fromFunction('inv', 3, (r, g, b) => [1 - r, 1 - g, 1 - b]));
    final decoded = img.decodeJpg(c.renderFull())!;
    expect(decoded.width, 80); // 原分辨率(预览档是 40×30)
    expect(decoded.height, 60);
    final p = decoded.getPixel(0, 0);
    expect(p.r, inInclusiveRange(40, 70));
    expect(p.g, inInclusiveRange(140, 170));
    expect(p.b, inInclusiveRange(190, 220));
    c.dispose();
  });

  test('中性时 renderFull 原字节直返', () async {
    final jpeg = _jpeg(60, 40);
    final c = EditController(jpeg: jpeg);
    await c.ready;
    expect(identical(c.renderFull(), jpeg), isTrue);
    c.dispose();
  });

  test('reset:回到中性,预览重渲染', () async {
    final c = EditController(jpeg: _jpeg(100, 80));
    await c.ready;
    c
      ..rotateRight()
      ..setCrop(const Rect.fromLTRB(0, 0, 0.5, 0.5))
      ..updateAdjustments(const EditAdjustments(saturation: 0))
      ..reset();
    await c.rendered;
    expect(c.edited, isFalse);
    expect(c.frameSize, const Size(100, 80));
    expect(c.cropRect, isNull);
    c.dispose();
  });

  test('监听:参数沿同步 notify,渲染落定沿再 notify', () async {
    final c = EditController(jpeg: _jpeg(60, 40));
    await c.ready; // 引导沿先行,不在计数窗内
    var notified = 0;
    c.addListener(() => notified++);
    c.rotateLeft();
    expect(notified, 1); // 参数沿(裁剪框/画幅/edited 即时上树)
    await c.rendered;
    expect(notified, 2); // 渲染沿(previewJpeg 落地)
    c.dispose();
  });

  test('连发改动:seq 闸只落最新一期(预览与最终参数一致)', () async {
    final c = EditController(
        jpeg: _solidJpeg(80, 60, 200, 100, 50), maxPreviewEdge: 40);
    await c.ready;
    c.setLut(
        CubeLut.fromFunction('inv', 3, (r, g, b) => [1 - r, 1 - g, 1 - b]));
    c.setLut(null); // 立即撤:最新参数中性;完成序不可控,迟到旧期必须弃
    await c.rendered;
    final decoded = img.decodeJpg(c.previewJpeg!)!;
    final p = decoded.getPixel(0, 0);
    expect(p.r, inInclusiveRange(185, 215)); // 原色 200(反色是 55)
    expect(p.g, inInclusiveRange(85, 115)); // 原色 100(反色是 155)
    c.dispose();
  });

  test('dispose 后:操作零投递,ready/rendered 不悬挂', () async {
    final c = EditController(jpeg: _jpeg(60, 40));
    await c.ready;
    var notified = 0;
    c.addListener(() => notified++);
    c.dispose();
    c
      ..rotateRight()
      ..updateAdjustments(const EditAdjustments(brightness: 1.5));
    await c.rendered;
    await c.ready;
    expect(notified, 0);
  });

  test('引导中途 dispose:迟到的引导产物零投递', () async {
    final c = EditController(jpeg: _jpeg(100, 80));
    var notified = 0;
    c.addListener(() => notified++);
    c.dispose(); // 不等 ready 直接销毁(监听须在 dispose 前挂)
    await c.ready; // completer 已在 dispose 收口
    c.rotateRight();
    expect(notified, 0); // 引导沿与操作沿零投递
    expect(c.isReady, isFalse); // 迟到的解码产物被世代闸弃
  });

  test('胶片预设:选中使能、清空回中性、reset 收走', () async {
    final c = EditController(jpeg: _jpeg(60, 40));
    await c.ready;
    final preset = filmPresets.firstWhere((p) => p.id == 'leicaMonochrome');
    expect(c.edited, isFalse);
    c.setFilmPreset(preset);
    expect(c.edited, isTrue);
    expect(c.filmPreset, same(preset));
    expect(c.edit.filmPreset, same(preset));
    c.setFilmPreset(null);
    expect(c.edited, isFalse);
    expect(c.filmPreset, isNull);
    c.setFilmPreset(preset);
    c.reset();
    await c.rendered;
    expect(c.edited, isFalse);
    expect(c.filmPreset, isNull);
    c.dispose();
  });

  test('renderFull:胶片矩阵烘焙进原分辨率输出(徕卡黑白 → 灰)', () async {
    // (200,100,50) → 0.35*200+0.65*100+0.15*50-10 = 132.5 → 133 ± JPEG。
    final c = EditController(
        jpeg: _solidJpeg(80, 60, 200, 100, 50), maxPreviewEdge: 40);
    await c.ready;
    c.setFilmPreset(filmPresets.firstWhere((p) => p.id == 'leicaMonochrome'));
    final decoded = img.decodeJpg(c.renderFull())!;
    expect(decoded.width, 80); // 原分辨率(预览档是 40×30)
    expect(decoded.height, 60);
    final p = decoded.getPixel(0, 0);
    expect(p.r, inInclusiveRange(118, 148));
    expect(p.g, inInclusiveRange(118, 148));
    expect(p.b, inInclusiveRange(118, 148));
    c.dispose();
  });

  test('renderCropBackdrop:应用调节/旋转/LUT 但不裁剪', () async {
    final c = EditController(
        jpeg: _solidJpeg(80, 60, 200, 100, 50), maxPreviewEdge: 40);
    await c.ready;
    c.setLut(
        CubeLut.fromFunction('inv', 3, (r, g, b) => [1 - r, 1 - g, 1 - b]));
    c.setCrop(const Rect.fromLTRB(0, 0, 0.5, 0.5));
    final backdrop = await c.renderCropBackdrop();
    final decoded = img.decodeJpg(backdrop!)!;
    // 不裁剪:整幅在(裁剪会变 40×30);反色 (55,155,205)。
    expect(decoded.width, 40);
    expect(decoded.height, 30);
    final p = decoded.getPixel(39, 29); // 右下角:裁剪版里不存在
    expect(p.r, inInclusiveRange(40, 70));
    expect(p.g, inInclusiveRange(140, 170));
    expect(p.b, inInclusiveRange(190, 220));
    c.dispose();
  });
}

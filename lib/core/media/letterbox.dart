/// 缩略信箱黑边裁剪:相机内嵌视频缩略(0x100A/0x90C4)把画面信箱化
/// 进固定画布(竖拍视频 = 横画布左右黑边),BoxFit.cover 只裁画布外,
/// 黑边是图内像素盖不掉 —— 解码后扫描**纯黑**边条(行/列最大亮度
/// ≤ [blackThreshold],严阈值防误裁暗场景)并居中裁掉,重编码 PNG
/// (dart:ui 无 JPEG 编码;Image.file 按内容嗅探解码,缓存扩展名
/// 不影响显示)。无黑边/解码失败/防误裁线触发 = null(调用方用原图)。
///
/// 只对视频缩略调用(静照无信箱);每缩略一次性成本(落盘前)。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'jpeg_limits.dart';

Future<Uint8List?> trimLetterboxJpeg(
  Uint8List jpeg, {
  int blackThreshold = 10,
}) async {
  if (!jpegWithinDecodeLimits(jpeg,
      maxPixels: kMaxPreviewJpegDecodePixels)) {
    return null;
  }
  ui.Image? sourceImage; // 解码原图(finally 释放)
  ui.Image? croppedImage; // 裁剪结果(finally 释放)
  try {
    final codec =
        await ui.instantiateImageCodec(jpeg, allowUpscaling: false);
    final frame = await codec.getNextFrame();
    sourceImage = frame.image;
    final w = sourceImage.width;
    final h = sourceImage.height;
    final data =
        (await sourceImage.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();

    int lum(int x, int y) {
      final i = (y * w + x) * 4;
      final r = data[i];
      final g = data[i + 1];
      final b = data[i + 2];
      return r > g ? (r > b ? r : b) : (g > b ? g : b);
    }

    // 内容界:逐行/列最大亮度 > 阈值即有内容(步进 2 省扫描)。
    int? top;
    int? bottom;
    for (var y = 0; y < h; y++) {
      var mx = 0;
      for (var x = 0; x < w; x += 2) {
        final l = lum(x, y);
        if (l > mx) mx = l;
      }
      if (mx > blackThreshold) {
        top ??= y;
        bottom = y;
      }
    }
    if (top == null || bottom == null) return null;
    int? left;
    int? right;
    for (var x = 0; x < w; x++) {
      var mx = 0;
      for (var y = top; y <= bottom; y += 2) {
        final l = lum(x, y);
        if (l > mx) mx = l;
      }
      if (mx > blackThreshold) {
        left ??= x;
        right = x;
      }
    }
    if (left == null || right == null) return null;

    // 四边都几乎无黑边:不折腾。
    if (top <= 1 && h - 1 - bottom <= 1 && left <= 1 && w - 1 - right <= 1) {
      return null;
    }
    final cropW = right - left + 1;
    final cropH = bottom - top + 1;
    // 内容占比过低 = 暗场景误判风险:放弃。
    if (cropW < w * 0.3 || cropH < h * 0.3) return null;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      sourceImage,
      ui.Rect.fromLTWH(left.toDouble(), top.toDouble(), cropW.toDouble(),
          cropH.toDouble()),
      ui.Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
      ui.Paint(),
    );
    final pic = recorder.endRecording();
    croppedImage = await pic.toImage(cropW, cropH);
    pic.dispose();
    final out =
        await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    return out?.buffer.asUint8List();
  } on Object {
    return null;
  } finally {
    sourceImage?.dispose();
    croppedImage?.dispose();
  }
}

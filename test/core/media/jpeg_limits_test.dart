import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/jpeg_limits.dart';

Uint8List _jpeg(int width, int height) => Uint8List.fromList(
      img.encodeJpg(img.Image(width: width, height: height)),
    );

Uint8List _soiSof(int width, int height) => Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xC0,
      0x00,
      0x0B,
      0x08,
      (height >> 8) & 0xFF,
      height & 0xFF,
      (width >> 8) & 0xFF,
      width & 0xFF,
      0x01,
      0x01,
      0x11,
      0x00,
      0xFF,
      0xD9,
    ]);

void main() {
  test('正常 JPEG 在默认和预览边界内', () {
    final jpeg = _jpeg(32, 24);
    expect(jpegWithinDecodeLimits(jpeg), isTrue);
    expect(
      jpegWithinDecodeLimits(jpeg, maxPixels: kMaxPreviewJpegDecodePixels),
      isTrue,
    );
  });

  test('超大 SOF 只读头部即拒绝,不做整图解码', () {
    final oversized = _soiSof(10000, 10000);
    expect(jpegWithinDecodeLimits(oversized), isFalse);
  });

  test('可自定义像素上限;畸形/非 JPEG 拒绝', () {
    final jpeg = _jpeg(32, 24);
    expect(jpegWithinDecodeLimits(jpeg, maxPixels: 100), isFalse);
    expect(
      jpegWithinDecodeLimits(Uint8List.fromList([1, 2, 3, 4])),
      isFalse,
    );
  });
}

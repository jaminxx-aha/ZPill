import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:z_pill/features/common/widgets/hero_zoom.dart';

void main() {
  testWidgets('原图 JPEG 图比首帧同步定盒(不异步缩小)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('zpill_hero_aspect');
    addTearDown(() => dir.deleteSync(recursive: true));
    final image = img.Image(width: 600, height: 400);
    img.fill(image, color: img.ColorRgb8(40, 80, 120));
    final file = File('${dir.path}/photo.jpg')
      ..writeAsBytesSync(img.encodeJpg(image));
    final thumb = File('${dir.path}/thumb.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.copyResize(image, width: 100)));

    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: HeroZoom(
            tag: 'aspect',
            thumbPath: thumb.path,
            imagePath: file.path,
            aspectBox: true,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ));
    // 首帧(未跑异步)就必须有按原图 3:2 定的盒。
    final ar = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(ar.aspectRatio, closeTo(1.5, 1e-9), reason: '图比从 JPEG 头同步读出,首帧定盒');
  });
}

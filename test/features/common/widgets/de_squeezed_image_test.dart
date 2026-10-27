import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:z_pill/features/common/widgets/de_squeezed_image.dart';

Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  testWidgets('ds ≤ 1 直通 contain(零开销路径)', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: DeSqueezedImage(
                image: MemoryImage(_png(32, 24)), deSqueeze: 1.0))));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('小图 contain 也撑满:松约束下 RenderImage 按固有像素排布'
      '不上放(2026-10-09 复报「点进去很小」—— 160×120 缩略 ≈ 4% 屏宽)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: DeSqueezedImage(
                image: MemoryImage(_png(32, 24)), deSqueeze: 1.0))));
    await tester.pump();

    // SizedBox.expand 把 contain 盒顶满可用空间:800×600 视口里
    // 32×24 的小图也铺满(不再是 32×24 的原尺寸小盒)
    final rect = tester.getRect(find.byType(Image));
    expect(rect.width, closeTo(800, 0.01));
    expect(rect.height, closeTo(600, 0.01));
  });

  testWidgets('ds > 1 解码未完先 contain(不白屏不炸)', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: DeSqueezedImage(
                image: MemoryImage(_png(32, 24)), deSqueeze: 1.5))));
    await tester.pump();

    // FakeAsync 下真解码不落地:未解出 = contain 原样顶着
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ds > 1 解出后按 w·ds/h 定盒 fill(拉伸恰为 ds)', (tester) async {
    final provider = MemoryImage(_png(32, 24));
    // 真解码在 FakeAsync 外预热(runAsync;context 用预热桩的),
    // 之后树上走缓存命中。
    await tester.pumpWidget(
        MaterialApp(home: const SizedBox.shrink(key: ValueKey('warm'))));
    final context = tester.element(find.byKey(const ValueKey('warm')));
    await tester.runAsync(() => precacheImage(provider, context));
    await tester.pumpWidget(MaterialApp(
        home: Center(child: DeSqueezedImage(image: provider, deSqueeze: 1.5))));
    await tester.pump();
    await tester.pump();

    final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(aspect.aspectRatio, closeTo(32 * 1.5 / 24, 1e-6)); // = 2.0
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.fill);
    // 800×600 盒内 2:1 → 800×400
    final rect = tester.getRect(find.byType(AspectRatio));
    expect(rect.width, closeTo(800, 0.01));
    expect(rect.height, closeTo(400, 0.01));
  });
}

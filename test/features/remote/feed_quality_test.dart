import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:z_pill/features/remote/feed_quality.dart';

Uint8List _jpeg() {
  final image = img.Image(width: 32, height: 24);
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  testWidgets('shader 不可用 → Image 回落(fast 档观感,不白屏不炸)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ShaderFeed(
                frame: _jpeg(),
                temporalDenoise: false,
                programLoader: () async => null))));
    // 加载未决期(program 回调前)也先走 Image,不空白
    expect(find.byType(Image), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50)); // loader 回 null
    final w = tester.widget<Image>(find.byType(Image));
    expect(w.filterQuality, FilterQuality.high,
        reason: '回落档 = 快速(双线性 high)');
    expect(w.gaplessPlayback, isTrue, reason: '换帧不闪黑保持');
    expect(w.fit, BoxFit.fill);
  });

  testWidgets('帧字节换新不炸(解码管线跑通,回落路径稳定出图)',
      (tester) async {
    final controller = ValueNotifier(_jpeg());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder<Uint8List>(
                valueListenable: controller,
                builder: (context, frame, _) => ShaderFeed(
                    frame: frame,
                    temporalDenoise: true,
                    programLoader: () async => null)))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(Image), findsOneWidget);
    controller.value = _jpeg(); // 新帧字节
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(Image), findsOneWidget,
        reason: '换帧后仍在出图(解码中只记最新,不掉树)');
    expect(tester.takeException(), isNull);
  });

  // 解码目标计算(纯函数;手算向量锁规则):
  // 目标长边 = 显示盒长边 × DPR(钳 1..2048)→ ≥ 源长边 × 0.9 判
  // 满分辨率(null),否则按长边所在轴折算出 targetWidth(高引擎保比)。
  group('feedDecodeTargetWidth(显示分辨率降采样目标)', () {
    test('显示小于源 → 按显示长边物理值降采样宽', () {
      // 300×225 逻辑 × DPR 2 → 物理长边 600 < 1024×0.9;源长边在宽轴
      // → targetWidth = 600(高由引擎保比 → 450)。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 1024,
              sourceHeight: 768,
              displayBox: const Size(300, 225),
              devicePixelRatio: 2.0),
          600);
    });

    test('显示大于源 → null(只降不升,保源帧)', () {
      // 500×400 × 3 = 1500 ≥ 1024×0.9 → 全分辨率,不升采样解码。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 1024,
              sourceHeight: 768,
              displayBox: const Size(500, 400),
              devicePixelRatio: 3.0),
          isNull);
    });

    test('容差边界:目标长边恰为源九成 → null;再小 → 降', () {
      // 源 1000×800:450×2 = 900 = 1000×0.9 → 视作满分辨率。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 1000,
              sourceHeight: 800,
              displayBox: const Size(450, 400),
              devicePixelRatio: 2.0),
          isNull);
      // 445×2 = 890 < 900 → 降到 890。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 1000,
              sourceHeight: 800,
              displayBox: const Size(445, 400),
              devicePixelRatio: 2.0),
          890);
    });

    test('盒为 0 → 钳 1(极端小盒不产出 0 宽)', () {
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 1024,
              sourceHeight: 768,
              displayBox: Size.zero,
              devicePixelRatio: 2.0),
          1);
    });

    test('大屏 DPR 3.0 → 目标封顶 2048(防解码膨胀到源之上)', () {
      // 1024×768 逻辑 × 3 = 3072 → 封 2048;源 4032 够大,仍降采样。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 4032,
              sourceHeight: 3024,
              displayBox: const Size(1024, 768),
              devicePixelRatio: 3.0),
          2048);
    });

    test('竖幅源:长边在高轴,目标宽按源宽高比折算', () {
      // 源 768×1024,显示 225×300 × 2 → 物理长边 600;宽 = 600×768/1024。
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 768,
              sourceHeight: 1024,
              displayBox: const Size(225, 300),
              devicePixelRatio: 2.0),
          450);
    });

    test('源尺寸非法(0)→ null 全分辨率兜底', () {
      expect(
          feedDecodeTargetWidth(
              sourceWidth: 0,
              sourceHeight: 768,
              displayBox: const Size(300, 225),
              devicePixelRatio: 2.0),
          isNull);
    });
  });

  // 真 shader 路线(资产加载 + 引擎解码)在 testWidgets 的 FakeAsync
  // 下不落地(真 I/O / 引擎线程不归假时钟管),widget 级只测回落;
  // 资产本身的可用性由 build 时的着色器编译与装机实测兜底。
}

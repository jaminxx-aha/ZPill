import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/features/remote/feed_quality.dart';

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

  // 真 shader 路线(资产加载 + 引擎解码)在 testWidgets 的 FakeAsync
  // 下不落地(真 I/O / 引擎线程不归假时钟管),widget 级只测回落;
  // 资产本身的可用性由 build 时的着色器编译与装机实测兜底。
}

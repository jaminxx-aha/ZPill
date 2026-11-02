import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/common/widgets/zoomable_page.dart';

void main() {
  testWidgets('双击放大/再双击复位;翻出当前页自动复位并回传真实缩放态', (tester) async {
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    final events = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, isActive, __) => Scaffold(
          body: ZoomablePage(
            active: isActive,
            onZoomChanged: events.add,
            child: const SizedBox(width: 300, height: 300),
          ),
        ),
      ),
    ));

    final viewer = find.byType(InteractiveViewer);
    TransformationController controllerOf() =>
        tester.widget<InteractiveViewer>(viewer).transformationController!;

    Future<void> doubleTap() async {
      await tester.tap(viewer);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(viewer);
      await tester.pump(); // 双击沿:动画起步
      await tester.pump(const Duration(milliseconds: 250));
    }

    await doubleTap();
    expect(events.last, isTrue, reason: '放大态回传宿主');
    expect(controllerOf().value.getMaxScaleOnAxis(), closeTo(2.0, 0.001));

    await doubleTap();
    expect(events.last, isFalse, reason: '再双击回 1x');
    expect(controllerOf().value.getMaxScaleOnAxis(), closeTo(1.0, 0.001));

    await doubleTap();
    expect(events.last, isTrue);
    active.value = false; // 翻页离开
    await tester.pump();
    expect(events.last, isFalse, reason: '离开页复位缩放闸');
    expect(controllerOf().value.getMaxScaleOnAxis(), closeTo(1.0, 0.001));
  });

  testWidgets('双击缩放是补间动画:放大/缩小中途 scale 都在 1x～2x 之间', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ZoomablePage(
          active: true,
          child: SizedBox(width: 300, height: 300),
        ),
      ),
    ));
    final viewer = find.byType(InteractiveViewer);
    double scaleNow() => tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!
        .value
        .getMaxScaleOnAxis();

    Future<void> doubleTapStart() async {
      await tester.tap(viewer);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(viewer);
      await tester.pump(); // 双击识别沿:动画起步
    }

    await doubleTapStart();
    await tester.pump(const Duration(milliseconds: 80));
    expect(scaleNow(), greaterThan(1.01), reason: '已开始放大');
    expect(scaleNow(), lessThan(1.99), reason: '不是瞬间跳到 2x');

    await tester.pump(const Duration(milliseconds: 200));
    expect(scaleNow(), closeTo(2.0, 0.001));

    await doubleTapStart();
    await tester.pump(const Duration(milliseconds: 80));
    expect(scaleNow(), greaterThan(1.01), reason: '缩小也有中间态');
    expect(scaleNow(), lessThan(1.99));

    await tester.pump(const Duration(milliseconds: 200));
    expect(scaleNow(), closeTo(1.0, 0.001));
  });
}

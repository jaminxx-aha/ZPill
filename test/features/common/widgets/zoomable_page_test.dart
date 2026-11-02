import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/common/widgets/zoomable_page.dart';

void main() {
  testWidgets('双击放大/再双击复位;翻出当前页自动复位并回传真实缩放态',
      (tester) async {
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
}

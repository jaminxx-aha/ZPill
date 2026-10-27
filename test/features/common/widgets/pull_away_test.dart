import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/common/widgets/pull_away.dart';

/// 下拉跟手共享件单测:跟手变换(布局缩小 + 绘制平移,实测盒随之)、
/// chrome 淡出口径、弹回复位。
void main() {
  testWidgets('跟手变换:位移下移 + 布局缩小,弹回复位', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = PullAwayController(vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PullAwayTransform(
          controller: controller,
          child: const SizedBox.expand(
            child: ColoredBox(
                color: Colors.red, key: ValueKey('box')),
          ),
        ),
      ),
    ));
    await tester.pump();
    final rest = tester.getRect(find.byKey(const ValueKey('box')));
    expect(rest.topLeft, Offset.zero);
    expect(rest.size, const Size(400, 600)); // 闲态直通(测试面 400×600)

    controller.update(120); // 过提交阈值(110)
    await tester.pump();
    final dragged = tester.getRect(find.byKey(const ValueKey('box')));
    expect(dragged.top, greaterThan(rest.top)); // 跟手下移
    expect(dragged.height, lessThan(rest.height)); // 布局缩小
    expect(controller.progress, 1.0); // chrome 淡出满档

    controller.settleBack(); // 弹回
    await tester.pumpAndSettle();
    expect(controller.dy, 0);
    expect(tester.getRect(find.byKey(const ValueKey('box'))), rest);
  });

  testWidgets('chrome 淡出口径:进度 = 位移/提交距离(钳 0..1)', (tester) async {
    final controller = PullAwayController(vsync: tester);
    addTearDown(controller.dispose);
    expect(controller.progress, 0.0);
    controller.update(55); // 半阈
    expect(controller.progress, closeTo(0.5, 0.001));
    controller.update(300); // 远超 → 钳 1
    expect(controller.progress, 1.0);
    controller.reset();
    expect(controller.progress, 0.0);
  });

  testWidgets('弹回动画:easeOutCubic 收敛到位(终值精确)', (tester) async {
    final controller = PullAwayController(vsync: tester);
    addTearDown(controller.dispose);
    controller.update(200);
    controller.settleBack();
    await tester.pumpAndSettle();
    expect(controller.dy, 0.0);
  });
}

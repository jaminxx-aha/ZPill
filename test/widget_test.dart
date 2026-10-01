import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app.dart';

void main() {
  testWidgets('应用启动并渲染底部三 tab', (WidgetTester tester) async {
    await tester.pumpWidget(const NikonPillApp());

    // 底部导航三 tab(TODO.md §七):标签文本与页内 AppBar 标题可能重名,
    // 故断言 NavigationBar 的三个目的地而非全局唯一文本。
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final labels = nav.destinations
        .map((d) => (d as NavigationDestination).label)
        .toList();
    expect(labels, containsAll(['相机', '相册', '下载']));
    expect(find.text('连接'), findsOneWidget);
  });
}

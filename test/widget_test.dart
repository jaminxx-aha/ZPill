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
    // 初始 tab = 相机(连接页):双链路卡片都在真实对象图里渲染出来
    expect(find.text('USB 连接'), findsOneWidget);
    expect(find.text('无线连接(Wi-Fi)'), findsOneWidget);
    expect(find.text('扫描相机'), findsOneWidget); // STA 扫描入口
    expect(find.text('手动连接'), findsOneWidget); // 手动 IP 兜底入口
  });
}

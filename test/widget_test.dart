import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app.dart';

void main() {
  testWidgets('应用启动并渲染底部四 tab', (WidgetTester tester) async {
    // 加高视口:三连接方式卡纵向排布,默认视口把 STA 卡挡在折线下
    // (ListView 懒构建,未 build 即不可断言)。
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();

    // 底部导航四 tab:标签文本与页内 AppBar 标题可能重名,
    // 故断言 NavigationBar 的四个目的地而非全局唯一文本。
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final labels = nav.destinations
        .map((d) => (d as NavigationDestination).label)
        .toList();
    expect(labels, ['相机', '拍摄', '图库', '设置']);
    // 初始 tab = 相机:三连接方式卡在真实对象图里渲染出来
    expect(find.text('有线连接(USB)'), findsOneWidget);
    expect(find.text('USB 连接'), findsOneWidget);
    expect(find.text('AP 连接(相机当热点)'), findsOneWidget);
    expect(find.text('AP 连接'), findsOneWidget);
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);
    expect(find.text('扫描相机'), findsOneWidget); // STA 扫描入口
  });
}

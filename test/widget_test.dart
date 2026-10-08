import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app.dart';

void main() {
  testWidgets('应用启动并渲染底部三 tab', (WidgetTester tester) async {
    // 加高视口:ListView 懒构建,折线下内容未 build 即不可断言。
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();

    // 底部导航三 tab(拍摄页 2026-10-08 改由相机页「进入拍摄」push
    // 进入):标签文本与页内 AppBar 标题可能重名,故断言 NavigationBar
    // 的目的地而非全局唯一文本。
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final labels = nav.destinations
        .map((d) => (d as NavigationDestination).label)
        .toList();
    expect(labels, ['相机', '图库', '设置']);
    // 初始 tab = 相机:连接方式分段切换 —— 默认有线,另两方式不占屏。
    expect(find.text('有线连接(USB)'), findsOneWidget);
    expect(find.text('USB 连接'), findsOneWidget);
    expect(find.text('AP 连接(相机当热点)'), findsNothing);
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsNothing);

    // 切到 AP 热点:出 IP 输入与「AP 连接」,有线卡退场。
    await tester.tap(find.text('AP 热点'));
    await tester.pumpAndSettle();
    expect(find.text('AP 连接(相机当热点)'), findsOneWidget);
    expect(find.text('AP 连接'), findsOneWidget);
    expect(find.text('USB 连接'), findsNothing);

    // 切到同一 Wi-Fi:出「扫描相机」入口。
    await tester.tap(find.text('同一 Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);
    expect(find.text('扫描相机'), findsOneWidget);
  });
}

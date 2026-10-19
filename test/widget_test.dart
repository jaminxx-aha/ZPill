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
    // 初始 tab = 相机:方式行(五轮)+ 状态行 + hero(点按即连接);说明
    // 藏方式行 ⓘ 后;其余方式入口收进右上角弹层不占屏。
    expect(find.text('未连接'), findsOneWidget, reason: '状态行常驻(灰点)');
    expect(find.text('有线'), findsOneWidget, reason: '方式行标题(五轮)');
    expect(find.text('连接相机'), findsNothing,
        reason: '中央连接钮退役(五轮:点图标连接)');
    expect(find.text('当前方式:有线'), findsNothing, reason: '「当前方式」字样整删');
    expect(find.textContaining('C-to-C 数据线直连'), findsNothing,
        reason: '说明藏方式行 ⓘ 后(点 ⓘ 弹窗)');

    // 右上角弹层:方式条目与收放(选中仅切换,真连接冒烟归
    // connection_page_test 假连接;壳冒烟只验条目)。
    await tester.tap(find.byTooltip('选择连接方式'));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsOneWidget);
    expect(find.text('AP 模式'), findsOneWidget);
    expect(find.text('STA 模式'), findsOneWidget);
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsNothing);

    // 切 STA 模式:原地替换两段列表,进页自动扫描(静默 —— 主机无
    // 插件,扫描失败静默收口;无扫描钮、无「扫描中」指示)。
    await tester.tap(find.byTooltip('选择连接方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STA 模式'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已配对'), findsOneWidget, reason: '两段列表段名');
    expect(find.text('其它设备'), findsOneWidget);
    expect(find.text('扫描相机'), findsNothing, reason: '扫描钮退役');
    expect(find.textContaining('扫描中'), findsNothing, reason: '扫描静默');
  });
}

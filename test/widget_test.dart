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
    // 初始 tab = 相机:未连接主视图(SnapBridge 式)—— 居中「连接相机」
    // 直连,其余方式入口收进右上角弹层不占屏。
    expect(find.text('连接相机'), findsOneWidget);
    expect(find.text('当前方式:有线'), findsOneWidget);
    expect(find.text('AP 连接(相机当热点)'), findsNothing);
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsNothing);
    expect(find.text('扫描相机'), findsNothing);

    // 右上角弹层:方式条目改名(2026-10-17)—— 选中即进流程,真连接
    // 冒烟归 connection_page_test 假连接;壳冒烟只验条目与收放。
    await tester.tap(find.byIcon(Icons.usb));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsOneWidget);
    expect(find.text('AP 模式'), findsOneWidget);
    expect(find.text('STA 模式'), findsOneWidget);
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('当前方式:有线'), findsOneWidget);

    // 切 STA 模式:选中即出扫描面板(被动 mDNS;主机无插件 → 扫描
    // 态如实)。有界 pump:面板自带永动 spinner。
    await tester.tap(find.byIcon(Icons.usb));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STA 模式'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 原地替换:STA 体没有「当前方式」副文(那是 USB/AP 主操作的)。
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);
    // 打开沿自动扫描(平台通道在测试环境无应答,扫描态常驻)
    expect(find.text('扫描中…(点按停止)'), findsOneWidget);
  });
}

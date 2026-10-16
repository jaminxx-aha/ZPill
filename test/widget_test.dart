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

    // 右上角弹层切 AP 热点:主视图换方式 + 接管预告(直连即锁盘)。
    await tester.tap(find.byIcon(Icons.usb));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsOneWidget);
    await tester.tap(find.text('AP 热点'));
    await tester.pumpAndSettle();
    expect(find.text('当前方式:AP 热点'), findsOneWidget);
    expect(find.textContaining('app 将自动接管相机'), findsOneWidget);

    // 切同一 Wi-Fi:点「连接相机」出扫描面板。
    await tester.tap(find.byIcon(Icons.wifi_tethering));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsOneWidget);
    await tester.tap(find.text('同一 Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.text('当前方式:同一 Wi-Fi'), findsOneWidget);
    await tester.tap(find.text('连接相机'));
    // 面板进场动画走完;打开沿自动扫描的 spinner 永不定帧
    // (pumpAndSettle 必超时),用带时长 pump。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('STA 连接(同一 Wi-Fi)'), findsOneWidget);
    // 打开沿自动扫描(平台通道在测试环境无应答,扫描态常驻)
    expect(find.text('扫描中…(点按停止)'), findsOneWidget);
  });
}

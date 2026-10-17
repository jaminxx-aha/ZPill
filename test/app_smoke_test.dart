import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/app.dart';

/// 整棵 UI 树冒烟:真机上"屏幕只打一堆文字"疑似渲染异常,
/// 此处先在本地复现/排除 Widget 层异常。
void main() {
  // 加高视口:ListView 懒构建,默认 600 逻辑高把页面尾部/设置项
  // 挡在折线下(未 build 即不可断言)。
  Future<void> boot(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();
  }

  testWidgets('应用骨架整体可渲染(相机 tab 未连接主视图)', (tester) async {
    await boot(tester);

    expect(find.text('相机'), findsWidgets); // AppBar 标题 + 底部 tab
    // 未连接组件退场(2026-10-17):disconnected 静置态只剩主操作。
    expect(find.text('未连接'), findsNothing);
    expect(find.text('连接相机'), findsOneWidget); // 默认方式 = 有线,居中直连
    expect(find.text('当前方式:有线'), findsOneWidget);
    expect(find.text('扫描相机'), findsNothing); // 方式入口收进右上角弹层
  });

  // 拍摄页冒烟不在此列:2026-10-08 起拍摄页由相机页已连接视图
  // 「进入拍摄」push 进入,真机无连接不可达;页面级渲染/控件就位
  // 由 remote_page_test 直挂 RemotePage 覆盖。

  testWidgets('图库 tab:空态(非 ohos 环境静默)', (tester) async {
    await boot(tester);

    await tester.tap(find.text('图库'));
    await tester.pumpAndSettle();
    expect(find.text('图库'), findsWidgets); // AppBar + tab
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'),
        findsOneWidget);
  });

  testWidgets('设置 tab:配置项在场', (tester) async {
    await boot(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets); // AppBar + tab
    expect(find.text('自动传输(速传)'), findsOneWidget);
    expect(find.text('水印'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget); // i18n 第一期(2026-10-14)
  });
}

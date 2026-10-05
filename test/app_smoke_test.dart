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

  testWidgets('应用骨架整体可渲染(相机 tab 连接方式分段)', (tester) async {
    await boot(tester);

    expect(find.text('相机'), findsWidgets); // AppBar 标题 + 底部 tab
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('USB 连接'), findsOneWidget); // 默认方式 = 有线
    expect(find.text('AP 连接'), findsNothing); // 未选中方式不占屏
    expect(find.text('扫描相机'), findsNothing);
  });

  testWidgets('拍摄 tab:取景/快门/参数芯片就位', (tester) async {
    await boot(tester);

    // 未连接时 linkUp 门闩默认放行(RemoteController 冷启乐观态),
    // 断连横幅不显示 —— 以取景/快门/参数控件在场为冒烟点。
    await tester.tap(find.text('拍摄'));
    await tester.pumpAndSettle();
    expect(find.text('拍摄'), findsWidgets); // AppBar + tab
    expect(find.text('取景'), findsOneWidget);
    // 「快门」×2:曝光参数 chip + 快门钮文案
    expect(find.text('快门'), findsNWidgets(2));
    // 参数目录 chips(未读值 = '--');参数扩到 17 后横滚行懒构建,
    // 行尾芯片(画质/对焦后拍)要滚到可见
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('白平衡'), findsOneWidget);
    final chips = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    await tester.scrollUntilVisible(find.text('画质'), 120, scrollable: chips);
    await tester.scrollUntilVisible(
        find.text('对焦后拍'), 120,
        scrollable: chips);
    expect(find.text('对焦后拍'), findsOneWidget);
  });

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
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/app.dart';

/// 整棵 UI 树冒烟:真机上"屏幕只打一堆文字"疑似渲染异常,
/// 此处先在本地复现/排除 Widget 层异常。
void main() {
  testWidgets('应用骨架整体可渲染(相机 tab)', (tester) async {
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();

    expect(find.text('相机'), findsWidgets); // AppBar 标题 + 底部 tab
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });

  testWidgets('相册 tab:未连接空态', (tester) async {
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsWidgets); // AppBar + tab
    expect(find.text('相机里还没有照片\n(未连接时请先在「相机」页连接)'),
        findsOneWidget);
  });

  testWidgets('下载 tab:空态 + 应用内文件(非 ohos 环境静默)', (tester) async {
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsWidgets); // AppBar + tab
    expect(find.text('暂无下载任务\n(在「相册」页多选或大图页单张下载)'),
        findsOneWidget);
  });
}

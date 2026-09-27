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
}

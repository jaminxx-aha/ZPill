import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app.dart';
import 'package:nikon_pill/app_services.dart';

/// 设置页文本框收起/落库(真机反馈:点开文本框后键盘收不起来)。
void main() {
  // 加高视口:ListView 懒构建,折线下控件未 build 不可断言/点按。
  Future<void> boot(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NikonPillApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('文本框:点空白散焦收键盘,输入随焦点离开落库', (tester) async {
    await boot(tester);

    final field = find.byType(TextField).first; // 作者(dc:creator)
    await tester.tap(field);
    await tester.pumpAndSettle();
    EditableText editableOf(Finder f) => tester.widget<EditableText>(
        find.descendant(of: f, matching: find.byType(EditableText)));
    expect(editableOf(field).focusNode.hasFocus, isTrue);

    await tester.enterText(field, 'aha');

    // 点无点按处理的 ListTile(空白区域)→ 散焦 + 输入落库
    await tester.tap(find.text('元数据注入(XMP)'));
    await tester.pumpAndSettle();

    expect(editableOf(field).focusNode.hasFocus, isFalse,
        reason: '点空白必须散焦,否则键盘收不起来');
    expect(AppServices.instance.settingsController.settings.xmpCreator, 'aha',
        reason: '焦点离开即落库,不依赖回车提交');
  });
}

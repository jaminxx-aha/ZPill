import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/settings/settings_widgets.dart';

void main() {
  testWidgets('开关行整行可点:点标题也切换,不再只认右侧开关', (tester) async {
    var value = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SettingsSwitchRow(
            title: '测试开关',
            subtitle: '副标题',
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('测试开关'));
    await tester.pump();
    expect(value, isTrue, reason: '标题区域命中整行 onTap');

    await tester.tap(find.text('测试开关'));
    await tester.pump();
    expect(value, isFalse);
  });
}

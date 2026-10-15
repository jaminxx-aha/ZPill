import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/media/cube_lut.dart';
import 'package:nikon_pill/features/edit/lut_presets.dart' show builtinLuts;
import 'package:nikon_pill/features/library/lut_export_sheet.dart';

/// 选表纯件单测:内置 LUT 全列 + 剪贴板入口;点选项即回调。
void main() {
  testWidgets('列出全部内置 LUT,点选回调对应实例', (tester) async {
    CubeLut? picked;
    var clipboardTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LutExportSheet(
          onPick: (lut) => picked = lut,
          onImportFromClipboard: () async => clipboardTaps++,
        ),
      ),
    ));

    expect(find.byType(ListTile),
        findsNWidgets(builtinLuts.length + 1)); // 内置 + 剪贴板入口
    expect(find.text('从剪贴板导入 .cube/.xmp'), findsOneWidget);

    await tester.tap(find.text(builtinLuts.first.title).last);
    await tester.pumpAndSettle();
    expect(identical(picked, builtinLuts.first), isTrue);

    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pumpAndSettle();
    expect(clipboardTaps, 1);
  });
}

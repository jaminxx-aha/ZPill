import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/remote/remote_banner.dart';

/// 横幅长按复制(2026-10-17 用户需求:报错码要能贴回开发侧):
/// 剪贴板进的是同屏文本(t() 翻译后原文/动态串直通),展开/提示态
/// 原文暂换「已复制」短反馈,收圆丸后长按仍复制完整原文。
void main() {
  const bulbErr = '快门在 B 门/Time 档:请用屏上快门钮按住曝光,或开启自拍定时组合为定时 B 门';

  String? copied;
  void spyClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = call.arguments['text'] as String;
      }
      return null;
    });
  }

  setUp(() => copied = null);

  testWidgets('错误横幅:长按复制原文 + 「已复制」短反馈后回落', (tester) async {
    spyClipboard(tester);
    await tester.pumpWidget(MaterialApp(
        home: LiveBannerHost(
            (key: 'remote.errBulbShutter', args: null), Colors.red)));
    expect(find.text(bulbErr), findsOneWidget);

    await tester.longPress(find.text(bulbErr));
    await tester.pump();
    expect(copied, bulbErr, reason: '剪贴板 = 同屏文本');
    expect(find.text('已复制'), findsOneWidget,
        reason: '复制成功原文暂换「已复制」');

    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('已复制'), findsNothing);
    expect(find.text(bulbErr), findsOneWidget, reason: '反馈后原文回落');
  });

  testWidgets('提示横幅同样长按可复制', (tester) async {
    spyClipboard(tester);
    const saved = '已拍摄并保存到图库(SDRAM,不入卡)';
    await tester.pumpWidget(MaterialApp(
        home: LiveBannerHost((key: 'remote.sdramSaved', args: null),
            Colors.green,
            autoDismiss: true)));
    expect(find.text(saved), findsOneWidget);

    await tester.longPress(find.text(saved));
    await tester.pump();
    expect(copied, saved);
  });

  testWidgets('错误收圆丸后:点按 = 展开 / 长按 = 复制完整原文', (tester) async {
    spyClipboard(tester);
    await tester.pumpWidget(MaterialApp(
        home: LiveBannerHost(
            (key: 'remote.errBulbShutter', args: null), Colors.red)));
    await tester.pump(const Duration(seconds: 8)); // 错误节律 8s 收圆丸
    expect(find.byIcon(Icons.priority_high), findsOneWidget);

    await tester.longPress(find.byIcon(Icons.priority_high));
    await tester.pump();
    expect(copied, bulbErr, reason: '圆丸长按复制的是完整原文(非截断)');
    expect(find.byIcon(Icons.priority_high), findsOneWidget,
        reason: '长按不展开,点按才展开');
  });
}

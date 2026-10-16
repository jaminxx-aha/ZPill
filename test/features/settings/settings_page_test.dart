import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app.dart';
import 'package:nikon_pill/app_services.dart';
import 'package:nikon_pill/data/settings_store.dart';
import 'package:nikon_pill/l10n/l10n.dart';

/// 设置页:文本框散焦/落库(真机反馈:点开文本框后键盘收不起来)+
/// 深色模式/语言分段切换即时落库(语言含 t() 经真实 scope 的翻转验证)。
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

  testWidgets('深色模式:三段切换即时改 themeMode 并落库', (tester) async {
    await boot(tester);

    ThemeMode appMode() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .themeMode!;
    // 语言行(2026-10-14)的 system 段也叫「跟随系统」:主题行的点按
    // 限定在主题 SegmentedButton 内,避免二义。
    Finder themeSeg(String label) => find.descendant(
        of: find.byType(SegmentedButton<AppThemeMode>),
        matching: find.text(label));
    expect(appMode(), ThemeMode.system, reason: '默认跟随系统');

    await tester.tap(themeSeg('深色'));
    await tester.pumpAndSettle();
    expect(appMode(), ThemeMode.dark, reason: '选深色应即时生效,无需重启');
    expect(AppServices.instance.settingsController.settings.themeMode,
        AppThemeMode.dark);

    await tester.tap(themeSeg('浅色'));
    await tester.pumpAndSettle();
    expect(appMode(), ThemeMode.light);
    expect(AppServices.instance.settingsController.settings.themeMode,
        AppThemeMode.light);

    await tester.tap(themeSeg('跟随系统'));
    await tester.pumpAndSettle();
    expect(appMode(), ThemeMode.system);
  });

  testWidgets('语言:三段切换即时落库,t() 经真实 scope 翻转,locale 跟随',
      (tester) async {
    await boot(tester);

    Finder langSeg(String label) => find.descendant(
        of: find.byType(SegmentedButton<AppLanguage>),
        matching: find.text(label));
    Locale? appLocale() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale;
    String scopeCode() =>
        tester.widget<L10nScope>(find.byType(L10nScope)).code;

    // 默认中文:选择器显示原文;locale 锁 zh。
    expect(AppServices.instance.settingsController.settings.language,
        AppLanguage.zh);
    expect(find.text('Follow System'), findsNothing);
    expect(appLocale(), const Locale('zh'));
    expect(scopeCode(), 'zh');

    // 切 English:落库 + scope 翻转 + 选择器 system 段经 t() 出英文
    // —— 即「t() 经真实 scope 的英文翻转重建」端到端验证。语言行与
    // 主题行 system 段撞义同串(均 common.followSystem),断言按行
    // 子树收窄各断一处(2026-10-16 主题段包 t() 后)。
    await tester.tap(langSeg('English'));
    await tester.pumpAndSettle();
    expect(AppServices.instance.settingsController.settings.language,
        AppLanguage.en);
    expect(scopeCode(), 'en');
    expect(appLocale(), const Locale('en'));
    expect(langSeg('Follow System'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SegmentedButton<AppThemeMode>),
            matching: find.text('Follow System')),
        findsOneWidget);

    // 切中文:回原文。
    await tester.tap(langSeg('中文'));
    await tester.pumpAndSettle();
    expect(AppServices.instance.settingsController.settings.language,
        AppLanguage.zh);
    expect(scopeCode(), 'zh');
    expect(appLocale(), const Locale('zh'));
    expect(find.text('Follow System'), findsNothing);

    // 跟随系统:locale 交还系统解析(null);测试环境平台语言 en_US →
    // scope 自解析为 en(非 en 落中文的同口径),选择器再出英文。
    await tester.tap(langSeg('跟随系统'));
    await tester.pumpAndSettle();
    expect(AppServices.instance.settingsController.settings.language,
        AppLanguage.system);
    expect(appLocale(), isNull);
    expect(scopeCode(), 'en');
    expect(langSeg('Follow System'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SegmentedButton<AppThemeMode>),
            matching: find.text('Follow System')),
        findsOneWidget);
  });
}

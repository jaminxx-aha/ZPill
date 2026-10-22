import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/l10n/l10n.dart';

/// t() 抽象键制(i18n 二期):t('ns.key') 查词表;裸树落 zh 词表;
/// en 未命中先落 zh 再直通键;运行期动态串(非键)原样透出;
/// {名} 占位替换;scope code 变化重建。全部用裸 Directionality 树
/// —— 刻意不带 MaterialApp/Localizations,证明存量测试树零依赖。
void main() {
  // 捕获式探针:build 里把 t() 结果写进 late 变量,断言不经 Text 渲染。
  late String a, b, c;

  testWidgets('裸树(无 scope):键落 zh 词表,动态串直通', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(builder: (context) {
        a = context.t('common.settings');
        b = context.t('snapshot.metaLine',
            {'model': 'Zf', 'n': 3, 'date': '2026-10-16'});
        c = context.t('相机未接入'); // 运行期动态串,非键
        return const SizedBox();
      }),
    ));
    expect(a, '设置', reason: '裸测试树(未装 scope)落 zh 词表不炸');
    expect(b, 'Zf · 3 项 · 2026-10-16');
    expect(c, '相机未接入', reason: '非键原样透出(动态串口径)');
  });

  testWidgets('zh scope:键落 zh 词表', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'zh',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('common.followSystem');
          b = context.t('快门'); // 非键动态串
          return const SizedBox();
        }),
      ),
    ));
    expect(a, '跟随系统');
    expect(b, '快门');
  });

  testWidgets('en scope:enCatalog 命中;语言专名不译;未知键直通',
      (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'en',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('common.followSystem');
          b = context.t('lang.zh');
          c = context.t('快门');
          return const SizedBox();
        }),
      ),
    ));
    expect(a, 'Follow System');
    expect(b, '中文', reason: '「中文」语言专名,英文环境不译');
    expect(c, '快门', reason: 'en 未命中落 zh 词表也未命中(非键),直通原文');
  });

  testWidgets('en scope:带参模板按 en 词表填充', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'en',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('snapshot.metaLine',
              {'model': 'Zf', 'n': 3, 'date': '2026-10-16'});
          b = context.t('录制控制失败:boom'); // 动态串直通,不走词表
          return const SizedBox();
        }),
      ),
    ));
    expect(a, 'Zf · 3 props · 2026-10-16');
    expect(b, '录制控制失败:boom', reason: '动态串原样透出,不查词表');
  });

  testWidgets('占位替换:多参/值 toString/未知 {x} 字面保留', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'zh',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('snapshot.metaLine',
              {'model': 'Zf', 'n': 12, 'date': '2026-10-16'});
          b = context.t('unknown.key {x}', {'n': 1});
          return const SizedBox();
        }),
      ),
    ));
    expect(a, 'Zf · 12 项 · 2026-10-16', reason: '值按 toString 填入');
    expect(b, 'unknown.key {x}', reason: '只替换已知参数名,不误伤字面花括号');
  });

  testWidgets('scope code 变化:依赖 t() 的子树重建(updateShouldNotify)',
      (tester) async {
    // 子树全程 const:排除「父级重建顺带」的可能,只有 scope 的
    // updateShouldNotify 通知能触发 _T 重建。
    Widget app(String code) => L10nScope(
          code: code,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: _T('common.followSystem'),
          ),
        );
    await tester.pumpWidget(app('zh'));
    expect(find.text('跟随系统'), findsOneWidget);
    await tester.pumpWidget(app('en'));
    expect(find.text('Follow System'), findsOneWidget,
        reason: 'code 变化必须通知依赖 t() 的组件重建');
    // code 不变:不应触发重建(此处不可直接断言「没重建」,仅回归文案)。
    await tester.pumpWidget(app('en'));
    expect(find.text('Follow System'), findsOneWidget);
  });
}

class _T extends StatelessWidget {
  const _T(this.textKey);

  final String textKey;

  @override
  Widget build(BuildContext context) => Text(context.t(textKey));
}

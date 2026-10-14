import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/l10n/l10n.dart';

/// t() 基建(i18n 第一期):中文原文即键;裸树兜底;enCatalog 命中/
/// 回落;{名} 占位替换;scope code 变化重建。全部用裸 Directionality
/// 树 —— 刻意不带 MaterialApp/Localizations,证明存量测试树零依赖。
void main() {
  // 捕获式探针:build 里把 t() 结果写进 late 变量,断言不经 Text 渲染。
  late String a, b, c;

  testWidgets('裸树(无 scope):原文直返,参数照替换', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(builder: (context) {
        a = context.t('快门');
        b = context.t('已选 {n} 项', {'n': 3});
        return const SizedBox();
      }),
    ));
    expect(a, '快门', reason: '裸测试树(未装 scope)必须原文直返不炸');
    expect(b, '已选 3 项');
  });

  testWidgets('zh scope:原文直返(键即文案)', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'zh',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('快门');
          b = context.t('已选 {n} 项', {'n': 3});
          return const SizedBox();
        }),
      ),
    ));
    expect(a, '快门');
    expect(b, '已选 3 项');
  });

  testWidgets('en scope:enCatalog 命中给译文;未命中回落原文', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'en',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('跟随系统');
          b = context.t('中文');
          c = context.t('English');
          return const SizedBox();
        }),
      ),
    ));
    expect(a, 'Follow System');
    expect(b, '中文', reason: '「中文」语言专名,英文环境不译');
    expect(c, 'English');

    await tester.pumpWidget(L10nScope(
      code: 'en',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('快门'); // enCatalog 未命中(第一期只放三条)
          b = context.t('未知 {n}', {'n': 7}); // 未命中 + 带参
          return const SizedBox();
        }),
      ),
    ));
    expect(a, '快门', reason: '未命中诚实回落中文,宁缺毋错');
    expect(b, '未知 7', reason: '回落原文仍做占位替换');
  });

  testWidgets('占位替换:多参/值 toString/未知 {x} 字面保留', (tester) async {
    await tester.pumpWidget(L10nScope(
      code: 'zh',
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          a = context.t('{a} + {b}', {'a': 1, 'b': 2.5});
          b = context.t('{x} 字面保留', {'n': 1});
          c = context.t('无参模板');
          return const SizedBox();
        }),
      ),
    ));
    expect(a, '1 + 2.5', reason: '值按 toString 填入');
    expect(b, '{x} 字面保留', reason: '只替换已知参数名,不误伤字面花括号');
    expect(c, '无参模板');
  });

  testWidgets('scope code 变化:依赖 t() 的子树重建(updateShouldNotify)',
      (tester) async {
    // 子树全程 const:排除「父级重建顺带」的可能,只有 scope 的
    // updateShouldNotify 通知能触发 _T 重建。
    Widget app(String code) => L10nScope(
          code: code,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: _T('跟随系统'),
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
  const _T(this.zh);

  final String zh;

  @override
  Widget build(BuildContext context) => Text(context.t(zh));
}

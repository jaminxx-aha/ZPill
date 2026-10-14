/// 应用文案 i18n 基建(i18n 第一期,2026-10-14):**中文原文即键**。
///
/// 不用 flutter gen-l10n / AppLocalizations —— 全仓 widget 测试用裸
/// MaterialApp(无 delegates)泵页面,`AppLocalizations.of(context)` 在
/// 裸树下抛异常会炸掉全部存量测试。改为自持轻量作用域:
///
/// - 中文环境:`context.t('中文原文')` 原文直返(键即文案,中文页零改写);
/// - 英文环境:查 [enCatalog](键 = 中文原文逐字精确含标点),命中给译文,
///   **未命中回落中文**(诚实兜底,宁缺毋错 —— 抽取进度外的文案如实
///   显示中文,不臆造);
/// - 裸测试树(未装 [L10nScope]):原文直返,存量测试零迁移。
///
/// 语言来源只有 [L10nScope](app 根装配,code 已解析成具体值)。
/// **不要用 Localizations.maybeLocaleOf 取语言** —— MaterialApp 测试树
/// 内部 Localizations 恒在且 test 默认 en_US,按它取语言会让存量中文
/// 断言全线翻车。
library;

import 'package:flutter/widgets.dart';

import 'en_catalog.dart';

/// 语言作用域:[t] 的唯一语言来源,app 根装配(app.dart)。
final class L10nScope extends InheritedWidget {
  const L10nScope({super.key, required this.code, required super.child});

  /// 语言码 'zh' / 'en'(**已解析成具体值,不存在 'system' 态** ——
  /// 跟随系统在装配侧自解析,见 app.dart)。
  final String code;

  /// 可空返回:裸测试树(未装 scope)取不到,t() 走原文兜底。
  static L10nScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<L10nScope>();

  @override
  bool updateShouldNotify(L10nScope oldWidget) => code != oldWidget.code;
}

/// 文案取用:`context.t('中文原文')`。
extension Tr on BuildContext {
  /// [zh] = 中文原文,**即查找键**(与 enCatalog 的键逐字一致,含标点)。
  /// [args] = `{名}` 占位参数:值 toString,只替换已知参数名 —— 未知
  /// `{x}` 字面保留,不误伤字面花括号。
  String t(String zh, [Map<String, Object>? args]) {
    final scope = L10nScope.of(this);
    // 裸测试树(无 scope)→ 原文直返;zh 同;en 未命中也回落原文。
    final text = scope != null && scope.code == 'en'
        ? (enCatalog[zh] ?? zh)
        : zh;
    return _fill(text, args);
  }
}

/// `{名}` 占位替换:只替换已知参数名,避免误伤字面花括号。
String _fill(String template, Map<String, Object>? args) {
  if (args == null || args.isEmpty) return template;
  var out = template;
  for (final e in args.entries) {
    out = out.replaceAll('{${e.key}}', e.value.toString());
  }
  return out;
}

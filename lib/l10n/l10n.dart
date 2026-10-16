/// 应用文案 i18n 基建(**抽象键制**,2026-10-16 由「中文即键」迁移)。
///
/// 不用 flutter gen-l10n / AppLocalizations —— 全仓 widget 测试用裸
/// MaterialApp(无 delegates)泵页面,`AppLocalizations.of(context)` 在
/// 裸树下抛异常会炸掉全部存量测试。改为自持轻量作用域:
///
/// - 调用:`context.t('ns.key')`,键为两段小驼峰抽象键(键名规范见
///   zh_catalog.dart 头注);中文值在 [zhCatalog],英文值在 [enCatalog],
///   两表键集必须完全相等(catalog_integrity_test 强制);
/// - 中文环境/裸测试树(未装 [L10nScope]):查 [zhCatalog] 得中文 ——
///   裸树默认走中文词表是存量中文断言零迁移的根基;
/// - 英文环境:先查 [enCatalog],未命中落 [zhCatalog],再未命中**直通
///   键本身**(诚实兜底,宁缺毋错)。直通也是运行期动态串($e 插值串、
///   相机上报值、.cube TITLE 等)的通道:动态串不是键,两表都查不中,
///   原样透出,与未抽取时代口径一致;
/// - 语言来源只有 [L10nScope](app 根装配,code 已解析成具体值)。
///   **不要用 Localizations.maybeLocaleOf 取语言** —— MaterialApp 测试树
///   内部 Localizations 恒在且 test 默认 en_US,按它取语言会让存量中文
///   断言全线翻车。
library;

import 'package:flutter/widgets.dart';

import 'en_catalog.dart';
import 'zh_catalog.dart';

/// 语言作用域:[t] 的唯一语言来源,app 根装配(app.dart)。
final class L10nScope extends InheritedWidget {
  const L10nScope({super.key, required this.code, required super.child});

  /// 语言码 'zh' / 'en'(**已解析成具体值,不存在 'system' 态** ——
  /// 跟随系统在装配侧自解析,见 app.dart)。
  final String code;

  /// 可空返回:裸测试树(未装 scope)取不到,t() 走中文词表。
  static L10nScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<L10nScope>();

  @override
  bool updateShouldNotify(L10nScope oldWidget) => code != oldWidget.code;
}

/// 文案取用:`context.t('ns.key')`。
extension Tr on BuildContext {
  /// [key] = 抽象键(两表共用的查找键)。运行期动态串(非键)原样
  /// 直通:两表都查不中时返回 [key] 本身。
  ///
  /// [args] = `{名}` 占位参数:值 toString,只替换已知参数名 —— 未知
  /// `{x}` 字面保留,不误伤字面花括号。
  String t(String key, [Map<String, Object>? args]) {
    final scope = L10nScope.of(this);
    String? text;
    if (scope != null && scope.code == 'en') {
      text = enCatalog[key];
    }
    text ??= zhCatalog[key];
    return _fill(text ?? key, args);
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

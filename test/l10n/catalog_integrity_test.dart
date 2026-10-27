import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/l10n/en_catalog.dart';
import 'package:z_pill/l10n/zh_catalog.dart';

/// 词表完整性闸门(键漂移防线):
/// 1. lib/ 全部 t('字面量') 键必须同时在 zh/en 两词表;
/// 2. 两表键集完全相等(加第三语种 = 加一份同键 Map);
/// 3. 键名两段小驼峰(永久契约);
/// 4. 带占位的键,两语种占位名集合一致(缺占位 = 运行期漏填)。
///
/// 控制器层动态串($e 插值等)按设计直通,不进词表也不进本闸门;
/// 键持有者(枚举 label/常量表)产出的键经显示点 t() 消费,若表内
/// 键名有笔误,第 2 条兜不住 —— 依赖第 1 条对字面量调用点的覆盖,
/// 非字面量路径靠 code review 把关。
void main() {
  final litCall = RegExp(r"\.t\(\s*'([^'\\\n]+)'");

  test('lib/ 全部 t() 字面量键都在两词表中', () {
    final used = <String, List<String>>{};
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.startsWith('lib/l10n/')) // 词表与 l10n.dart 本体(注释示例非调用)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(sources, isNotEmpty, reason: 'lib/ 源码必须扫得到(工作目录口径)');
    for (final f in sources) {
      final src = f.readAsStringSync();
      for (final m in litCall.allMatches(src)) {
        // 行号供失败信息定位
        final line = src.substring(0, m.start).split('\n').length;
        used.putIfAbsent(m.group(1)!, () => []).add('${f.path}:$line');
      }
    }
    expect(used, isNotEmpty, reason: 'lib/ 必须存在 t() 字面量调用');
    final missingZh = used.keys.where((k) => !zhCatalog.containsKey(k)).toList();
    final missingEn = used.keys.where((k) => !enCatalog.containsKey(k)).toList();
    expect(missingZh, isEmpty,
        reason: '键不在 zhCatalog(笔误/漏加词表):'
            '${[for (final k in missingZh) '$k <- ${used[k]!.take(2).join(", ")}']}');
    expect(missingEn, isEmpty,
        reason: '键不在 enCatalog(笔误/漏加词表):'
            '${[for (final k in missingEn) '$k <- ${used[k]!.take(2).join(", ")}']}');
  });

  test('zh/en 两表键集完全相等', () {
    final onlyZh = zhCatalog.keys.toSet().difference(enCatalog.keys.toSet());
    final onlyEn = enCatalog.keys.toSet().difference(zhCatalog.keys.toSet());
    expect(onlyZh, isEmpty, reason: '只在 zh 词表的键: $onlyZh');
    expect(onlyEn, isEmpty, reason: '只在 en 词表的键: $onlyEn');
  });

  test('键名两段小驼峰', () {
    final bad = [
      ...zhCatalog.keys,
      ...enCatalog.keys,
    ].where((k) => !RegExp(r'^[a-z][a-zA-Z0-9]*\.[a-z][a-zA-Z0-9]*$').hasMatch(k));
    expect(bad, isEmpty, reason: '键名格式违规(两段小驼峰契约): $bad');
  });

  test('带占位的键两语种占位名一致', () {
    final ph = RegExp(r'\{([a-zA-Z0-9]+)\}');
    final bad = <String>[];
    for (final k in zhCatalog.keys) {
      final en = enCatalog[k];
      if (en == null) continue;
      final zhNames = ph.allMatches(zhCatalog[k]!).map((m) => m.group(1)).toSet();
      final enNames = ph.allMatches(en).map((m) => m.group(1)).toSet();
      if (zhNames.toString() != enNames.toString()) {
        bad.add('$k: zh=$zhNames en=$enNames');
      }
    }
    expect(bad, isEmpty, reason: '占位名不一致(翻译会漏填/误留): $bad');
  });
}

/// 弹层选项持久化(排序/筛选/显示/视图;JSON 文件
/// `<dataDir>/ui_prefs.json`,键值直存)。**文件夹选择不入账**:
/// 句柄随相机内容/会话漂移,持久化会指错夹 —— 每次进页回到「全部照片」。
/// 通道未就绪(测试环境/IO 失败)由调用方吞掉走默认值。
library;

import 'dart:convert';
import 'dart:io';

abstract interface class UiPrefsStore {
  /// 全量键值(无文件 = 空表)。
  Future<Map<String, Object?>> load();

  /// 全量覆盖写。
  Future<void> save(Map<String, Object?> value);
}

final class FileUiPrefsStore implements UiPrefsStore {
  FileUiPrefsStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  Map<String, Object?>? _cache;

  @override
  Future<Map<String, Object?>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    var value = <String, Object?>{};
    final file = File('${await _dataDir()}/ui_prefs.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) value = json;
      } on FormatException {
        // 损坏文件:按空表重建
      }
    }
    return _cache = value;
  }

  @override
  Future<void> save(Map<String, Object?> value) async {
    // 合并写:相机/图库共用一份文件,各自只落自己的键前缀
    //(grid.* / lib.*),整表覆盖会把另一页的选项擦掉。
    final all = await load();
    all.addAll(value);
    _cache = all;
    final file = File('${await _dataDir()}/ui_prefs.json');
    await file.create(recursive: true);
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(all));
  }
}

final class InMemoryUiPrefsStore implements UiPrefsStore {
  final Map<String, Object?> _value = {};

  @override
  Future<Map<String, Object?>> load() async => _value;

  @override
  Future<void> save(Map<String, Object?> value) async {
    _value.addAll(value);
  }
}

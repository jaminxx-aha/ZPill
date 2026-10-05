/// 命名快照仓库(TODO §三 菜单预设):`<dataDir>/config_snapshots.json`,
/// 单文件存「名字 → 快照」全量表,内存缓存 + 全量写回,与设置仓库同款;
/// 损坏文件按空表重建(快照可重拍,无损恢复)。
library;

import 'dart:convert';
import 'dart:io';

import '../core/remote/config_snapshot.dart';

final class ConfigSnapshotStore {
  ConfigSnapshotStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  Map<String, CameraConfigSnapshot>? _cache;

  Future<Map<String, CameraConfigSnapshot>> loadAll() async {
    final cached = _cache;
    if (cached != null) return cached;
    var value = <String, CameraConfigSnapshot>{};
    final file = File('${await _dataDir()}/config_snapshots.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) {
          value = {
            for (final e in json.entries) e.key: CameraConfigSnapshot.fromJson(e.value as Map<String, Object?>),
          };
        }
      } on FormatException {
        // 损坏文件:按空表重建
      }
    }
    return _cache = value;
  }

  Future<void> save(String name, CameraConfigSnapshot snapshot) async {
    final all = await loadAll();
    all[name] = snapshot;
    await _write(all);
  }

  Future<void> delete(String name) async {
    final all = await loadAll();
    if (all.remove(name) == null) return;
    await _write(all);
  }

  Future<void> _write(Map<String, CameraConfigSnapshot> all) async {
    _cache = all;
    final file = File('${await _dataDir()}/config_snapshots.json');
    await file.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      for (final e in all.entries) e.key: e.value.toJson(),
    }));
  }
}

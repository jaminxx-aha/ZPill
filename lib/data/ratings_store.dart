/// 本地评分仓库(TODO §三 文件操作:评级):`<dataDir>/ratings.json`,
/// 「照片身份键 → 1-5 星」。相机侧评级(MTP Rating 属性)是 Zf 死路
/// (MTP 专有,Zf 拒答),评分只存本地、不回写相机。
///
/// 身份键见 [groupKeyOf]:基名 + 组总字节 —— 双格式组在渐进配对前后
/// (代表文件 JPG↔NEF 切换)与重连后句柄变化下都稳定。
library;

import 'dart:convert';
import 'dart:io';

import '../core/browser/photo_group.dart';

/// 相册条目的评分身份键:`基名|组总字节`。
///
/// 句柄跨会话不稳定、代表文件会随配对切换,基名 + 字节数才是跨启动
/// 稳定的组合;同基名不同体积(换卡重拍)不会串评。
String photoGroupKey(PhotoGroup group) =>
    '${baseNameOf(group.primary.name)}|${group.totalBytes}';

abstract interface class RatingsStore {
  /// 键 → 星(1-5);0/未评分不入表。
  Future<Map<String, int>> loadAll();

  /// 写评分([stars] 0 = 清除);持久化失败按调用方捕获处理。
  Future<void> set(String key, int stars);
}

final class FileRatingsStore implements RatingsStore {
  FileRatingsStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  Map<String, int>? _cache;

  @override
  Future<Map<String, int>> loadAll() async {
    final cached = _cache;
    if (cached != null) return cached;
    var value = <String, int>{};
    final file = File('${await _dataDir()}/ratings.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) {
          value = {
            for (final e in json.entries)
              if (e.value is num && (e.value as num).toInt() >= 1)
                e.key: (e.value as num).toInt(),
          };
        }
      } on FormatException {
        // 损坏文件:按空表重建(评分可重标)
      }
    }
    return _cache = value;
  }

  @override
  Future<void> set(String key, int stars) async {
    final all = await loadAll();
    if (stars >= 1) {
      all[key] = stars;
    } else {
      all.remove(key);
    }
    _cache = all;
    final file = File('${await _dataDir()}/ratings.json');
    await file.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(all));
  }
}

final class InMemoryRatingsStore implements RatingsStore {
  final Map<String, int> _value = {};

  @override
  Future<Map<String, int>> loadAll() async => _value;

  @override
  Future<void> set(String key, int stars) async {
    if (stars >= 1) {
      _value[key] = stars;
    } else {
      _value.remove(key);
    }
  }
}

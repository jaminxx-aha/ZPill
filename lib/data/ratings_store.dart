/// 本地文件级评分快照:`<dataDir>/ratings.json`,`文件名|字节 → 1-5 星`。
///
/// 评级真源 = 相机(MTP 0xDC8A Rating,官方 §6.6.3.3 Get/Set —— 旧注
/// 「Zf 拒答」系误断,规格书明文支持,未见真发反证):相机相册的打星
/// 走 0x9804/0x9803 直写相机,不经本仓。本仓只管**应用内文件**(图库)
/// 的评级快照 —— 下载落盘沿按所在组评级写入([fileRatingKey]),相册
/// 改评沿按基名传播,图库的评级徽标与筛选读这里。
///
/// 键含字节长:重拍同名(换卡重编号)文件不串评;旧版组键
///(`基名|组总字节`)遗留条目因文件必带扩展名而天然不命中,无需迁移。
library;

import 'dart:convert';
import 'dart:io';

/// 图库文件条目的评分身份键:`文件名|字节数`。
String fileRatingKey(String name, int bytes) => '$name|$bytes';

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

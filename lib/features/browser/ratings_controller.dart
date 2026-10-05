/// 本地评分控制器(TODO §三):网格角标与查看器打星共享同一状态;
/// 组身份键跨会话稳定(见 ratings_store.photoGroupKey)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/photo_group.dart';
import '../../data/ratings_store.dart';

final class RatingsController extends ChangeNotifier {
  RatingsController({required this.store}) {
    unawaited(_load());
  }

  final RatingsStore store;

  /// 键 → 星(0-5;0 = 未评)。
  final Map<String, int> ratings = {};

  Future<void> _load() async {
    try {
      ratings.addAll(await store.loadAll());
    } on Object {
      // 通道未就绪(测试环境):空表,界面照常只是无星
    }
    notifyListeners();
  }

  /// 组当前评分(0 = 未评)。
  int ratingOf(PhotoGroup group) => ratings[photoGroupKey(group)] ?? 0;

  /// 打星([stars] 0 = 清除);乐观上屏,失败静默回滚。
  Future<void> rate(PhotoGroup group, int stars) async {
    final key = photoGroupKey(group);
    final previous = ratings[key] ?? 0;
    if (stars >= 1) {
      ratings[key] = stars;
    } else {
      ratings.remove(key);
    }
    notifyListeners();
    try {
      await store.set(key, stars);
    } on Object {
      if (previous >= 1) {
        ratings[key] = previous;
      } else {
        ratings.remove(key);
      }
      notifyListeners();
    }
  }
}

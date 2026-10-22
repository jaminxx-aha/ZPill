/// 图库评级(应用内文件快照):键 = `文件名|字节`(见 ratings_store
/// [fileRatingKey]),网格徽标与筛选弹层共享同一状态。写入沿在
/// AppServices:下载落盘沿按所在组评级快照,相册改评沿按基名传播。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/ratings_store.dart';

final class LibraryRatings extends ChangeNotifier {
  LibraryRatings({required this.store}) {
    unawaited(reload());
  }

  final RatingsStore store;

  Map<String, int> _values = const {};

  /// 首轮装载是否完成(筛选分区只在装载后展示,防空筛)。
  bool loaded = false;

  /// 文件当前评分(0 = 未评/文件不可读)。
  int ratingOf(File file) {
    try {
      return _values[fileRatingKey(_nameOf(file), file.lengthSync())] ?? 0;
    } on FileSystemException {
      return 0;
    }
  }

  /// 写文件评分([stars] 0 = 清除)并刷新(相册改评传播沿)。
  Future<void> setFile(String name, int bytes, int stars) async {
    await store.set(fileRatingKey(name, bytes), stars);
    await reload();
  }

  /// 重读仓库(装载/传播/下载沿后调)。
  Future<void> reload() async {
    try {
      _values = await store.loadAll();
      loaded = true;
    } on Object {
      // 通道未就绪(测试环境):保持空表,界面照常只是无星
      return;
    }
    notifyListeners();
  }

  String _nameOf(File file) => file.uri.pathSegments.last;
}

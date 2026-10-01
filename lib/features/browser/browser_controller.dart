/// 相册浏览控制器:连接成功自动加载、断连清空、枚举进度上报。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/album.dart';
import '../../core/browser/object_repository.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/camera/camera_connection.dart';

final class BrowserController extends ChangeNotifier {
  BrowserController({
    required this.repository,
    this.connection,
    this.thumbnails,
  }) {
    // 连接成功 → 自动加载(浏览页处于后台 tab 时也能就绪)。
    connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        load();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _invalidate();
      }
    });
  }

  final ObjectRepository repository;
  final CameraConnection? connection;
  final ThumbnailCache? thumbnails;

  List<CameraAlbum> albums = const [];
  bool loading = false;
  String? error;

  /// 枚举进度 (已加载, 总数);null = 未在枚举。
  (int, int)? progress;

  Future<void> load() async {
    if (loading) {
      return;
    }
    loading = true;
    error = null;
    progress = null;
    notifyListeners();
    try {
      albums = await repository.loadAlbums(
        onProgress: (loaded, total) {
          progress = (loaded, total);
          notifyListeners();
        },
      );
    } on Exception catch (e) {
      albums = const [];
      error = '加载失败:$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 断连/失败:相册清空(仓库缓存由 AppServices 的连接监听负责 reset)。
  void _invalidate() {
    albums = const [];
    error = null;
    progress = null;
    notifyListeners();
  }
}

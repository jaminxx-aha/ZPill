/// 相册浏览控制器:连接成功自动加载、断连清空、渐进同步进度上报。
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
    // 渐进发布:每块一次(约 25 次/602 对象,非逐对象)。
    _updatesSub = repository.updates.listen(_onUpdate);
    // 连接成功 → 自动加载(浏览页处于后台 tab 时也能就绪)。
    connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        load();
      } else if (s == CameraLinkState.reconnecting) {
        // 自动重连期:门闩挡迟到的块事件,数据冻结不清 —— 重连成功沿
        // load() 照旧重载(connected 分支在上)。
        _linkUp = false;
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

  /// 后台同步剩余对象中(不阻塞浏览;每块一次 notifyListeners)。
  bool syncing = false;
  String? error;

  /// 同步进度 (已加载, 总数);null = 未在同步。
  (int, int)? progress;

  /// 连接态门闩:断连/失败后闩上 —— 迟到的块事件直接丢弃,断连引发的
  /// 在途枚举异常也不上屏(_invalidate 已清态)。解决控制器 _invalidate
  /// 与 AppServices 的 repository.reset() 两个订阅者之间的事件穿插竞态。
  /// 默认放行:无连接构造(独立使用/测试)照常加载。
  bool _linkUp = true;

  StreamSubscription<AlbumsUpdate>? _updatesSub;

  void _onUpdate(AlbumsUpdate update) {
    if (!_linkUp) return;
    albums = update.albums;
    progress = (update.loaded, update.total);
    notifyListeners();
  }

  Future<void> load() async {
    if (syncing) {
      return;
    }
    syncing = true;
    error = null;
    progress = null;
    notifyListeners();
    try {
      final result = await repository.loadAlbums();
      // 断连门闩:枚举期间断连的话 _invalidate 已清态,迟到的返回值
      // (reset 后 _loadAll 提前正常返回,_buildAlbums 读到的是清空后的
      // 缓存)不得再覆盖界面。
      if (_linkUp) {
        albums = result;
      }
    } on Exception catch (e) {
      if (!_linkUp) return; // 断连引发的失败:_invalidate 已清态,不报错
      error = albums.isEmpty
          ? '加载失败:$e'
          : '部分对象同步中断:$e(已显示内容可继续浏览)';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// 手动刷新 / 下拉刷新:重置后重新渐进枚举(缩略图磁盘缓存仍在)。
  Future<void> reload() async {
    repository.reset();
    await load();
  }

  /// 断连/失败:相册清空(仓库缓存由 AppServices 的连接监听负责 reset)。
  void _invalidate() {
    _linkUp = false;
    albums = const [];
    error = null;
    progress = null;
    syncing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    super.dispose();
  }
}

/// 缩略图缓存:GetThumb / Nikon GetLargeThumb → 落盘 + LRU 容量控制。
///
/// 两档来源([ThumbSource]):grid = 网格小图(0x100A,小而快),
/// preview = 大图预览(尼康 0x90C4;相机不支持时回落 GetThumb 放大)。
///
/// 缓存键 = 文件名 + 字节数(内容键):跨会话稳定,不怕相机重连后
/// handle 失效指向别的照片。拉取经 [PtpSession] 全局串行锁
/// (相机一次一个事务);同键并发请求合并(网格滚动反复 build 不重复拉)。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/gallery_saver.dart';
import '../ptp/ptp_session.dart';
import 'object_entry.dart';

/// 缩略图来源档位。
enum ThumbSource { grid, preview }

typedef _CachedThumb = ({String path, int bytes});

final class ThumbnailCache {
  ThumbnailCache({
    required this.session,
    required this.gallery,
    this.gridLimitBytes = 32 * 1024 * 1024,
    this.previewLimitBytes = 256 * 1024 * 1024,
  });

  final PtpSession session;
  final GallerySaver gallery;

  /// LRU 字节上限(构造可注入,测试用)。超出后按最久未访问驱逐删盘。
  final int gridLimitBytes;
  final int previewLimitBytes;

  /// LRU 索引:Dart Map 即 LinkedHashMap,插入序 = 访问序(命中重插刷新)。
  final Map<String, _CachedThumb> _grid = {};
  final Map<String, _CachedThumb> _preview = {};
  final Map<(ThumbSource, String), Future<String>> _pending = {};

  String? _thumbsDir;
  String? _previewsDir;

  /// 取 [entry] 在 [source] 档位的缩略图文件路径;内存/磁盘未命中时
  /// 向相机拉取并落盘。失败不缓存失败态(下次可重试),异常原样上抛。
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) {
    final key = _keyFor(entry);
    final lru = _lruFor(source);
    final cached = lru[key];
    if (cached != null) {
      lru.remove(key);
      lru[key] = cached;
      return Future.value(cached.path);
    }
    final pendingKey = (source, key);
    final inFlight = _pending[pendingKey];
    if (inFlight != null) {
      return inFlight;
    }
    final fetch = _fetch(entry, source, key);
    _pending[pendingKey] = fetch;
    return fetch.whenComplete(() => _pending.remove(pendingKey));
  }

  /// 断连时清内存索引;缓存键是内容键(文件名+大小),跨会话稳定,
  /// 磁盘缓存保留,重连后直接命中。
  void reset() {
    _grid.clear();
    _preview.clear();
  }

  Future<String> _fetch(
      ObjectEntry entry, ThumbSource source, String key) async {
    final dir = await _dirFor(source);
    final path = '$dir/$key.jpg';
    final file = File(path);
    if (await file.exists()) {
      // 磁盘缓存命中:登记索引,不进相机。
      _remember(source, key, path, await file.length());
      await _evictIfNeeded(source);
      return path;
    }
    Uint8List data;
    try {
      data = source == ThumbSource.grid
          ? await session.getThumb(entry.handle)
          : await _fetchPreview(entry.handle);
    } catch (e) {
      // 真机诊断辅助:缩略图拉取失败的原因进 hilog(不改变行为,
      // 异常原样上抛,UI 显示占位)。
      debugPrint('[缩略图] $source ${entry.name}'
          '(0x${entry.handle.toRadixString(16)}) 失败: $e');
      rethrow;
    }
    await file.writeAsBytes(data, flush: true);
    _remember(source, key, path, data.length);
    await _evictIfNeeded(source);
    return path;
  }

  /// 大图预览:优先 Nikon GetLargeThumb(0x90C4,NEF 也有 JPEG 预览);
  /// 相机不支持或拒绝(部分机身对个别对象回错误码)时回落标准
  /// GetThumb(小图,UI 放大显示)。
  Future<Uint8List> _fetchPreview(int handle) async {
    try {
      return await session.getLargeThumb(handle);
    } on UnsupportedError {
      return session.getThumb(handle);
    } on PtpResponseException {
      return session.getThumb(handle);
    }
  }

  Map<String, _CachedThumb> _lruFor(ThumbSource source) =>
      source == ThumbSource.grid ? _grid : _preview;

  Future<String> _dirFor(ThumbSource source) async {
    if (source == ThumbSource.grid) {
      return _thumbsDir ??= await gallery.thumbsDir();
    }
    return _previewsDir ??= await gallery.previewsDir();
  }

  void _remember(ThumbSource source, String key, String path, int bytes) {
    _lruFor(source)[key] = (path: path, bytes: bytes);
  }

  Future<void> _evictIfNeeded(ThumbSource source) async {
    final lru = _lruFor(source);
    final limit =
        source == ThumbSource.grid ? gridLimitBytes : previewLimitBytes;
    var total = 0;
    for (final c in lru.values) {
      total += c.bytes;
    }
    while (total > limit && lru.isNotEmpty) {
      final oldestKey = lru.keys.first;
      final oldest = lru.remove(oldestKey)!;
      total -= oldest.bytes;
      try {
        await File(oldest.path).delete();
      } on FileSystemException {
        // 盘上已无此文件:索引清掉即可
      }
    }
  }

  /// 内容键:文件名(去非法字符)+ 字节数。同名同大小的两张照片
  /// 即便存在也字节级几乎不可能同内容,碰撞风险可忽略。
  static String _keyFor(ObjectEntry entry) {
    final safe =
        entry.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${safe}_${entry.sizeInBytes}';
  }
}

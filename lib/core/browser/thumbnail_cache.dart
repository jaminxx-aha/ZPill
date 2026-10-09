/// 缩略图缓存:GetThumb / Nikon GetLargeThumb → 落盘 + LRU 容量控制。
///
/// 两档来源([ThumbSource]):grid = 网格小图(0x100A,小而快),
/// preview = 大图预览。preview 按对象类型分流:
/// - 普通图像(含 JPG):Nikon 0x90C4 大图 JPEG(实测 640×424);
///   相机不支持时回落 GetThumb 放大。
/// - NEF(Z f 定案 2026-10-09:0x90C4 对 NEF 回 320×212 的 NEF 压缩
///   条带,非 JPEG;档内也无大 JPEG)→ 下载整档 → 原生 RAW 解码
///   (iOS ImageIO,Android/ohos 待补)→ JPEG 落盘;解码不可用/失败
///   回落 GetThumb(160×120 小图)。
///
/// 缓存键 = 文件名 + 字节数(内容键):跨会话稳定,不怕相机重连后
/// handle 失效指向别的照片。拉取经 [PtpSession] 全局串行锁
/// (相机一次一个事务);同键并发请求合并(网格滚动反复 build 不重复拉)。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../ptp/ptp_session.dart';
import '../transfer/object_downloader.dart';
import 'object_entry.dart';
import 'photo_group.dart' show isRawFile;

/// 缩略图来源档位。
enum ThumbSource { grid, preview }

typedef _CachedThumb = ({String path, int bytes});

/// 非 final + 依赖字段私有:widget 测试可 implements(仅 pathFor/reset,
/// 注入假路径,避开平台目录/MethodChannel)。
class ThumbnailCache {
  ThumbnailCache({
    required PtpSession session,
    required GallerySaver gallery,
    ObjectDownloader? downloader,
    RawDecoder? rawDecoder,
    this.previewMaxPixelSize = 2560,
    this.gridLimitBytes = 32 * 1024 * 1024,
    this.previewLimitBytes = 256 * 1024 * 1024,
  })  : _session = session,
        _gallery = gallery,
        _downloader = downloader ?? ObjectDownloader(session: session),
        _rawDecoder = rawDecoder;

  final PtpSession _session;
  final GallerySaver _gallery;

  /// NEF 预览管线用(整档下载);缺省自建(同 session)。
  final ObjectDownloader _downloader;

  /// NEF 预览管线用(原生 RAW 解码);null = 该平台无解码器
  /// (Android/ohos 待补)→ 回落 GetThumb 小图。
  final RawDecoder? _rawDecoder;

  /// NEF 解码长边上限(像素):对齐高端手机屏宽级缩放解码,
  /// 平衡清晰度/解码耗时/缓存体积(2560px JPEG ≈ 1-2MB)。
  final int previewMaxPixelSize;

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
          ? await _session.getThumb(entry.handle)
          : await _fetchPreview(entry);
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

  /// 大图预览分流:NEF 走「整档下载 → 原生解码」管线(0x90C4 对 NEF
  /// 回非 JPEG 的压缩条带,档内也无大 JPEG —— 2026-10-09 探针定案);
  /// 其余走 Nikon GetLargeThumb(0x90C4),相机不支持或拒绝(部分机身
  /// 对个别对象回错误码)时回落标准 GetThumb(小图,UI 放大显示)。
  Future<Uint8List> _fetchPreview(ObjectEntry entry) async {
    if (isRawFile(entry)) {
      return _fetchNefPreview(entry);
    }
    try {
      return await _session.getLargeThumb(entry.handle);
    } on UnsupportedError {
      return _session.getThumb(entry.handle);
    } on PtpResponseException {
      return _session.getThumb(entry.handle);
    }
  }

  /// NEF 预览:整档下载到临时目录 → 原生解码为 JPEG(长边 ≤
  /// [previewMaxPixelSize])→ 删临时档。任一环不可用(平台无解码器/
  /// 下载失败/解码失败)回落 GetThumb(160×120;Z f 实测恒可用)。
  Future<Uint8List> _fetchNefPreview(ObjectEntry entry) async {
    final decoder = _rawDecoder;
    if (decoder == null) {
      return _session.getThumb(entry.handle);
    }
    ObjectDownload? dl;
    try {
      dl = await _downloader.download(entry,
          targetDir: await _gallery.tempDir());
      return await decoder.decodeJpeg(dl.path,
          maxPixelSize: previewMaxPixelSize);
    } on Exception {
      return _session.getThumb(entry.handle);
    } finally {
      if (dl != null) {
        try {
          await File(dl.path).delete();
        } on FileSystemException {
          // 删失败不挡预览(临时目录系统可回收)
        }
      }
    }
  }

  Map<String, _CachedThumb> _lruFor(ThumbSource source) =>
      source == ThumbSource.grid ? _grid : _preview;

  Future<String> _dirFor(ThumbSource source) async {
    if (source == ThumbSource.grid) {
      return _thumbsDir ??= await _gallery.thumbsDir();
    }
    return _previewsDir ??= await _gallery.previewsDir();
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

/// 缩略图缓存:GetThumb / Nikon GetLargeThumb → 落盘 + LRU 容量控制。
///
/// 两档来源([ThumbSource]):grid = 网格小图(0x100A,小而快),
/// preview = 大图预览(两席位):
/// - 小图席位(先显,即时):JPG = Nikon 0x90C4(实测 640×424,
///   **直发不查能力表** —— 无线 STA 的 op 小表是假门,查表会把大图
///   无谓拒成 160×120 回落,2026-10-09 装机复报「点进去很小」根因;
///   相机拒绝时回落 GetThumb);NEF = GetThumb(0x90C4 对 NEF 回
///   320×212 的 NEF 压缩条带非 JPEG,Z f 定案档内也无大 JPEG)。
/// - 高清席位([warmPreview],查看器页 settle 触发):整档下载 →
///   原生解码(iOS ImageIO,长边 ≤ [ThumbnailCache.previewMaxPixelSize],
///   JPG/NEF 通吃)→ 落盘 → [ThumbnailCache.previewUpgrades] 发换图
///   事件(小图 640×424/160×120 撑满是糊的,2026-10-09 复报;解码
///   产物原生已转正不再注入方向)。解码不可用(Android/ohos 待补)
///   只有小图席位。
///
/// 方向规整(见 [_orientThumb]):相机缩略是裸 JPEG(竖拍像素横置、
/// 无 EXIF),取原文件头 EXIF Orientation 注入缩略,引擎解码即转正 —
/// 网格格与查看器共用同一份缓存文件。**旧版本的缓存文件没有注入而
/// 内容键不变** —— [_dirFor] 带一次性格式清空闸,升级后首轮访问把
/// 旧档清掉重建(2026-10-09 复报「竖拍仍不转正」根因:磁盘命中旧档)。
///
/// 缓存键 = 文件名 + 字节数(内容键):跨会话稳定,不怕相机重连后
/// handle 失效指向别的照片。拉取经 [PtpSession] 全局串行锁
/// (相机一次一个事务);同键并发请求合并(网格滚动反复 build 不重复拉)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../media/jpeg_orientation.dart';
import '../ptpip/object_format.dart' show ObjectKind;
import '../ptp/ptp_session.dart';
import '../transfer/object_downloader.dart';
import 'object_entry.dart';
import 'photo_group.dart' show isRawFile;

/// 缩略图来源档位。
enum ThumbSource { grid, preview }

/// 大图预览升级事件([ThumbnailCache.warmPreview] 整档解码完成后发;
/// 查看器按 handle + 字节数匹配换图)。
typedef PreviewUpgrade = ({int handle, int sizeInBytes, String path});

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

  /// 原文件 EXIF 方向(内容键 → 1-8;0 = 未知/无转正含义)。取一次
  /// 2KB 头读(见 [_orientThumb]),网格缩略与预览两档共用。
  final Map<String, Future<int>> _orientationOf = {};

  /// 高清席位升级事件总线([previewUpgrades] 的源)。
  final StreamController<PreviewUpgrade> _upgradeCtrl =
      StreamController<PreviewUpgrade>.broadcast();

  /// 高清预热:在途内容键 / 单槽排队(只留最新)/ 本会话已试(成败
  /// 都记,失败不重试)。
  String? _hqWarming;
  ObjectEntry? _hqNext;
  final Set<String> _hqTried = {};

  /// 目录格式清空闸(见 [_dirFor]):每目录每实例只扫一次。
  final Map<String, Future<void>> _swept = {};

  String? _thumbsDir;
  String? _previewsDir;

  /// 预览升级流:[warmPreview] 的高清档落盘后发(小图先显,事件到即
  /// 换高清)。广播流,查看器各页订阅后按 handle+字节数过滤。
  Stream<PreviewUpgrade> get previewUpgrades => _upgradeCtrl.stream;

  /// 预热大图预览(高清席位):查看器页 settle 后调 —— 小图已先显,
  /// 这里后台拉整档 → 原生解码 → 落盘 `hq_<键>.jpg` → [previewUpgrades]
  /// 发换图事件。串行单槽:在途不顶(已占的带宽不白费),未起跑的
  /// 排队只留最新(快速翻页只暖停留的页);本会话每张只试一次。
  /// 返回的 future 在「本次尝试 settle(或被排队顶掉)」后完成,仅供
  /// 测试等待;调用方换图走事件,不等待。
  Future<void> warmPreview(ObjectEntry entry) async {
    if (_rawDecoder == null) return; // 无解码器平台(Android/ohos):无高清
    if (entry.kind == ObjectKind.video) return; // 视频海报无高清语义
    final key = _keyFor(entry);
    if (_hqWarming == key || _hqTried.contains(key)) return;
    if (_hqWarming == null) {
      await _startHq(entry, key);
    } else {
      _hqNext = entry;
    }
  }

  Future<void> _startHq(ObjectEntry entry, String key) async {
    _hqWarming = key;
    _hqTried.add(key);
    try {
      final dir = await _dirFor(ThumbSource.preview);
      final path = '$dir/hq_$key.jpg';
      if (await File(path).exists()) return; // 高清已在(本会话/前会话)
      ObjectDownload? dl;
      try {
        dl = await _downloader.download(entry,
            targetDir: await _gallery.tempDir());
        // 解码产物已被原生 transform 转正,不再注入方向(防二次旋转)。
        final jpeg = await _rawDecoder!
            .decodeJpeg(dl.path, maxPixelSize: previewMaxPixelSize);
        await File(path).writeAsBytes(jpeg, flush: true);
        _remember(ThumbSource.preview, 'hq_$key', path, jpeg.length);
        await _evictIfNeeded(ThumbSource.preview);
        _upgradeCtrl.add(
            (handle: entry.handle, sizeInBytes: entry.sizeInBytes, path: path));
      } on Exception {
        // 尽力而为:失败不重试本会话(高清缺席,小图继续顶着)
      } finally {
        if (dl != null) {
          try {
            await File(dl.path).delete();
          } on FileSystemException {
            // 删失败不挡(临时目录系统可回收)
          }
        }
      }
    } finally {
      _hqWarming = null;
      final next = _hqNext;
      _hqNext = null;
      if (next != null) {
        await warmPreview(next); // 排队里的最新一张接棒
      }
    }
  }

  /// 取 [entry] 在 [source] 档位的缩略图文件路径;内存/磁盘未命中时
  /// 向相机拉取并落盘。失败不缓存失败态(下次可重试),异常原样上抛。
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) {
    final key = _keyFor(entry);
    final lru = _lruFor(source);
    // 高清席位优先(预览档):升级档一旦就位,同会话重开直接给高清
    // (小图条目还在索引里,普通命中会永远回小图;warmPreview 又因
    // 「本会话已试」不再发事件)。
    if (source == ThumbSource.preview) {
      final hq = lru['hq_$key'];
      if (hq != null) {
        lru.remove('hq_$key');
        lru['hq_$key'] = hq;
        return Future.value(hq.path);
      }
    }
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

  static const _fmtMarker = '.fmt-v2';

  Future<String> _fetch(
      ObjectEntry entry, ThumbSource source, String key) async {
    final dir = await _dirFor(source);
    if (source == ThumbSource.preview) {
      // 高清席位(整档解码)优先:在则直接给高清
      final hqPath = '$dir/hq_$key.jpg';
      final hqFile = File(hqPath);
      if (await hqFile.exists()) {
        _remember(source, 'hq_$key', hqPath, await hqFile.length());
        await _evictIfNeeded(source);
        return hqPath;
      }
    }
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
          ? await _orientThumb(entry, await _session.getThumb(entry.handle))
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

  /// 大图预览的**小图席位**(先显,即时):JPG = Nikon 0x90C4 **直发
  /// 不查能力表**(无线 STA 的 op 小表是假门,查表会把大图无谓拒成
  /// 160×120 回落);相机拒绝(错误码)回落标准 GetThumb。NEF =
  /// GetThumb 直取(0x90C4 对 NEF 回非 JPEG 的压缩条带,Z f 定案)。
  /// 小图撑满是糊的 —— 高清席位见 [warmPreview](整档下载 + 原生
  /// 解码,先显后换)。
  Future<Uint8List> _fetchPreview(ObjectEntry entry) async {
    if (isRawFile(entry)) {
      return _orientThumb(entry, await _session.getThumb(entry.handle));
    }
    try {
      return await _orientThumb(
          entry, await _session.getLargeThumb(entry.handle, force: true));
    } on PtpResponseException {
      return _orientThumb(entry, await _session.getThumb(entry.handle));
    }
  }

  /// 缩略方向规整:相机回的缩略是裸 JPEG(竖拍像素横置、无 EXIF ——
  /// 2026-10-09 探针定案,见 jpeg_orientation.dart),读原文件头部的
  /// EXIF Orientation 注入缩略,引擎解码即转正(网格/查看器同享)。
  /// 视频跳过(海报无 EXIF 语义);带 EXIF 的缩略(引擎自会转)不动;
  /// 头读失败(旧机身不支持 0x101B/解析不了)静默不转,不挡缩略。
  Future<Uint8List> _orientThumb(ObjectEntry entry, Uint8List thumb) async {
    if (entry.kind == ObjectKind.video) return thumb;
    if (jpegHasExif(thumb)) return thumb;
    final orientation =
        await _orientationOf.putIfAbsent(_keyFor(entry), () async {
      try {
        // JPG 的 IFD0 条目表与 NEF 的 IFD0@8 都在文件头 2KB 内。
        return orientationFromHead(
            await _session.getPartialObject(entry.handle, 0, 2048));
      } on Exception {
        return 0; // 协议层失败(旧机身拒 0x101B 等):无转正,不挡缩略
      } on Object catch (e) {
        // 意外(Error 类)同样尽力而为:0 驻留本会话,不挡缩略本身
        debugPrint('[缩略图] 方向头读失败 ${entry.name}: $e');
        return 0;
      }
    });
    return injectJpegOrientation(thumb, orientation);
  }

  Map<String, _CachedThumb> _lruFor(ThumbSource source) =>
      source == ThumbSource.grid ? _grid : _preview;

  Future<String> _dirFor(ThumbSource source) async {
    final dir = source == ThumbSource.grid
        ? _thumbsDir ??= await _gallery.thumbsDir()
        : _previewsDir ??= await _gallery.previewsDir();
    // 格式清空闸:缓存文件格式升版(方向注入上线)后,旧档与新版同
    // 内容键会互相命中 —— 一次性清空重建(标记档在,永不再扫)。每
    // 目录每实例只走一次([_swept] 合并并发)。
    await _swept.putIfAbsent(dir, () => _sweepOnce(dir));
    return dir;
  }

  Future<void> _sweepOnce(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return; // 目录未建:无旧档可清
    final marker = File('$dir/$_fmtMarker');
    if (await marker.exists()) return;
    try {
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.jpg')) {
          try {
            await f.delete();
          } on FileSystemException {
            // 单档删失败不挡其余
          }
        }
      }
      await marker.writeAsString('cleared');
    } on FileSystemException {
      // 目录枚举异常:尽力清到此为止(标记可能未落,下个会话再扫一遍
      // 也只是空扫)
    }
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

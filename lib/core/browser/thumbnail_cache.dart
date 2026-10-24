/// 缩略图缓存:GetThumb / Nikon GetLargeThumb → 落盘 + LRU 容量控制。
///
/// 两档来源([ThumbSource]):grid = 网格小图(JPG = Nikon 0x90C4 高清
/// ~1024px 优先,失败/不支持回落 0x100A 小图 —— N-link 手法,网格
/// 自动受益;NEF/视频 = 0x100A,0x90C4 对 NEF 回压缩条带非 JPEG),
/// preview = 大图预览(三席位):
/// - FHD 席位(先显,2026-10-16 起照片通吃):Nikon 0x920F FHD JPEG
///   (1920 级,原 640×424 小图撑满全屏太糊 —— 真机复报「点进去模糊
///   然后一闪变清晰」的糊段压缩)。JPG/RAW 同路(0x920F 对 JPG 在册性
///   未证:直发 + 失败会话级降级回落,直发纪律同 0x90C4/0x920F 现行);
///   视频不试(海报无 FHD 语义)。独立键 `fhd_<内容键>`,网格不吃。
/// - 小图席位(先显兜底):JPG = Nikon 0x90C4(实测 640×424,
///   **直发不查能力表** —— 无线 STA 的 op 小表是假门,查表会把大图
///   无谓拒成 160×120 回落,2026-10-09 装机复报「点进去很小」根因;
///   失败回落 GetThumb —— 2026-10-15 起网格档 JPG 同路,并加会话级
///   降级旗标防逐张浪费 RTT);NEF = FHD 失败回落 GetThumb。
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
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../log/app_log.dart';
import '../media/jpeg_orientation.dart';
import '../media/letterbox.dart';
import '../media/watermark.dart' show ExifCardData, exifCardFromHead;
import '../ptpip/object_format.dart' show ObjectFormatCode, ObjectKind;
import '../ptpip/transport.dart' show PtpLinkException;
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
    this.gridLimitBytes = 256 * 1024 * 1024,
    this.previewLimitBytes = 512 * 1024 * 1024,
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

  /// LRU 字节账(与索引同序维护,O(1) 驱逐记账):旧版 [_evictIfNeeded]
  /// 每次全表求和,大相册每取一格 O(n) 扫一遍。账随索引走 —— 索引的
  /// 全部变更收口在 [_remember]/[_forget]/[_evictIfNeeded]/[reset]
  /// (插入/覆盖加、出表减、清空归零),账恒等于索引在册字节和,按
  /// 构造保证账实相符,无需周期性全表重算兜底;索引是按访问惰性建
  /// (无冷启动批量建账点),构造从零起。
  int _gridBytes = 0;
  int _previewBytes = 0;

  int _bytesOf(ThumbSource source) =>
      source == ThumbSource.grid ? _gridBytes : _previewBytes;

  void _addBytes(ThumbSource source, int delta) {
    if (source == ThumbSource.grid) {
      _gridBytes += delta;
    } else {
      _previewBytes += delta;
    }
  }
  final Map<(ThumbSource, String), Future<String>> _pending = {};

  /// 原文件 EXIF 方向(内容键 → 1-8;0 = 未知/无转正含义)。取一次
  /// 2KB 头读(见 [_orientThumb]),网格缩略与预览两档共用。
  final Map<String, Future<int>> _orientationOf = {};

  /// 原文件 EXIF 摘要(内容键 → 卡;null = 无 EXIF)。64KB 头读一次
  /// (IFD0/ExifIFD/LensModel 全在前段,Zf 实测),查看器信息栏用;
  /// 协议层失败不驻留(下次点开重试)。
  final Map<String, Future<ExifCardData?>> _exifCards = {};

  /// 高清席位升级事件总线([previewUpgrades] 的源)。
  final StreamController<PreviewUpgrade> _upgradeCtrl =
      StreamController<PreviewUpgrade>.broadcast();

  /// 0x920F FHD 席位的会话降级旗标(Zf 对 JPG 的在册性未证):一拍
  /// 失败(错误应答/单事务超时)即置位,本会话后续照片预览不再逐张
  /// 浪费 RTT(JPG/RAW 同旗);链路类异常不置(链死时后续取数同败,
  /// 无谓连坐)。[reset](断连)复位重新探测。
  bool _fhdPictureDegraded = false;

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
    // 命中即刷到 LRU 尾部(最新端);**盘档已无的命中当未命中**(LRU
    // 驱逐删档/系统回收后,死路径缓存不失效会让格子永远断图 —— 索引
    // 在而文件不在,2026-10-16 真机 440 张相册「回拉全部断图」根因)。
    _CachedThumb? refresh(String k) {
      final c = lru[k];
      if (c == null) return null;
      if (!File(c.path).existsSync()) {
        // 盘档已无:出表出账当未命中(账随索引,不走全表重算)
        _forget(source, k);
        return null;
      }
      _remember(source, k, c.path, c.bytes); // 命中移尾(字节不变,账净零)
      return c;
    }

    // 高清席位优先(预览档):升级档一旦就位,同会话重开直接给高清
    // (小图条目还在索引里,普通命中会永远回小图;warmPreview 又因
    // 「本会话已试」不再发事件)。
    if (source == ThumbSource.preview) {
      final hq = refresh('hq_$key');
      if (hq != null) return Future.value(hq.path);
    }
    // FHD 席位次之(预览档,照片通吃 —— JPG 0x90C4 640×424 撑满太糊,
    // 见库注):本会话/前会话已取到 FHD 的直接给。
    if (source == ThumbSource.preview &&
        entry.kind != ObjectKind.video) {
      final fhd = refresh('fhd_$key');
      if (fhd != null) return Future.value(fhd.path);
    }
    // JPG 的 0x90C4 高清档(lt_ 键)先于小图档:本会话已取到高清的
    // 直接给(见 [_fetchJpg] 的双键设计)。
    if (_isJpgObject(entry)) {
      final lt = refresh('lt_$key');
      if (lt != null) return Future.value(lt.path);
    }
    final cached = refresh(key);
    if (cached != null) return Future.value(cached.path);
    final pendingKey = (source, key);
    final inFlight = _pending[pendingKey];
    if (inFlight != null) {
      return inFlight;
    }
    final fetch = _fetch(entry, source, key);
    _pending[pendingKey] = fetch;
    return fetch.whenComplete(() => _pending.remove(pendingKey));
  }

  /// 取 [entry] 原文件的 EXIF 摘要(查看器信息栏):64KB→16KB 头读
  /// 阶梯 → [exifCardFromHead](JPG APP1 / NEF TIFF 头同路)。视频无
  /// EXIF 语义直接 null;协议失败(旧机身拒 0x101B/链路忙)不缓存,
  /// 下次点开重试;解析出的卡(含「确无 EXIF」的 null)按内容键驻留
  /// 本会话,翻回不再拉。
  Future<ExifCardData?> exifCardOf(ObjectEntry entry) {
    if (entry.kind == ObjectKind.video) return Future.value(null);
    final key = _keyFor(entry);
    return _exifCards.putIfAbsent(key, () async {
      Uint8List? head;
      for (final size in const [64 * 1024, 16 * 1024]) {
        try {
          final chunk = await _session.getPartialObject(entry.handle, 0, size);
          if (chunk.isNotEmpty) {
            head = chunk;
            break;
          }
        } on Exception {
          // 该档失败:试下一档(镜头卡 _readLens 同款阶梯)
        }
      }
      if (head == null) {
        // 协议失败不驻留:下次点开重试(remove 掉的是本在途 future,
        // 并发共享者已各自持有,不受影响)。
        unawaited(_exifCards.remove(key));
        return null;
      }
      return exifCardFromHead(head);
    });
  }

  /// 断连时清内存索引;缓存键是内容键(文件名+大小),跨会话稳定,
  /// 磁盘缓存保留,重连后直接命中。FHD 席位降级旗标同复位(新链重探)。
  /// 字节账随索引归零(账实相符的清空沿)。
  void reset() {
    _grid.clear();
    _preview.clear();
    _gridBytes = 0;
    _previewBytes = 0;
    _fhdPictureDegraded = false;
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
      // FHD 席位(照片通吃,视频海报不试):磁盘命中(前会话产物)即用;
      // 未降级先发 0x920F 直取(不查能力表,假门教训同 0x90C4)。失败
      // 置会话降级,后续照片直走下方小图链。
      if (entry.kind != ObjectKind.video) {
        final fhdPath = '$dir/fhd_$key.jpg';
        final fhdFile = File(fhdPath);
        if (await fhdFile.exists()) {
          _remember(source, 'fhd_$key', fhdPath, await fhdFile.length());
          await _evictIfNeeded(source);
          return fhdPath;
        }
        if (!_fhdPictureDegraded) {
          try {
            final data = await _orientThumb(
                entry, await _session.getFhdPicture(entry.handle));
            await fhdFile.writeAsBytes(data, flush: true);
            _remember(source, 'fhd_$key', fhdPath, data.length);
            await _evictIfNeeded(source);
            return fhdPath;
          } on PtpResponseException {
            _fhdPictureDegraded = true; // 错误应答:本会话不再逐张试
          } on TimeoutException {
            _fhdPictureDegraded = true; // 单事务超时:同上
          }
          // 链路类异常不置降级不拦:下方取数同链,死链自然冒错占位
        }
      }
    }
    // JPG(非 RAW 照片):0x90C4 高清档优先,双键分流见 [_fetchJpg];
    // NEF/视频不试 0x90C4 —— 对 NEF 回 320×212 压缩条带非 JPEG(实测
    // 定案),单个失败还会置会话降级旗标连累 JPG 的高清。
    if (_isJpgObject(entry)) {
      try {
        return await _fetchJpg(entry, source, key, dir);
      } catch (e) {
        _logFetchError(entry, source, e);
        rethrow;
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
      // 信箱黑边裁剪:相机内嵌缩略(HIF/NEF/视频均会)把画面信箱化进
      // 固定画布,cover 裁不掉图内黑边;静照无黑边时裁剪自回 null;
      // 暗场景由内容占比防误裁线兜底。
      data = await trimLetterboxJpeg(data) ?? data;
    } catch (e) {
      _logFetchError(entry, source, e);
      rethrow;
    }
    await file.writeAsBytes(data, flush: true);
    _remember(source, key, path, data.length);
    await _evictIfNeeded(source);
    return path;
  }

  /// 真机诊断辅助:缩略图拉取失败的原因进 hilog(不改变行为,异常
  /// 原样上抛,UI 显示占位)。
  void _logFetchError(ObjectEntry entry, ThumbSource source, Object e) {
    AppLog.w(AppLog.browser, '缩略图 $source ${entry.name}'
        '(0x${entry.handle.toRadixString(16)}) 失败: $e');
  }

  /// JPG 取数(网格档与大图预览小图席位共用):Nikon 0x90C4 高清缩略
  /// (~1024px)优先,失败(错误应答/非 SOI/超时)回落标准 GetThumb
  /// (0x100A,Zf 160×120)。会话级降级在 [PtpSession]:首个失败即置
  /// 旗标,本会话后续 JPG 直走小图不逐张浪费 RTT。
  ///
  /// 缓存键分尺寸档:高清 = `lt_<内容键>`、小图 = `<内容键>`(旧制)—
  /// 旧版小图缓存不挡高清重取;降级会话的小图也不冒充高清档,来日
  /// 支持的会话照常升级(「能拿到高清就高清」跨会话成立)。
  Future<String> _fetchJpg(
      ObjectEntry entry, ThumbSource source, String key, String dir) async {
    // ① 高清档:磁盘命中(前会话产物)即用 —— 内容键做主,与相机无关
    final ltKey = 'lt_$key';
    final ltPath = '$dir/$ltKey.jpg';
    final ltFile = File(ltPath);
    if (await ltFile.exists()) {
      _remember(source, ltKey, ltPath, await ltFile.length());
      await _evictIfNeeded(source);
      return ltPath;
    }
    // ② 未降级:试 0x90C4(已降级时 session 层也会秒拒,这里直查免
    //    一次异常开销)
    if (!_session.largeThumbDegraded) {
      try {
        final data = await _orientThumb(
            entry, await _session.getLargeThumb(entry.handle, force: true));
        await ltFile.writeAsBytes(data, flush: true);
        _remember(source, ltKey, ltPath, data.length);
        await _evictIfNeeded(source);
        // 高清档就位,同键旧小图档成了不进 LRU 账的孤儿档:顺手清掉
        // (出表出账走 [_forget])
        _forget(source, key);
        try {
          await File('$dir/$key.jpg').delete();
        } on FileSystemException {
          // 本无此档/删失败:不挡
        }
        return ltPath;
      } on UnsupportedError {
        // 码表不在册 / 非 SOI 载荷 / 本会话已降级:回落小图
      } on PtpResponseException {
        // 相机拒绝:回落小图
      } on TimeoutException {
        // USB 单事务超时(链路未毒化):回落小图
      } on PtpLinkException {
        // PTP-IP 看门狗超时/断链:回落小图(链已死时 getThumb 同败,
        // 占位由上层兜)
      }
    }
    // ③ 小图档:磁盘命中(旧版/降级会话缓存)即用,键保持旧制
    final path = '$dir/$key.jpg';
    final file = File(path);
    if (await file.exists()) {
      _remember(source, key, path, await file.length());
      await _evictIfNeeded(source);
      return path;
    }
    final data =
        await _orientThumb(entry, await _session.getThumb(entry.handle));
    await file.writeAsBytes(data, flush: true);
    _remember(source, key, path, data.length);
    await _evictIfNeeded(source);
    return path;
  }

  /// JPG 对象判定(0x90C4 高清缩略的目标):照片类且非 RAW(NEF/NRW
  /// 的 0x90C4 是压缩条带);格式码已知时仅认 JPEG 族(0x3801/0x3808)
  /// —— 单个怪对象失败会拖垮整会话降级旗标,不值得为他格式冒险。
  static bool _isJpgObject(ObjectEntry entry) {
    if (entry.kind != ObjectKind.image || isRawFile(entry)) return false;
    final fmt = entry.formatCode;
    return fmt == null ||
        fmt == ObjectFormatCode.exifJpeg ||
        fmt == ObjectFormatCode.jfif;
  }

  /// 小图末档回退(仅非 JPG 对象会到这里 —— JPG 已分流 [_fetchJpg];
  /// 照片到此处 = FHD 席位失败/会话降级,视频 = 海报):GetThumb 直取
  /// (Zf 160×120,撑满全屏是糊的,高清席位见 [warmPreview])。
  Future<Uint8List> _fetchPreview(ObjectEntry entry) async {
    return _orientThumb(entry, await _session.getThumb(entry.handle));
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
        // (error 级:随 AppLog 崩溃尾巴落盘,意外类最值得留痕)。
        AppLog.e(AppLog.browser, '缩略图 方向头读失败 ${entry.name}: $e');
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

  /// 入表+入账(先摘旧键再插 = 移到最新端;同键覆盖先减旧账再加新)。
  void _remember(ThumbSource source, String key, String path, int bytes) {
    final lru = _lruFor(source);
    final old = lru.remove(key);
    if (old != null) {
      _addBytes(source, -old.bytes);
    }
    lru[key] = (path: path, bytes: bytes);
    _addBytes(source, bytes);
  }

  /// 出表+出账(键不在册则无事)。
  void _forget(ThumbSource source, String key) {
    final old = _lruFor(source).remove(key);
    if (old != null) {
      _addBytes(source, -old.bytes);
    }
  }

  Future<void> _evictIfNeeded(ThumbSource source) async {
    final lru = _lruFor(source);
    final limit =
        source == ThumbSource.grid ? gridLimitBytes : previewLimitBytes;
    // O(1):字节账现成(增减收口见类注),不再全表求和。
    while (_bytesOf(source) > limit && lru.isNotEmpty) {
      final oldestKey = lru.keys.first;
      final oldest = lru.remove(oldestKey)!;
      _addBytes(source, -oldest.bytes);
      try {
        await File(oldest.path).delete();
      } on FileSystemException {
        // 盘上已无此文件:索引与账已清,账实仍相符
      }
    }
  }

  /// 内容键:文件名(去非法字符)+ 字节数。同名同大小的两张照片
  /// 即便存在也字节级几乎不可能同内容,碰撞风险可忽略。
  static String _keyFor(ObjectEntry entry) {
    final safe = entry.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // 键全量升版(v2):黑边裁剪放开到全部缩略(HIF/NEF 预览同样
    // 信箱化),旧未裁剪条目按 miss 重取一次。
    return 'v2_${safe}_${entry.sizeInBytes}';
  }
}

/// 仅测试:[cache] 某档位字节账 + 索引在册条目快照(键 → 在册字节)。
/// 记账测试的对照面 —— 全表重算(旧版每次驱逐前的逐条求和)对着
/// 增量账断言「账实相符」。顶层函数而非实例成员:测试替身对
/// [ThumbnailCache] 是 implements(仅 pathFor/reset),加实例成员会破
/// 它们;同库可及私有字段。生产不可达。
@visibleForTesting
({int account, Map<String, int> entries}) debugLruAccount(
    ThumbnailCache cache, ThumbSource source) {
  final lru = cache._lruFor(source);
  return (
    account: cache._bytesOf(source),
    entries: {for (final e in lru.entries) e.key: e.value.bytes},
  );
}

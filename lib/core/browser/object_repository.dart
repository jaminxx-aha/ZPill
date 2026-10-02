/// 对象仓库:GetObjectHandles → GetObjectInfo 组合(TODO.md §三 P1)。
library;

import 'dart:async';
import 'dart:math' as math;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
import '../ptp/ptp_session.dart';
import 'album.dart';
import 'object_entry.dart';

/// 一次增量发布:渐进枚举期间每块完成时广播,末尾一次 [complete] 事件
/// (空相机 / 断点续传零缺口也至少有一次完成事件,订阅方有确定终态)。
final class AlbumsUpdate {
  const AlbumsUpdate({
    required this.albums,
    required this.loaded,
    required this.total,
    required this.complete,
  });

  /// 截至本次发布的相册快照(每块全量重建,不可变)。
  final List<CameraAlbum> albums;

  /// 已处理的对象数(含相机明确拒答而跳过的)。
  final int loaded;

  /// GetObjectHandles 得到的对象总数。
  final int total;

  /// 枚举是否全部完成。
  final bool complete;
}

abstract interface class ObjectRepository {
  /// 相册枚举(渐进):GetObjectHandles 后分块取 ObjectInfo,每块合并入
  /// 缓存并广播到 [updates];本 Future 在**全部块完成**时给出最终快照
  /// (失败则抛出,部分结果已通过 [updates] 发布)。
  /// 并发调用共享同一次枚举(_loading 去重),各订阅者仍能收到全部块。
  Future<List<CameraAlbum>> loadAlbums();

  /// 增量发布流(broadcast):枚举期间的每个块一次;无订阅者时静默。
  Stream<AlbumsUpdate> get updates;

  Future<ObjectEntry> entryFor(int handle);

  /// 丢弃缓存并废弃在途枚举(世代计数);断连/手动刷新用。
  void reset();

  /// PtpObjectInfo → ObjectEntry(解析 PTP 日期串、格式码分类、扩展名兜底)。
  static ObjectEntry toEntry(PtpObjectInfo info) {
    var kind = kindForFormatCode(info.objectFormat);
    if (kind == ObjectKind.other) {
      // NEF 的格式码就是 0x3000(真机实测),必须按扩展名二次兜底。
      kind = kindForFilename(info.filename);
    }
    return ObjectEntry(
      handle: info.handle,
      name: info.filename,
      sizeInBytes: info.compressedSize,
      kind: kind,
      parentHandle: info.parentHandle ?? 0,
      capturedAt: _parsePtpDate(info.captureDate),
      formatCode: info.objectFormat,
    );
  }

  /// PTP 日期串 `YYYYMMDDThhmmss.s`(UTC)→ DateTime;解析失败返回 null。
  static DateTime? _parsePtpDate(String? raw) {
    if (raw == null || raw.length < 15) return null;
    final y = int.tryParse(raw.substring(0, 4));
    final mo = int.tryParse(raw.substring(4, 6));
    final d = int.tryParse(raw.substring(6, 8));
    final h = int.tryParse(raw.substring(9, 11));
    final mi = int.tryParse(raw.substring(11, 13));
    final s = int.tryParse(raw.substring(13, 15));
    if (y == null || mo == null || d == null || h == null || mi == null || s == null) {
      return null;
    }
    return DateTime.utc(y, mo, d, h, mi, s);
  }
}

/// 基于 [PtpSession] 的实现:GetObjectHandles 一次全量,然后**分块**逐个
/// GetObjectInfo,每块完成即合并入缓存并广播 —— UI 渐进显示最新照片,
/// 其余对象后台同步,不再全屏阻塞等全部 N+1 次往返。
///
/// 填充顺序:句柄倒序(尼康句柄升序 ≈ 拍摄顺序,最新照片低延迟亮相;
/// probe --objmeta 相关性结论若证伪则删反转 —— 只影响出现先后,不影响
/// 最终排序)。Nikon 0x9434 GetObjectsMetaData 批量快路留后续(探针先行)。
///
/// Zf 真机语义(2026-09-27 实测):parent=0 才是全量枚举(602 个对象,
/// 0xFFFFFFFF 只回根层),故全量走 [GetObjectHandlesParams.parentRoot]。
///
/// 断点续传:中途失败部分结果保留在缓存,重试只补缺失对象。缓存失效:
/// 会话关闭/重连后必须 [reset](AppServices 订阅连接状态驱动),否则句柄
/// 可能已过期。
final class ObjectRepositoryImpl implements ObjectRepository {
  ObjectRepositoryImpl({required this.session, this.chunkSize = 24});

  final PtpSession session;

  /// 分块大小:每块结束广播一次(602 对象 ≈ 25 次刷新);真机节奏实测后可调。
  final int chunkSize;

  final StreamController<AlbumsUpdate> _updatesCtrl =
      StreamController<AlbumsUpdate>.broadcast(sync: true);

  @override
  Stream<AlbumsUpdate> get updates => _updatesCtrl.stream;

  Map<int, ObjectEntry> _byHandle = <int, ObjectEntry>{};
  bool _loaded = false;

  /// 枚举中标志:并发 loadAlbums/entryFor 共享同一次枚举。
  Future<void>? _loading;

  /// 缓存世代:reset() 递增;在途枚举发现世代不符即停,不再写缓存/发布。
  int _generation = 0;

  /// 缓存是否已建立(全量枚举完成)。
  bool get isLoaded => _loaded;

  @override
  Future<List<CameraAlbum>> loadAlbums() async {
    await _ensureLoaded();
    return _buildAlbums();
  }

  @override
  Future<ObjectEntry> entryFor(int handle) async {
    await _ensureLoaded();
    final entry = _byHandle[handle];
    if (entry == null) {
      throw StateError('对象 0x${handle.toRadixString(16)} 不在缓存(会话已重置?)');
    }
    return entry;
  }

  /// 丢弃缓存(断开/失败后由连接状态监听调用;重连后首次加载重枚举)。
  @override
  void reset() {
    _generation++;
    _byHandle = <int, ObjectEntry>{};
    _loaded = false;
    _loading = null; // 在途枚举由世代计数废弃;新调用立即开新一轮
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    final pending = _loading;
    if (pending != null) return pending;
    final load = _loadAll();
    _loading = load;
    // 失败也要清标志,下次调用重试;reset 已换新 _loading 时不覆盖。
    return load.whenComplete(() {
      if (identical(_loading, load)) {
        _loading = null;
      }
    });
  }

  /// 全量枚举(渐进):GetObjectHandles(Zf 语义 parent=0)→ 句柄倒序 →
  /// 跳过已缓存(断点续传)→ 分块逐个 GetObjectInfo,每块合并入缓存并
  /// 广播到 [updates]。
  Future<void> _loadAll() async {
    final generation = _generation;
    // Zf 把 0 与 0xFFFFFFFF 的语义做反了:parent 必须传 0 才是全量。
    final handles = await session.getObjectHandles();
    // 最新优先(2026-10-02 Zf 实测):GetObjectHandles 线序 =
    // [文件夹][slot-1 照片升序][slot-2 照片升序],槽内句柄升序=拍摄顺序
    // (双槽各对拍 40 条验证)。倒序让最新照片在首个块亮相,文件夹对象
    // 最后到(_publish 的 dropUnnamedFolders 依赖此点)。
    final ordered = handles.reversed.toList(growable: false);
    // 同会话内已删除的对象清出缓存防幽灵;已缓存对象跳过(断点续传)。
    final handleSet = handles.toSet();
    _byHandle.removeWhere((h, _) => !handleSet.contains(h));
    final pending = [
      for (final h in ordered)
        if (!_byHandle.containsKey(h)) h,
    ];
    var loaded = ordered.length - pending.length;
    var consecutiveFailures = 0;
    for (var start = 0; start < pending.length; start += chunkSize) {
      final end = math.min(start + chunkSize, pending.length);
      for (var i = start; i < end; i++) {
        final handle = pending[i];
        final PtpObjectInfo info;
        try {
          info = await session.getObjectInfo(handle);
        } on PtpResponseException {
          // 相机明确拒答单个对象(如同刻被删):跳过继续;连续 3 个失败
          // 视为会话级拒绝,上抛终止本轮(防空转数百次)。传输层/看门狗
          // 异常不经此捕获,直接终止。
          consecutiveFailures++;
          if (consecutiveFailures >= 3) rethrow;
          loaded++;
          continue;
        }
        consecutiveFailures = 0;
        if (generation != _generation) return; // 每个 await 后、写缓存前
        _byHandle[handle] = ObjectRepository.toEntry(info);
        loaded++;
      }
      if (generation != _generation) return;
      _publish(loaded, ordered.length, complete: false);
    }
    if (generation != _generation) return;
    _loaded = true;
    // 完成事件兜底:空相机 / 续传零缺口(块循环没跑)也要有确定终态。
    _publish(loaded, ordered.length, complete: true);
  }

  /// 广播一次增量快照;未完成发布丢弃未具名文件夹相册(见 _buildAlbums)。
  void _publish(int loaded, int total, {required bool complete}) {
    _updatesCtrl.add(AlbumsUpdate(
      albums: _buildAlbums(dropUnnamedFolders: !complete),
      loaded: loaded,
      total: total,
      complete: complete,
    ));
  }

  /// 派生相册:汇总 + 按文件夹分组(仅 image/video 计入)。
  ///
  /// [dropUnnamedFolders]:渐进期间文件夹对象(低句柄,倒序后最后取)可能
  /// 尚未到达 —— true 时这些相册暂不亮相,避免「文件夹 0x11」先占位再
  /// 改名的闪变;最终发布与 [loadAlbums] 返回值用默认 false(兜底名,
  /// 防文件夹对象真缺失时丢相册)。
  List<CameraAlbum> _buildAlbums({bool dropUnnamedFolders = false}) {
    final all = <ObjectEntry>[];
    final byFolder = <int, List<ObjectEntry>>{};
    for (final entry in _byHandle.values) {
      if (entry.isFolder) continue;
      if (entry.kind != ObjectKind.image && entry.kind != ObjectKind.video) {
        continue;
      }
      all.add(entry);
      byFolder.putIfAbsent(entry.parentHandle, () => []).add(entry);
    }
    all.sort(compareEntries);

    final folderAlbums = <CameraAlbum>[];
    byFolder.forEach((folderHandle, items) {
      items.sort(compareEntries);
      final folder = _byHandle[folderHandle];
      if (folder == null && dropUnnamedFolders) return;
      folderAlbums.add(CameraAlbum(
        name: folder?.name ?? '文件夹 0x${folderHandle.toRadixString(16)}',
        folderHandle: folderHandle,
        items: List.unmodifiable(items),
      ));
    });
    // 文件夹相册按最新拍摄时间倒序(与相册内照片排序一致),再按名稳定兜底。
    folderAlbums.sort((a, b) {
      final at = a.newestAt;
      final bt = b.newestAt;
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if ((at == null) != (bt == null)) return at == null ? 1 : -1;
      return a.name.compareTo(b.name);
    });

    return [CameraAlbum.allPhotos(all), ...folderAlbums];
  }

  /// 同层排序:文件夹在前,照片按拍摄时间倒序(新的在前),无时间按名。
  static int compareEntries(ObjectEntry a, ObjectEntry b) {
    if (a.isFolder != b.isFolder) {
      return a.isFolder ? -1 : 1;
    }
    final at = a.capturedAt;
    final bt = b.capturedAt;
    if (at != null && bt != null && at != bt) {
      return bt.compareTo(at);
    }
    if ((at == null) != (bt == null)) {
      return at == null ? 1 : -1;
    }
    return a.name.compareTo(b.name);
  }
}

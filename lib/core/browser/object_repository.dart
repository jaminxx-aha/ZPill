/// 对象仓库:GetObjectHandles → GetObjectInfo 组合(TODO.md §三 P1)。
library;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
import '../ptp/ptp_session.dart';
import 'album.dart';
import 'object_entry.dart';

abstract interface class ObjectRepository {
  /// 相册列表:汇总「全部照片」+ 各文件夹相册(直接含 image/video 的
  /// 文件夹;MISC 等非照片目录自然消失)。
  ///
  /// 首次调用触发全量枚举(N+1 次 GetObjectInfo,约数秒),
  /// [onProgress] 回调枚举进度(loaded/total,UI 显示「枚举 x/N」)。
  Future<List<CameraAlbum>> loadAlbums({
    void Function(int loaded, int total)? onProgress,
  });

  Future<ObjectEntry> entryFor(int handle);

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

/// 基于 [PtpSession] 的实现:一次 GetObjectHandles 全量 + 逐个 GetObjectInfo,
/// 内存建 handle 索引与 parent 分组,loadAlbums 只查缓存。
///
/// Zf 真机语义(2026-09-27 实测):parent=0 才是全量枚举(602 个对象,
/// 0xFFFFFFFF 只回根层),故全量走 [GetObjectHandlesParams.parentRoot]。
/// 代价:首次 ~602 次往返(数秒);Nikon 0x9434 GetObjectsMetaData
/// 批量优化留后续。
///
/// 缓存失效:会话关闭/重连后必须 [reset](AppServices 订阅连接状态驱动),
/// 否则句柄可能已过期。
final class ObjectRepositoryImpl implements ObjectRepository {
  ObjectRepositoryImpl({required this.session});

  final PtpSession session;

  Map<int, ObjectEntry> _byHandle = const {};
  bool _loaded = false;

  /// 枚举中标志:并发 loadAlbums/entryFor 共享同一次枚举。
  Future<void>? _loading;

  /// 缓存世代:reset() 递增;在途枚举完成时世代不符则丢弃结果。
  int _generation = 0;

  /// 缓存是否已建立(全量枚举完成)。
  bool get isLoaded => _loaded;

  @override
  Future<List<CameraAlbum>> loadAlbums({
    void Function(int loaded, int total)? onProgress,
  }) async {
    await _ensureLoaded(onProgress: onProgress);
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
  void reset() {
    _generation++;
    _byHandle = const {};
    _loaded = false;
    _loading = null; // 在途枚举由世代计数废弃;新调用立即开新一轮
  }

  Future<void> _ensureLoaded({void Function(int, int)? onProgress}) {
    if (_loaded) return Future.value();
    final pending = _loading;
    if (pending != null) return pending;
    final load = _loadAll(onProgress: onProgress);
    _loading = load;
    // 失败也要清标志,下次调用重试;reset 已换新 _loading 时不覆盖。
    return load.whenComplete(() {
      if (identical(_loading, load)) {
        _loading = null;
      }
    });
  }

  /// 全量枚举:GetObjectHandles(Zf 语义 parent=0)→ 逐个 GetObjectInfo →
  /// 建 handle 索引。
  Future<void> _loadAll({void Function(int, int)? onProgress}) async {
    final generation = _generation;
    // Zf 把 0 与 0xFFFFFFFF 的语义做反了:parent 必须传 0 才是全量。
    final handles = await session.getObjectHandles();
    final byHandle = <int, ObjectEntry>{};
    var loaded = 0;
    for (final handle in handles) {
      final info = await session.getObjectInfo(handle);
      byHandle[handle] = ObjectRepository.toEntry(info);
      loaded++;
      onProgress?.call(loaded, handles.length);
    }
    if (generation != _generation) {
      return; // 枚举途中被 reset(断连):丢弃过期结果
    }
    _byHandle = byHandle;
    _loaded = true;
  }

  /// 派生相册:汇总 + 按文件夹分组(仅 image/video 计入)。
  List<CameraAlbum> _buildAlbums() {
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

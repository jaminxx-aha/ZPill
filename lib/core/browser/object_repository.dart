/// 对象仓库:GetObjectHandles → GetObjectInfo 组合(TODO.md §三 P1)。
library;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
import '../ptp/ptp_session.dart';
import 'object_entry.dart';

abstract interface class ObjectRepository {
  /// 列出某文件夹下的对象;[parentHandle] 为 0 时列根目录。
  /// PTP 没有真实目录树:文件夹即 Association 对象,靠 parentHandle 分层。
  Future<List<ObjectEntry>> listFolder({int parentHandle = 0});

  Future<ObjectEntry> entryFor(int handle);

  /// P2: GetThumb(0x100A) → 落本地缓存文件,交由 UI 层图片组件加载。
  /// TODO(P2): 缓存目录、LRU 上限与 Coil 等价加载策略。
  Future<String> thumbPathFor(int handle);

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
/// 内存建 parent→children 树,listFolder 只查缓存。
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
  Map<int, List<ObjectEntry>> _children = const {};
  bool _loaded = false;

  /// 缓存是否已建立(全量枚举完成)。
  bool get isLoaded => _loaded;

  @override
  Future<List<ObjectEntry>> listFolder({int parentHandle = 0}) async {
    if (!_loaded) {
      await _loadAll();
    }
    return List.of(_children[parentHandle] ?? const []);
  }

  @override
  Future<ObjectEntry> entryFor(int handle) async {
    if (!_loaded) {
      await _loadAll();
    }
    final entry = _byHandle[handle];
    if (entry == null) {
      throw StateError('对象 0x${handle.toRadixString(16)} 不在缓存(会话已重置?)');
    }
    return entry;
  }

  @override
  Future<String> thumbPathFor(int handle) => throw UnimplementedError(); // P2

  /// 丢弃缓存(断开/失败后由连接状态监听调用;重连后首次 listFolder 重枚举)。
  void reset() {
    _byHandle = const {};
    _children = const {};
    _loaded = false;
  }

  /// 全量枚举:GetObjectHandles(Zf 语义 parent=0)→ 逐个 GetObjectInfo →
  /// 建 parent→children 树 + handle 索引。
  Future<void> _loadAll() async {
    // Zf 把 0 与 0xFFFFFFFF 的语义做反了:parent 必须传 0 才是全量。
    final handles = await session.getObjectHandles();
    final byHandle = <int, ObjectEntry>{};
    final children = <int, List<ObjectEntry>>{};
    for (final handle in handles) {
      final info = await session.getObjectInfo(handle);
      final entry = ObjectRepository.toEntry(info);
      byHandle[handle] = entry;
      children.putIfAbsent(info.parentHandle ?? 0, () => []).add(entry);
    }
    for (final list in children.values) {
      list.sort(compareEntries);
    }
    _byHandle = byHandle;
    _children = children;
    _loaded = true;
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

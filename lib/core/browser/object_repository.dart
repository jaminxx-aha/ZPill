/// 对象仓库:GetObjectHandles → GetObjectInfo 组合(TODO.md §三 P1)。
library;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
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
    final kind = kindForFormatCode(info.objectFormat);
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

/// TODO(P1): 基于 PtpIpSession 的实现(列表 + 详情组合,含进度上报)。
final class ObjectRepositoryImpl implements ObjectRepository {
  @override
  Future<List<ObjectEntry>> listFolder({int parentHandle = 0}) =>
      throw UnimplementedError();

  @override
  Future<ObjectEntry> entryFor(int handle) => throw UnimplementedError();

  @override
  Future<String> thumbPathFor(int handle) => throw UnimplementedError();
}

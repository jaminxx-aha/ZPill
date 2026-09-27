/// 浏览层对象模型:GetObjectHandles + GetObjectInfo 的组合结果。
library;

import '../ptpip/object_format.dart';

final class ObjectEntry {
  const ObjectEntry({
    required this.handle,
    required this.name,
    required this.sizeInBytes,
    required this.kind,
    this.capturedAt,
    this.formatCode,
  });

  /// 只能来自 GetObjectHandles 响应(TODO 注意事项 2)。
  final int handle;
  final String name;
  final int sizeInBytes;
  final ObjectKind kind;
  final DateTime? capturedAt;
  final int? formatCode;

  bool get isFolder => kind == ObjectKind.folder;

  ObjectEntry copyWith({DateTime? capturedAt}) => ObjectEntry(
        handle: handle,
        name: name,
        sizeInBytes: sizeInBytes,
        kind: kind,
        capturedAt: capturedAt ?? this.capturedAt,
        formatCode: formatCode,
      );
}

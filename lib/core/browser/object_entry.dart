/// 浏览层对象模型:GetObjectHandles + GetObjectInfo 的组合结果。
library;

import '../ptpip/object_format.dart';

final class ObjectEntry {
  const ObjectEntry({
    required this.handle,
    required this.name,
    required this.sizeInBytes,
    required this.kind,
    this.parentHandle = 0,
    this.capturedAt,
    this.formatCode,
    this.protectionStatus = 0,
  });

  /// 只能来自 GetObjectHandles 响应(TODO 注意事项 2)。
  final int handle;
  final String name;
  final int sizeInBytes;
  final ObjectKind kind;

  /// 所属文件夹(Association 对象)的 handle;0 = 根层。
  /// 相册按文件夹分组、批量下载文件名消歧都靠它。
  final int parentHandle;

  final DateTime? capturedAt;
  final int? formatCode;

  /// ProtectionStatus(ObjectInfo 定长头 @6,u16):0 = 无保护/1 = 只读。
  /// 相册列表的真值来源(重列即新);查看器保护态 = 会话乐观 Map 优先、
  /// 此字段兜底(2026-10-16 接线)。
  final int protectionStatus;

  bool get isFolder => kind == ObjectKind.folder;
  bool get isProtected => protectionStatus == 1;

  ObjectEntry copyWith({DateTime? capturedAt}) => ObjectEntry(
        handle: handle,
        name: name,
        sizeInBytes: sizeInBytes,
        kind: kind,
        parentHandle: parentHandle,
        capturedAt: capturedAt ?? this.capturedAt,
        formatCode: formatCode,
      );
}

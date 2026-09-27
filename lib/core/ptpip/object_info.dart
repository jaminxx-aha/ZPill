/// GetObjectInfo(0x1008)返回的 ObjectInfo 数据集(ISO 15740)。
///
/// 浏览列表的文件名 / 大小 / 拍摄日期全部来自这里(TODO.md §一),
/// 禁止从文件路径推导任何字段。
library;

/// 协议层原始 ObjectInfo;日期解析、分类等 UI 语义在 browser 层完成。
final class PtpObjectInfo {
  const PtpObjectInfo({
    required this.handle,
    required this.storageId,
    required this.objectFormat,
    required this.compressedSize,
    required this.filename,
    this.captureDate,
    this.parentHandle,
  });

  /// 必须来自 GetObjectHandles 响应(TODO 注意事项 2)。
  final int handle;
  final int storageId;
  final int objectFormat;
  final int compressedSize;
  final String filename;

  /// PTP 日期串,形如 `YYYYMMDDThhmmss.s`(UTC);解析见 browser 层。
  final String? captureDate;

  /// 所属文件夹(Association 对象)的 handle;根目录为 0。
  final int? parentHandle;

  // TODO(P0): 完整数据集字段(缩略图格式/尺寸、保护状态等)按需补充,
  // 字段布局以规范 + tools/ptpip_probe 真机抓包为准。
}

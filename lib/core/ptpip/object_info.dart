/// GetObjectInfo(0x1008)返回的 ObjectInfo 数据集(ISO 15740)。
///
/// 浏览列表的文件名 / 大小 / 拍摄日期全部来自这里(TODO.md §一),
/// 禁止从文件路径推导任何字段。
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';

/// 协议层原始 ObjectInfo;日期解析、分类等 UI 语义在 browser 层完成。
final class PtpObjectInfo {
  const PtpObjectInfo({
    required this.handle,
    required this.storageId,
    required this.objectFormat,
    required this.compressedSize,
    required this.filename,
    this.captureDate,
    this.modificationDate,
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

  /// 修改时刻(ISO 15740 ObjectInfo 末串):个别对象 CaptureDate 缺失时
  /// 作拍摄时刻的回落(相机文件拍后不改,两者实际同值)。
  final String? modificationDate;

  /// 所属文件夹(Association 对象)的 handle;根目录为 0。
  final int? parentHandle;

  /// 解析 ObjectInfo 数据集(PTP-IP 与 PTP/USB 同构)。
  ///
  /// 定长头 52 字节,布局按 ISO 15740 并经 Zf 真机校验
  /// (tools/usb_probe dump_object_info 同一结构):
  /// storageId u32 / objectFormat u16 / protection u16 / size u32 /
  /// thumbFormat u16 / thumbSize u32 / thumbW u32 / thumbH u32 /
  /// imageW u32 / imageH u32 / bitDepth u32 / **parentObject u32** /
  /// assocType u16 / assocDesc u32 / sequence u32,随后
  /// filename STRING / captureDate STRING / modificationDate STRING。
  static PtpObjectInfo parse({required int handle, required Uint8List dataset}) {
    final r = ByteReader(dataset);
    final storageId = r.u32();
    final objectFormat = r.u16();
    r.u16(); // ProtectionStatus
    final compressedSize = r.u32();
    r.u16(); // ThumbFormat
    r.u32(); // ThumbCompressedSize
    r.u32(); // ThumbPixWidth
    r.u32(); // ThumbPixHeight
    r.u32(); // ImagePixWidth
    r.u32(); // ImagePixHeight
    r.u32(); // ImageBitDepth
    final parentHandle = r.u32();
    r.u16(); // AssociationType
    r.u32(); // AssociationDesc
    r.u32(); // SequenceNumber
    final filename = r.ptpString() ?? '';
    final captureDate = r.ptpString();
    // 末串 ModificationDate:真机应答都带,但个别对象可能截断;ByteReader
    // 无越界保护,读前判 eof 兜底(空串语义与 captureDate 的 0xFF 相同)。
    final modificationDate = r.eof ? null : r.ptpString();
    return PtpObjectInfo(
      handle: handle,
      storageId: storageId,
      objectFormat: objectFormat,
      compressedSize: compressedSize,
      filename: filename,
      captureDate: captureDate,
      modificationDate: modificationDate,
      parentHandle: parentHandle,
    );
  }

  // TODO(P0): 完整数据集字段(缩略图格式/尺寸、保护状态等)按需补充,
  // 字段布局以规范 + tools/ptpip_probe 真机抓包为准。
}

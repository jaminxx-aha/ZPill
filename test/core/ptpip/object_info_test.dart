import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptpip/object_info.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

/// 数据集手搓(布局独立于被测代码,字段排布按 ISO 15740 §13.3 与
/// probe dump_object_info 的 Zf 真机结构):52 字节定长头 + 三个 STRING
/// (filename / captureDate / modificationDate)。
Uint8List buildDataset() {
  final w = ByteWriter()
    ..u32(0x00010001) // StorageID(Slot 1)
    ..u16(0x3801) // ObjectFormat = EXIF/JPEG
    ..u16(0x0000) // ProtectionStatus
    ..u32(8400000) // CompressedSize
    ..u16(0x3801) // ThumbFormat
    ..u32(50000) // ThumbCompressedSize
    ..u32(640) // ThumbPixWidth
    ..u32(424) // ThumbPixHeight
    ..u32(3968) // ImagePixWidth
    ..u32(2624) // ImagePixHeight
    ..u32(24) // ImageBitDepth
    ..u32(0x00000064) // ParentObject(所属文件夹 handle)
    ..u16(0x0000) // AssociationType
    ..u32(0) // AssociationDesc
    ..u32(0); // SequenceNumber
  // filename:Zf 真机带结尾 NUL,解析必须剥掉(否则扩展名判断失效)
  w
    ..u8('DSC_1234.JPG'.length + 1)
    ..utf16le('DSC_1234.JPG')
    ..u16(0);
  // captureDate:PTP 日期串,不带 NUL 的形态也一并覆盖
  w
    ..u8(15)
    ..utf16le('20260927T101520');
  return w.takeBytes();
}

void main() {
  test('ObjectInfo 数据集:52 字节头 + STRING,字段逐一对位', () {
    final info = PtpObjectInfo.parse(handle: 0x11, dataset: buildDataset());
    expect(info.handle, 0x11);
    expect(info.storageId, 0x00010001);
    expect(info.objectFormat, 0x3801);
    expect(info.compressedSize, 8400000);
    expect(info.parentHandle, 0x00000064);
    expect(info.filename, 'DSC_1234.JPG'); // NUL 已剥
    expect(info.captureDate, '20260927T101520');
  });

  test('父目录在头部偏移 38:篡改父 handle 不影响其他字段', () {
    final bytes = buildDataset();
    // parentObject 位于偏移 38(u32):改成 0x000000C8
    ByteData.sublistView(bytes).setUint32(38, 0xC8, Endian.little);
    final info = PtpObjectInfo.parse(handle: 2, dataset: bytes);
    expect(info.parentHandle, 0xC8);
    expect(info.filename, 'DSC_1234.JPG');
    expect(info.captureDate, '20260927T101520');
  });

  test('末串 ModificationDate:完整数据集解析出;截断在 captureDate 后则容错为 null', () {
    // 完整数据集:在 buildDataset 尾部补上第三个 STRING。
    final w = ByteWriter()
      ..u8(15)
      ..utf16le('20260927T101523');
    final withMod = Uint8List.fromList([...buildDataset(), ...w.takeBytes()]);
    final info = PtpObjectInfo.parse(handle: 3, dataset: withMod);
    expect(info.captureDate, '20260927T101520');
    expect(info.modificationDate, '20260927T101523');

    // 截断数据集(captureDate 后戛然而止):不抛越界,modificationDate 为 null。
    final truncated = PtpObjectInfo.parse(handle: 4, dataset: buildDataset());
    expect(truncated.captureDate, '20260927T101520');
    expect(truncated.modificationDate, isNull);
  });
}

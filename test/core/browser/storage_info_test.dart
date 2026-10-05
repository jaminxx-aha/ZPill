import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/storage_info.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

/// 手搓 GetStorageInfo 数据集(ISO 15740 §13.5 布局)。
Uint8List _storageDataset({
  int storageType = 0x0004,
  int maxCapacity = 64 * 1024 * 1024 * 1024,
  int freeBytes = 21 * 1024 * 1024 * 1024,
  int freeImages = 480,
  String? description = 'Slot 1',
  String? volumeLabel = 'NIKON CFexpress',
}) {
  final w = ByteWriter()
    ..u16(storageType)
    ..u16(0x0002) // filesystemType: generic flat
    ..u16(0x0000) // accessCapability: read-write
    ..u64(maxCapacity)
    ..u64(freeBytes)
    ..u32(freeImages);
  _ptpString(w, description);
  _ptpString(w, volumeLabel);
  return w.takeBytes();
}

void _ptpString(ByteWriter w, String? s) {
  if (s == null) {
    w.u8(0xFF);
    return;
  }
  w.u8(s.length + 1);
  w.utf16le(s);
  w.u16(0); // 结尾 NUL(Zf 真机形态)
}

void main() {
  test('完整数据集解析:字段齐全,字符串剥 NUL', () {
    final storage = CameraStorage.parse(
        id: 0x00010001, dataset: _storageDataset());
    expect(storage.id, 0x00010001);
    expect(storage.storageType, 0x0004);
    expect(storage.isRemovable, isTrue);
    expect(storage.maxCapacityBytes, 64 * 1024 * 1024 * 1024);
    expect(storage.freeSpaceBytes, 21 * 1024 * 1024 * 1024);
    expect(storage.freeSpaceImages, 480);
    expect(storage.description, 'Slot 1');
    expect(storage.volumeLabel, 'NIKON CFexpress');
    expect(storage.label, 'Slot 1');
    expect(storage.freeRatio, closeTo(21 / 64, 0.001));
  });

  test('字符串未提供(0xFF):展示名回落卷标/序号', () {
    final noDesc = CameraStorage.parse(
        id: 0x00020001,
        dataset: _storageDataset(description: null));
    expect(noDesc.description, isNull);
    expect(noDesc.label, 'NIKON CFexpress');

    final neither = CameraStorage.parse(
        id: 0x00020001,
        dataset: _storageDataset(description: null, volumeLabel: null));
    expect(neither.label, '存储 0x20001');
  });

  test('容量未上报(0):freeRatio null,界面不画进度条', () {
    final storage = CameraStorage.parse(
        id: 1, dataset: _storageDataset(maxCapacity: 0, freeBytes: 0));
    expect(storage.freeRatio, isNull);
  });

  test('剩余超总容量(相机口径怪异):钳制为 1', () {
    final storage = CameraStorage.parse(
        id: 1, dataset: _storageDataset(maxCapacity: 1000, freeBytes: 4000));
    expect(storage.freeRatio, 1);
  });
}

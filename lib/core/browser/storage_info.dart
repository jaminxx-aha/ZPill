/// 相机存储槽信息:GetStorageInfo(0x1005)数据集解析(TODO §三
/// 存储空间管理:双卡槽余量展示)。
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';

/// ISO 15740 StorageType 码。
abstract final class PtpStorageType {
  static const int undefined = 0x0000;
  static const int fixedRom = 0x0001;
  static const int removableRom = 0x0002;
  static const int fixedRam = 0x0003;
  static const int removableRam = 0x0004; // 存储卡(双卡槽即两个)
}

final class CameraStorage {
  const CameraStorage({
    required this.id,
    required this.storageType,
    required this.filesystemType,
    required this.accessCapability,
    required this.maxCapacityBytes,
    required this.freeSpaceBytes,
    required this.freeSpaceImages,
    this.description,
    this.volumeLabel,
  });

  /// 解析 GetStorageInfo 数据集(ISO 15740 §13.5):
  /// u16 storageType + u16 filesystemType + u16 accessCapability +
  /// u64 maxCapacity + u64 freeSpaceInBytes + u32 freeSpaceInImages +
  /// STRING description + STRING volumeLabel。
  /// 截断/越界读由 ByteReader 的 RangeError 上抛(调用方按不支持处理)。
  factory CameraStorage.parse({required int id, required Uint8List dataset}) {
    final r = ByteReader(dataset);
    return CameraStorage(
      id: id,
      storageType: r.u16(),
      filesystemType: r.u16(),
      accessCapability: r.u16(),
      maxCapacityBytes: r.u64(),
      freeSpaceBytes: r.u64(),
      freeSpaceImages: r.u32(),
      description: r.ptpString(),
      volumeLabel: r.ptpString(),
    );
  }

  final int id;

  /// [PtpStorageType] 码;存储卡 = removableRam。
  final int storageType;
  final int filesystemType;
  final int accessCapability;

  /// 卡总容量 / 剩余字节(u64;0 = 相机未上报,如卡未插)。
  final int maxCapacityBytes;
  final int freeSpaceBytes;
  final int freeSpaceImages;

  /// 相机侧描述(如 "Slot 1" / 卡卷标);null = 未提供。
  final String? description;
  final String? volumeLabel;

  bool get isRemovable => storageType == PtpStorageType.removableRam;

  /// 展示名:描述 → 卷标 → 序号兜底。
  String get label {
    final d = description;
    if (d != null && d.isNotEmpty) return d;
    final v = volumeLabel;
    if (v != null && v.isNotEmpty) return v;
    return '存储 0x${id.toRadixString(16)}';
  }

  /// 余量占比(0-1);容量未知返回 null(界面不画进度条)。
  double? get freeRatio {
    if (maxCapacityBytes <= 0 || freeSpaceBytes < 0) return null;
    if (freeSpaceBytes > maxCapacityBytes) return 1;
    return freeSpaceBytes / maxCapacityBytes;
  }
}

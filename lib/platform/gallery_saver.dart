/// 系统相册保存(TODO.md §四 P1)。
///
/// 流程:传输引擎流式写盘到临时文件(边收边写)→ 本接口导入相册 → 删临时文件。
/// 三端落点:Android MediaStore(Pictures/Movies/NikonBridge)、
/// iOS PHPhotoLibrary、ohos photoAccessHelper。
library;

import 'package:flutter/services.dart';

import '../core/ptpip/object_format.dart';

abstract interface class GallerySaver {
  /// 导入已完成下载的临时文件,返回系统侧内容 Uri(iOS/ohos 亦统一为
  /// 字符串形式返回)。[kind] 决定相册目录与 MIME(JPEG/NEF/TIFF/MP4/MOV 映射,
  /// 见 core/ptpip/object_format.dart)。
  Future<Uri> importFile(
    String tempPath, {
    required ObjectKind kind,
    required String filename,
  });
}

/// 经 `nikonbridge/gallery` channel:方法 `import`(参数 path/kind/filename)。
///
/// TODO(P1): native 实现。
/// - Android:NEF 用 IS_PENDING + RELATIVE_PATH 提交流;大文件避免二次拷贝
/// - iOS:PHAssetCreationRequest 追加文件后标记 origin,避免重复导入
/// - ohos:photoAccessHelper 的安全控件授权策略需真机核对
final class MethodChannelGallerySaver implements GallerySaver {
  static const MethodChannel channel = MethodChannel('nikonbridge/gallery');

  @override
  Future<Uri> importFile(
    String tempPath, {
    required ObjectKind kind,
    required String filename,
  }) => throw UnimplementedError();
}

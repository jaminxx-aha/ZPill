/// 系统相册保存 + 应用文件目录(TODO.md §四)。
///
/// 目录分工:
/// - tempDir/thumbsDir/previewsDir 在 cacheDir(系统可随时回收,不承诺持久)
/// - downloadsDir 在 filesDir(应用内持久存储,「下载到应用」的目的地)
///
/// 相册导入(ohos,真机约束 2026-09-30 核实):HarmonyOS NEXT 三方应用
/// 静默写媒体库需 ACL 特批权限;免权限路径是
/// photoAccessHelper 的 showAssetsCreationDialog(系统保存对话框,
/// 每批一次,用户确认后应用写入授权 URI)。PhotoViewPicker.save 已从
/// SDK 移除,勿再引用。
///
/// 三端落点:Android MediaStore(Pictures/Movies/NikonPill)、
/// iOS PHPhotoLibrary、ohos photoAccessHelper(上述对话框)。
library;

import 'package:flutter/services.dart';

import '../core/ptpip/object_format.dart';

/// 一次相册导入请求:已落盘的本地文件 → 系统媒体库。
final class GalleryImportRequest {
  const GalleryImportRequest({
    required this.path,
    required this.kind,
    required this.filename,
  });

  /// 本地文件绝对路径(下载引擎的临时产物)。
  final String path;

  /// 内容类别(决定媒体库 photoType image/video 与目录)。
  final ObjectKind kind;
  final String filename;
}

abstract interface class GallerySaver {
  /// 下载临时目录(流式落盘用):GetObject 边收边写到这里,
  /// 导入相册或放弃后删除。零新依赖、不引 path_provider。
  Future<String> tempDir();

  /// 网格缩略图缓存目录(cacheDir 下,可被系统回收)。
  Future<String> thumbsDir();

  /// 大图预览缓存目录(cacheDir 下,可被系统回收)。
  Future<String> previewsDir();

  /// 应用内下载存储(filesDir 下,持久):「下载到应用」的目的地。
  Future<String> downloadsDir();

  /// 批量导入系统相册。ohos 实现弹一次系统保存对话框(showAssetsCreationDialog),
  /// 用户确认后把各文件写入授权 URI。
  ///
  /// 返回内容 Uri 列表(与 [requests] 等长);**用户取消对话框 → 空列表**
  /// (不抛异常,调用方据此标记「未导入」,可重新发起)。
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests);
}

/// 经 `nikonpill/gallery` channel。
///
/// native 实现状态:ohos(GalleryPlugin.ets)全量实现;
/// Android/iOS 留待平台落地(native 侧 notImplemented,Dart 不改)。
final class MethodChannelGallerySaver implements GallerySaver {
  static const MethodChannel channel = MethodChannel('nikonpill/gallery');

  @override
  Future<String> tempDir() => _dir('tempDir');

  @override
  Future<String> thumbsDir() => _dir('thumbsDir');

  @override
  Future<String> previewsDir() => _dir('previewsDir');

  @override
  Future<String> downloadsDir() => _dir('downloadsDir');

  Future<String> _dir(String method) async {
    final dir = await channel.invokeMethod<String>(method);
    if (dir == null || dir.isEmpty) {
      throw StateError('gallery channel 未返回目录($method)');
    }
    return dir;
  }

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async {
    final uris = await channel.invokeListMethod<String>('importFiles', [
      for (final r in requests)
        {'path': r.path, 'kind': r.kind.name, 'filename': r.filename},
    ]);
    return [for (final u in uris ?? const <String>[]) Uri.parse(u)];
  }
}

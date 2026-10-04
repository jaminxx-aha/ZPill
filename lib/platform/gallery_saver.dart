/// 系统相册保存 + 应用文件目录(TODO.md §四)。
///
/// 目录分工:
/// - tempDir/thumbsDir/previewsDir 在 cacheDir(系统可随时回收,不承诺持久)
/// - downloadsDir 在 filesDir(应用内持久存储,「下载到应用」的目的地)
///
/// 相册导入(ohos,真机约束 2026-10-03 修订):HarmonyOS NEXT 三方应用
/// 静默写媒体库需 ACL 特批权限;免权限路径有二 ——
/// showAssetsCreationDialog(系统保存对话框)在本机(HarmonyOS 6)
/// 因对话框进程冷启动稳定超时(14000011)且零落库,已弃用;现走
/// SaveButton 安全控件:native 侧亮面板,用户点「保存到图库」获得
/// ~10s 临时授权,窗口内 createAsset + 拷字节。
/// PhotoViewPicker.save 已从 SDK 移除,勿再引用。
///
/// 三端落点:Android MediaStore(Pictures/Movies/NikonPill)、
/// iOS PHPhotoLibrary、ohos photoAccessHelper(SaveButton 路径)。
library;

import 'package:flutter/foundation.dart';
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

  /// 应用数据目录(applicationSupport,持久):客户端身份、已配对
  /// 相机等 JSON 状态文件(区别于可被系统回收的 cache 三兄弟)。
  Future<String> dataDir();

  /// 批量导入系统相册。ohos 实现亮出 native 保存面板(SaveButton 安全
  /// 控件),用户点「保存到图库」后 native 侧在临时授权窗口内把各文件
  /// 写入 createAsset 授权 URI。
  ///
  /// 返回内容 Uri 列表(与 [requests] 等长);**用户取消面板 → 空列表**
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
  Future<String> dataDir() => _dir('dataDir');

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
    List<String>? uris;
    try {
      uris = await channel.invokeListMethod<String>('importFiles', [
        for (final r in requests)
          {'path': r.path, 'kind': r.kind.name, 'filename': r.filename},
      ]);
    } on PlatformException catch (e) {
      // 导入失败原因(通道异常)必须可见:引擎侧会按「未导入」落定,
      // 没有这行日志就只剩无声的黑盒。
      debugPrint('[Gallery] importFiles 通道异常: ${e.code} ${e.message}');
      rethrow;
    }
    final list = uris ?? const <String>[];
    if (list.length != requests.length) {
      debugPrint('[Gallery] importFiles 返回 ${list.length}/${requests.length}'
          '(用户取消/部分选择)');
    }
    return [for (final u in list) Uri.parse(u)];
  }
}

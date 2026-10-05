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
/// 三端落地状态:ohos ✅ 真机闭环(photoAccessHelper + SaveButton
/// 安全控件);iOS ✅ 真机闭环(PHPhotoLibrary + SaveButton 控件,
/// 提交 f949349);Android ✅ 已落地(编译过,真机待验证)——
/// MediaStore 直写(RELATIVE_PATH=Pictures/Movies/NikonPill +
/// IS_PENDING 自有贡献,免权限零弹窗;无系统对话框故无取消路径,
/// 要么全量成功要么整体异常)。
///
/// 实况照片三端路径(见 [GalleryImportRequest.videoPath]):iOS =
/// photo+pairedVideo 同资源配对;ohos = IMAGE+VIDEO 分开导入;Android =
/// 平台层(Dart)先拼回运动照片单文件再走普通图片导入(见
/// [MethodChannelGallerySaver.importFiles] Android 前置)。
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/media/motion_photo.dart' show spliceMotionPhoto;
import '../core/ptpip/object_format.dart';

/// 一次相册导入请求:已落盘的本地文件 → 系统媒体库。
final class GalleryImportRequest {
  const GalleryImportRequest({
    required this.path,
    required this.kind,
    required this.filename,
    this.videoPath,
  });

  /// 本地文件绝对路径(下载引擎的临时产物)。
  final String path;

  /// 内容类别(决定媒体库 photoType image/video 与目录)。
  final ObjectKind kind;
  final String filename;

  /// 实况照片配对(TODO §五 LivePhoto 导出):非 null 时本请求按
  /// 「静帧 + 视频段」导入为一张实况(iOS 配对资源 / ohos 动态照片 /
  /// Android 原生拼接回运动照片单文件)。native 不识别该字段时按普通
  /// 图片落库。视频来源二选一:相机同基名 MOV 成员,或运动照片 JPG
  /// 内嵌段拆出的 MP4(见 core/media/motion_photo.dart)。
  final String? videoPath;
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
    // Android 前置:实况照片在平台层拼回运动照片单文件 —— native
    // GalleryPlugin.kt 走 MediaStore 直写,不识别 videoPath(Android 相册
    // 也无第三方实况配对 API);拼接复用 core 纯 Dart 的
    // spliceMotionPhoto。拼接失败按普通静帧导入(宁可丢实况不丢照片)。
    // 瞬时内存 ≈ 静帧+视频+拼接产物(~40MB 量级),v1 可接受。
    final splicedTemps = <String>[];
    final payload = <Map<String, Object?>>[];
    for (final r in requests) {
      var path = r.path;
      if (Platform.isAndroid && r.videoPath != null) {
        final merged = await _spliceMotionPhotoTemp(r.path, r.videoPath!);
        if (merged != null) {
          path = merged;
          splicedTemps.add(merged);
        } else {
          debugPrint('[Gallery] 运动照片拼接失败,按普通静帧导入: ${r.filename}');
        }
      }
      payload.add({
        'path': path,
        'kind': r.kind.name,
        'filename': r.filename,
        // videoPath 仅 iOS/ohos native 消费;Android 已拼入单文件,不下发。
        if (r.videoPath != null && !Platform.isAndroid) 'videoPath': r.videoPath,
      });
    }
    List<String>? uris;
    try {
      uris = await channel.invokeListMethod<String>('importFiles', payload);
    } on PlatformException catch (e) {
      // 导入失败原因(通道异常)必须可见:引擎侧会按「未导入」落定,
      // 没有这行日志就只剩无声的黑盒。
      debugPrint('[Gallery] importFiles 通道异常: ${e.code} ${e.message}');
      rethrow;
    } finally {
      for (final p in splicedTemps) {
        try {
          File(p).deleteSync();
        } catch (_) {
          // cacheDir 产物,残留也可被系统回收
        }
      }
    }
    final list = uris ?? const <String>[];
    if (list.length != requests.length) {
      debugPrint('[Gallery] importFiles 返回 ${list.length}/${requests.length}'
          '(用户取消/部分选择)');
    }
    return [for (final u in list) Uri.parse(u)];
  }

  /// 拼接静帧 + 视频段 → 同目录临时文件;任一步失败返回 null(降级)。
  Future<String?> _spliceMotionPhotoTemp(String imagePath, String videoPath) async {
    try {
      final image = await File(imagePath).readAsBytes();
      final video = await File(videoPath).readAsBytes();
      final merged = spliceMotionPhoto(image, video);
      final tmp = File('$imagePath.motionphoto.jpg');
      await tmp.writeAsBytes(merged, flush: true);
      return tmp.path;
    } catch (e) {
      debugPrint('[Gallery] _spliceMotionPhotoTemp: $e');
      return null;
    }
  }
}

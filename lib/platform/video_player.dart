/// 视频播放接口:`nikonpill/video` 通道契约。
///
/// 两个方法:
/// - `play({path})`:全屏播放本地视频文件,返回于播放器关闭时
///   (native 侧 present → 用户退出 → dismiss 回调)。native 侧
///   iOS = AVKit(见 ios/Runner/VideoPlugin.swift:AVPlayerViewController
///   包一层关闭钮),Android/ohos 待补(ExoPlayer 平台视图 /
///   @ohos.multimedia.media)。
/// - `thumbnail({path, maxPixelSize})`:抽取一帧编码为 JPEG 返回
///   (iOS AVAssetImageGenerator;取 0.1s 处避开纯黑首帧,按拍摄方向
///   正立)。图库网格/查看器用它出 MOV 海报帧。
///
/// PTP 相机没有流式播放在谈:MOV 播放必须先整档下载到临时目录
/// (Nikon moov 原子位置未验证,且 PTP 无 HTTP range 语义),
/// 调用方(PhotoViewerPage)播完删档。通道未实现(Android/ohos)抛
/// MissingPluginException,调用方按「该平台暂不支持」提示(缩略图
/// 则回落图标格)。
library;

import 'package:flutter/services.dart';

abstract interface class VideoPlayer {
  /// 全屏播放 [path];Future 在播放器关闭时完成。文件不存在/无法播放
  /// 抛 [Exception]。
  Future<void> play(String path);

  /// 抽取 [path] 的一帧编码为 JPEG;[maxPixelSize] 为长边上限像素。
  /// 文件不存在/无法抽帧/平台无通道抛 [Exception]。
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize});
}

final class MethodChannelVideoPlayer implements VideoPlayer {
  static const MethodChannel _channel = MethodChannel('nikonpill/video');

  @override
  Future<void> play(String path) async {
    await _channel.invokeMethod<void>('play', {'path': path});
  }

  @override
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize}) async {
    final jpeg = await _channel.invokeMethod<Uint8List>('thumbnail', {
      'path': path,
      'maxPixelSize': maxPixelSize,
    });
    if (jpeg == null || jpeg.isEmpty) {
      throw const FormatException('video thumbnail 载荷为空');
    }
    return jpeg;
  }
}

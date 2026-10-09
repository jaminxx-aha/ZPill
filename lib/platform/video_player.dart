/// 视频播放接口:`nikonpill/video` 通道契约。
///
/// 三个方法:
/// - `play({path, rate})`:全屏播放本地视频文件,返回于播放器关闭时
///   (native 侧 present → 用户退出 → dismiss 回调)。native 侧
///   iOS = AVKit(见 ios/Runner/VideoPlugin.swift:AVPlayerViewController
///   包一层关闭钮),Android/ohos 待补(ExoPlayer 平台视图 /
///   @ohos.multimedia.media)。[rate] 为播放速率:顺帧预览(conform)
///   传 24/fps(如 60fps 素材按 24fps 看 = 0.4);非 1 速率静音 —— 变速
///   下音轨无意义(OpenZCine conform 同款)。
/// - `thumbnail({path, maxPixelSize})`:抽取一帧编码为 JPEG 返回
///   (iOS AVAssetImageGenerator;取 0.1s 处避开纯黑首帧,按拍摄方向
///   正立)。图库网格/查看器用它出 MOV 海报帧。
/// - `frameRate({path})`:探测视频标称帧率(iOS
///   AVAssetTrack.nominalFrameRate)。顺帧预览的门禁:>30fps 的高帧率
///   素材才提供「24fps 顺帧」选项;拿不到/无视频轨返回 null。
///
/// PTP 相机没有流式播放在谈:MOV 播放必须先整档下载到临时目录
/// (Nikon moov 原子位置未验证,且 PTP 无 HTTP range 语义),
/// 调用方(PhotoViewerPage)播完删档。通道未实现(Android/ohos)抛
/// MissingPluginException,调用方按「该平台暂不支持」提示(缩略图
/// 则回落图标格)。
library;

import 'package:flutter/services.dart';

abstract interface class VideoPlayer {
  /// 全屏播放 [path];Future 在播放器关闭时完成。[rate] 播放速率
  /// (顺帧预览 = 24/fps;非 1 速率静音)。文件不存在/无法播放抛
  /// [Exception]。
  Future<void> play(String path, {double rate});

  /// 抽取 [path] 的一帧编码为 JPEG;[maxPixelSize] 为长边上限像素。
  /// 文件不存在/无法抽帧/平台无通道抛 [Exception]。
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize});

  /// 探测 [path] 的标称帧率;无视频轨/平台无通道/探测失败返回 null
  /// (调用方按「实时播放」处理,不拦顺帧以外的路径)。
  Future<double?> frameRate(String path);
}

final class MethodChannelVideoPlayer implements VideoPlayer {
  static const MethodChannel _channel = MethodChannel('nikonpill/video');

  @override
  Future<void> play(String path, {double rate = 1.0}) async {
    await _channel.invokeMethod<void>('play', {
      'path': path,
      'rate': rate,
    });
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

  @override
  Future<double?> frameRate(String path) async {
    try {
      return await _channel.invokeMethod<double>('frameRate', {'path': path});
    } on MissingPluginException {
      return null;
    }
  }
}

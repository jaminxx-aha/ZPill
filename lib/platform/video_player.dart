/// 视频播放接口:`nikonpill/video` 通道契约。
///
/// 三个方法:
/// - `play({path, rate})`:全屏播放本地视频文件,返回于播放器关闭时
///   (native 侧 present → 用户退出 → dismiss 回调)。三端已补齐
///   (2026-10-13):iOS = AVKit(见 ios/Runner/VideoPlugin.swift:
///   AVPlayerViewController 包一层关闭钮),Android = VideoActivity
///   (MediaPlayer + TextureView),ohos = VideoSheet 覆盖层(AVPlayer +
///   XComponent)。[rate] 为播放速率:顺帧预览(conform)
///   传 24/fps(如 60fps 素材按 24fps 看 = 0.4);非 1 速率静音 —— 变速
///   下音轨无意义(OpenZCine conform 同款)。
/// - `thumbnail({path, maxPixelSize})`:抽取一帧编码为 JPEG 返回
///   (iOS AVAssetImageGenerator / Android MediaMetadataRetriever +
///   ROTATION 正立 / ohos AVImageGenerator;取 0.1s 处避开纯黑首帧,
///   iOS 按拍摄方向正立)。图库网格/查看器用它出 MOV 海报帧。
///   三端抽帧通道已落地;内嵌视图由 iOS/ohos 提供,Android 回落全屏。
/// - `frameRate({path})`:探测视频标称帧率(iOS
///   AVAssetTrack.nominalFrameRate)。顺帧预览的门禁:>30fps 的高帧率
///   素材才提供「24fps 顺帧」选项;拿不到/无视频轨返回 null。
///
/// 另有**内嵌播放**一路(图库查看器视频页,2026-10-09):
/// - `supportsEmbeddedView`:平台是否具备内嵌播放视图(= iOS/ohos
///   平台视图 `nikonpill/video-view` 已注册;Android 回 false → 调用方
///   回落海报帧 + 播放钮,点了走全屏 play)。
/// - `loadEmbeddedView(viewId, path)`:内嵌视图装载档案。**路径不走
///   平台视图 creationParams**(引擎对工厂可选编解码钩子的挂接不可靠,
///   实测参数到不了原生侧 → 黑页无法播放),改走方法通道 ——
///   [embeddedVideoViewBuilder] 的 onCreated 回传 viewId 后、起播前
///   显式调用;同通道 FIFO,时序有保证。
/// - `controlEmbeddedView(viewId, {playing, rate})`:驱动内嵌视图的
///   起播/暂停与速率(顺帧开关)。viewId 来自 [embeddedVideoViewBuilder]
///   的 onCreated 回调。视图本体 = [embeddedVideoViewBuilder](UiKitView
///   包 AVPlayerViewController;点按出 Flutter 自绘控制、横滑归 Flutter
///   翻页 —— UiKitView 空 gestureRecognizers 的竞技场语义;视图本体
///   iOS = UiKitView 包 AVPlayerViewController,ohos = OhosView 包
///   XComponent + AVPlayer(2026-10-24 对齐,iOS 同款点按层语义)。
///
/// PTP 相机没有流式播放在谈:MOV 播放必须先整档下载(相机相册路径),
/// 调用方(PhotoViewerPage)播完删档(iOS 内嵌路;原生全屏路临时档
/// 交会话缓存供重播)。play/缩略图通道三端齐备;仅内嵌视图缺失的
/// 平台回落海报 + 全屏播放(缩略图失败则回落图标格)。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 内嵌播放视图构建器:[path] 为本地视频档,[onCreated] 回传平台视图号
/// (供 [VideoPlayer.controlEmbeddedView] 寻址)。生产实现 =
/// [embeddedVideoViewBuilder](iOS 平台视图);测试注入假件。
typedef EmbeddedVideoViewBuilder = Widget Function(
    String path, void Function(int viewId) onCreated);

abstract interface class VideoPlayer {
  /// 全屏播放 [path];Future 在播放器关闭时完成,**值 = 关闭时刻的
  /// 播放位置(秒;原生未报/出错 = null)** —— 调用方续播用。[rate]
  /// 播放速率(顺帧预览 = 24/fps;非 1 速率静音)。[position] 起播位置
  /// (秒,续播;缺省从头;ohos 已实现,iOS/Android 从头且回 null)。
  /// 文件不存在/无法播放抛 [Exception]。
  Future<double?> play(String path, {double rate = 1.0, double? position});

  /// 抽取 [path] 的一帧编码为 JPEG;[maxPixelSize] 为长边上限像素。
  /// 文件不存在/无法抽帧/平台无通道抛 [Exception]。
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize});

  /// 探测 [path] 的标称帧率;无视频轨/平台无通道/探测失败返回 null
  /// (调用方按「实时播放」处理,不拦顺帧以外的路径)。
  Future<double?> frameRate(String path);

  /// 内嵌播放视图是否可用(iOS/ohos 平台视图已注册;Android 回 false,
  /// 调用方回落海报帧 + 全屏 play)。
  bool get supportsEmbeddedView;

  /// 内嵌播放视图 [viewId] 装载 [path](onCreated 回传 viewId 后、
  /// 起播前调用一次)。路径走方法通道而非平台视图 creationParams
  /// (引擎编解码钩子不可靠,见库注释)。视图未创建/已销毁时静默忽略。
  Future<void> loadEmbeddedView(int viewId, String path);

  /// 驱动内嵌播放视图 [viewId]:起播/暂停 + 速率(顺帧 = 24/fps,
  /// 非 1 速率静音)。视图未创建/已销毁时静默忽略。
  Future<void> controlEmbeddedView(int viewId,
      {required bool playing, required double rate});

  /// 读内嵌播放视图 [viewId] 的当前状态:位置/时长(秒)与是否在播
  /// (播放控制的轮询数据;时长未就绪 = 0)。
  Future<({double position, double duration, bool playing})>
      embeddedViewStatus(int viewId);

  /// 把内嵌播放视图 [viewId] 拖到 [position](秒)。
  Future<void> seekEmbeddedView(int viewId, {required double position});
}

/// 生产内嵌视图:`nikonpill/video-view` 平台视图 —— iOS = UiKitView 包
/// AVPlayerViewController(VideoPlugin 注册),ohos = **OhosView**(fork
/// 亲儿子件,渲染对象 offset 带仿射 transform,引擎旋转支持只认它 ——
/// AndroidView 载具实测转横即死:无 transform 被引擎按「不处理旋转」
/// 摆位,纹理停在旧几何,2026-10-24 探针实锤)。上游 flutter 无
/// OhosView 符号,lib/ 须双 SDK 编译 —— 上游 widgets 已打构造兼容垫片
/// (ink_sparkle 同账,升级丢补丁要回打;垫片运行时不可达:调用方以
/// Platform.operatingSystem 门禁)。不带 creationParams —— 档案路径由
/// [VideoPlayer.loadEmbeddedView] 走方法通道装载(见类注释)。
/// Android 未注册(原生全屏 play 兜底);未注册平台不得构建。
Widget embeddedVideoViewBuilder(
    String path, void Function(int viewId) onCreated) {
  if (Platform.isIOS) {
    return UiKitView(
      viewType: 'nikonpill/video-view',
      onPlatformViewCreated: onCreated,
    );
  }
  if (Platform.operatingSystem == 'ohos') {
    return OhosView(
      viewType: 'nikonpill/video-view',
      onPlatformViewCreated: onCreated,
    );
  }
  // 门禁外平台(supportsEmbeddedView=false):空占位,不应走到。
  return const SizedBox.expand();
}

final class MethodChannelVideoPlayer implements VideoPlayer {
  static const MethodChannel _channel = MethodChannel('nikonpill/video');

  @override
  bool get supportsEmbeddedView =>
      Platform.isIOS || Platform.operatingSystem == 'ohos';

  @override
  Future<void> loadEmbeddedView(int viewId, String path) async {
    await _channel.invokeMethod<void>('viewLoad', {
      'id': viewId,
      'path': path,
    });
  }

  @override
  Future<void> controlEmbeddedView(int viewId,
      {required bool playing, required double rate}) async {
    await _channel.invokeMethod<void>('viewControl', {
      'id': viewId,
      'playing': playing,
      'rate': rate,
    });
  }

  @override
  Future<({double position, double duration, bool playing})>
      embeddedViewStatus(int viewId) async {
    final map = await _channel
        .invokeMapMethod<String, Object?>('viewStatus', {'id': viewId});
    return (
      position: (map?['position'] as num?)?.toDouble() ?? 0,
      duration: (map?['duration'] as num?)?.toDouble() ?? 0,
      playing: map?['playing'] as bool? ?? false,
    );
  }

  @override
  Future<void> seekEmbeddedView(int viewId, {required double position}) async {
    await _channel.invokeMethod<void>('viewSeek', {
      'id': viewId,
      'position': position,
    });
  }

  @override
  Future<double?> play(String path,
      {double rate = 1.0, double? position}) async {
    return _channel.invokeMethod<double>('play', {
      'path': path,
      'rate': rate,
      if (position != null) 'position': position,
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

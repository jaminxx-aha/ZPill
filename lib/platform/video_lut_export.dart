/// 视频 LUT 导出平台契约:本地视频 + .cube LUT → 烘焙导出 MP4 临时档。
///
/// 对应 native:Android Media3 Transformer(SingleColorLut +
/// ToInt16PcmAudioProcessor + FrameworkMuxer 防 fragmented-MP4,借
/// Camera_Bridge 思路);iOS AVAssetExportSession +
/// AVVideoComposition(applyingCIFiltersWithHandler)内 CIColorCube;
/// ohos 走 rawdecoder.so 的 C++ 解封装、硬解、CPU LUT 与硬编管线。
///
/// 契约:
/// - `export(path, lut)`:native 自选 cacheDir 临时输出,导出完成返回
///   产物路径;**落库不归本层** —— 调用方走 GallerySaver.importFiles
///   (视频类)导入系统相册后可删临时档。
/// - 进度经通道反向调用 `onProgress`(int 0-100,~250ms 一拍);
///   `cancel` 尽力而为(导出失败/取消都走结果异常)。
/// - 同一时刻仅一个导出在途;重复 export 抛 StateError。
///
/// LUT 数据形态(Dart 侧 [CubeLut.cubeDataRgba] 产出):Float32 N³×4
/// RGBA、红最快、alpha 恒 1 —— 正是 CIColorCube 的 cubeData 布局;
/// Media3 侧由 native 再折成 SingleColorLut 的嵌套数组。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../core/media/cube_lut.dart';

abstract interface class VideoLutExportHost {
  /// 平台是否带导出实现。探测走真调用,通道缺失
  /// (MissingPluginException)即不支持,不按平台名硬编码。
  Future<bool> isSupported();

  /// 导出 [path] 的本地视频,套 [lut] 后落临时 MP4,返回产物路径。
  /// [onProgress] 0-100;失败抛 PlatformException(取消也是)。
  Future<String> export(
    String path,
    CubeLut lut, {
    void Function(int progress)? onProgress,
  });

  /// 取消在途导出;无在途时无害。
  Future<void> cancel();
}

/// 经 `nikonpill/video_lut` channel。
final class MethodChannelVideoLutExport implements VideoLutExportHost {
  static const MethodChannel _channel = MethodChannel('nikonpill/video_lut');

  bool _inFlight = false;
  void Function(int)? _progress;

  @override
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // 实现侧对 isSupported 不该报错;真报了按不支持降级(诚实兜底)。
      return false;
    }
  }

  @override
  Future<String> export(
    String path,
    CubeLut lut, {
    void Function(int progress)? onProgress,
  }) async {
    if (_inFlight) {
      throw StateError('视频 LUT 导出已在途');
    }
    _inFlight = true;
    _progress = onProgress;
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final out = await _channel
          .invokeMethod<String>('export', <String, Object?>{
        'path': path,
        'cube': lut.cubeDataRgba(),
        'size': lut.size,
      });
      if (out == null || out.isEmpty) {
        throw PlatformException(
            code: 'export_failed', message: 'native 未返回产物路径');
      }
      return out;
    } finally {
      _inFlight = false;
      _progress = null;
      _channel.setMethodCallHandler(null);
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onProgress':
        final p = call.arguments as int? ?? 0;
        _progress?.call(p.clamp(0, 100));
        return null;
      default:
        return null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // 无实现即无在途,无害。
    }
  }
}

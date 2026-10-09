/// RAW 解码接口:`nikonpill/raw` 通道契约。
///
/// MethodChannel `nikonpill/raw` 的 `decode` 方法把 RAW 文件(尼康 NEF)
/// 原生解码为 JPEG 字节返回,参数 `{path, maxPixelSize}`,返回
/// `FlutterStandardTypedData`(JPEG;字节陷阱见 flutter-ios-channel-byte-trap)。
///
/// 为什么走原生:Z f 的 NEF 内没有任何大尺寸 JPEG(2026-10-09 探针定案:
/// 只有 160×120 缩略 JPEG,320×212/1620×1080 预览都是 NEF 压缩条带,
/// 0x90C4 对 NEF 回的就是 320×212 条带 —— 非 JPEG),纯 Dart 无 RAW
/// 解码器;iOS ImageIO 原生支持 NEF(整机 RAW 管线,直出 6064×4040)。
/// native 侧 iOS = CGImageSource(见 ios/Runner/RawDecodePlugin.swift),
/// Android/ohos 待补(libraw 绑定或相机内嵌预览路)。
///
/// 通道未实现(Android/ohos)抛 MissingPluginException —— 调用方
/// (ThumbnailCache)按「回落 GetThumb 小图」降级,不重试。
library;

import 'package:flutter/services.dart';

abstract interface class RawDecoder {
  /// 把 [path] 的 RAW 解码为 JPEG 字节;[maxPixelSize] 为长边上限像素
  /// (缩放解码,省内存省缓存)。解码失败抛 [Exception]。
  Future<Uint8List> decodeJpeg(String path, {required int maxPixelSize});
}

final class MethodChannelRawDecoder implements RawDecoder {
  static const MethodChannel _channel = MethodChannel('nikonpill/raw');

  @override
  Future<Uint8List> decodeJpeg(String path, {required int maxPixelSize}) async {
    final raw = await _channel.invokeMethod<Uint8List>('decode', {
      'path': path,
      'maxPixelSize': maxPixelSize,
    });
    if (raw == null || raw.isEmpty) {
      throw const FormatException('raw decode 载荷为空');
    }
    return raw;
  }
}

// ZPill RAW 解码通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/raw_decoder.dart:
// - decode({path, maxPixelSize}):CGImageSource 读 RAW(尼康 NEF,
//   iOS ImageIO 整机 RAW 管线原生支持)→ 缩放解码为位图 → JPEG(0.85)
//   → FlutterStandardTypedData(字节必须走 typedData,裸 Data 会触发
//   Dart 侧 TypeError —— 见 memory flutter-ios-channel-byte-trap)。
//
// 解码必须在后台队列:NEF 全尺寸解码 + 缩放 + JPEG 编码是秒级重活,
// 方法回调默认落在主线程 —— 真机实证 UI 整体冻结、点击无响应
// (2026-10-09 用户报「无法点击」)。结果汇主线程回投
// (FlutterResult 线程契约)。
//
// 为什么走原生:Z f 的 NEF 内没有任何大尺寸 JPEG(2026-10-09 探针
// 定案:160×120 缩略 JPEG 之外,320×212/1620×1080 预览都是 NEF 压缩
// 条带),纯 Dart 无 RAW 解码器;ImageIO 直出全尺寸(6064×4040),
// kCGImageSourceThumbnailMaxPixelSize 控制长边。
//
// 失败语义:文件不存在/无法解码/无 RAW 支持 → FlutterError(调用方
// ThumbnailCache 回落 GetThumb 小图)。

import Flutter
import UIKit

public final class RawDecodePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zpill/raw", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(RawDecodePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "decode":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let maxPixelSize = args["maxPixelSize"] as? Int else {
        result(FlutterError(code: "bad_args", message: "decode 须传 path/maxPixelSize", details: nil))
        return
      }
      // 秒级重活绝不能占主线程(见文件头);结果回主线程交付。
      DispatchQueue.global(qos: .userInitiated).async {
        let outcome = Self.decode(path: path, maxPixelSize: maxPixelSize)
        DispatchQueue.main.async {
          switch outcome {
          case .ok(let jpeg):
            result(FlutterStandardTypedData(bytes: jpeg))
          case .failed(let error):
            result(error)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private enum DecodeOutcome {
    case ok(Data)
    case failed(FlutterError)
  }

  private static func decode(path: String, maxPixelSize: Int) -> DecodeOutcome {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return .failed(FlutterError(code: "open_failed", message: "无法打开文件: \(path)", details: nil))
    }
    // CreateThumbnailFromImageAlways:RAW 没有足够大的内嵌缩略图(NEF
    // 只有 160×120),必须强制解码原图;kCGImageSourceThumbnailMaxPixelSize
    // 让 ImageIO 在解码管线里缩放(省内存)。
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return .failed(FlutterError(code: "decode_failed", message: "RAW 解码失败(格式不受支持?)", details: nil))
    }
    let image = UIImage(cgImage: cgImage)
    guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
      return .failed(FlutterError(code: "encode_failed", message: "JPEG 编码失败", details: nil))
    }
    return .ok(jpeg)
  }
}

import AVFoundation
import CoreImage
import Flutter
import Foundation
import UIKit

/// 视频 LUT 导出(`nikonpill/video_lut` 通道;Dart 契约
/// lib/platform/video_lut_export.dart)。
///
/// AVFoundation 管线:AVAssetExportSession + AVVideoComposition
/// (applyingCIFiltersWithHandler)逐帧过 CIColorCube(借 OpenZCine
/// MediaLUTExport 的 cube 管线思路,其导出主体在其私有仓,此处按公开
/// API 自写)。音频由 export session 原样带过,不重编码。
///
/// - cube 数据由 Dart 侧 CubeLut.cubeDataRgba 产出:Float32 N³×4
///   RGBA、红最快、alpha 恒 1 —— 正是 CIColorCube 的 inputCubeData
///   布局,直通不转换。
/// - 逐帧 handler 内现建 CIFilter(每帧构造成本相对解码可忽略,免
///   跨帧复用的线程心疑)。
/// - 进度 0.25s 轮询 session.progress;cancel 走 cancelExport,结果以
///   「cancelled」错误收场(Dart 侧按取消消费)。
/// - 产物 = caches 目录临时 MP4;成功保留交 Dart 经 GallerySaver 落库,
///   失败/取消删除。
final class VideoLutExportPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var session: AVAssetExportSession?
  private var outputURL: URL?
  private var progressTimer: Timer?
  private var settled = false

  /// export 的通道结果(收口时恰好回一次)。
  private var pending: ((Any?) -> Void)?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "nikonpill/video_lut",
                                       binaryMessenger: registrar.messenger())
    let instance = VideoLutExportPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "export":
      export(call, result)
    case "cancel":
      cancelInFlight()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func export(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if session != nil {
      result(FlutterError(code: "busy", message: "已有导出在途", details: nil))
      return
    }
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let size = args["size"] as? Int, size >= 2,
          let cubeTyped = args["cube"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "bad_args", message: "path/size/cube 缺失或非法", details: nil))
      return
    }
    let cubeData = cubeTyped.data  // Float32 N³×4 RGBA 红最快(小端,ARM 直读)
    let expected = size * size * size * 4 * MemoryLayout<Float>.size
    guard cubeData.count == expected else {
      result(FlutterError(code: "bad_cube",
                          message: "cube 数据应为 \(expected)B(\(size)³×4 float),得 \(cubeData.count)",
                          details: nil))
      return
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let composition: AVVideoComposition
    do {
      composition = try lutComposition(asset: asset, size: size, cubeData: cubeData)
    } catch {
      result(FlutterError(code: "composition_failed",
                          message: error.localizedDescription, details: nil))
      return
    }
    let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    let out = URL(fileURLWithPath: caches)
      .appendingPathComponent("lut_export_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
    try? FileManager.default.removeItem(at: out)
    guard let export = AVAssetExportSession(asset: asset,
                                            presetName: AVAssetExportPresetHighestQuality) else {
      result(FlutterError(code: "session_failed", message: "导出会话建立失败", details: nil))
      return
    }
    outputURL = out
    session = export
    settled = false
    pending = result
    export.videoComposition = composition
    export.outputURL = out
    export.outputFileType = .mp4
    export.exportAsynchronously { [weak self] in
      DispatchQueue.main.async { self?.finishExport() }
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self, let session = self.session else { return }
      self.channel?.invokeMethod("onProgress",
                                 arguments: min(99, Int(session.progress * 100)))
    }
    progressTimer = timer
  }

  /// LUT 合成器:CIColorCube 逐帧(见类注,filter 每帧现建)。
  private func lutComposition(asset: AVAsset, size: Int,
                              cubeData: Data) throws -> AVVideoComposition {
    return try AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
      let filter = CIFilter(name: "CIColorCube")
      filter?.setValue(NSNumber(value: size), forKey: "inputCubeDimension")
      filter?.setValue(cubeData, forKey: "inputCubeData")
      filter?.setValue(request.sourceImage, forKey: kCIInputImageKey)
      if let output = filter?.outputImage {
        request.finish(with: output.cropped(to: request.sourceImage.extent), context: nil)
      } else {
        request.finish(with: request.sourceImage, context: nil)
      }
    })
  }

  /// 终态收口(恰好一次):停表、按状态回结果;失败/取消删临时档,
  /// 成功保留交 Dart 落库。收口后迟到的回调全部无害。
  private func finishExport() {
    guard !settled, let export = session, let pending = self.pending else { return }
    settled = true
    progressTimer?.invalidate()
    progressTimer = nil
    session = nil
    let out = outputURL
    outputURL = nil
    self.pending = nil
    switch export.status {
    case .completed:
      channel?.invokeMethod("onProgress", arguments: 100)
      pending(out?.path ?? "")
    case .cancelled:
      if let out { try? FileManager.default.removeItem(at: out) }
      pending(FlutterError(code: "cancelled", message: "已取消", details: nil))
    default:
      if let out { try? FileManager.default.removeItem(at: out) }
      pending(FlutterError(code: "export_failed",
                           message: export.error?.localizedDescription ?? "导出失败",
                           details: nil))
    }
  }

  /// 取消在途:cancelExport 异步触发 finishExport(.cancelled)路径。
  private func cancelInFlight() {
    session?.cancelExport()
  }
}

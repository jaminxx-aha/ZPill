// ZPill 相册/文件通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/gallery_saver.dart:
// - tempDir()/thumbsDir()/previewsDir():NSTemporaryDirectory 下专用子目录
//   (缓存语义,系统可回收;缩略图 LRU 与下载临时落盘用);
// - downloadsDir():Documents 下持久目录(「下载到应用」的目的地,
//   Info.plist 已开 UIFileSharingEnabled,文件 App 可见);
// - importFiles([{path, kind('image'|'video'), filename, videoPath?}]):
//   PHPhotoLibrary add-only 批量导入。**授权拒绝/受限 → 空列表**(契约:
//   空 = 未导入,不抛错,可重新发起);performChanges 失败 → FlutterError。
//   videoPath 非空 = 实况照片:静帧 .photo + 配对视频 .pairedVideo 同一
//   资产(视频来自相机运动照片拆分段,无苹果实况元数据,动画行为待真机
//   核对)。返回 phassets://<localIdentifier>(对 Dart 是不透明 Uri;
//   标识符在 changes block 内取的是占位值,提交成功后即为正式资产 ID)。

import Flutter
import Photos
import UIKit

private let tempSubdir = "zpill"
private let thumbsSubdir = "zpill-thumbs"
private let previewsSubdir = "zpill-previews"
private let downloadsSubdir = "zpill-downloads"
private let dataSubdir = "zpill-data"

public final class GalleryPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zpill/gallery", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(GalleryPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "tempDir": result(Self.ensureSubdir(tempSubdir, base: NSTemporaryDirectory()))
    case "thumbsDir": result(Self.ensureSubdir(thumbsSubdir, base: NSTemporaryDirectory()))
    case "previewsDir": result(Self.ensureSubdir(previewsSubdir, base: NSTemporaryDirectory()))
    case "downloadsDir":
      let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
      result(Self.ensureSubdir(downloadsSubdir, base: docs))
    case "dataDir":
      // applicationSupport(沙盒内应用私有,持久):客户端身份/配对记录等状态文件
      let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
      let dataDir = Self.ensureSubdir(dataSubdir, base: appSupport)
      if let dataDir {
        Self.excludeFromBackup(dataDir)
      }
      result(dataDir)
    case "importFiles": importFiles(call.arguments, result: result)
    case "shareFiles": shareFiles(call.arguments, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// 系统分享(UIActivityViewController):本地文件 URL + 可选文本。
  /// iPad 必须给 popover 锚点,否则 present 会崩。
  private func shareFiles(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
      let paths = args["paths"] as? [String], !paths.isEmpty
    else {
      result(FlutterError(code: "gallery_error", message: "shareFiles 参数须为非空路径列表", details: nil))
      return
    }
    for path in paths where !FileManager.default.fileExists(atPath: path) {
      result(FlutterError(code: "gallery_error", message: "文件不存在: \(path)", details: nil))
      return
    }
    var items: [Any] = paths.map { URL(fileURLWithPath: $0) }
    if let text = args["text"] as? String, !text.isEmpty {
      items.append(text)
    }
    DispatchQueue.main.async {
      guard let host = Self.topViewController() else {
        result(FlutterError(code: "gallery_error", message: "无可展示分享面板的视图控制器", details: nil))
        return
      }
      let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
      if let popover = controller.popoverPresentationController {
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      host.present(controller, animated: true) { result(nil) }
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?
      .rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    if let nav = top as? UINavigationController {
      return nav.visibleViewController ?? nav
    }
    if let tab = top as? UITabBarController {
      return tab.selectedViewController ?? tab
    }
    return top
  }

  private static func ensureSubdir(_ name: String, base: String) -> String? {
    let dir = (base as NSString).appendingPathComponent(name)
    do {
      if !FileManager.default.fileExists(atPath: dir) {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      }
      return dir
    } catch {
      NSLog("[GalleryPlugin] createDirectory \(dir): \(error)")
      return nil
    }
  }

  /// Pairing identities and device-local logs must not migrate to another
  /// device through iCloud backup. User media stays in Documents and remains
  /// eligible for backup.
  private static func excludeFromBackup(_ path: String) {
    var url = URL(fileURLWithPath: path, isDirectory: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      NSLog("[GalleryPlugin] excludeFromBackup \(path): \(error)")
    }
  }

  private func importFiles(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let items = arguments as? [[String: Any]], !items.isEmpty else {
      result(FlutterError(code: "gallery_error", message: "importFiles 参数须为非空列表", details: nil))
      return
    }
    var pairs: [(url: URL, isVideo: Bool, filename: String, videoURL: URL?)] = []
    for item in items {
      guard let path = item["path"] as? String, !path.isEmpty,
        let filename = item["filename"] as? String, !filename.isEmpty
      else {
        result(FlutterError(code: "gallery_error", message: "importFiles 项缺 path/filename", details: nil))
        return
      }
      let isVideo = (item["kind"] as? String) == "video"
      let videoPath = item["videoPath"] as? String
      let videoURL = (videoPath?.isEmpty == false)
        ? URL(fileURLWithPath: videoPath!) : nil
      pairs.append((URL(fileURLWithPath: path), isVideo, filename, videoURL))
    }

    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        result([])  // 授权拒绝 → 空列表(未导入,不是错误)
        return
      }
      var identifiers: [String] = []
      PHPhotoLibrary.shared().performChanges({
        for pair in pairs {
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = pair.filename
          let request = PHAssetCreationRequest.forAsset()
          if let videoURL = pair.videoURL {
            // 实况照片(Dart 契约 videoPath 非空):静帧 + 配对视频资源
            // 同一资产。相机运动照片拆出的 MP4 无苹果实况视频元数据,
            // Photos 是否播放动画待真机核对 —— 静帧资产本身不受影响。
            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.originalFilename =
              ((pair.filename as NSString).deletingPathExtension) + ".MOV"
            request.addResource(with: .photo, fileURL: pair.url, options: options)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
          } else {
            request.addResource(
              with: pair.isVideo ? .video : .photo, fileURL: pair.url, options: options)
          }
          if let placeholder = request.placeholderForCreatedAsset {
            identifiers.append(placeholder.localIdentifier)
          }
        }
      }) { success, error in
        if let error {
          result(FlutterError(code: "gallery_error", message: "performChanges: \(error)", details: nil))
        } else if success {
          result(identifiers.map { "phassets://\($0)" })
        } else {
          result(FlutterError(code: "gallery_error", message: "performChanges 未成功", details: nil))
        }
      }
    }
  }
}

// NikonPill 视频播放通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/video_player.dart:
// - play({path, rate}):AVPlayer 播放本地文件,全屏 present。AVPlayerViewController
//   自带播放控制(进度/音量/全屏),补一个左上关闭钮(原生播放器没有
//   Done);关闭 = dismiss + result(nil)(Dart 侧 Future 于此刻完成,
//   调用方随后删临时档)。rate 非 1 = 顺帧预览(conform,如 60fps 素材
//   按 24fps 看 = 0.4):静音播放 —— 变速下音轨无意义(OpenZCine
//   conform 同款)。
// - thumbnail({path, maxPixelSize}):AVAssetImageGenerator 抽帧 → JPEG。
//   取 0.1s 处(避开纯黑首帧)、appliesPreferredTrackTransform 按拍摄
//   方向正立。抽帧是磁盘读 + 解码,移后台队列,结果回主线程交付
//   (线程契约同 RawDecodePlugin);字节必须 FlutterStandardTypedData
//   回传(裸 Data 触发 Dart 侧 TypeError —— 见 memory
//   flutter-ios-channel-byte-trap)。
// - frameRate({path}):AVAssetTrack.nominalFrameRate(标称帧率;顺帧
//   预览的门禁数据)。无视频轨/探测失败回 nil,Dart 侧按「实时播放」
//   处理。
//
// present 的 VC 取法:iOS 13+ 场景化(SceneDelegate),从
// connectedScenes 取 foregroundActive 的 keyWindow rootVC,再走
// 最顶层 presentedVC;Flutter 的 VC 在栈里。

import AVKit
import Flutter
import UIKit

public final class VideoPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "nikonpill/video", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VideoPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "play 须传 path", details: nil))
        return
      }
      let rate = args["rate"] as? Double ?? 1.0
      DispatchQueue.main.async {
        Self.presentPlayer(path: path, rate: rate, result: result)
      }
    case "thumbnail":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let maxPixelSize = args["maxPixelSize"] as? Int else {
        result(FlutterError(code: "bad_args", message: "thumbnail 须传 path/maxPixelSize", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let outcome = Self.thumbnail(path: path, maxPixelSize: maxPixelSize)
        DispatchQueue.main.async {
          switch outcome {
          case .ok(let jpeg):
            result(FlutterStandardTypedData(bytes: jpeg))
          case .failed(let error):
            result(error)
          }
        }
      }
    case "frameRate":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "frameRate 须传 path", details: nil))
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "file_missing", message: "视频文件不存在: \(path)", details: nil))
        return
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      asset.loadTracks(withMediaType: .video) { tracks, _ in
        DispatchQueue.main.async {
          // 无视频轨/探测失败 = nil:调用方按「实时播放」走,不拦路径。
          if let fps = tracks?.first?.nominalFrameRate, fps > 0 {
            result(Double(fps))
          } else {
            result(nil)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private enum ThumbOutcome {
    case ok(Data)
    case failed(FlutterError)
  }

  /// 抽帧(须在后台队列调用):0.1s 处一帧,长边压到 maxPixelSize,
  /// JPEG(0.85)返回。
  private static func thumbnail(path: String, maxPixelSize: Int) -> ThumbOutcome {
    guard FileManager.default.fileExists(atPath: path) else {
      return .failed(FlutterError(code: "file_missing", message: "视频文件不存在: \(path)", details: nil))
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    generator.appliesPreferredTrackTransform = true
    do {
      // 本 SDK 的 copyCGImage 直接返回 CGImage(旧版返回 (image, actualTime)
      // 元组,新导入签名已改)。
      let cgImage = try generator.copyCGImage(
        at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
      guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) else {
        return .failed(FlutterError(code: "encode_failed", message: "JPEG 编码失败", details: nil))
      }
      return .ok(jpeg)
    } catch {
      return .failed(FlutterError(code: "thumb_failed", message: "视频抽帧失败: \(error.localizedDescription)", details: nil))
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    guard
      let scene = scenes.first(where: { $0.activationState == .foregroundActive })
        as? UIWindowScene,
      let root = scene.keyWindow?.rootViewController
    else {
      return nil
    }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  private static func presentPlayer(path: String, rate: Double, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "file_missing", message: "视频文件不存在: \(path)", details: nil))
      return
    }
    guard let presenting = topViewController() else {
      result(FlutterError(code: "no_vc", message: "找不到 presenting VC", details: nil))
      return
    }
    let player = AVPlayer(url: url)
    let playerVC = AVPlayerViewController()
    playerVC.player = player
    if abs(rate - 1.0) > 0.001 {
      // 顺帧预览(conform):变速下音轨无意义,静音(OpenZCine 同款)。
      player.isMuted = true
    }

    // 包一层自带关闭钮的壳:AVPlayerViewController 无 Done,
    // 全屏 modal 也不吃下滑dismiss。
    let host = _CloseHostViewController(playerViewController: playerVC) {
      result(nil)
    }
    host.modalPresentationStyle = .fullScreen
    presenting.present(host, animated: true) {
      player.play()
      if abs(rate - 1.0) > 0.001 {
        player.rate = Float(rate)
      }
    }
  }
}

/// 关闭钮宿主:左上角悬浮 X,点击停播 + dismiss + 回调。
final class _CloseHostViewController: UIViewController {
  private let playerViewController: AVPlayerViewController
  private let onClose: () -> Void
  private var didClose = false

  init(playerViewController: AVPlayerViewController, onClose: @escaping () -> Void) {
    self.playerViewController = playerViewController
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    addChild(playerViewController)
    view.addSubview(playerViewController.view)
    playerViewController.view.frame = view.bounds
    playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    playerViewController.didMove(toParent: self)

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.tintColor = .white
    close.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    close.layer.cornerRadius = 18
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    view.addSubview(close)
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: 36),
      close.heightAnchor.constraint(equalToConstant: 36),
      close.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      close.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
    ])
  }

  @objc private func closeTapped() {
    guard !didClose else { return }
    didClose = true
    playerViewController.player?.pause()
    playerViewController.player = nil
    dismiss(animated: true) { [onClose] in
      onClose()
    }
  }
}

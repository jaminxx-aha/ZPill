// ZPill 视频播放通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/video_player.dart:
// - play({path, rate}):AVPlayer 播放本地文件,全屏 present。AVPlayerViewController
//   自带播放控制(进度/音量/全屏),补一个左上关闭钮(原生播放器没有
//   Done)。**任何途径**的关闭(自家 × / iOS 26 AVKit 自绘 × / 系统
//   dismiss)= 停播 + result(nil)(Dart 侧 Future 于此刻完成,调用方
//   随后删临时档)。rate 非 1 = 顺帧预览(conform,如 60fps 素材
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
// - viewLoad({id, path}):内嵌播放视图装载档案(平台视图
//   `zpill/video-view` 创建后、起播前由 Dart 侧调用 —— 平台视图
//   不走 creationParams 传路径,引擎侧编解码钩子不可靠,见工厂注释)。
// - viewControl({id, playing, rate}):驱动内嵌播放视图(平台视图
//   `zpill/video-view`,图库查看器视频页):起播/暂停 + 顺帧速率。
//   AVPlayerViewController 以子视图进 Flutter 树,原生传输条关闭
//   (播放控制 Flutter 自绘);横滑翻页手势归 Flutter(UiKitView 空
//   gestureRecognizers,拖动由 Flutter 滚动手势认领,点按未被认领才
//   送达原生)。视图销毁 = 暂停 + 摘 player;Dart 侧 dispose 时也显式
//   发一条暂停兜底(引擎销毁时序不保证即时,2026-10-09 退出查看器
//   声音未停复报)。
//
// present 的 VC 取法:iOS 13+ 场景化(SceneDelegate),从
// connectedScenes 取 foregroundActive 的 keyWindow rootVC,再走
// 最顶层 presentedVC;Flutter 的 VC 在栈里。

import AVKit
import Flutter
import UIKit

public final class VideoPlugin: NSObject, FlutterPlugin {
  /// 内嵌播放视图登记表(viewId → 视图;创建/销毁与通道回调都在主线程)。
  static var embeddedViews: [Int64: EmbeddedVideoPlatformView] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zpill/video", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VideoPlugin(), channel: channel)
    registrar.register(
      EmbeddedVideoViewFactory(), withId: "zpill/video-view")
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
    case "viewLoad":
      guard let args = call.arguments as? [String: Any],
            let id = (args["id"] as? NSNumber)?.int64Value,
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "viewLoad 须传 id/path", details: nil))
        return
      }
      // 视图可能正在销毁途 mid-teardown:找不到就静默 OK(Dart 侧不收口)。
      Self.embeddedViews[id]?.load(path: path)
      result(nil)
    case "viewControl":
      guard let args = call.arguments as? [String: Any],
            let id = (args["id"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "bad_args", message: "viewControl 须传 id", details: nil))
        return
      }
      let playing = args["playing"] as? Bool ?? false
      let rate = args["rate"] as? Double ?? 1.0
      // 视图可能正在销毁途 mid-teardown:找不到就静默 OK(Dart 侧不收口)。
      Self.embeddedViews[id]?.apply(playing: playing, rate: rate)
      result(nil)
    case "viewStatus":
      guard let args = call.arguments as? [String: Any],
            let id = (args["id"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "bad_args", message: "viewStatus 须传 id", details: nil))
        return
      }
      // 视图销毁竞态:回 null(Dart 侧按 0/0/false 兜底)。
      result(Self.embeddedViews[id]?.status())
    case "viewSeek":
      guard let args = call.arguments as? [String: Any],
            let id = (args["id"] as? NSNumber)?.int64Value,
            let position = args["position"] as? Double else {
        result(FlutterError(code: "bad_args", message: "viewSeek 须传 id/position", details: nil))
        return
      }
      Self.embeddedViews[id]?.seek(to: position)
      result(nil)
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
    dismiss(animated: true)
  }

  // 任何途径的收场都停播 + 收口:自家 × 之外,iOS 26 的 AVKit 在全屏
  // modal 语境还会自绘一排控制(左上含 ×,「双 ×」旧患)—— 点那个 ×
  // 只 dismiss 宿主、不走 closeTapped → 声音继续、result 悬挂、临时档
  // 永不删(2026-10-09 真机复报)。统一在宿主消失钩子收尾,一次性。
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isBeingDismissed, !didClose else { return }
    didClose = true
    playerViewController.player?.pause()
    playerViewController.player = nil
    onClose()
  }
}

/// 内嵌播放平台视图工厂:不带 creationParams —— 实测引擎不把
/// creationParams 送给工厂(createArgsCodec 可选钩子的 @objc 可见性
/// 不可靠,2026-10-09 模拟器探针实证 rawArgs=nil → player=nil → 黑页
/// 无法播放),档案路径改走 viewLoad 通道(onPlatformViewCreated 后
/// Dart 侧显式装载,方法通道 FIFO 时序有保证;Android/ohos 将来同路)。
final class EmbeddedVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    EmbeddedVideoPlatformView(viewId: viewId)
  }
}

/// 内嵌播放视图:AVPlayerViewController 以子视图进 Flutter 树(图库
/// 查看器视频页)。档案装载(viewLoad)、起播/暂停/顺帧速率
/// (viewControl)、进度(viewStatus/viewSeek)全走方法通道,由 Dart
/// 侧 _VideoPage 驱动(翻页离场即暂停)。非全屏子视图上下文,AVKit
/// 不画自家关闭钮(全屏 modal 语境才画,与 _CloseHostViewController
/// 的关闭钮叠加成双 × 的老问题不复发)。
final class EmbeddedVideoPlatformView: NSObject, FlutterPlatformView {
  private let viewId: Int64
  private var player: AVPlayer?
  private let controller = AVPlayerViewController()

  init(viewId: Int64) {
    self.viewId = viewId
    self.player = nil // viewLoad 装载前:黑底空视图
    // 播放控制由 Flutter 侧自绘(Dart _VideoPage):原生传输条关掉,
    // 横滑手势才归 PageView 翻页、点按归 Flutter 切控制浮层。
    controller.showsPlaybackControls = false
    super.init()
    VideoPlugin.embeddedViews[viewId] = self
  }

  func view() -> UIView {
    controller.view
  }

  func dispose() {
    player?.pause()
    controller.player = nil
    VideoPlugin.embeddedViews.removeValue(forKey: viewId)
  }

  /// 装载档案(Dart 侧 onPlatformViewCreated 后调用;仅首次生效,
  /// 翻回同页复用同一视图)。文件缺失保持黑底(Dart 侧另有海报帧兜底)。
  func load(path: String) {
    guard player == nil, FileManager.default.fileExists(atPath: path) else {
      return
    }
    let p = AVPlayer(url: URL(fileURLWithPath: path))
    player = p
    controller.player = p
  }

  /// 起播/暂停 + 速率(顺帧):rate != 1 静音(变速下音轨无意义,
  /// OpenZCine conform 同款)。playing 时 rate != 1 用 rate 直接起播
  /// (play() 后再设 rate 会有 1× 起步闪一下)。
  func apply(playing: Bool, rate: Double) {
    guard let player else { return }
    player.isMuted = abs(rate - 1.0) > 0.001
    if playing {
      if abs(rate - 1.0) > 0.001 {
        player.rate = Float(rate)
      } else {
        player.play()
      }
    } else {
      player.pause()
    }
  }

  /// 播放控制的轮询数据(位置/时长秒 + 是否在播)。时长未就绪/直传流
  /// (CMTime 非数值)= 0,Dart 侧按无进度条处理。
  func status() -> [String: Any] {
    guard let player else {
      return ["position": 0.0, "duration": 0.0, "playing": false]
    }
    let current = player.currentTime().seconds
    let dur = player.currentItem?.duration.seconds ?? 0
    return [
      "position": current.isFinite ? current : 0.0,
      "duration": dur.isFinite ? dur : 0.0,
      "playing": player.timeControlStatus == .playing,
    ]
  }

  func seek(to seconds: Double) {
    // 零容差精确档:默认 seek(to:) 是高效档,会吸附到目标前方最近的
    // 关键帧(最多偏一个 GOP)—— 拖进度条落点回跳、重放回 0 不在 0,
    // 全屏位置搬运时进度条凭空剩一截「没播完」。本地档解码回溯代价
    // 可忽略,一律精确落点。
    player?.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero)
  }
}

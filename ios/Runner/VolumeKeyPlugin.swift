// ZPill 音量键快门通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/volume_keys.dart:
// MethodChannel `zpill/volume`:Dart → 原生 'setEnabled'(bool),
// 原生 → Dart 'onVolumeKey'({'key': "up"|"down"})。
//
// iOS 系统不把音量键事件发给应用,唯一可观察面是系统音量本身:
// - 检测:KVO AVAudioSession.outputVolume(公开文档路径,主沿)+
//   未公开 SystemVolumeDidChange 通知兜底(音量顶/底再按同向键时
//   outputVolume 不变、KVO 不响,通知仍会到;两路喂同一去抖,同一
//   按压只会出一次)。通知沿 Reason=ExplicitVolumeChange 才算。
// - 藏 HUD + 回吸:MPVolumeView 挂进 keyWindow(1×1pt、近透明)压
//   掉系统音量条;其内部 slider 在每次触发后把音量写回「锚点」——
//   锚点取用户当前音量并向两端各留 1/16 余量,任意方向一步都会离开
//   锚点即被识别,连按也不会把音量推进顶/底死区(回吸手法 = 每按
//   一次吸回,音量恒在锚点 ± 一步)。
// - 假阳性防线:回吸自身引发的音量沿(值≈锚点 / 落在自写窗)吞掉;
//   0.6s 去抖窗内重复沿算一次按压;音频路由变更(插拔耳机)音量跳
//   变 ≠ 按键 —— 0.8s 抑制窗 + 重取锚点重挂视图;app 非 active
//   (后台/控制中心拖音量)不触发。
// - 会话:启用即激活 .playback 音频会话(音量键才会调「媒体音量」
//   而非铃声,mixWithOthers 不打断其他声音);停用经 slider 把各路
//   由音量还原到启用前值再 deactivate。
// - 静音键:铃/静音不影响 outputVolume,行为一致(真机再核)。
//
// 手法借自 OpenZCine BluetoothShutterMonitor(Apache-2.0,已过审上
// 架);按本仓插件风格重写为 MethodChannel 单文件。
//
// 契约语义:setEnabled(true) 装观察者/回吸,false 拆掉还原;app 存
// 活期插件实例恒在(addMethodCallDelegate 持引),enable/disable 幂等。

import AVFoundation
import Flutter
import MediaPlayer
import UIKit

public final class VolumeKeyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zpill/volume", binaryMessenger: registrar.messenger())
    let instance = VolumeKeyPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  /// 反向推送口(原生 → Dart 'onVolumeKey')。
  private let channel: FlutterMethodChannel

  // MARK: - 判定窗常量(OpenZCine 实证值)

  /// iOS 音量一步 = 1/16:锚点向两端各留一步,同向连按仍有沿可走。
  private static let step: Float = 1.0 / 16.0
  /// 一次物理按压的重复沿窗(蓝牙遥控器一按发两报文;长按连发也靠它收敛)。
  private static let debounce: TimeInterval = 0.6
  /// 自己回吸写音量后的回声窗:窗内沿一律不算按键。
  private static let echoWindow: TimeInterval = 0.4
  /// 音频路由变更后的抑制窗:插/拔耳机音量跳变不是按键。
  private static let routeQuiet: TimeInterval = 0.8
  /// KVO/通知到达序不保证:延迟一拍再判定,给路由抑制窗先落地的时间。
  private static let settleDelay: TimeInterval = 0.1
  /// Float 音量值直等不可靠,统一容差比较。
  private static let epsilon: Float = 0.001
  /// 未公开系统通知名(仅作 KVO 的兜底补充,命名/契约随 iOS 版本可能变)。
  private static let volumeNotification = Notification.Name("SystemVolumeDidChange")

  // MARK: - 会话态(全部只在主线程碰)

  private var enabled = false
  /// 回吸锚点 = 用户当前音量向两端各留一步(见 [anchored])。
  private var anchor: Float = 0.5
  /// 当前音频路由签名(路由变更判定:签名变才重挂视图/重取锚点)。
  private var routeSignatureNow = ""
  private var volumeObservation: NSKeyValueObservation?
  private var volumeObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var volumeView: MPVolumeView?
  /// MPVolumeView 内部 slider(唯一可编程写系统音量的口子)。
  private var volumeSlider: UISlider?
  /// slider 轮询计数(0 = 无轮询链在跑,>0 兼作代际闸防双链)。
  private var sliderPolls = 0
  /// 路由抑制窗截止时刻。
  private var quietUntil: TimeInterval = 0
  private var lastTriggerAt: TimeInterval = 0
  private var lastEchoWriteAt: TimeInterval = 0
  /// 每路由启用前音量(耳机/扬声器各有各的音量),停用逐路由还原。
  private var restoreVolumes: [String: Float] = [:]

  deinit {
    // 兜底(实践不可达:addMethodCallDelegate 恒持本实例):只清非
    // UIKit 资源,离主线程也安全;视图拆除/会话停用丢回主线程。
    volumeObservation?.invalidate()
    if let observer = volumeObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
    let view = volumeView
    let session = AVAudioSession.sharedInstance()
    DispatchQueue.main.async {
      view?.removeFromSuperview()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  // MARK: - FlutterPlugin

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setEnabled":
      // 载荷即布尔(Android 同契约);失败也回成功 —— 静默降级,
      // 音量键本就可能归系统,Dart 侧零错误路径。
      if call.arguments as? Bool ?? false {
        enable()
      } else {
        disable()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 启停

  private func enable() {
    guard !enabled else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback:音量键调媒体音量(outputVolume 才会动、HUD 才归
      // MPVolumeView 管);mixWithOthers:不打断用户正在放的其他声音。
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      // 会话起不来 = 音量观察面不可用:不开观察,静默降级。
      return
    }
    enabled = true
    routeSignatureNow = Self.routeSignature(session)
    restoreVolumes[routeSignatureNow] = session.outputVolume
    anchor = Self.anchored(session.outputVolume)
    installVolumeView()
    beginSliderAcquisition()
    // 公开文档的观察路径,主检测器。
    volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) {
      [weak self] observed, change in
      let value = change.newValue ?? observed.outputVolume
      DispatchQueue.main.async { self?.volumeChanged(value) }
    }
    // 未公开通知:仅在顶/底不再变值(KVO 哑火)时兜底。
    volumeObserver = NotificationCenter.default.addObserver(
      forName: Self.volumeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let info = note.userInfo,
        info["Reason"] as? String == "ExplicitVolumeChange",
        let volume = Self.asVolume(info["Volume"])
      else { return }
      self?.volumeChanged(volume)
    }
    // 插拔耳机等路由变更:音量跳变不是按键。
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
    ) { [weak self] _ in
      self?.routeChanged()
    }
  }

  /// 拆观察者/视图;restore 时先还原音量再 deactivate。
  private func disable() {
    guard enabled else { return }
    stop(restore: true)
  }

  private func stop(restore: Bool) {
    enabled = false
    sliderPolls = 0
    volumeObservation?.invalidate()
    volumeObservation = nil
    if let observer = volumeObserver { NotificationCenter.default.removeObserver(observer) }
    volumeObserver = nil
    if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
    routeObserver = nil
    if restore, let slider = volumeSlider,
      let volume = restoreVolumes[Self.routeSignature(AVAudioSession.sharedInstance())]
    {
      // slider 已在手:同步还原,趁会话还归本插件持有。
      slider.setValue(volume, animated: false)
    }
    restoreVolumes.removeAll()
    routeSignatureNow = ""
    let view = volumeView
    volumeView = nil
    volumeSlider = nil
    view?.removeFromSuperview()
    if restore {
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    }
  }

  // MARK: - 音量沿判定

  private func volumeChanged(_ value: Float) {
    // KVO 与路由通知的到达序不保证:延迟一拍再判定(通知侧本就在主
    // 队列,dispatch 幂等;KVO 侧此跳即线程收口)。
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
      [weak self] in
      self?.adjudicate(value)
    }
  }

  private func adjudicate(_ value: Float) {
    // 判定窗一拍间可能已停用;后台/被盖时系统音量变化(控制中心)
    // 一律不算按键。
    guard enabled, UIApplication.shared.applicationState == .active else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now < quietUntil {
      // 路由变更抑制窗:跳变不是按键,但要把音量拉回锚点防漂走。
      repinIfDrifted(value, now: now)
      return
    }
    // 回吸落点(自己写的)= 回声,非按键。
    if abs(value - anchor) <= Self.epsilon { return }
    // 自写窗:回声即使没精确落在锚点也不算。
    if now - lastEchoWriteAt < Self.echoWindow { return }
    // 去抖窗:同一次按压的重复沿,拉回锚点防音量漂走。
    if now - lastTriggerAt < Self.debounce {
      repinIfDrifted(value, now: now)
      return
    }
    lastTriggerAt = now
    let key = value > anchor ? "up" : "down"
    writeAnchor()
    channel.invokeMethod("onVolumeKey", arguments: ["key": key])
  }

  /// 非按键沿但音量已偏离锚点(抑制/去抖吞掉的沿):拉回,音量永不
  /// 走向顶/底死区。
  private func repinIfDrifted(_ value: Float, now: TimeInterval) {
    if abs(value - anchor) > Self.epsilon, now - lastEchoWriteAt >= Self.echoWindow {
      writeAnchor()
    }
  }

  // MARK: - 路由变更

  private func routeChanged() {
    guard enabled else { return }
    let session = AVAudioSession.sharedInstance()
    let signature = Self.routeSignature(session)
    quietUntil = CFAbsoluteTimeGetCurrent() + Self.routeQuiet
    if signature == routeSignatureNow {
      // 同路由(类别变更等):只开抑制窗,不重挂。
      return
    }
    routeSignatureNow = signature
    if restoreVolumes[signature] == nil {
      restoreVolumes[signature] = session.outputVolume
    }
    // 每路由各有各的音量:锚点随新路由重取,不跨路由携带。
    anchor = Self.anchored(session.outputVolume)
    // MPVolumeView 的内部 slider 随路由重建:重挂视图 + 重找 slider。
    volumeSlider = nil
    let view = volumeView
    volumeView = nil
    view?.removeFromSuperview()
    installVolumeView()
    beginSliderAcquisition()
  }

  // MARK: - MPVolumeView(HUD 压制 + 可编程写口)

  /// MPVolumeView 挂进 keyWindow 才压得住系统音量 HUD(离屏不行);
  /// 1×1pt、近透明、禁交互 —— 功能件不是 UI。
  private func installVolumeView() {
    guard volumeView == nil,
      let window = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return }
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    view.alpha = 0.02
    view.clipsToBounds = true
    view.isUserInteractionEnabled = false
    window.addSubview(view)
    volumeView = view
  }

  /// MPVolumeView 的 slider 子视图是异步长出来的(挂进层级后才会
  /// 建),立即找找不到 —— 轮询直到出现;找到即回吸一次(启用时刻
  /// 用户音量可能正在顶/底,先拉回保证双向都有沿)。20 次后转 1s
  /// 慢轮兜底(场景就绪慢)。
  private func beginSliderAcquisition() {
    guard volumeSlider == nil, sliderPolls == 0 else { return }
    sliderPolls = 1
    pollForSlider()
  }

  private func pollForSlider() {
    guard enabled, volumeSlider == nil else {
      sliderPolls = 0
      return
    }
    if volumeView == nil { installVolumeView() }
    if let view = volumeView, let slider = Self.firstSlider(in: view) {
      volumeSlider = slider
      sliderPolls = 0
      writeAnchor()
      return
    }
    sliderPolls += 1
    let delay: TimeInterval = sliderPolls <= 20 ? 0.15 : 1.0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.pollForSlider()
    }
  }

  /// 把系统音量写回锚点(回吸)。slider 刚出现的一拍内写入会被吃掉,
  /// 短延时后再写;写动作自身引发的音量沿由 adjudicate 的
  /// 落锚/自写窗吞掉。无 slider(未长出/路由重建中)= 写不进,靠
  /// 锚点余量 + 通知兜底扛到 slider 就位。
  private func writeAnchor() {
    lastEchoWriteAt = CFAbsoluteTimeGetCurrent()
    guard let slider = volumeSlider else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      [weak self, weak slider] in
      guard let self, let slider, self.enabled else { return }
      slider.setValue(self.anchor, animated: false)
    }
  }

  // MARK: - 纯工具

  /// 锚点 = 当前音量向两端各留一步:音量到顶/底再按同向键
  /// outputVolume 不变 = 死区,留一步 = 双向任意按都有沿。
  private static func anchored(_ volume: Float) -> Float {
    min(max(volume, step), 1 - step)
  }

  /// 每路由签名(耳机/扬声器各有各的音量)。
  private static func routeSignature(_ session: AVAudioSession) -> String {
    session.currentRoute.outputs
      .map { "\($0.portType.rawValue):\($0.uid)" }
      .sorted()
      .joined(separator: "|")
  }

  /// 通知载荷里的音量值随 iOS 版本在 Float/Double/NSNumber 间漂,
  /// 逐型收口。
  private static func asVolume(_ raw: Any?) -> Float? {
    switch raw {
    case let value as Float: return value
    case let value as Double: return Float(value)
    case let value as NSNumber: return value.floatValue
    default: return nil
    }
  }

  private static func firstSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    for subview in view.subviews {
      if let slider = firstSlider(in: subview) { return slider }
    }
    return nil
  }
}

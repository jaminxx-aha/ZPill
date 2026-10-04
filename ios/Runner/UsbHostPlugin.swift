// NikonPill USB 通道(iOS 平台,native 侧)—— ImageCaptureCore 实现。
//
// 路线抉择(2026-10-03/04 实证):DriverKit dext 需付费开发者账号;
// 沙盒 App 直连 IOKit(IOServiceOpen USB 节点)被拒 kIOReturnNotPermitted。
// ImageCaptureCore 公开 API(iOS 13+)经 TCC 授权
// (kTCCServiceExternalCameraMedia_iOS,Info.plist 的 NSCameraUsageDescription)
// 即可枚举 USB 相机、收发原始 PTP 命令 —— 免费个人团队可用,真机已验证。
//
// 对应 Dart 契约 lib/platform/usb/usb_host.dart(`nikonpill/usb`):
// - listCameras → ICDeviceBrowser 枚举 USB 相机,过滤 VID=0x04B0,
//   identifier = ICDevice.uuidString(Dart 只透传);
// - open(identifier) → requestContentsAuthorization(首次 TCC 弹窗,
//   listCameras 已就绪)+ requestControlAuthorization + requestOpenSession;
// - bulkOut/bulkRead → IcPtpSession 容器翻译适配器(见下);
// - close → requestCloseSession。
//
// requestSendPTPCommand 字节格式(2026-10-04 macOS + Zf 实测,/tmp/icprobe):
// - command = **完整命令容器**(u32 len + u16 type=1 + u16 code + u32 txid
//   + params);裸命令块(无容器头)被守护进程静默忽略(err=nil 但零字节);
// - outData = 数据出相位裸负载(应用 v1 无 dataOut 命令);
// - responseData = **裸数据负载**(无容器头);
// - ptpResponseData = **完整响应容器**(type=3),但 txid 是守护进程自己的
//   事务号(它还会夹自己的枚举流量)→ 适配器改写 txid 为本事务号,
//   否则 Dart 传输层的 txid 校验必炸;
// - IC 守护进程自持 PTP 会话:直发 OpenSession(0x1002)相机会回
//   0x201E SessionAlreadyOpen → 拦截 0x1002/0x1003 伪造 OK 响应,
//   真实会话生命周期归 requestOpenSession/requestCloseSession。
//
// bulkRead 契约(对齐 ohos):至多 maxLen、≥1 字节或 usb_timeout;
// 完整事务响应序列(data 容器 + response 容器)在完成时一次性入缓冲,
// 之后每次 bulkRead 从缓冲切片返回 —— 无超读,Dart 的 _take 循环不会饥饿。
//
// 线程模型:方法调用一律 hop 到 usbQueue(串行,与 Dart 事务串行同构);
// IC 调用在主线程发起(守护进程回调依赖主 runloop 泵,真机探针验证过的
// 结构),usbQueue 只等信号量 —— 主线程永不被阻塞,无死锁。

import Flutter
import Foundation
import ImageCaptureCore

private let kNikonUsbVendorId = 0x04B0


// PTP 容器与操作码(lib/core/ptpusb/containers.dart 的镜像,改那边须同步)。
private let kContainerHeaderLength = 12
private let kContainerTypeCommand: UInt16 = 1
private let kContainerTypeData: UInt16 = 2
private let kContainerTypeResponse: UInt16 = 3
private let kOpcodeOpenSession: UInt16 = 0x1002
private let kOpcodeCloseSession: UInt16 = 0x1003
private let kResponseOk: UInt16 = 0x2001
private let kResponseSessionAlreadyOpen: UInt16 = 0x201E

// staging 里单个容器的长度上限:命令/属性数据远小于此,超了即流错位。
private let kMaxStagedContainerBytes = 64 * 1024 * 1024

private enum UsbError: Error {
  case timeout
  case closed(message: String)
  case platform(code: String, message: String)

  var flutterError: FlutterError {
    switch self {
    case .timeout:
      return FlutterError(code: "usb_timeout", message: "bulkRead 窗口内未收到数据", details: nil)
    case .closed(let message):
      return FlutterError(code: "usb_closed", message: message, details: nil)
    case .platform(let code, let message):
      return FlutterError(code: code, message: message, details: nil)
    }
  }
}

// ── 小端读写 ─────────────────────────────────────────────────────

private func u16le(_ d: Data, _ off: Int) -> UInt16 {
  return UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
}

private func u32le(_ d: Data, _ off: Int) -> UInt32 {
  return UInt32(d[d.startIndex + off]) | (UInt32(d[d.startIndex + off + 1]) << 8)
    | (UInt32(d[d.startIndex + off + 2]) << 16) | (UInt32(d[d.startIndex + off + 3]) << 24)
}

// 数组版(0 基,恒安全)。staging 必须用 [UInt8] 而非 Data:
// Data.removeFirst 后 startIndex 不归零,后续 0 基 subdata 会越界 trap
// (2026-10-04 真机崩溃实证)。
private func u16le(_ d: [UInt8], _ off: Int) -> UInt16 {
  return UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
}

private func u32le(_ d: [UInt8], _ off: Int) -> UInt32 {
  return UInt32(d[off]) | (UInt32(d[off + 1]) << 8) | (UInt32(d[off + 2]) << 16) | (UInt32(d[off + 3]) << 24)
}

private func appendU16(_ v: UInt16, to out: inout [UInt8]) {
  out.append(UInt8(v & 0xFF))
  out.append(UInt8((v >> 8) & 0xFF))
}

private func appendU32(_ v: UInt32, to out: inout [UInt8]) {
  out.append(UInt8(v & 0xFF))
  out.append(UInt8((v >> 8) & 0xFF))
  out.append(UInt8((v >> 16) & 0xFF))
  out.append(UInt8((v >> 24) & 0xFF))
}

/// 伪造的 OK 响应容器(无参数)。
private func synthOkResponse(txid: UInt32) -> [UInt8] {
  var out = [UInt8]()
  appendU32(UInt32(kContainerHeaderLength), to: &out)
  appendU16(kContainerTypeResponse, to: &out)
  appendU16(kResponseOk, to: &out)
  appendU32(txid, to: &out)
  return out
}

/// 把守护进程返回的裸数据负载组成本事务的数据容器。
private func synthDataContainer(opcode: UInt16, txid: UInt32, payload: Data) -> [UInt8] {
  var out = [UInt8]()
  appendU32(UInt32(kContainerHeaderLength + payload.count), to: &out)
  appendU16(kContainerTypeData, to: &out)
  appendU16(opcode, to: &out)
  appendU32(txid, to: &out)
  out.append(contentsOf: payload)
  return out
}

// ── 设备枚举(插件生命周期内常驻) ───────────────────────────────

/// ICDeviceBrowser 单例:授权、启动浏览、维护当前相机快照。
/// 回调来自 IC 队列,状态一律加锁。
private final class CameraStore: NSObject, ICDeviceBrowserDelegate {
  static let shared = CameraStore()

  let browser = ICDeviceBrowser()
  private let lock = NSLock()
  private var _cameras: [ICCameraDevice] = []
  private var _startRequested = false
  private var _firstDiscoveryWaited = false
  var onDeviceRemoved: ((String) -> Void)?

  /// 主线程调用:授权(首次弹 TCC)→ 开始浏览。
  func startIfNeeded() {
    lock.lock()
    if _startRequested {
      lock.unlock()
      return
    }
    _startRequested = true
    lock.unlock()

    browser.delegate = self
    if browser.contentsAuthorizationStatus == .authorized {
      browser.start()
    } else {
      browser.requestContentsAuthorization { [weak self] status in
        guard let self = self, status == .authorized else { return }
        self.browser.start()
      }
    }
  }

  var cameras: [ICCameraDevice] {
    lock.lock()
    defer { lock.unlock() }
    return _cameras
  }

  func camera(withUuid uuid: String) -> ICCameraDevice? {
    return cameras.first { $0.uuidString == uuid }
  }

  /// 尼康 USB 相机快照(listCameras 的数据源)。
  func nikonUsbCameras() -> [ICCameraDevice] {
    return cameras.filter {
      $0.transportType == ICDeviceTransport.transportTypeUSB.rawValue
        && $0.usbVendorID == kNikonUsbVendorId
    }
  }

  /// 仅首次调用阻塞:给授权弹窗与设备发现留窗口;之后立刻返回快照
  /// (会话期看门狗高频轮询 listCameras,不能每次都等)。
  func waitForFirstDiscovery(timeoutMs: Int) {
    lock.lock()
    if _firstDiscoveryWaited {
      lock.unlock()
      return
    }
    lock.unlock()
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
      if !nikonUsbCameras().isEmpty { break }
      usleep(150_000)
    }
    lock.lock()
    _firstDiscoveryWaited = true
    lock.unlock()
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let camera = device as? ICCameraDevice else { return }
    lock.lock()
    _cameras.append(camera)
    lock.unlock()
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    guard let camera = device as? ICCameraDevice else { return }
    lock.lock()
    _cameras.removeAll { $0.uuidString == camera.uuidString }
    lock.unlock()
    onDeviceRemoved?(camera.uuidString ?? "")
  }
}

// ── 会话期设备委托 ───────────────────────────────────────────────

/// IC 文档要求:不设 delegate,请求会被静默忽略。除拔出外全部 no-op
/// (内容目录、缩略图、元数据都走我们自己的 PTP 通道,不用 IC 的封装)。
/// didReceivePTPEvent 的事件字节格式未实证(v1 无 interrupt 订阅者),
/// 遥控拍摄落地时再补格式翻译。
private final class DeviceDelegate: NSObject, ICDeviceDelegate, ICCameraDeviceDelegate {
  var onRemoved: (() -> Void)?

  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
  func didRemove(_ device: ICDevice) {
    onRemoved?()
  }
  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
    for item: ICCameraItem, error: Error?
  ) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem, error: Error?
  ) {}
  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// ── PTP 容器翻译会话 ─────────────────────────────────────────────

/// 把 Dart 的 bulkOut/bulkRead 字节管道契约翻译到
/// requestSendPTPCommand(command, outData) 单调用模型:
/// - bulkOut 攒容器:命令容器 → 待发命令;数据容器 → 待发 outData;
/// - bulkRead 首次触发 IC 调用,完成时把 [数据容器(合成) + 响应容器
///   (txid 改写)] 整体入缓冲,后续调用从缓冲切片;
/// - OpenSession/CloseSession 被拦截,直接伪造 OK(守护进程自持会话,
///   直发会得到 0x201E;真实开关在 requestOpen/CloseSession);
/// - 相机拔出(didRemove)→ 在途等待立即以 usb_error 结束。
private final class IcPtpSession {
  let camera: ICCameraDevice
  let cameraUuid: String
  private let deviceDelegate = DeviceDelegate()

  private let lock = NSLock()
  private var staging = [UInt8]()
  private var pendingCommand: Data?
  private var pendingOpcode: UInt16 = 0
  private var pendingTxid: UInt32 = 0
  private var pendingOutData: Data?
  private var responseBuffer = [UInt8]()
  private var responseOffset = 0
  private var removed = false

  // 在途 IC 调用的完成状态(与 lock 配套;信号量一次性)
  private var inFlight = false
  private var completionArrived = false
  private var completionError: Error?
  private var completionResponse: Data?
  private var completionPtpResponse: Data?
  private let completionSem = DispatchSemaphore(value: 0)

  init?(camera: ICCameraDevice) {
    self.camera = camera
    self.cameraUuid = camera.uuidString ?? ""
    if self.cameraUuid.isEmpty { return nil }
  }

  /// 主线程发起授权 + 开会话;usbQueue 等待。返回错误文案或 nil。
  func open(timeoutMs: Int) -> String? {
    deviceDelegate.onRemoved = { [weak self] in
      self?.markRemoved()
    }
    let sem = DispatchSemaphore(value: 0)
    var openError: String?
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        sem.signal()
        return
      }
      self.camera.delegate = self.deviceDelegate
      CameraStore.shared.browser.requestControlAuthorization { _ in
        self.camera.requestOpenSession(options: nil) { error in
          openError = error.map { "\($0)" }
          sem.signal()
        }
      }
    }
    if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
      return "打开相机会话超时"
    }
    return openError
  }

  /// 主线程关会话并等待完成(重连前确保旧会话收干净)。
  func close(timeoutMs: Int) {
    lock.lock()
    removed = true
    lock.unlock()
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        sem.signal()
        return
      }
      self.camera.requestCloseSession(options: nil) { _ in
        sem.signal()
      }
      self.camera.delegate = nil
    }
    _ = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
  }

  func markRemoved() {
    lock.lock()
    removed = true
    let shouldWake = inFlight
    lock.unlock()
    if shouldWake {
      completionSem.signal()
    }
  }

  /// bulkOut:攒容器 + 命令拦截。
  func bulkOut(_ bytes: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    if removed {
      throw UsbError.platform(code: "usb_error", message: "相机已断开")
    }
    staging.append(contentsOf: bytes)
    while staging.count >= kContainerHeaderLength {
      let length = Int(u32le(staging, 0))
      if length < kContainerHeaderLength || length > kMaxStagedContainerBytes {
        throw UsbError.platform(code: "usb_error", message: "容器长度字段非法(\(length)),流错位")
      }
      if staging.count < length { break }  // 未攒满,等后续 bulkOut
      let type = u16le(staging, 4)
      let code = u16le(staging, 6)
      let txid = u32le(staging, 8)
      if type == kContainerTypeCommand {
        // 新命令开启新事务:上一事务若中途夭折(超时/上层异常),未消费
        // 完的帧已作废 —— 丢弃,否则下一事务首读会吃到旧载荷被当容器头
        // 解析(真机实证:残帧污染,txid 校验连败触发看门狗断链)。
        if responseOffset < responseBuffer.count {
          responseBuffer.removeAll(keepingCapacity: false)
          responseOffset = 0
        }
        // OpenSession/CloseSession 拦截:守护进程自持 PTP 会话,直发
        // OpenSession 得 0x201E;CloseSession 会关掉守护进程的会话。
        // 伪造 OK,真实生命周期归 requestOpen/CloseSession。
        if code == kOpcodeOpenSession || code == kOpcodeCloseSession {
          responseBuffer.append(contentsOf: synthOkResponse(txid: txid))
        } else {
          pendingCommand = Data(staging[0..<length])
          pendingOpcode = code
          pendingTxid = txid
          pendingOutData = nil
        }
      } else if type == kContainerTypeData {
        pendingOutData = (pendingOutData ?? Data()) + Data(staging[kContainerHeaderLength..<length])
      } else {
        throw UsbError.platform(code: "usb_error", message: "bulk OUT 收到意外容器 type=\(type)")
      }
      staging.removeFirst(length)
    }
  }

  /// bulkRead:缓冲切片;缓冲空则发出待发命令并等待 IC 完成。
  func bulkRead(maxLen: Int, timeoutMs: Int) throws -> [UInt8] {
    lock.lock()
    if removed {
      lock.unlock()
      throw UsbError.platform(code: "usb_error", message: "相机已断开")
    }
    if responseOffset < responseBuffer.count {
      let take = min(maxLen, responseBuffer.count - responseOffset)
      let out = Array(responseBuffer[responseOffset..<(responseOffset + take)])
      responseOffset += take
      if responseOffset == responseBuffer.count {
        responseBuffer.removeAll(keepingCapacity: false)
        responseOffset = 0
      }
      lock.unlock()
      return out
    }
    guard let command = pendingCommand else {
      lock.unlock()
      throw UsbError.timeout
    }
    pendingCommand = nil
    let outData = pendingOutData
    pendingOutData = nil
    let opcode = pendingOpcode
    let txid = pendingTxid
    inFlight = true
    completionArrived = false
    completionError = nil
    completionResponse = nil
    completionPtpResponse = nil
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.camera.requestSendPTPCommand(command, outData: outData) {
        responseData, ptpResponseData, error in
        self.lock.lock()
        if self.inFlight {
          self.completionResponse = responseData
          self.completionPtpResponse = ptpResponseData
          self.completionError = error
          self.completionArrived = true
          self.inFlight = false
          self.completionSem.signal()
        }
        self.lock.unlock()
      }
    }

    _ = completionSem.wait(timeout: .now() + .milliseconds(timeoutMs))

    lock.lock()
    if !completionArrived {
      inFlight = false  // 迟到完成会被上面的 inFlight 检查丢弃
      let wasRemoved = removed
      lock.unlock()
      if wasRemoved {
        throw UsbError.platform(code: "usb_error", message: "相机已断开(USB 连接消失)")
      }
      throw UsbError.timeout
    }
    let response = completionResponse
    let ptpResponse = completionPtpResponse
    let error = completionError
    completionArrived = false
    lock.unlock()

    if let error = error {
      throw UsbError.platform(code: "usb_error", message: "PTP 命令失败:\(error)")
    }
    guard let ptp = ptpResponse, ptp.count >= kContainerHeaderLength,
      u16le(ptp, 4) == kContainerTypeResponse
    else {
      throw UsbError.platform(code: "usb_error", message: "守护进程返回空/畸形响应容器")
    }

    var frame = [UInt8]()
    if let response = response, !response.isEmpty {
      frame += synthDataContainer(opcode: opcode, txid: txid, payload: response)
    }
    frame += ptp
    // 守护进程用自己的事务号重发命令,响应容器 txid 与本事务不符 ——
    // 改写为本事务号,Dart 传输层按 txid 校验容器归属。
    let txidLE = txid
    for i in 0..<4 {
      frame[frame.count - ptp.count + 8 + i] = UInt8((txidLE >> (8 * UInt32(i))) & 0xFF)
    }
    lock.lock()
    responseBuffer = frame
    responseOffset = 0
    lock.unlock()
    return try bulkRead(maxLen: maxLen, timeoutMs: timeoutMs)
  }
}

// ── Flutter 插件 ─────────────────────────────────────────────────

public final class UsbHostPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let usbQueue = DispatchQueue(label: "nikonpill.usb")
  private var session: IcPtpSession?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "nikonpill/usb", binaryMessenger: registrar.messenger())
    let instance = UsbHostPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "nikonpill/usb/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listCameras":
      usbQueue.async {
        result(self.listCamerasLocked())
      }
    case "open":
      let identifier = (call.arguments as? [String: Any])?["identifier"] as? String ?? ""
      usbQueue.async {
        self.openLocked(identifier: identifier, result: result)
      }
    case "bulkOut":
      let bytes = (call.arguments as? [String: Any])?["bytes"] as? FlutterStandardTypedData
      usbQueue.async {
        guard let session = self.session, let bytes = bytes else {
          result(UsbError.closed(message: "USB 会话未打开").flutterError)
          return
        }
        do {
          try session.bulkOut(bytes.data)
          result(nil)
        } catch let e as UsbError {
          result(e.flutterError)
        } catch {
          result(UsbError.platform(code: "usb_error", message: "\(error)").flutterError)
        }
      }
    case "bulkRead":
      let args = call.arguments as? [String: Any]
      let maxLen = args?["maxLen"] as? Int ?? 0
      let timeoutMs = args?["timeoutMs"] as? Int ?? 0
      usbQueue.async {
        guard let session = self.session, maxLen > 0, timeoutMs > 0 else {
          result(UsbError.closed(message: "USB 会话未打开").flutterError)
          return
        }
        do {
          // 必须 FlutterStandardTypedData 回传:裸 [UInt8] 桥接 NSArray、
          // codec 落成 List<dynamic>,Dart 侧 invokeMethod<Uint8List> 强转
          // TypeError —— 属 Error 非 Exception,逃逸 connect 的 catch,
          // 状态机永远停在 connecting(真机实证:连接无限转圈的根因)。
          result(FlutterStandardTypedData(
            bytes: Data(try session.bulkRead(maxLen: maxLen, timeoutMs: timeoutMs))))
        } catch let e as UsbError {
          result(e.flutterError)
        } catch {
          result(UsbError.platform(code: "usb_error", message: "\(error)").flutterError)
        }
      }
    case "close":
      usbQueue.async {
        let old = self.session
        self.session = nil
        old?.close(timeoutMs: 10_000)
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // v1 无 interrupt 事件订阅者(拍摄检测未启用);IC 的事件字节格式
  // 未实证,如实 no-op,遥控拍摄落地时再接 didReceivePTPEvent。
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }

  // ── usbQueue 串行段 ─────────────────────────────────────────────

  private func listCamerasLocked() -> [[String: Any]] {
    DispatchQueue.main.async { CameraStore.shared.startIfNeeded() }
    CameraStore.shared.waitForFirstDiscovery(timeoutMs: 10_000)
    let found = CameraStore.shared.nikonUsbCameras()
    return found.map { camera in
      [
        "vendorId": Int(camera.usbVendorID),
        "productId": Int(camera.usbProductID),
        "identifier": camera.uuidString ?? "",
      ]
    }
  }

  private func openLocked(identifier: String, result: @escaping FlutterResult) {
    session = nil
    CameraStore.shared.onDeviceRemoved = { [weak self] uuid in
      guard let self = self, let current = self.session, current.cameraUuid == uuid else { return }
      current.markRemoved()
    }
    guard let camera = CameraStore.shared.camera(withUuid: identifier) else {
      result(
        UsbError.platform(code: "usb_error", message: "未找到相机(可能已拔出)").flutterError)
      return
    }
    guard let newSession = IcPtpSession(camera: camera) else {
      result(UsbError.platform(code: "usb_error", message: "相机标识无效").flutterError)
      return
    }
    if let openError = newSession.open(timeoutMs: 20_000) {
      result(UsbError.platform(code: "usb_error", message: "打开相机会话失败:\(openError)").flutterError)
      return
    }
    session = newSession
    result(nil)
  }
}

// ZPill mDNS 相机发现(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/nsd_scanner.dart(`zpill/nsd` +
// `zpill/nsd/events`):浏览 `_ptp._tcp.` 并解析出 IP/端口/TXT,
// found/lost 事件经 EventChannel 上报。
//
// 路线抉择:**NetServiceBrowser + NetService**(纯 DNS-SD),不用
// NWBrowser —— Network.framework 没有"只解析不连接"的 API,要拿 IP
// 只能 NWConnection 真连 15740,而相机是单连接服务器,探测性 TCP 连接
// 会被它保持(等 Init)并导致后续连接被拒(呛住),本仓探针实证过。
// NetService.resolve 走 mDNSResponder 的 SRV/TXT/A 查询,相机侧零感知。
// (NSNetService 的 socket 收发方法自 iOS 13 起废弃,浏览/解析未废弃;
// 若未来 SDK 移除,后备方案是 dnssd C API:DNSServiceBrowse/Resolve/
// GetAddrInfo,语义一一对应。)
//
// Info.plist 前提:NSBonjourServices 声明 `_ptp._tcp`(iOS 14+ 未声明
// 时浏览被系统静默拦截);首次浏览触发本地网络权限弹窗(与 PTP-IP
// 连接共用 NSLocalNetworkUsageDescription)。
//
// 线程模型:Flutter 方法回调与 NetService 委托都在主线程;DNS 解析由
// 系统进程异步完成,主线程只做字典搬运。

import Flutter
import Foundation

private let kServiceType = "_ptp._tcp."
private let kLocalDomain = "local."
private let kResolveTimeout: TimeInterval = 5

final class NsdPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let browser = NetServiceBrowser()
  private var sink: FlutterEventSink?
  /// 正在解析/已解析的服务,按实例名去重(浏览器可能重复上报)。
  private var services: [String: NetService] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NsdPlugin()
    let methods = FlutterMethodChannel(
      name: "zpill/nsd", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "zpill/nsd/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  // MARK: - MethodChannel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      // 幂等:先停旧浏览(委托清空,不再发 lost),再重新起。
      stopBrowsing()
      browser.delegate = self
      browser.searchForServices(ofType: kServiceType, inDomain: kLocalDomain)
      result(nil)
    case "stop":
      stopBrowsing()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stopBrowsing() {
    browser.stop()
    for service in services.values {
      service.delegate = nil
      service.stop()
    }
    services.removeAll()
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    stopBrowsing()
    return nil
  }

  private func emit(_ payload: [String: Any?]) {
    // Dart 侧可能尚未挂监听(先 start 后 listen 的窗口):事件丢弃即可,
    // found 会随 mDNS 周期重播而再来。
    sink?(payload)
  }
}

// MARK: - NetServiceBrowserDelegate(浏览)

extension NsdPlugin: NetServiceBrowserDelegate {
  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    guard !service.name.isEmpty else { return }
    if services[service.name] != nil { return }  // 去重
    services[service.name] = service
    service.delegate = self
    service.resolve(withTimeout: kResolveTimeout)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
  ) {
    guard let known = services.removeValue(forKey: service.name) else { return }
    known.delegate = nil
    known.stop()
    emit(["event": "lost", "name": service.name])
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber])
  {
    // 常见原因:本地网络权限被拒 / 当前无 Wi-Fi。不上抛报错流,静默即可
    // (UI 层表现为扫不到,引导用户检查网络与权限)。
  }
}

// MARK: - NetServiceDelegate(解析:纯 DNS,不连相机)

extension NsdPlugin: NetServiceDelegate {
  func netServiceDidResolveAddress(_ sender: NetService) {
    // 取 IPv4(相机 AP/STA 均为 v4;v6 备选)。
    var host = sender.hostName ?? ""
    for data in sender.addresses ?? [] where data.count >= MemoryLayout<sockaddr_in>.size {
      let sin = data.withUnsafeBytes { $0.load(as: sockaddr_in.self) }
      guard sin.sin_family == sa_family_t(AF_INET) else { continue }
      var addr = sin.sin_addr
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
        host = String(cString: buf)
        break
      }
    }
    var txt: [String: String] = [:]
    if let data = sender.txtRecordData() {
      for (key, value) in NetService.dictionary(fromTXTRecord: data) {
        txt[key] = String(data: value, encoding: .utf8) ?? ""
      }
    }
    emit([
      "event": "found",
      "name": sender.name,
      "host": host,
      "port": Int(sender.port),
      "txt": txt,
    ])
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    // 解析失败(服务消失/IPv6-only 等):从记账里摘掉,等 mDNS 重播再试。
    if let known = services.removeValue(forKey: sender.name) {
      known.delegate = nil
    }
  }
}

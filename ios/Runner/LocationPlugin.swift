// ZPill 位置采样通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/location_host.dart:
// - MethodChannel `zpill/location` 的 `current` 做一次定位,返回
//   [latitude, longitude](WGS84 十进制度),不可用返回 nil。
// - EventChannel `zpill/location/stream` + `startStream`/`stopStream`
//   连续定位流(BLE GPS 注入用):distanceFilter 3m、后台可续
//   (allowsBackgroundLocationUpdates,配 UIBackgroundModes=location)、
//   不自动暂停;事件载荷 Map{latitude, longitude, altitude}。
// - `requestAlways` 两段式授权第二段(后台注入用),`authStatus` 回当前
//   授权态字符串(未定/使用时/始终/拒绝/受限)。
//
// 流程:授权未定 → requestWhenInUseAuthorization(委托回调里接着
// requestLocation);已授权 → 直接 requestLocation;拒绝/受限 → nil。
// 单发语义 + 8s 超时(精度换时延:desiredAccuracy 百米级,供下载时点
// 戳 GPS 元数据用,不是导航)。超时/失败一律 nil(Dart 按无位置降级)。
//
// Info.plist 需要 NSLocationWhenInUseUsageDescription(后台注入另需
// NSLocationAlwaysAndWhenInUseUsageDescription)。

import CoreLocation
import Flutter
import UIKit

public final class LocationPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate,
                                  FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LocationPlugin()
    let channel = FlutterMethodChannel(
      name: "zpill/location", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let stream = FlutterEventChannel(
      name: "zpill/location/stream", binaryMessenger: registrar.messenger())
    stream.setStreamHandler(instance)
  }

  private static let timeout: TimeInterval = 8

  private let manager = CLLocationManager()
  private var pending: FlutterResult?
  private var timer: Timer?

  // 连续定位流(BLE GPS 注入):onListen 只挂 sink,起/停由 startStream
  // /stopStream 方法驱动 —— 授权拒绝时 native 侧不报错关闭,静默无事件
  // (Dart 按「无定位」降级,状态由 authStatus 查询)。
  private var sink: FlutterEventSink?
  private var streaming = false

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "current":
      if streaming {
        // 连续流在跑:直接吐最近位置,不再 requestLocation(同一
        // manager 两路混用行为未定义)。
        if let last = manager.location {
          result([last.coordinate.latitude, last.coordinate.longitude])
        } else {
          result(nil)
        }
        return
      }
      guard pending == nil else {
        result(nil)  // 上一次还没落地:单发并发保护
        return
      }
      pending = result
      timer = Timer.scheduledTimer(
        withTimeInterval: Self.timeout, repeats: false
      ) { [weak self] _ in
        self?.finish(nil)
      }
      switch manager.authorizationStatus {
      case .notDetermined:
        manager.requestWhenInUseAuthorization()
      case .authorizedWhenInUse, .authorizedAlways:
        manager.requestLocation()
      default:
        finish(nil)  // 拒绝/受限:无位置,不是错误
      }
    case "startStream":
      streaming = true
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      manager.distanceFilter = 3
      manager.allowsBackgroundLocationUpdates = true
      manager.pausesLocationUpdatesAutomatically = false
      startUpdatesIfAuthorized()
      result(nil)
    case "stopStream":
      streaming = false
      manager.stopUpdatingLocation()
      result(nil)
    case "requestAlways":
      manager.requestAlwaysAuthorization()
      result(nil)
    case "authStatus":
      result(authName(manager.authorizationStatus))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startUpdatesIfAuthorized() {
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      manager.startUpdatingLocation()
    case .notDetermined:
      manager.requestWhenInUseAuthorization()  // 授权回调里再起
    default:
      break  // 拒绝/受限:静默,流上无事件
    }
  }

  private func authName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .authorizedWhenInUse: return "whenInUse"
    case .authorizedAlways: return "always"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "unknown"
    }
  }

  private func finish(_ coords: [Double]?) {
    timer?.invalidate()
    timer = nil
    guard let result = pending else { return }  // 超时后的迟到回调:丢弃
    pending = nil
    result(coords)
  }

  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if streaming {
      startUpdatesIfAuthorized()  // 授权落定沿:恢复/起流(幂等)
    }
    guard pending != nil else { return }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      manager.requestLocation()
    case .denied, .restricted:
      finish(nil)
    default:
      break
    }
  }

  public func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    guard let loc = locations.last else { return }
    if streaming {
      sink?(["latitude": loc.coordinate.latitude,
             "longitude": loc.coordinate.longitude,
             "altitude": loc.altitude])
      return
    }
    finish([loc.coordinate.latitude, loc.coordinate.longitude])
  }

  public func locationManager(
    _ manager: CLLocationManager, didFailWithError error: Error
  ) {
    if !streaming {
      finish(nil)
    }
    // 流模式:kCLErrorLocationUnknown 类瞬时失败等下一发,不关流。
  }

  // MARK: - FlutterStreamHandler(连续定位流)

  public func onListen(withArguments _: Any?, eventSink sink: @escaping FlutterEventSink)
    -> FlutterError? {
    self.sink = sink
    return nil
  }

  public func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

// NikonPill 位置采样通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/location_host.dart:
// MethodChannel `nikonpill/location` 的 `current` 做一次定位,返回
// [latitude, longitude](WGS84 十进制度),不可用返回 nil。
//
// 流程:授权未定 → requestWhenInUseAuthorization(委托回调里接着
// requestLocation);已授权 → 直接 requestLocation;拒绝/受限 → nil。
// 单发语义 + 8s 超时(精度换时延:desiredAccuracy 百米级,供下载时点
// 戳 GPS 元数据用,不是导航)。超时/失败一律 nil(Dart 按无位置降级)。
//
// Info.plist 需要 NSLocationWhenInUseUsageDescription。

import CoreLocation
import Flutter
import UIKit

public final class LocationPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "nikonpill/location", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocationPlugin(), channel: channel)
  }

  private static let timeout: TimeInterval = 8

  private let manager = CLLocationManager()
  private var pending: FlutterResult?
  private var timer: Timer?

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "current":
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
    default:
      result(FlutterMethodNotImplemented)
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
    finish([loc.coordinate.latitude, loc.coordinate.longitude])
  }

  public func locationManager(
    _ manager: CLLocationManager, didFailWithError error: Error
  ) {
    finish(nil)
  }
}

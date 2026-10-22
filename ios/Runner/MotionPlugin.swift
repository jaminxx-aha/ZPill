// ZPill 水平仪姿态通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/motion_host.dart:
// EventChannel `zpill/motion/attitude` 广播 [pitch, roll](弧度)。
//
// 数据源 CoreMotion CMDeviceMotion.gravity(设备坐标系下重力方向,
// 模长 1)。换算(手机竖持拍人像的相机视角,契约:抬头为正 / 右倾为正,
// ±π/2 内有效):
//   pitch = atan2(g.z, -g.y)   —— 抬头(镜头指天)为正,平放屏幕朝上
//                                (镜头朝地)为 -π/2
//   roll  = atan2(g.x, -g.y)   —— 顶部向右倒为正
// 竖持时 -g.y ≈ 1,两角均为小量;水平放置分母归零,角度退化(契约本就
// 只承诺 ±π/2 窗口)。
//
// 设备无姿态传感器(老 iPad 等)→ listen 即发 motion_unavailable 错误事件,
// Dart 侧 StreamBuilder 按无数据降级(不显示水平仪)。

import CoreMotion
import Flutter
import UIKit

public final class MotionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterEventChannel(
      name: "zpill/motion/attitude", binaryMessenger: registrar.messenger())
    let instance = MotionPlugin()
    channel.setStreamHandler(instance)
  }

  private let manager = CMMotionManager()

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard manager.isDeviceMotionAvailable else {
      events(
        FlutterError(
          code: "motion_unavailable", message: "设备姿态传感器不可用",
          details: nil))
      return nil
    }
    manager.deviceMotionUpdateInterval = 1.0 / 30.0
    manager.startDeviceMotionUpdates(to: .main) { motion, _ in
      guard let g = motion?.gravity else { return }
      events([
        atan2(g.z, -g.y),  // pitch
        atan2(g.x, -g.y),  // roll
      ])
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    manager.stopDeviceMotionUpdates()
    return nil
  }
}

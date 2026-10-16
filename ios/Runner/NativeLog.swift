// NikonPill 原生日志上报(iOS 平台,native 侧)—— native → Dart 反向通道。
//
// 对应 Dart 契约 lib/platform/log_bridge.dart(MethodChannel `nikonpill/log`):
// native → Dart 调 'onNativeLog',参数 {level: "d"|"i"|"w"|"e", tag, line},
// 由 Dart 合流进 AppLog 的 native 域。三端 native 在关键路径(USB bulk
// 失败 / BLE 状态沿)显式上报、不做系统日志抓流;android/ohos 各有对等件
// (NativeLog.kt / NativeLog.ets,同名同参)。
//
// 契约要点(与 Dart 侧注释一致):
// - fire-and-forget:iOS SDK 的 invokeMethod 无 throwing 变体(3.47 实况),
//   错误一律经 result 回调回流 —— 显式接收并丢弃即吞错:Dart handler
//   未装配 → FlutterMethodNotImplemented,handler 抛错 → FlutterError,
//   引擎已 detach → 回 nil;上报链路永不反噬调用方(等价于 Android 侧
//   的 try/catch 吞错,此处以空 result 闭包达成同款语义)。
// - 恒主线程 invoke:调用方多在 usbQueue / IC / BLE 回调上下文(不保证
//   主线程),统一 DispatchQueue.main.async 收口(先例:VolumeKeyPlugin
//   的 onVolumeKey 反向推送)。
// - install 前的上报静默丢弃:引擎初始化沿即装配,早于一切插桩点
//   (Dart 侧 handler 装配前的早到上报同样被 Dart 端静默丢弃,对称)。

import Flutter
import Foundation

/// 无实例命名空间:插桩点一行调用(e/w/i),别处零成本。
enum NativeLog {
  /// 反向通道(AppDelegate 在 implicit engine 初始化沿 install,常驻)。
  private static var channel: FlutterMethodChannel?

  /// 装配点:用引擎 binaryMessenger 建通道(幂等,重复 install 无副作用)。
  static func install(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    channel = FlutterMethodChannel(name: "nikonpill/log", binaryMessenger: messenger)
  }

  static func e(_ tag: String, _ line: String) { send("e", tag, line) }
  static func w(_ tag: String, _ line: String) { send("w", tag, line) }
  static func i(_ tag: String, _ line: String) { send("i", tag, line) }

  private static func send(_ level: String, _ tag: String, _ line: String) {
    guard let channel = channel else { return }
    DispatchQueue.main.async {
      channel.invokeMethod("onNativeLog", arguments: ["level": level, "tag": tag, "line": line]) { _ in
        // 错误回流面:未装配 / handler 抛错 / 引擎 detach 三态一律吞。
      }
    }
  }
}

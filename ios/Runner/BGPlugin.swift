// ZPill 后台传输保活通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/background_transfer.dart:
// MethodChannel `zpill/bg`:ensureRunning(队列非空)/ stop(清空)。
//
// iOS 语义:beginBackgroundTask 申请的后台宽限(~30s,系统调度)——
// 传输引擎在后台把正在写盘的批次收尾够用;到期 expiration handler
// 主动交还(不交还会被系统杀进程)。幂等:重复 ensure 不叠加任务。
//
// BGTaskScheduler 续传(app refresh / processing)需系统后台唤起
// Flutter 引擎恢复队列,行为未真机验证,未启用 —— 只做宽限窗口。

import Flutter
import UIKit

public final class BGPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zpill/bg", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BGPlugin(), channel: channel)
  }

  private var task: UIBackgroundTaskIdentifier = .invalid

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ensureRunning":
      if task == .invalid {
        task = UIApplication.shared.beginBackgroundTask(
          withName: "zpill-transfer"
        ) { [weak self] in
          self?.end()  // 宽限到期:系统要收回,必须收尾交还
        }
      }
      result(nil)
    case "stop":
      end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}

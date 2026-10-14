// NikonPill 程序化加入 Wi-Fi 通道(iOS 平台,native 侧)。
//
// 对应 Dart 契约 lib/platform/network_monitor.dart 的 WifiJoiner:
// - MethodChannel `nikonpill/network` 的 `join`(ssid/password/security)
//   → {ok: Bool, reason: String?}:NEHotspotConfigurationManager.apply
//   加入相机热点。已在该网络(alreadyAssociated)按成功收口 —— 重进
//   页面再 join 是常态。userDenied / 其他错误如实回 reason,Dart 按
//   「自动加入失败」回落手动指引。
// - `release` → removeConfiguration(forSSID:)(join 成功沿记下 SSID;
//   joinOnce=true 的配置本就随断开/重启即弃,release 是显式对齐
//   Android 的解绑语义,防跨会话残留)。
//
// security 传 0x2004 原始字节:0x01 开放 → 无密码构造;其余有密码走
// passphrase 构造(isWEP 只是遗留参数名,WPA2/WPA3 通吃)。
//
// **capability 门(2026-10-15)**:真机调用 apply 要求 App ID 带
// Network Extensions capability(entitlement 值 hotspot-configuration),
// 免费个人签名加不上 —— 未挂 capability 时 apply 运行时如实报错,
// 走上面的人工回落;哪天转付费账号挂上 capability,本文件即插即用,
// 零改动。模拟器上 apply 恒成功(no-op),验证必须真机。

import Flutter
import NetworkExtension
import UIKit

public final class NetworkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NetworkPlugin()
    let channel = FlutterMethodChannel(
      name: "nikonpill/network", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// 最近一次 join 成功的 SSID(release 对齐 Android 解绑语义用)。
  private var lastJoinedSsid: String?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "join":
      let args = call.arguments as? [String: Any] ?? [:]
      let ssid = args["ssid"] as? String ?? ""
      let password = args["password"] as? String ?? ""
      let security = args["security"] as? Int ?? 0
      join(ssid: ssid, password: password, security: security, result: result)
    case "release":
      if let ssid = lastJoinedSsid {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        lastJoinedSsid = nil
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func join(ssid: String, password: String, security: Int,
                    result: @escaping FlutterResult) {
    let config: NEHotspotConfiguration
    if password.isEmpty {
      // 开放网络(0x2004 安全字节 0x01):无密码构造。
      config = NEHotspotConfiguration(ssid: ssid)
    } else {
      config = NEHotspotConfiguration(ssid: ssid, passphrase: password,
                                      isWEP: false)
    }
    config.joinOnce = true // 临时会话:断开/重启即弃,不在 Wi-Fi 列表留痕
    NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
      // 回主线程再结算(FlutterResult 须在 platform 主线程调)。
      DispatchQueue.main.async {
        guard let error = error else {
          self?.lastJoinedSsid = ssid
          result(["ok": true])
          return
        }
        let nsError = error as NSError
        // NEHotspotConfigurationError 是 NS_ENUM(非 NS_ERROR_ENUM,
        // 无 .code 成员;SDK 头文件定案:alreadyAssociated=13,
        // userDenied=7),按 domain + rawValue 判别。
        guard nsError.domain == NEHotspotConfigurationErrorDomain,
              let code = NEHotspotConfigurationError(rawValue: nsError.code) else {
          result(["ok": false, "reason": nsError.localizedDescription])
          return
        }
        switch code {
        case .alreadyAssociated:
          // 已在该网络 = 加入语义已达成。
          result(["ok": true])
        case .userDenied:
          result(["ok": false, "reason": "user denied"])
        default:
          result(["ok": false, "reason": nsError.localizedDescription])
        }
      }
    }
  }
}

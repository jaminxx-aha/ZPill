/// WiFi 网络监测。
library;

import 'package:flutter/services.dart';

import '../core/camera/camera_discovery.dart';

/// 当前 WiFi 链路信息;非 WiFi / 不可用时为 null。
final class WifiLinkInfo {
  const WifiLinkInfo({this.ssid, this.gateway});

  final String? ssid;
  final String? gateway;

  /// 命中相机热点启发式(SSID 含 NIKON/CCCC)。
  bool get isLikelyCamera => isLikelyCameraSsid(ssid);
}

abstract interface class NetworkMonitor {
  /// 网络变化事件流;UI 据此提示「请连接相机 WiFi」。
  Stream<WifiLinkInfo?> get link;

  /// 立即查询一次。
  Future<WifiLinkInfo?> current();
}

/// native 侧经 `nikonpill/network` channel 上报:
/// - 方法 `current` → `{ssid, gateway}`(可缺省)
/// - 事件  `linkChanged` → 同上
///
/// TODO(P1): 实现 native 端。iOS 无法读 SSID:返回 gateway 探测结果即可,
/// SSID 提示降级为「尝试直连 192.168.1.1」。
final class MethodChannelNetworkMonitor implements NetworkMonitor {
  static const MethodChannel channel = MethodChannel('nikonpill/network');

  @override
  Stream<WifiLinkInfo?> get link => throw UnimplementedError();

  @override
  Future<WifiLinkInfo?> current() => throw UnimplementedError();
}

/// 程序化加入 Wi-Fi 的结果;ok=false 时 [reason] 如实(unsupported /
/// timeout / unavailable / 平台原话)。
final class WifiJoinResult {
  const WifiJoinResult({required this.ok, this.reason, this.gateway});

  final bool ok;
  final String? reason;

  /// 加入网络的 DHCP 网关(点分 IPv4;native 在 join 定局沿读,拿不到
  /// 不带该键 → null)。相机热点是 AP 拓扑,网关即相机本机 IP —— 比
  /// 硬编码 192.168.1.1 普适(不同相机网段不同)。**只有 AP(加入相机
  /// 热点)路可消费**:STA 的网关是路由器,连它只会得到莫名超时。
  final String? gateway;
}

/// 程序化加入热点(`nikonpill/network` 方法 `join`/`release`)。
/// BLE→WiFi 交接用(SnapBridge 同款):0x2004 凭据 → 写 0x2005 断
/// BLE → join → PTP/IP。Android = WifiNetworkSpecifier + requestNetwork
/// + bindProcessToNetwork(specifier 网络无互联网,socket 须绑过去,
/// [release] 解绑);iOS = NEHotspotConfiguration(代码已就位,真机
/// 调用要求 Network Extensions capability —— 免费签名签发被拒,
/// 2026-10-15 实验:profile 不含该 entitlement,build 拒;未挂时
/// apply 运行时报错走回落,付费账号挂上即插即用);ohos wifiManager
/// 属 system_basic 权限,同回落 —— 通道缺失时 [join] 返回
/// unsupported 不抛,调用点按手动指引降级。
abstract interface class WifiJoiner {
  /// [security] 传 0x2004 原始字节(0-4),映射在各 native。
  Future<WifiJoinResult> join({
    required String ssid,
    required String password,
    required int security,
  });

  /// 释放持有的网络并恢复进程默认路由;幂等,未持有无操作。
  Future<void> release();
}

final class MethodChannelWifiJoiner implements WifiJoiner {
  static const MethodChannel _channel = MethodChannel('nikonpill/network');

  @override
  Future<WifiJoinResult> join({
    required String ssid,
    required String password,
    required int security,
  }) async {
    try {
      final r = await _channel
          .invokeMethod<Object?>('join', <String, Object?>{
        'ssid': ssid,
        'password': password,
        'security': security,
      });
      final map = r as Map<Object?, Object?>?;
      return WifiJoinResult(
        ok: map?['ok'] == true,
        reason: map?['reason'] as String?,
        // native 拿不到就不带键 → null(契约见类注)
        gateway: map?['gateway'] as String?,
      );
    } on MissingPluginException {
      // iOS/ohos 未落地(见类注):如实 unsupported,UI 回手动指引。
      return const WifiJoinResult(ok: false, reason: 'unsupported');
    } on PlatformException catch (e) {
      return WifiJoinResult(ok: false, reason: e.message ?? e.code);
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // 平台未实现:本就没持网络,无妨
    } on PlatformException {
      // 释放失败不致命(进程退出自然解绑)
    }
  }
}

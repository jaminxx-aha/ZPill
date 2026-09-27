/// WiFi 网络监测(TODO.md §二 P1)。
library;

import 'package:flutter/services.dart';

import '../core/camera/camera_discovery.dart';

/// 当前 WiFi 链路信息;非 WiFi / 不可用时为 null。
final class WifiLinkInfo {
  const WifiLinkInfo({this.ssid, this.gateway});

  final String? ssid;
  final String? gateway;

  /// 命中相机热点启发式(TODO.md §二:SSID 含 NIKON/CCCC)。
  bool get isLikelyCamera => isLikelyCameraSsid(ssid);
}

abstract interface class NetworkMonitor {
  /// 网络变化事件流;UI 据此提示「请连接相机 WiFi」。
  Stream<WifiLinkInfo?> get link;

  /// 立即查询一次。
  Future<WifiLinkInfo?> current();
}

/// native 侧经 `nikonbridge/network` channel 上报:
/// - 方法 `current` → `{ssid, gateway}`(可缺省)
/// - 事件  `linkChanged` → 同上
///
/// TODO(P1): 实现 native 端。iOS 无法读 SSID:返回 gateway 探测结果即可,
/// SSID 提示降级为「尝试直连 192.168.1.1」。
final class MethodChannelNetworkMonitor implements NetworkMonitor {
  static const MethodChannel channel = MethodChannel('nikonbridge/network');

  @override
  Stream<WifiLinkInfo?> get link => throw UnimplementedError();

  @override
  Future<WifiLinkInfo?> current() => throw UnimplementedError();
}

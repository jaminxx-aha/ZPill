/// mDNS/Bonjour 相机发现(`nikonpill/nsd` channel)。
///
/// 相机「网络 → 连接至智能设备 → Wi-Fi 连接(STA)」加入局域网后广播
/// Bonjour 服务 `_ptp._tcp.local.`:实例名 = 相机设备名(如 Z_f_8014411),
/// SRV 端口 15740,TXT 含 guid(=InitCommandResponse 相机 GUID)/vid/pid/
/// ver/apps(2026-10-04 Zf 真机实测;AP 模式是否同样广播待真机核对)。
///
/// 契约要点:
/// - **纯 DNS-SD 解析,绝不向相机发 TCP 连接** —— 相机是单连接服务器,
///   静默连接会被保持(等 Init)、关闭后呛住不接新 SYN(见 docs 与
///   tools/ptpip_probe 探针记录);iOS 侧用 NetService 解析拿 IP,
///   不走 NWConnection(那会真连 15740)。
/// - iOS 14+ 浏览 Bonjour 需 Info.plist `NSBonjourServices` 声明
///   `_ptp._tcp`(已加),否则系统静默拦截。
/// - 三端落地状态:iOS ✅ 真机验证(NetServiceBrowser/NetService,提交
///   f68a5d2);ohos/Android ✅ 已落地(编译过,真机待验证)——
///   @ohos.net.mdns(NsdPlugin.ets)/ NsdManager(NsdPlugin.kt)。
///   serviceType 尾点差异各按平台文档(iOS/Android 带尾点,ohos 无),
///   待真机核对。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 一次扫描发现的相机(mDNS 解析产物)。
final class DiscoveredIpCamera {
  const DiscoveredIpCamera({
    required this.name,
    required this.host,
    required this.port,
    this.txt = const {},
  });

  /// mDNS 实例名 = 相机设备名(如 Z_f_8014411;Zf 命名 = 型号_序列号)。
  final String name;

  /// 解析出的 IP 地址(点分 IPv4)。
  final String host;

  /// SRV 端口(Zf = 15740)。
  final int port;

  /// TXT 记录(guid/vid/pid/ver/apps);guid 会话间会变,勿当稳定标识。
  final Map<String, String> txt;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredIpCamera &&
      other.name == name &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, host, port);

  static DiscoveredIpCamera fromMap(Map<Object?, Object?> map) {
    final txt = <String, String>{};
    final raw = map['txt'];
    if (raw is Map) {
      raw.forEach((k, v) => txt['$k'] = '$v');
    }
    return DiscoveredIpCamera(
      name: map['name'] as String? ?? '',
      host: map['host'] as String? ?? '',
      port: map['port'] as int? ?? 15740,
      txt: txt,
    );
  }
}

/// 扫描事件流元素。
sealed class NsdEvent {
  const NsdEvent();
}

/// 发现(解析完成,拿到 IP)。
final class NsdCameraFound extends NsdEvent {
  const NsdCameraFound(this.camera);
  final DiscoveredIpCamera camera;
}

/// 服务消失(离开网络/退出 Wi-Fi 等待态)。
final class NsdCameraLost extends NsdEvent {
  const NsdCameraLost(this.name);
  final String name;
}

abstract interface class NsdScanner {
  /// 发现/消失事件(广播语义;未开始浏览时静默无流)。
  Stream<NsdEvent> get events;

  /// 开始浏览 `_ptp._tcp`(幂等:重复调用先停再启,清空旧结果)。
  Future<void> startBrowsing();

  /// 停止浏览(幂等)。
  Future<void> stopBrowsing();
}

/// 经 `nikonpill/nsd`(方法 start/stop)+ `nikonpill/nsd/events`
/// (EventChannel,载荷 Map{event: found|lost, …})。
///
/// native 未实现的平台(ohos/Android)调 start 会抛
/// MissingPluginException —— 由上层捕获并降级为「手动输入 IP」。
final class MethodChannelNsdScanner implements NsdScanner {
  static const MethodChannel _methods = MethodChannel('nikonpill/nsd');
  static const EventChannel _events = EventChannel('nikonpill/nsd/events');

  Stream<NsdEvent>? _stream;

  @override
  Stream<NsdEvent> get events =>
      _stream ??= _events.receiveBroadcastStream().expand(_parseEvents);

  @override
  Future<void> startBrowsing() => _methods.invokeMethod<void>('start');

  @override
  Future<void> stopBrowsing() => _methods.invokeMethod<void>('stop');

  static Iterable<NsdEvent> _parseEvents(Object? raw) {
    if (raw is! Map) return const [];
    final map = Map<Object?, Object?>.from(raw);
    return switch (map['event']) {
      'found' => [NsdCameraFound(DiscoveredIpCamera.fromMap(map))],
      'lost' => [NsdCameraLost(map['name'] as String? ?? '')],
      _ => const [], // 未知载荷:丢弃( native 契约扩展时此处升级)
    };
  }
}

/// 已配对相机的领域模型(TODO.md §五 P2 持久化字段)。
library;

final class CameraInfo {
  const CameraInfo({
    required this.id,
    required this.name,
    this.model,
    this.bleAddress,
    this.wifiSsid,
    this.lastIp,
    this.lastConnectedAt,
  });

  final String id;
  final String name; // 展示名(mDNS 实例名,如 Z_f_8014411)
  final String? model; // 机身型号,来自 GetDeviceInfo
  final String? bleAddress; // P3 BLE 直连用
  final String? wifiSsid;
  final String? lastIp; // 最近一次无线连接的 IP(快速重连)
  final DateTime? lastConnectedAt;

  CameraInfo copyWith({
    String? name,
    String? model,
    String? bleAddress,
    String? wifiSsid,
    String? lastIp,
    DateTime? lastConnectedAt,
  }) =>
      CameraInfo(
        id: id,
        name: name ?? this.name,
        model: model ?? this.model,
        bleAddress: bleAddress ?? this.bleAddress,
        wifiSsid: wifiSsid ?? this.wifiSsid,
        lastIp: lastIp ?? this.lastIp,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      );
}

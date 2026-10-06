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
    this.wirelessPaired = false,
  });

  final String id;
  final String name; // 展示名(mDNS 实例名,如 Z_f_8014411)
  final String? model; // 机身型号,来自 GetDeviceInfo
  final String? bleAddress; // P3 BLE 直连用
  final String? wifiSsid;
  final String? lastIp; // 最近一次无线连接的 IP(快速重连)
  final DateTime? lastConnectedAt;

  /// 相机侧已完成配对记录(0x935A 应答 OK)。false = 仅应用侧记住
  /// (STA「连接至计算机」模式相机不答配对 op 的形态)—— 下次连接
  /// 仍会尝试配对,直到相机侧记录为止。
  final bool wirelessPaired;

  CameraInfo copyWith({
    String? name,
    String? model,
    String? bleAddress,
    String? wifiSsid,
    String? lastIp,
    DateTime? lastConnectedAt,
    bool? wirelessPaired,
  }) =>
      CameraInfo(
        id: id,
        name: name ?? this.name,
        model: model ?? this.model,
        bleAddress: bleAddress ?? this.bleAddress,
        wifiSsid: wifiSsid ?? this.wifiSsid,
        lastIp: lastIp ?? this.lastIp,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        wirelessPaired: wirelessPaired ?? this.wirelessPaired,
      );
}

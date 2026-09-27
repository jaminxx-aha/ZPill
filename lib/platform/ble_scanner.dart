/// BLE 扫描与 GATT(TODO.md §二 P3 + 实现注意事项 4/5/6)。
///
/// 铁律:
/// - 扫描必须设超时(相机 BLE 广播仅在配对模式持续约 60–120s)
/// - 按名称匹配,**不按 UUID 过滤**
/// - GATT 连接传 TRANSPORT_LE,跳过系统配对 createBond(Z5 实测免 PIN)
/// - SnapBridge 私有协议常量必须真实抓包逆向,**不可臆造**
library;

import 'package:flutter/services.dart';

final class DiscoveredCamera {
  const DiscoveredCamera({required this.name, required this.address, required this.rssi});
  final String name;
  final String address;
  final int rssi;
}

abstract interface class BleScanner {
  /// 扫描 [timeout](默认 10s,TODO.md §二);返回按名称过滤后的设备。
  Future<List<DiscoveredCamera>> scan({Duration timeout});

  /// GATT 连接(TRANSPORT_LE,免配对);触发相机 WiFi 服务激活的
  /// write 操作待真机抓包确认(15740 是否依赖 BLE 激活,待验证)。
  Future<void> connect(String address);
}

/// 经 `nikonpill/ble` channel:方法 `scan`/`connect`。
/// TODO(P3): iOS/Android 可评估 flutter_blue_plus 直接实现;
/// ohos 需在 ArkTS 侧写 channel 对接 @ohos.bluetooth.ble。
final class MethodChannelBleScanner implements BleScanner {
  static const MethodChannel channel = MethodChannel('nikonpill/ble');

  @override
  Future<List<DiscoveredCamera>> scan({Duration timeout = const Duration(seconds: 10)}) =>
      throw UnimplementedError();

  @override
  Future<void> connect(String address) => throw UnimplementedError();
}

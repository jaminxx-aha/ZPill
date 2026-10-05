/// 位置采样接口(TODO §四 GPS 元数据):`nikonpill/location` 通道契约。
///
/// MethodChannel `nikonpill/location` 的 `current` 方法做一次定位,返回
/// `[latitude, longitude]`(double,十进制度,WGS84;正 = 北纬/东经),
/// 未授权/不可用/超时返回 null。native 侧 iOS = CoreLocation、
/// ohos = @ohos.geoLocationManager、Android = LocationManager,
/// 见各平台 Plugin(阶段 B/C/D)。
///
/// 通道未实现(旧 native)抛 MissingPluginException —— 调用方按
/// 「无位置」降级,不重试。
library;

import 'package:flutter/services.dart';

/// 一次定位结果(十进制度)。
final class LocationFix {
  const LocationFix({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  /// 从通道载荷 `[latitude, longitude]` 解析;布局不符抛 FormatException。
  factory LocationFix.fromList(Object? raw) {
    if (raw is! List || raw.length != 2) {
      throw const FormatException('location 载荷须为 [latitude, longitude]');
    }
    return LocationFix(
      latitude: (raw[0] as num).toDouble(),
      longitude: (raw[1] as num).toDouble(),
    );
  }
}

abstract interface class LocationHost {
  /// 单次定位(尽量快;精度换时延,供下载时点戳 GPS 用)。
  Future<LocationFix?> current();
}

final class MethodChannelLocationHost implements LocationHost {
  static const MethodChannel _channel = MethodChannel('nikonpill/location');

  @override
  Future<LocationFix?> current() async {
    final raw = await _channel.invokeMethod<List<Object?>>('current');
    if (raw == null) return null;
    return LocationFix.fromList(raw);
  }
}

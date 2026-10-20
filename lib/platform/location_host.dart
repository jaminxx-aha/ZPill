/// 位置采样接口(GPS 元数据):`nikonpill/location` 通道契约。
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

/// 连续定位采样(BLE GPS 注入驱动源;native = startUpdatingLocation,
/// distanceFilter 3m、后台可续)。
final class LocationSample {
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.altitude,
  });

  final double latitude;
  final double longitude;
  final double altitude;
}

/// 定位流宿主(`nikonpill/location/stream` EventChannel + 授权方法)。
/// 未授权时流上无事件(native 静默),状态经 [authorizationStatus] 查询;
/// native 未实现(M2 后的 Android/ohos)抛 MissingPluginException 按
/// 「无定位」降级。
abstract interface class LocationStreamHost {
  /// 起流(native startUpdatingLocation,distanceFilter 3m;幂等)。
  Future<void> startStream();

  /// 订阅连续定位流(广播语义;停止用 [stopStream],取消订阅不足以
  /// 停 native 侧 GPS)。
  Stream<LocationSample> stream();

  /// 停流(native stopUpdatingLocation;幂等)。
  Future<void> stopStream();

  /// 两段式授权第二段:后台注入前申请「始终允许」。
  Future<void> requestAlwaysAuthorization();

  /// 当前授权态(notDetermined/whenInUse/always/denied/restricted)。
  Future<String?> authorizationStatus();
}

final class MethodChannelLocationStream implements LocationStreamHost {
  const MethodChannelLocationStream();

  static const MethodChannel _channel = MethodChannel('nikonpill/location');
  static const EventChannel _events =
      EventChannel('nikonpill/location/stream');

  @override
  Future<void> startStream() => _channel.invokeMethod<void>('startStream');

  @override
  Stream<LocationSample> stream() => _events
      .receiveBroadcastStream()
      .map((raw) => raw is Map
          ? LocationSample(
              latitude: (raw['latitude'] as num).toDouble(),
              longitude: (raw['longitude'] as num).toDouble(),
              altitude: (raw['altitude'] as num?)?.toDouble() ?? 0,
            )
          : throw const FormatException('location 流载荷须为 Map'));

  @override
  Future<void> stopStream() =>
      _channel.invokeMethod<void>('stopStream');

  @override
  Future<void> requestAlwaysAuthorization() =>
      _channel.invokeMethod<void>('requestAlways');

  @override
  Future<String?> authorizationStatus() =>
      _channel.invokeMethod<String>('authStatus');
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

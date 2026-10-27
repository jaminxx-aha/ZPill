/// 水平仪姿态接口(监看辅助):`zpill/motion` 通道契约。
///
/// EventChannel `zpill/motion/attitude` 广播设备姿态(重力方向):
/// 每条事件 = `[pitch, roll]`(double,弧度;pitch 抬头为正,roll 右倾
/// 为正)。native 侧 iOS = CoreMotion CMDeviceMotion.gravity,
/// ohos = @ohos.sensor 重力传感器,Android = SensorManager 重力向量,
/// 见各平台 Plugin(阶段 B/C/D)。
///
/// 通道未实现(旧 native)时 listen 报 MissingPluginException —— 交给
/// 调用方按「不可用」降级,不缓存不重试。
library;

import 'package:flutter/services.dart';

/// 一次姿态采样(弧度)。
final class MotionOrientation {
  const MotionOrientation({required this.pitchRad, required this.rollRad});

  /// 俯仰(绕横轴,弧度;±π/2 内有效)。
  final double pitchRad;

  /// 横滚(绕纵轴,弧度;±π/2 内有效)。
  final double rollRad;

  /// 从通道事件载荷 `[pitch, roll]` 解析;布局不符抛 FormatException。
  factory MotionOrientation.fromList(Object? raw) {
    if (raw is! List || raw.length != 2) {
      throw const FormatException('motion 事件载荷须为 [pitch, roll]');
    }
    return MotionOrientation(
      pitchRad: (raw[0] as num).toDouble(),
      rollRad: (raw[1] as num).toDouble(),
    );
  }

  /// 度数显示(保留 1 位)。
  String get pitchText => '${(pitchRad * 180 / 3.141592653589793).toStringAsFixed(1)}°';
  String get rollText => '${(rollRad * 180 / 3.141592653589793).toStringAsFixed(1)}°';
}

abstract interface class MotionHost {
  /// 姿态广播流(订阅期持续采样;单订阅语义由 EventChannel 广播承载)。
  Stream<MotionOrientation> get attitudes;
}

final class MethodChannelMotionHost implements MotionHost {
  static const EventChannel _channel =
      EventChannel('zpill/motion/attitude');

  @override
  Stream<MotionOrientation> get attitudes => _channel
      .receiveBroadcastStream()
      .map(MotionOrientation.fromList);
}

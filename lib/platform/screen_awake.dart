/// 屏幕常亮宿主:取景/间隔拍摄期间阻止系统自动锁屏。
///
/// 走既有 `zpill/bg` 通道(三端 BgPlugin 已持有 Activity/UIAbility,
/// 再加一个插件只为置一个窗口标志不划算);方法 `setScreenAwake`
/// 携 `enabled`:true = 开,false = 还系统默认。
///
/// 失败/旧 native 未实现一律静默降级(屏幕照常按系统策略休眠),
/// 不阻塞拍摄主链路。
library;

import 'package:flutter/services.dart';

abstract interface class ScreenAwakeHost {
  Future<void> setAwake(bool awake);
}

final class MethodChannelScreenAwake implements ScreenAwakeHost {
  static const MethodChannel channel = MethodChannel('zpill/bg');

  @override
  Future<void> setAwake(bool awake) async {
    try {
      await channel.invokeMethod<void>('setScreenAwake', <String, Object>{
        'enabled': awake,
      });
    } on MissingPluginException {
      // 旧 native:不持有常亮能力,按系统默认休眠
    } on PlatformException {
      // native 实现失败:同样按默认休眠降级
    }
  }
}

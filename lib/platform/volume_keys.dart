/// Android 音量键快门通道件:`nikonpill/volume` 通道契约。
///
/// 反向通道(原生主动推 Dart,本仓第一例):MainActivity 覆写 onKeyUp
/// 拦 KEYCODE_VOLUME_UP/DOWN(开关开时),命中经 'onVolumeKey'
/// ({'key': 'up'|'down'}) 推回框架;Dart → 原生仅 'setEnabled'(bool)
/// —— 关/默认不拦,音量键归系统。**只拦 ACTION_UP**:长按的连发都在
/// DOWN,不拦 DOWN = 音量长按调节仍归系统(见 MainActivity 注释)。
///
/// 原生侧 Android 独有:iOS 系统不放行音量键给应用、ohos 未做原生
/// 拦截,均无实现 —— [MethodChannelVolumeKeys.setEnabled] 撞上
/// MissingPluginException(异端/热重启窗口)静默吞掉,零炸零提示。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 音量键事件(上/下;两键同效 = 快门,不分功能)。
enum VolumeKey { up, down }

abstract interface class VolumeKeyHost {
  /// 音量键事件广播流(原生 onKeyUp 命中即发;未启用期间静默无流)。
  Stream<VolumeKey> get keys;

  /// 开关推原生:true = 拦音量键转 [keys],false = 还给系统调音量。
  Future<void> setEnabled(bool enabled);
}

final class MethodChannelVolumeKeys implements VolumeKeyHost {
  static const MethodChannel _channel = MethodChannel('nikonpill/volume');

  /// 共享单例(广播流可多订阅;构造即挂 handler,app 存活期恒在)。
  static final MethodChannelVolumeKeys instance = MethodChannelVolumeKeys._();

  final _ctrl = StreamController<VolumeKey>.broadcast();

  MethodChannelVolumeKeys._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onVolumeKey') return null;
      final key = call.arguments is Map ? call.arguments['key'] : null;
      // 未知键名(协议漂移)静默丢弃,不炸流
      switch (key) {
        case 'up':
          _ctrl.add(VolumeKey.up);
        case 'down':
          _ctrl.add(VolumeKey.down);
      }
      return null;
    });
  }

  @override
  Stream<VolumeKey> get keys => _ctrl.stream;

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // 无原生实现(异端/热重启窗口):静默降级,音量键本就归系统
    }
  }
}

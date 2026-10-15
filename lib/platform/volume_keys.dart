/// 音量键快门通道件:`nikonpill/volume` 通道契约。
///
/// 反向通道(原生主动推 Dart,本仓第一例):Dart → 原生仅
/// 'setEnabled'(bool) —— 关/默认不拦,音量键归系统;命中沿原生
/// 回推 'onVolumeKey'({'key': 'up'|'down'}),两键同效 = 快门。
///
/// 平台实现:
/// - Android:MainActivity 覆写 onKeyUp 拦 KEYCODE_VOLUME_UP/DOWN
///   (开关开时)。**只拦 ACTION_UP**:长按的连发都在 DOWN,不拦
///   DOWN = 音量长按调节仍归系统(见 MainActivity 注释)。
/// - iOS:系统不放行音量键事件,VolumeKeyPlugin 观察
///   AVAudioSession.outputVolume(KVO)+ SystemVolumeDidChange 通知
///   兜底,MPVolumeView 藏系统音量 HUD 并在每次触发后把音量「回吸」
///   到锚点 —— 音量沿即按键,顶/底死区靠锚点两侧各留一步余量扛住
///   (手法借自 OpenZCine BluetoothShutterMonitor,Apache-2.0)。
///   副作用:启用期系统音量会在锚点 ± 一步内被来回写,停用还原。
/// - ohos:未做原生拦截 —— [MethodChannelVolumeKeys.setEnabled] 撞上
///   MissingPluginException(异端/热重启窗口)静默吞掉,零炸零提示。
library;

import 'dart:async';
import 'dart:io' show Platform;

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

  /// 平台分派(纯判定,单测直测):Android(onKeyUp 拦截)与 iOS
  /// (KVO 音量观察 + 回吸)有原生实现;ohos/桌面无 → null。
  static VolumeKeyHost? hostOn({required bool android, required bool ios}) =>
      (android || ios) ? instance : null;

  /// 当前平台接线宿主(生产入口;Android/iOS → 单例,其余 null,
  /// 消费方按「无宿主」降级不接线)。
  static VolumeKeyHost? get platformHost =>
      hostOn(android: Platform.isAndroid, ios: Platform.isIOS);

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

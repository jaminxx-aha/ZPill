/// 原生日志合流通道(native → Dart 反向调用;volume 通道同款接线)。
///
/// 三端 native 在关键路径(USB bulk 失败 / BLE 状态沿 / 通道异常)显式
/// 上报,不做 logcat 抓取类自动收流 —— 体量可控、三端一致(自动抓取在
/// iOS/ohos 无对等 API,显式钩子是唯一三端公平的方案)。native 侧工具:
/// android/…/log/NativeLog.kt、ios/Runner/NativeLog.swift、
/// ohos/…/log/NativeLog.ets;均须主线程 invoke + try/catch 容错
/// (Dart 侧 handler 装配前后的早到上报静默丢弃)。
library;

import 'package:flutter/services.dart';

import '../core/log/app_log.dart';

final class NativeLogBridge {
  NativeLogBridge._();

  static const MethodChannel _ch = MethodChannel('nikonpill/log');
  static bool _installed = false;

  /// main() 在 PlatformServices.bootstrap() 后立即 install;测试不经
  /// main 时不装配,通道无人监听 = 上报自然丢失,无害。
  static void install() {
    if (_installed) return;
    _installed = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'onNativeLog') return null;
      final args = call.arguments;
      if (args is Map) {
        AppLog.log(_levelOf(args['level']), AppLog.native,
            '[${args['tag']}] ${args['line']}');
      }
      return null;
    });
  }

  static AppLogLevel _levelOf(Object? v) => switch (v) {
        'd' => AppLogLevel.debug,
        'i' => AppLogLevel.info,
        'w' => AppLogLevel.warn,
        'e' => AppLogLevel.error,
        _ => AppLogLevel.error, // 缺省从严:上报的都是关键点
      };
}

/// 后台传输调度(TODO.md §四 P1)。
///
/// Android:WorkManager + 前台服务 + 指数退避(重试上限 3);
/// iOS:BGTaskScheduler(系统随时可能挂起,重进前台续传);
/// ohos:后台任务模式 + 通知。
/// 调度从这里发起,**执行细节在 native**,Dart 侧只保证队列状态可恢复。
library;

import 'package:flutter/services.dart';

abstract interface class BackgroundTransferScheduler {
  /// 申请后台执行权(Android 前台服务通知 / iOS 任务登记)。
  /// 队列非空期间保持;失败降级为「仅前台传输」并告知 UI。
  Future<void> ensureRunning();

  /// 队列清空 / 用户暂停时释放。
  Future<void> stop();
}

/// 经 `nikonpill/bg` channel:方法 `ensureRunning` / `stop`。
/// 三端 native 均为幂等实现(重复 ensure 不叠加任务)。native 未实现
/// (旧端)抛 MissingPluginException —— 按「仅前台传输」静默降级。
final class MethodChannelBackgroundScheduler implements BackgroundTransferScheduler {
  static const MethodChannel channel = MethodChannel('nikonpill/bg');

  @override
  Future<void> ensureRunning() async {
    try {
      await channel.invokeMethod<void>('ensureRunning');
    } on MissingPluginException {
      // 旧 native:仅前台传输
    }
  }

  @override
  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // 旧 native:本来就没开
    }
  }
}

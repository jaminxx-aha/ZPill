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

/// 经 `nikonbridge/bg` channel:方法 `ensureRunning` / `stop`。
/// TODO(P1): native 实现;通知文案、渠道 id 在各端工程内定义。
final class MethodChannelBackgroundScheduler implements BackgroundTransferScheduler {
  static const MethodChannel _channel = MethodChannel('nikonbridge/bg');

  @override
  Future<void> ensureRunning() => throw UnimplementedError();

  @override
  Future<void> stop() => throw UnimplementedError();
}

/// 传输引擎:入队去重、顺序下载、指数退避重试、流式写盘(TODO.md §四 P1)。
///
/// 与平台的分工:
/// - 本层(纯 Dart):队列状态机、去重、进度/速度/剩余时间
/// - platform 层:前台通知 + WorkManager/BGTask 调度、相册导入
///   (Android: MediaStore Pictures/Movies/NikonPill;iOS: PHPhotoLibrary;
///   ohos: photoAccessHelper)
library;

import '../browser/object_entry.dart';
import 'transfer_task.dart';

abstract interface class TransferEngine {
  /// 任务快照流(进行中 + 历史);UI 的数据源。
  Stream<List<TransferTask>> get tasks;

  /// 入队:已完成的同 handle 任务跳过(去重,TODO.md §四 P1);
  /// 队列中的重复任务合并,不重复下载。
  Future<void> enqueue(Iterable<ObjectEntry> entries);

  /// 取消单个任务:中断流式写入、删除半成品临时文件。
  Future<void> cancel(String taskId);

  /// 清空历史(仅已完成/已取消/已失败)。
  Future<void> clearHistory();
}

/// TODO(P1): 实现 ——
/// 1. 并发 = 1(单 TCP 会话内串行,避免相机侧事务交错)
/// 2. PtpIpSession.getObject 流 → 临时文件(边收边写,禁止整文件进内存)
/// 3. 完成后交 GallerySaver 导入系统相册,再清理临时文件
/// 4. 失败指数退避:attempts < 3 时重排队
/// 5. 进度经 [tasks] 流上报;速度/剩余时间用 SpeedEstimator
final class TransferEngineImpl implements TransferEngine {
  @override
  Stream<List<TransferTask>> get tasks => throw UnimplementedError();

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries) => throw UnimplementedError();

  @override
  Future<void> cancel(String taskId) => throw UnimplementedError();

  @override
  Future<void> clearHistory() => throw UnimplementedError();
}

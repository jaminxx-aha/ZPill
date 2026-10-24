/// 传输历史持久化接口(终态任务的落盘账本)。
///
/// 接口在 core(引擎要持有),文件实现在 data(transfer_history_store.dart,
/// JSON 落 `<dataDir>/transfer_history.json`);core→data 禁依赖,方向
/// 只许 data→core。实现须自行保证写盘不反噬传输主链路(失败静默,
/// 内存快照仍是账本)。
library;

import 'transfer_task.dart';

abstract interface class TransferHistoryStore {
  /// 全部历史记录(新→旧)。无文件/损坏文件 = 空表(按空表重建)。
  Future<List<TransferTask>> load();

  /// 按 id 去重置顶(更新内容并提到最新位),超容量裁最旧。
  Future<void> upsert(TransferTask task);

  /// 删除单条(传输页左滑单独删除)。
  Future<void> remove(String taskId);

  /// 清空(传输页「清空历史」)。
  Future<void> clear();
}

/// 传输历史持久化(JSON 文件 `<dataDir>/transfer_history.json`)。
///
/// 账本只收终态任务(引擎侧保证),新→旧存内存缓存,每次变更链式
/// 写穿(无防抖:终态沿本就离散,大批量连拍按下载节奏摊开,每秒
/// 至多几次小 JSON 写;写入失败静默,内存快照仍是本次会话的账本)。
/// 落盘走临时文件 + rename(半截写不毒化旧账);损坏文件按空表重建。
library;

import 'dart:convert';
import 'dart:io';

import '../core/transfer/transfer_history.dart';
import '../core/transfer/transfer_task.dart';

/// 历史条数上限(滚动淘汰最旧;连拍大批量下载下 500 条 ≈ 数月账)。
const int kTransferHistoryCap = 500;

final class FileTransferHistoryStore implements TransferHistoryStore {
  FileTransferHistoryStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  List<TransferTask>? _cache;
  Future<void> _chain = Future<void>.value();

  Future<String> get _path async =>
      '${await _dataDir()}/transfer_history.json';

  @override
  Future<List<TransferTask>> load() async =>
      List.of(await _ensureLoaded()); // 副本:外间不得改内存账本

  /// 内存账本本体(无则从盘读一次);变更都在写链上串行,拿到的
  /// 永远是当前态,无并发旧基线覆盖新账的口。
  Future<List<TransferTask>> _ensureLoaded() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = File(await _path);
    var records = <TransferTask>[];
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) {
          final raw = json['records'];
          if (raw is List) {
            for (final r in raw) {
              if (r is! Map<String, Object?>) continue;
              final t = _taskFromJson(r);
              if (t != null) records.add(t);
            }
          }
        }
      } on FormatException {
        // 损坏文件:按空表重建
      }
    }
    return _cache = records.take(kTransferHistoryCap).toList();
  }

  @override
  Future<void> upsert(TransferTask task) => _mutate((list) async {
        list.removeWhere((t) => t.id == task.id);
        list.insert(0, task);
        if (list.length > kTransferHistoryCap) {
          list.removeRange(kTransferHistoryCap, list.length);
        }
      });

  @override
  Future<void> remove(String taskId) => _mutate((list) async {
        list.removeWhere((t) => t.id == taskId);
      });

  @override
  Future<void> clear() => _mutate((list) async {
        list.clear();
      });

  /// 链式串行变更 + 写穿:引擎的终态沿是 unawaited 突发(批次回填一串
  /// upsert),全走同一链才不丢账;任一步失败静默(内存快照仍是账本,
  /// 不反噬传输主链路)。变更落定(含写盘)才返回 —— 引擎侧 unawaited
  /// 不受影响,测试侧拿到确定性。
  Future<void> _mutate(
      Future<void> Function(List<TransferTask> live) op) {
    final run = _chain.then((_) async {
      try {
        await op(await _ensureLoaded());
        await _flush();
      } on Object {
        // 盘满/权限等:静默,内存账本兜底本次会话
      }
    });
    _chain = run;
    return run;
  }

  Future<void> _flush() async {
    final list = _cache;
    if (list == null) return;
    final file = File(await _path);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ')
        .convert({'v': 1, 'records': [for (final t in list) _taskToJson(t)]}));
    await tmp.rename(file.path);
  }

  static Map<String, Object?> _taskToJson(TransferTask t) => {
        'id': t.id,
        'handle': t.handle,
        'filename': t.filename,
        'totalBytes': t.totalBytes,
        'destination': t.destination.name,
        'state': t.state.name,
        'receivedBytes': t.receivedBytes,
        if (t.error != null) 'error': t.error,
        'attempts': t.attempts,
        if (t.galleryUri != null) 'galleryUri': t.galleryUri.toString(),
        if (t.startedAt != null) 'startedAt': t.startedAt!.toIso8601String(),
        if (t.finishedAt != null) 'finishedAt': t.finishedAt!.toIso8601String(),
        'downloadMs': t.downloadMs,
      };

  /// 脏数据(缺 id/state/destination、枚举名不识)整条弃,不毒化账本。
  static TransferTask? _taskFromJson(Map<String, Object?> j) {
    final id = j['id'];
    final state = TransferState.values.asNameMap()[j['state']];
    final destination =
        TransferDestination.values.asNameMap()[j['destination']];
    final filename = j['filename'];
    final totalBytes = j['totalBytes'];
    if (id is! String ||
        state == null ||
        destination == null ||
        filename is! String ||
        totalBytes is! int) {
      return null;
    }
    final handle = j['handle'];
    final receivedBytes = j['receivedBytes'];
    final attempts = j['attempts'];
    final downloadMs = j['downloadMs'];
    final error = j['error'];
    final galleryUri = j['galleryUri'];
    final startedAt = j['startedAt'];
    final finishedAt = j['finishedAt'];
    return TransferTask(
      id: id,
      handle: handle is int ? handle : 0,
      filename: filename,
      totalBytes: totalBytes,
      destination: destination,
      state: state,
      receivedBytes: receivedBytes is int ? receivedBytes : 0,
      error: error is String ? error : null,
      attempts: attempts is int ? attempts : 0,
      galleryUri: galleryUri is String ? Uri.tryParse(galleryUri) : null,
      startedAt:
          startedAt is String ? DateTime.tryParse(startedAt)?.toLocal() : null,
      finishedAt: finishedAt is String
          ? DateTime.tryParse(finishedAt)?.toLocal()
          : null,
      downloadMs: downloadMs is int ? downloadMs : 0,
    );
  }
}

/// 进程内实现(测试用):语义与文件版一致(去重置顶/裁剪/删除/清空)。
final class InMemoryTransferHistoryStore implements TransferHistoryStore {
  InMemoryTransferHistoryStore({this.cap = kTransferHistoryCap});

  final int cap;
  final List<TransferTask> _records = [];

  @override
  Future<List<TransferTask>> load() async => List.of(_records);

  @override
  Future<void> upsert(TransferTask task) async {
    _records.removeWhere((t) => t.id == task.id);
    _records.insert(0, task);
    if (_records.length > cap) {
      _records.removeRange(cap, _records.length);
    }
  }

  @override
  Future<void> remove(String taskId) async {
    _records.removeWhere((t) => t.id == taskId);
  }

  @override
  Future<void> clear() async => _records.clear();
}

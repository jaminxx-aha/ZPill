/// 传输引擎:入队去重、顺序下载、指数退避重试、相册导入编排(TODO.md §四)。
///
/// 队列模型:并发 = 1(相机 PTP 会话本就一次一个事务,PtpSession 锁
/// 兜底;这里再按 FIFO 泵任务,进度/速度/取消的编排都在本层)。
///
/// gallery 目的地两段式:整批先流式下载到 tempDir → 全部落定后调
/// **一次** [GallerySaver.importFiles](系统保存对话框只弹一次)→
/// 回填 galleryUri、删临时文件。对话框期间泵暂停(排在后面的批次
/// 等用户确认,避免对话框叠罗汉)。
///
/// app 目的地:直接流式写入 downloadsDir,文件名冲突加 ` (n)` 序号。
library;

import 'dart:async';
import 'dart:io';

import '../browser/object_entry.dart';
import '../../platform/gallery_saver.dart';
import 'object_downloader.dart';
import 'transfer_task.dart';

abstract interface class TransferEngine {
  /// 任务快照流(进行中 + 历史,入队序);UI 的数据源。
  Stream<List<TransferTask>> get tasks;

  /// 入队一批对象到 [destination]。去重只对进行中(queued/running)的
  /// 同 handle + 同目的地生效;已完成的可重新入队(相册重导/失败重试)。
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination});

  /// 取消单个任务:queued 直接标 cancelled;running 置标志
  /// (downloader 停止写盘、排空数据流、删半成品)。
  Future<void> cancel(String taskId);

  /// 清空历史(仅已完成/已取消/已失败)。
  Future<void> clearHistory();
}

/// 一次 enqueue 对应一个批次:gallery 批次共享同一次导入对话框。
final class _Batch {
  _Batch(this.destination);

  final TransferDestination destination;
  final List<({String id, ObjectEntry entry})> members = [];
  final Map<String, ObjectDownload> downloads = {}; // id → 已完成落盘
  final Set<String> terminalIds = {};
  var finished = false;

  bool get allTerminal => terminalIds.length == members.length;
}

final class _Job {
  _Job(this.task, this.batch);

  TransferTask task; // 就地替换的快照
  final _Batch batch;
  var cancelRequested = false; // running 中被 cancel 置位
}

/// 默认指数退避:第 [retry] 次重试等 200ms * 2^(retry-1)。
Duration _defaultBackoff(int retry) =>
    Duration(milliseconds: 200 * (1 << (retry - 1)));

final class TransferEngineImpl implements TransferEngine {
  TransferEngineImpl({
    required this.downloader,
    required this.gallery,
    this.maxAttempts = 3,
    Duration Function(int retry)? backoffFor,
  }) : _backoffFor = backoffFor ?? _defaultBackoff;

  final ObjectDownloader downloader;
  final GallerySaver gallery;

  /// 失败重试上限(首跑之外的重试次数)。
  final int maxAttempts;
  final Duration Function(int retry) _backoffFor;

  /// Dart Map 即 LinkedHashMap:入队序 = 快照序 = 执行序。
  final Map<String, _Job> _jobs = {};
  final StreamController<List<TransferTask>> _ctrl =
      StreamController<List<TransferTask>>.broadcast();
  var _pumping = false;
  var _seq = 0;
  String? _tempDir;
  String? _downloadsDir;

  @override
  Stream<List<TransferTask>> get tasks => _ctrl.stream;

  List<TransferTask> get _snapshot =>
      [for (final job in _jobs.values) job.task];

  void _notify() => _ctrl.add(_snapshot);

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {
    final batch = _Batch(destination);
    for (final entry in entries) {
      final active = _jobs.values.any((j) =>
          !j.task.isTerminal &&
          j.task.handle == entry.handle &&
          j.task.destination == destination);
      if (active) continue;
      final id = 't${_seq++}';
      final task = TransferTask(
        id: id,
        handle: entry.handle,
        filename: entry.name,
        totalBytes: entry.sizeInBytes,
        destination: destination,
      );
      _jobs[id] = _Job(task, batch);
      batch.members.add((id: id, entry: entry));
    }
    if (batch.members.isEmpty) return;
    _notify();
    unawaited(_pump());
  }

  @override
  Future<void> cancel(String taskId) async {
    final job = _jobs[taskId];
    if (job == null || job.task.isTerminal) return;
    if (job.task.state == TransferState.running) {
      job.cancelRequested = true; // downloader 排空后以 cancelled 落定
    } else {
      _settle(job, TransferState.cancelled, null);
    }
  }

  @override
  Future<void> clearHistory() async {
    _jobs.removeWhere((_, job) => job.task.isTerminal);
    _notify();
  }

  // ---- 队列泵 ----------------------------------------------------------

  Future<void> _pump() async {
    if (_pumping) return; // 已有泵在跑,它会把新任务一起带掉
    _pumping = true;
    try {
      _Job? job;
      while ((job = _firstQueued()) != null) {
        await _run(job!);
      }
    } finally {
      _pumping = false;
    }
  }

  _Job? _firstQueued() {
    for (final job in _jobs.values) {
      if (job.task.state == TransferState.queued) return job;
    }
    return null;
  }

  Future<void> _run(_Job job) async {
    job.cancelRequested = false;
    job.task = job.task.copyWith(state: TransferState.running, clearError: true);
    _notify();
    final dir = job.task.destination == TransferDestination.gallery
        ? _tempDir ??= await gallery.tempDir()
        : _downloadsDir ??= await gallery.downloadsDir();
    try {
      final dl = await downloader.download(
        _entryOf(job),
        targetDir: dir,
        onProgress: (received) {
          if (!job.task.isTerminal) {
            job.task = job.task.copyWith(receivedBytes: received);
            _notify();
          }
        },
        isCancelled: () => job.cancelRequested,
      );
      job.batch.downloads[job.task.id] = dl;
      job.task =
          job.task.copyWith(state: TransferState.completed, receivedBytes: dl.bytes);
    } on DownloadCancelledException {
      job.task = job.task.copyWith(state: TransferState.cancelled, clearError: true);
    } catch (e) {
      // 链路/写盘失败(StateError、PtpResponseException、FileSystemException…)
      final attempts = job.task.attempts + 1;
      if (attempts <= maxAttempts) {
        await Future<void>.delayed(_backoffFor(attempts));
        job.task = job.task.copyWith(
            state: TransferState.queued, attempts: attempts, error: e.toString());
      } else {
        // 放弃:attempts 保留已用重试数(不含本次放弃的尝试)。
        job.task = job.task.copyWith(state: TransferState.failed, error: e.toString());
      }
    }
    if (job.task.isTerminal) {
      job.batch.terminalIds.add(job.task.id);
    }
    _notify();
    await _finishBatchIfDone(job.batch);
  }

  /// 批次全员落定后收尾:gallery 批次发起一次导入、回填 galleryUri、
  /// 删临时文件;app 批次无事可做(文件已直接落 downloadsDir)。
  Future<void> _finishBatchIfDone(_Batch batch) async {
    if (batch.finished || batch.destination != TransferDestination.gallery) {
      return;
    }
    if (!batch.allTerminal) return;
    batch.finished = true;
    final pairs = [
      for (final m in batch.members)
        if (batch.downloads[m.id] != null) (m, batch.downloads[m.id]!),
    ];
    if (pairs.isEmpty) return; // 全取消/全失败:无文件可导
    var uris = const <Uri>[];
    try {
      uris = await gallery.importFiles([
        for (final (m, dl) in pairs)
          GalleryImportRequest(
              path: dl.path, kind: m.entry.kind, filename: m.entry.name),
      ]);
    } on Exception {
      uris = const <Uri>[]; // 导入通道异常 → 全员按「未导入」落定
    }
    for (var i = 0; i < pairs.length; i++) {
      final (m, _) = pairs[i];
      final job = _jobs[m.id];
      if (job == null) continue; // 历史已被清:只删文件,不回填
      job.task = job.task.copyWith(
          galleryUri: i < uris.length ? uris[i] : null); // null = 未导入
    }
    // 临时文件清理:导入成功(字节已进媒体库)与未导入都删,
    // 重试导入走重新入队(全新下载)。
    for (final (_, dl) in pairs) {
      try {
        final f = File(dl.path);
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // 清理失败不掩盖任务结果
      }
    }
    _notify();
  }

  /// 任务快照里没有 ObjectEntry(handle→entry 映射在批次里),
  /// downloader 需要 name/kind/handle → 从批次反查。
  ObjectEntry _entryOf(_Job job) {
    for (final m in job.batch.members) {
      if (m.id == job.task.id) return m.entry;
    }
    throw StateError('任务不在自己批次里:内部状态不一致');
  }

  /// 终态落定 + 通知(queued 取消用;running 取消经 downloader 走)。
  void _settle(_Job job, TransferState state, String? error) {
    job.task = job.task.copyWith(state: state, error: error);
    job.batch.terminalIds.add(job.task.id);
    _notify();
  }
}

/// 传输引擎:入队去重、顺序下载、指数退避重试、相册导入编排。
///
/// 两级流水:下载泵(并发 = 1,相机 PTP 会话本就一次一个事务)只管把
/// 文件拉落盘;落盘后的拆分/水印/XMP/mtime 链入独立 FIFO 后处理链,
/// 与下载重叠 —— 相机链路不再为 CPU 后处理空转(该段以
/// [TransferState.processing] 表达;水印重活本就在子 isolate,这里再
/// 消除的是「后处理期间泵停摆」的串行)。后处理一次一个(多 isolate
/// 并发解码高像素 JPG 的内存峰值不值得)。
///
/// gallery 目的地两段式:整批先流式下载到 tempDir → 全部落定后调
/// **一次** [GallerySaver.importFiles](系统保存对话框只弹一次)→
/// 回填 galleryUri、删临时文件。导入段走引擎级串行闸:泵与后处理都
/// 不等导入,前后两批先后齐员时导入排队,防系统对话框叠罗汉(旧实现
/// 靠「对话框期间泵暂停」达成同一目的)。
///
/// app 目的地:直接流式写入 downloadsDir,文件名冲突加 ` (n)` 序号。
library;

import 'dart:async';
import 'dart:io';

import '../browser/object_entry.dart';
import '../browser/photo_group.dart' show baseNameOf, isJpgFile;
import '../media/motion_photo.dart' show splitMotionPhoto;
import '../media/watermark.dart';
import '../media/xmp_metadata.dart';
import '../ptpip/object_format.dart' show ObjectKind;
import '../../platform/gallery_saver.dart';
import 'object_downloader.dart';
import 'transfer_history.dart';
import 'transfer_task.dart';

abstract interface class TransferEngine {
  /// 任务快照流(进行中 + 历史,入队序);UI 的数据源。启动时持久化
  /// 的历史记录(见 [TransferHistoryStore])会先于此流发出。
  Stream<List<TransferTask>> get tasks;

  /// 入队一批对象到 [destination]。去重只对进行中(queued/running)的
  /// 同 handle + 同目的地生效;已完成的可重新入队(相册重导/失败重试)。
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination});

  /// 取消单个任务:queued 直接标 cancelled;running 置标志(下载器块间
  /// 旗标兜底,排空后以 cancelled 落定);processing 置标志但不可中断
  /// (文件已完整,后处理收尾后照常 completed)。
  Future<void> cancel(String taskId);

  /// 清空历史(仅已完成/已取消/已失败;持久化历史一并清)。
  Future<void> clearHistory();

  /// 删除单条历史记录(传输页左滑单独删除;仅终态,进行中不响应 ——
  /// 取消走 [cancel])。
  Future<void> removeRecord(String taskId);
}

/// 一次 enqueue 对应一个批次:gallery 批次共享同一次导入对话框。
final class _Batch {
  _Batch(this.destination);

  final TransferDestination destination;
  final List<({String id, ObjectEntry entry})> members = [];
  final Map<String, ObjectDownload> downloads = {}; // id → 已完成落盘
  final Map<String, String> liveVideos = {}; // id → 拆出的 MP4 临时文件
  final Set<String> terminalIds = {};
  var finished = false;

  bool get allTerminal => terminalIds.length == members.length;
}

final class _Job {
  _Job(this.task, this.batch);

  TransferTask task; // 就地替换的快照
  final _Batch batch;
  var cancelRequested = false; // running 中被 cancel 置位

  /// 首跑起点(elapsed 墙钟口径;重试不重盖)。
  DateTime? firstStart;

  /// 本次尝试的起点(downloadMs 纯下载口径;重试逐次重盖)。
  DateTime? attemptStart;
}

/// 默认指数退避:第 [retry] 次重试等 200ms * 2^(retry-1)。
Duration _defaultBackoff(int retry) =>
    Duration(milliseconds: 200 * (1 << (retry - 1)));

final class TransferEngineImpl implements TransferEngine {
  TransferEngineImpl({
    required this.downloader,
    required this.gallery,
    this.history,
    this.maxAttempts = 3,
    this.metadataFor,
    this.watermarkFor,
    this.watermarkRaster,
    this.onAppFileSaved,
    Duration Function(int retry)? backoffFor,
  }) : _backoffFor = backoffFor ?? _defaultBackoff {
    // 持久化历史恢复(异步):终态记录拼回快照流,重启后传输页仍有账。
    // 失败静默(空账起家,不反噬传输主链路)。
    if (history != null) {
      _ready = _restoreHistory();
    }
  }

  final ObjectDownloader downloader;
  final GallerySaver gallery;

  /// 终态历史持久化(null = 不持久化,测试/进程内用);构造沿异步
  /// 恢复,终态沿 [TransferHistoryStore.upsert] 落盘。
  final TransferHistoryStore? history;

  /// 元数据提供器:JPG 下载落盘后按此注入 XMP
  ///(版权/作者/评分/GPS);null 或返回 null = 不注入。注入失败
  /// 不影响传输结果(文件在注入前已完整)。
  final Future<XmpMetadata?> Function(ObjectEntry entry)? metadataFor;

  /// 水印提供器:JPG 下载落盘后、XMP 注入前合成水印
  ///(重编码会丢段,顺序不能反);null 或返回 null = 不合成。
  final Future<WatermarkOptions?> Function(ObjectEntry entry)? watermarkFor;

  /// app 目的地单文件落盘收尾回调(评级快照等扩展点;mtime 回写后、
  /// 任务置 completed 前调用);null = 无。异常吞掉不影响传输结果。
  final Future<void> Function(ObjectEntry entry, String path)? onAppFileSaved;

  /// 水印文本光栅注入(测试用色块假实现);null = 生产 dart:ui 渲染。
  final TextRaster? watermarkRaster;

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

  /// 恢复就绪闸:入队沿等账本恢复完(id 序号与去重都以全量任务表为
  /// 基线,半恢复期入队会撞历史号)。无账本即值。
  Future<void> _ready = Future<void>.value();

  @override
  Stream<List<TransferTask>> get tasks => _ctrl.stream;

  List<TransferTask> get _snapshot =>
      [for (final job in _jobs.values) job.task];

  /// 进度通知节流窗:块级 onProgress 到达率远高于 UI 需要率(USB 1MB
  /// 块 ~20+/s;Wi-Fi PTP-IP 按帧更碎,可达百级/s),逐块广播会让 tasks
  /// 的所有订阅者跟着高频重建 —— 常驻图库页在 ListenableBuilder 里
  /// 整页重建且逐文件 statSync,下载期全 app 卡顿的根因。进度快照
  /// 100ms 一档足够顺滑;状态沿(起跑/落定/取消/重排)不走节流,
  /// 即时通知并清掉尾随定时器。
  static const Duration _progressInterval = Duration(milliseconds: 100);
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingNotify;

  void _notify() {
    _trailingNotify?.cancel();
    _trailingNotify = null;
    _lastNotifyAt = DateTime.now();
    _ctrl.add(_snapshot);
  }

  /// 进度沿通知:距上次通知不足窗则合并进尾随定时器(尾随保证窗内
  /// 最后的进度不丢;并发 = 1,泵同时只跑一个任务,单槽足够)。
  void _notifyProgress() {
    if (DateTime.now().difference(_lastNotifyAt) >= _progressInterval) {
      _notify();
      return;
    }
    _trailingNotify ??= Timer(_progressInterval, () {
      _trailingNotify = null;
      _notify();
    });
  }

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {
    await _ready; // 恢复闸:账本拼回后才有正确的 id 起号基线
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
    if (job.task.state == TransferState.running ||
        job.task.state == TransferState.processing) {
      // running:downloader 排空后以 cancelled 落定;processing:后处理
      // 不可中断(文件已完整落盘),旗标无人再查,等自然落 completed
      // —— 与旧实现「下载完成后无法取消」一致。
      job.cancelRequested = true;
    } else {
      _settle(job, TransferState.cancelled, null);
    }
  }

  @override
  Future<void> clearHistory() async {
    _jobs.removeWhere((_, job) => job.task.isTerminal);
    await history?.clear();
    _notify();
  }

  @override
  Future<void> removeRecord(String taskId) async {
    final job = _jobs[taskId];
    if (job == null || !job.task.isTerminal) return; // 进行中:取消走 cancel
    _jobs.remove(taskId);
    _notify();
    await history?.remove(taskId);
  }

  /// 持久化历史恢复:终态记录拼回任务表(批次用已完结的哑批次,导入
  /// 收尾短路),id 序号跳过历史最大值防新任务撞号。
  Future<void> _restoreHistory() async {
    List<TransferTask> records;
    try {
      records = await history!.load();
    } on Object {
      return; // 恢复失败 = 空账起家,不反噬传输主链路
    }
    if (records.isEmpty) return;
    for (final task in records) {
      if (!task.isTerminal) continue; // 账本只收终态;脏数据不计
      final seq = RegExp(r'^t(\d+)$').firstMatch(task.id);
      if (seq != null) {
        _seq = _seq > int.parse(seq.group(1)!) ? _seq : int.parse(seq.group(1)!) + 1;
      }
      final batch = _Batch(task.destination)..finished = true;
      _jobs[task.id] = _Job(task, batch);
    }
    _notify();
  }

  /// 终态沿落盘账本(best-effort,失败静默;store 自带内存快照兜底)。
  void _recordHistory(TransferTask task) {
    if (!task.isTerminal) return;
    unawaited(history?.upsert(task));
  }

  // ---- 队列泵 ----------------------------------------------------------

  Future<void> _pump() async {
    if (_pumping) return; // 已有泵在跑,它会把新任务一起带掉
    _pumping = true;
    try {
      _Job? job;
      while ((job = _firstQueued()) != null) {
        await _runDownload(job!);
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

  /// 下载段(泵内):一个任务的相机传输。成功即把后处理链入独立 FIFO
  /// 链(**不 await**)并返回,泵随即开下一个文件;失败/取消在本段收终态。
  ///
  /// 时间口径:startAt 首跑不重盖;attemptStart 逐次重盖(重试从头下,
  /// downloadMs 只记末次);终态沿盖 finishedAt(= 下载时间)。
  Future<void> _runDownload(_Job job) async {
    job.cancelRequested = false;
    final now = DateTime.now();
    job.firstStart ??= now;
    job.attemptStart = now;
    job.task = job.task.copyWith(
        state: TransferState.running,
        clearError: true,
        startedAt: job.firstStart,
        downloadMs: 0);
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
            _notifyProgress();
          }
        },
        isCancelled: () => job.cancelRequested,
      );
      job.batch.downloads[job.task.id] = dl;
      // 移交后处理:任务落 processing(非终态,批次不收尾),由
      // [_runPostproc] 在后处理链上收场。
      job.task = job.task.copyWith(
          state: TransferState.processing, downloadMs: _attemptMs(job));
      _notify();
      _enqueuePostproc(job, dl);
    } on DownloadCancelledException {
      job.task = job.task.copyWith(
          state: TransferState.cancelled,
          clearError: true,
          downloadMs: _attemptMs(job),
          finishedAt: DateTime.now());
      _settleAfterDownload(job);
    } catch (e) {
      // 链路/写盘失败(StateError、PtpResponseException、FileSystemException…)
      final attempts = job.task.attempts + 1;
      if (attempts <= maxAttempts) {
        await Future<void>.delayed(_backoffFor(attempts));
        job.task = job.task.copyWith(
            state: TransferState.queued, attempts: attempts, error: e.toString());
        _notify();
      } else {
        // 放弃:attempts 保留已用重试数(不含本次放弃的尝试)。
        job.task = job.task.copyWith(
            state: TransferState.failed,
            error: e.toString(),
            downloadMs: _attemptMs(job),
            finishedAt: DateTime.now());
        _settleAfterDownload(job);
      }
    }
  }

  /// 末次尝试的纯下载耗时(毫秒);无起点(理论不可达)记 0。
  int _attemptMs(_Job job) {
    final start = job.attemptStart;
    return start == null ? 0 : DateTime.now().difference(start).inMilliseconds;
  }

  /// 下载段终态收尾(取消/放弃失败):记账 + 落盘账本 + 通知 + 批次收尾检查。
  void _settleAfterDownload(_Job job) {
    if (job.task.isTerminal) {
      job.batch.terminalIds.add(job.task.id);
      _recordHistory(job.task);
    }
    _notify();
    _finishBatchIfDone(job.batch);
  }

  /// 后处理全局 FIFO(串行链,与下载泵并行):失败不断链,同
  /// PtpSession._serialized 口径。
  Future<void> _postprocGate = Future<void>.value();

  void _enqueuePostproc(_Job job, ObjectDownload dl) {
    final run = _postprocGate.then((_) => _runPostproc(job, dl));
    _postprocGate = run.then<void>((_) {}, onError: (_) {});
  }

  /// 后处理段:拆分 → 水印 → XMP → mtime 回写 → 收尾回调,与旧泵内
  /// 实现同序;完成后任务落 completed。文件在下载段已完整落盘,各步骤
  /// 皆 best-effort(内部吞异常),故出乎意料的错误(Error 级)也按
  /// 完成收场 —— 旧实现此时会把任务打成失败重下整档,是文件已完整时
  /// 的误伤。
  Future<void> _runPostproc(_Job job, ObjectDownload dl) async {
    try {
      await _splitMotionPhoto(job, dl); // 先拆(水印重编码会毁内嵌视频段)
      await _applyWatermark(job, dl.path); // 先水印(重编码丢段,XMP 后补)
      await _injectMetadata(job, dl.path);
      // 全部落盘链路(拆分/水印/XMP)收尾后,把 mtime 回写为拍摄时刻
      //(仅 app 目的地):mtime 原为落盘时刻(下载序 ≠ 拍摄序),回写后
      // 本地图库排序/连拍聚合/信息底单都以拍摄时刻为准;gallery 目的地
      // 是临时文件导入系统相册后即删,不必写。best-effort:失败静默。
      try {
        final capturedAt = _entryOf(job).capturedAt;
        if (job.task.destination == TransferDestination.app &&
            capturedAt != null) {
          await File(dl.path).setLastModified(capturedAt);
        }
      } on Exception {
        // 部分文件系统拒绝改 mtime:排序/聚合回落落盘时刻,不挡传输
      }
      if (job.task.destination == TransferDestination.app) {
        try {
          await onAppFileSaved?.call(_entryOf(job), dl.path);
        } on Exception {
          // 收尾扩展点失败(评级快照等)不挡传输
        }
      }
      job.task = job.task.copyWith(
          state: TransferState.completed,
          receivedBytes: dl.bytes,
          finishedAt: DateTime.now());
    } on Object {
      // 后处理意外抛错:文件已完整,不重下,按完成落定(见方法注释)
    }
    job.batch.terminalIds.add(job.task.id);
    _recordHistory(job.task);
    _notify();
    _finishBatchIfDone(job.batch);
  }

  /// 运动照片拆分(实况照片导出):尼康运动照片是 JPG 尾部
  /// 内嵌 MP4 的单文件(Google Motion Photo 字节格式,标记语义待真机
  /// 核对)。gallery 目的地才拆 —— 静帧照常走水印/XMP,视频段记到批次
  /// 收尾配对导出;app 目的地保留相机原始单文件不动。拆不出(普通
  /// JPG)不碰文件。
  Future<void> _splitMotionPhoto(_Job job, ObjectDownload dl) async {
    if (job.task.destination != TransferDestination.gallery) return;
    try {
      if (!isJpgFile(_entryOf(job))) return;
      final file = File(dl.path);
      final src = await file.readAsBytes();
      final split = splitMotionPhoto(src);
      if (split == null) return;
      await file.writeAsBytes(split.image);
      final videoPath = '${dl.path}_live.mp4';
      await File(videoPath).writeAsBytes(split.video);
      job.batch.liveVideos[job.task.id] = videoPath;
    } on Exception {
      // 读盘/写盘/拆分异常:按普通照片走,不挡传输
    }
  }

  /// 下载成功后按需合成水印(见 [watermarkFor])。只对 JPG;失败静默跳过。
  Future<void> _applyWatermark(_Job job, String path) async {
    final watermarkFor = this.watermarkFor;
    if (watermarkFor == null) return;
    try {
      final entry = _entryOf(job);
      if (!isJpgFile(entry)) return;
      final options = await watermarkFor(entry);
      if (options == null || options.style == WatermarkStyle.off) return;
      final file = File(path);
      final src = await file.readAsBytes();
      final out = await applyWatermark(src, options,
          raster: watermarkRaster ?? defaultTextRaster);
      if (identical(src, out)) return;
      await file.writeAsBytes(out);
    } on Exception {
      // 水印失败不掩盖传输结果
    }
  }

  /// 下载成功后按需注入 XMP(见 [metadataFor])。只对 JPG;失败静默跳过
  ///(元数据是锦上添花,不能把传输拖成失败)。
  Future<void> _injectMetadata(_Job job, String path) async {
    final metadataFor = this.metadataFor;
    if (metadataFor == null) return;
    try {
      final entry = _entryOf(job);
      if (!isJpgFile(entry)) return; // RAW/视频不走 XMP APP1 路径
      final meta = await metadataFor(entry);
      if (meta == null || meta.isEmpty) return;
      final file = File(path);
      final src = await file.readAsBytes();
      final out = injectXmpIntoJpeg(src, meta);
      if (identical(src, out)) return; // 非 JPEG(字节级复核)等免写
      await file.writeAsBytes(out);
    } on Exception {
      // 读盘/写盘/提供器异常:任务照常按已下载完成落定
    }
  }

  /// 批次全员落定后收尾:gallery 批次发起一次导入、回填 galleryUri、
  /// 删临时文件;app 批次无事可做(文件已直接落 downloadsDir)。
  ///
  /// 实况照片编排:静帧请求在前(同基名 MOV 成员或运动照片 JPG 拆出的
  /// MP4 挂到 [GalleryImportRequest.videoPath] 配对导入,并入的视频成员
  /// 不再单发、回填同一实况 Uri);其余文件按入队序在后。native 不识别
  /// videoPath 时按普通图片落库。
  ///
  /// 导入段链入 [_importGate] 串行(见字段注释),本方法同步返回。
  void _finishBatchIfDone(_Batch batch) {
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

    final requests = <GalleryImportRequest>[];
    final owners = <List<String>>[]; // 请求 i 覆盖的成员 id(实况 = 静帧+视频)
    final pairedAway = <String>{}; // 已并入实况请求的视频成员 id
    for (final (m, dl) in pairs) {
      if (m.entry.kind != ObjectKind.image || !isJpgFile(m.entry)) continue;
      var videoPath = batch.liveVideos[m.id];
      var videoOwnerId = '';
      for (final (vm, vdl) in pairs) {
        if (!pairedAway.contains(vm.id) &&
            vm.entry.kind == ObjectKind.video &&
            baseNameOf(vm.entry.name) == baseNameOf(m.entry.name)) {
          videoPath = vdl.path;
          videoOwnerId = vm.id;
          pairedAway.add(vm.id);
          break;
        }
      }
      requests.add(GalleryImportRequest(
        path: dl.path,
        kind: m.entry.kind,
        filename: m.entry.name,
        videoPath: videoPath,
      ));
      owners.add([m.id, if (videoOwnerId.isNotEmpty) videoOwnerId]);
    }
    for (final (m, dl) in pairs) {
      if (m.entry.kind == ObjectKind.image && isJpgFile(m.entry)) continue;
      if (pairedAway.contains(m.id)) continue;
      requests.add(GalleryImportRequest(
          path: dl.path, kind: m.entry.kind, filename: m.entry.name));
      owners.add([m.id]);
    }

    final run =
        _importGate.then((_) => _importBatch(requests, owners, batch));
    _importGate = run.then<void>((_) {}, onError: (_) {});
  }

  /// 导入串行闸:gallery 系统导入对话框一次只弹一个。泵与后处理都不等
  /// 导入后,前后两批可能先后齐员 —— 导入段在此排队,防对话框叠罗汉
  /// (旧「对话框期间泵暂停」语义的替代实现);失败不断链。
  Future<void> _importGate = Future<void>.value();

  /// 导入段(importGate 内):调导入、回填 Uri、删临时文件、通知。
  ///
  /// 临时文件 = 请求的 path + videoPath(拆出的 `_live.mp4` / 配对 MOV)
  /// ∪ [batch] 的 liveVideos 全集 —— 后者兜「运动照片与同基名 MOV 同批,
  /// videoPath 位被 MOV 占走」的边角,拆出的视频段也不落孤儿。
  Future<void> _importBatch(List<GalleryImportRequest> requests,
      List<List<String>> owners, _Batch batch) async {
    var uris = const <Uri>[];
    try {
      uris = await gallery.importFiles(requests);
    } on Exception {
      uris = const <Uri>[]; // 导入通道异常 → 全员按「未导入」落定
    }
    for (var i = 0; i < owners.length; i++) {
      final uri = i < uris.length ? uris[i] : null;
      for (final id in owners[i]) {
        final job = _jobs[id];
        if (job == null) continue; // 历史已被清:只删文件,不回填
        job.task = job.task.copyWith(galleryUri: uri);
        // 导入结果晚于 completed 沿(账本已按无 Uri 记过):回填沿重记,
        // 持久化账本的「已导入」口径与快照一致。
        _recordHistory(job.task);
      }
    }
    // 临时文件清理:导入成功(字节已进媒体库)与未导入都删,
    // 重试导入走重新入队(全新下载)。
    final tempPaths = <String>[
      ...batch.liveVideos.values,
      for (final r in requests) ...[
        r.path,
        if (r.videoPath case final v?) v,
      ],
    ];
    for (final path in tempPaths) {
      try {
        final f = File(path);
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
    job.task = job.task.copyWith(state: state, error: error,
        finishedAt: DateTime.now());
    job.batch.terminalIds.add(job.task.id);
    _recordHistory(job.task);
    _notify();
  }
}

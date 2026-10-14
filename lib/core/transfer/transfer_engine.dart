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
import '../browser/photo_group.dart' show baseNameOf, isJpgFile;
import '../media/motion_photo.dart' show splitMotionPhoto;
import '../media/watermark.dart';
import '../media/xmp_metadata.dart';
import '../ptpip/object_format.dart' show ObjectKind;
import '../../data/settings_store.dart' show WatermarkStyle;
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
}

/// 默认指数退避:第 [retry] 次重试等 200ms * 2^(retry-1)。
Duration _defaultBackoff(int retry) =>
    Duration(milliseconds: 200 * (1 << (retry - 1)));

final class TransferEngineImpl implements TransferEngine {
  TransferEngineImpl({
    required this.downloader,
    required this.gallery,
    this.maxAttempts = 3,
    this.metadataFor,
    this.watermarkFor,
    this.watermarkRaster,
    Duration Function(int retry)? backoffFor,
  }) : _backoffFor = backoffFor ?? _defaultBackoff;

  final ObjectDownloader downloader;
  final GallerySaver gallery;

  /// 元数据提供器(TODO §四):JPG 下载落盘后按此注入 XMP
  ///(版权/作者/评分/GPS);null 或返回 null = 不注入。注入失败
  /// 不影响传输结果(文件在注入前已完整)。
  final Future<XmpMetadata?> Function(ObjectEntry entry)? metadataFor;

  /// 水印提供器(TODO §五 T4):JPG 下载落盘后、XMP 注入前合成水印
  ///(重编码会丢段,顺序不能反);null 或返回 null = 不合成。
  final Future<WatermarkOptions?> Function(ObjectEntry entry)? watermarkFor;

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

  /// 运动照片拆分(TODO §五 LivePhoto 导出):尼康运动照片是 JPG 尾部
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
      }
    }
    // 临时文件清理:导入成功(字节已进媒体库)与未导入都删,
    // 重试导入走重新入队(全新下载)。
    final tempPaths = <String>[
      for (final (_, dl) in pairs) dl.path,
      ...batch.liveVideos.values,
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
    job.task = job.task.copyWith(state: state, error: error);
    job.batch.terminalIds.add(job.task.id);
    _notify();
  }
}

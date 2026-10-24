/// 传输任务模型。
library;

/// 任务状态机:queued → running(下载中)→ processing(落盘后处理:
/// 拆分/水印/XMP/mtime/收尾回调)→ completed;失败/取消见各自终态。
/// running 与 processing 拆开的缘由:后处理不占相机链路,可与下一个
/// 文件的下载重叠(见 TransferEngineImpl);running 保持「至多一个」
/// 的下载语义,processing 可与 running 并存。
enum TransferState { queued, running, processing, completed, failed, cancelled }

/// 下载目的地:系统相册(ohos 经系统保存对话框导入)/ 应用内存储。
enum TransferDestination { gallery, app }

final class TransferTask {
  const TransferTask({
    required this.id,
    required this.handle,
    required this.filename,
    required this.totalBytes,
    required this.destination,
    this.state = TransferState.queued,
    this.receivedBytes = 0,
    this.error,
    this.attempts = 0,
    this.galleryUri,
    this.startedAt,
    this.finishedAt,
    this.downloadMs = 0,
  });

  final String id;
  final int handle; // 相机侧 object handle
  final String filename;
  final int totalBytes;
  final TransferDestination destination;

  final TransferState state;
  final int receivedBytes;
  final String? error;

  /// 已重试次数;指数退避,上限 3 次。
  final int attempts;

  /// 相册导入结果(gallery 目的地);null = 未导入(用户取消对话框/
  /// 导入失败)或非 gallery 任务。重新入队可重试导入。
  final Uri? galleryUri;

  /// 首次进入 running 的时刻(重试不重盖);排队即取消则 null。
  final DateTime? startedAt;

  /// 终态落定时刻(completed/failed/cancelled 即「下载时间」,持久化
  /// 后按它倒序;非终态 null)。
  final DateTime? finishedAt;

  /// 末次尝试的纯下载耗时(重试逐次清零重计):速度 = 字节 ÷ 它,
  /// 重试退避与后处理不摊进下载速度。
  final int downloadMs;

  /// 全程墙钟耗时(首跑起跑到终态,含重试退避与后处理);缺起点或
  /// 终点(非终态/排队即取消)返回 null。
  Duration? get elapsed {
    final s = startedAt, f = finishedAt;
    return (s == null || f == null) ? null : f.difference(s);
  }

  /// 下载速度 bytes/s;只对 completed 且下过字节有意义(失败半程/
  /// 取消半程不设速度口径)。
  double? get downloadSpeed =>
      state == TransferState.completed && downloadMs > 0 && receivedBytes > 0
          ? receivedBytes * 1000 / downloadMs
          : null;

  bool get isTerminal =>
      state == TransferState.completed ||
      state == TransferState.failed ||
      state == TransferState.cancelled;

  double? get progress =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  TransferTask copyWith({
    TransferState? state,
    int? receivedBytes,
    String? error,
    bool clearError = false,
    int? attempts,
    Uri? galleryUri,
    bool clearGalleryUri = false,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? downloadMs,
  }) =>
      TransferTask(
        id: id,
        handle: handle,
        filename: filename,
        totalBytes: totalBytes,
        destination: destination,
        state: state ?? this.state,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        error: clearError ? null : (error ?? this.error),
        attempts: attempts ?? this.attempts,
        galleryUri: clearGalleryUri ? null : (galleryUri ?? this.galleryUri),
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        downloadMs: downloadMs ?? this.downloadMs,
      );
}

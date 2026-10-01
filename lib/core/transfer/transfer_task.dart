/// 传输任务模型(TODO.md §四)。
library;

enum TransferState { queued, running, completed, failed, cancelled }

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
  });

  final String id;
  final int handle; // 相机侧 object handle
  final String filename;
  final int totalBytes;
  final TransferDestination destination;

  final TransferState state;
  final int receivedBytes;
  final String? error;

  /// 已重试次数;指数退避,上限 3 次(TODO.md §四 P1)。
  final int attempts;

  /// 相册导入结果(gallery 目的地);null = 未导入(用户取消对话框/
  /// 导入失败)或非 gallery 任务。重新入队可重试导入。
  final Uri? galleryUri;

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
      );
}

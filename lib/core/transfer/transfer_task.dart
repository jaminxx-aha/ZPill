/// 传输任务模型(TODO.md §四)。
library;

enum TransferState { queued, running, completed, failed, cancelled }

final class TransferTask {
  const TransferTask({
    required this.id,
    required this.handle,
    required this.filename,
    required this.totalBytes,
    this.state = TransferState.queued,
    this.receivedBytes = 0,
    this.error,
    this.attempts = 0,
  });

  final String id;
  final int handle; // 相机侧 object handle
  final String filename;
  final int totalBytes;

  final TransferState state;
  final int receivedBytes;
  final String? error;

  /// 已重试次数;指数退避,上限 3 次(TODO.md §四 P1)。
  final int attempts;

  double? get progress =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  TransferTask copyWith({
    TransferState? state,
    int? receivedBytes,
    String? error,
    int? attempts,
  }) =>
      TransferTask(
        id: id,
        handle: handle,
        filename: filename,
        totalBytes: totalBytes,
        state: state ?? this.state,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        error: error ?? this.error,
        attempts: attempts ?? this.attempts,
      );
}

/// 单对象流式下载(传输引擎的工作单元)。
///
/// 分工:GetObject 数据容器按块回调(PtpTransport.execute 的 onData)→
/// 本类边收边写目标文件,**不整体驻留内存**;写到哪个目录、下载完
/// 之后要不要进相册,由 TransferEngine 编排(本类不碰 GallerySaver)。
///
/// 取消语义:[isCancelled] 返回 true 后停止写盘(transport 继续收块
/// 排空数据流,保持 USB/PTP 事务状态机干净),排空完毕删除半成品,
/// 抛 [DownloadCancelledException]。
library;

import 'dart:io';

import '../browser/object_entry.dart';
import '../ptp/ptp_session.dart';

/// 下载被取消:半成品已删,数据流已排空。
final class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '下载已取消';
}

/// 一次完成的下载:落盘信息 + 耗时/平均速度。
final class ObjectDownload {
  const ObjectDownload({
    required this.path,
    required this.bytes,
    required this.elapsed,
    required this.averageBytesPerSecond,
  });

  final String path;
  final int bytes;
  final Duration elapsed;
  final double averageBytesPerSecond;

  double get megabytesPerSecond => averageBytesPerSecond / 1024 / 1024;
}

final class ObjectDownloader {
  ObjectDownloader({required PtpSession session}) : _session = session;

  final PtpSession _session;

  /// 流式下载 [entry] 到 [targetDir](不存在则创建),文件名冲突自动
  /// 加 ` (n)` 序号。[onProgress] 每块回调累计字节数(块大小对齐
  /// kUsbStreamChunkBytes,64KB 级)。
  Future<ObjectDownload> download(
    ObjectEntry entry, {
    required String targetDir,
    void Function(int receivedBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(targetDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File(await uniquePath(dir, _safeBasename(entry.name)));
    final sink = file.openWrite();
    final watch = Stopwatch()..start();
    var received = 0;
    var cancelled = false;
    try {
      await _session.getObject(entry.handle, onData: (chunk) {
        if (isCancelled != null && isCancelled()) {
          cancelled = true;
          return; // 不写盘,继续收块排空
        }
        if (cancelled) return;
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      });
      await sink.flush();
      await sink.close();
    } on Exception {
      try {
        await sink.close();
      } on Exception {
        // 关闭失败不掩盖原始异常
      }
      await _deleteQuietly(file);
      rethrow;
    }
    watch.stop();
    if (cancelled) {
      await _deleteQuietly(file);
      throw const DownloadCancelledException();
    }
    return ObjectDownload(
      path: file.path,
      bytes: received,
      elapsed: watch.elapsed,
      averageBytesPerSecond: received / watch.elapsed.inMicroseconds * 1e6,
    );
  }

  /// 目录内不冲突的完整路径:`A.JPG` → `A (1).JPG`、`A (2).JPG`…
  /// (app 目的地持久保留会撞名;gallery 临时目录残留也一并防住。)
  static Future<String> uniquePath(Directory dir, String basename) async {
    final dot = basename.lastIndexOf('.');
    final stem = dot > 0 ? basename.substring(0, dot) : basename;
    final ext = dot > 0 ? basename.substring(dot) : '';
    var candidate = basename;
    var n = 0;
    while (await File('${dir.path}/$candidate').exists()) {
      n++;
      candidate = '$stem ($n)$ext';
    }
    return '${dir.path}/$candidate';
  }

  static Future<void> _deleteQuietly(File file) async {
    if (await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException {
        // 删失败不掩盖原始结果
      }
    }
  }

  /// 只取最后一段作文件名(PTP 相机文件名本不含分隔符,防御性处理)。
  static String _safeBasename(String name) {
    final base = name.split('/').last;
    return base.isEmpty ? 'object' : base;
  }
}

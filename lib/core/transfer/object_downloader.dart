/// 单对象流式下载(P0 闭环的最小传输实现;TODO.md §四 的完整
/// TransferEngine 队列化留 P1,复用本类的落盘/测速逻辑)。
///
/// 分工:GetObject 数据容器按块回调(PtpTransport.execute 的 onData)→
/// 本类边收边写临时文件,**不整体驻留内存**;完成后尝试经
/// [GallerySaver] 导入系统相册 —— ohos v1 导入未实现(安全控件限制,
/// 计划内后备):保留沙箱文件并返回路径。
library;

import 'dart:io';

import '../../platform/gallery_saver.dart';
import '../browser/object_entry.dart';
import '../ptp/ptp_session.dart';

/// 一次完成的下载:落盘信息 + 耗时/平均速度(P0 传输测速即取此处数据)。
final class ObjectDownload {
  const ObjectDownload({
    required this.path,
    required this.bytes,
    required this.elapsed,
    required this.averageBytesPerSecond,
    this.galleryUri,
  });

  /// 文件落盘路径(已导入相册时为导入前的临时文件)。
  final String path;

  final int bytes;
  final Duration elapsed;
  final double averageBytesPerSecond;

  /// 相册内容 Uri;null = 未导入(ohos v1 后备:沙箱文件,展示路径)。
  final Uri? galleryUri;

  double get megabytesPerSecond => averageBytesPerSecond / 1024 / 1024;
}

final class ObjectDownloader {
  ObjectDownloader({required PtpSession session, required GallerySaver gallery})
      : _session = session,
        _gallery = gallery;

  final PtpSession _session;
  final GallerySaver _gallery;

  /// 流式下载 [entry] 到临时目录。[onProgress] 每块回调累计字节数
  /// (UI 进度对话框用;块大小对齐 kUsbStreamChunkBytes,64KB 级)。
  ///
  /// 失败/取消语义:删除半成品临时文件后原样上抛。
  Future<ObjectDownload> download(
    ObjectEntry entry, {
    void Function(int receivedBytes)? onProgress,
  }) async {
    final dir = await _gallery.tempDir();
    final file = File('$dir/${_safeBasename(entry.name)}');
    final sink = file.openWrite();
    final watch = Stopwatch()..start();
    var received = 0;
    try {
      await _session.getObject(entry.handle, onData: (chunk) {
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
      if (await file.exists()) {
        try {
          await file.delete();
        } on FileSystemException {
          // 同上
        }
      }
      rethrow;
    }
    watch.stop();

    Uri? uri;
    try {
      uri = await _gallery.importFile(
        file.path,
        kind: entry.kind,
        filename: entry.name,
      );
    } on UnimplementedError {
      // ohos v1(计划内后备):相册导入未实现,保留沙箱文件、返回路径。
    } on Exception {
      // 导入失败:下载本身已成功,同样保留沙箱文件、返回路径。
    }
    return ObjectDownload(
      path: file.path,
      bytes: received,
      elapsed: watch.elapsed,
      averageBytesPerSecond:
          received / watch.elapsed.inMicroseconds * 1e6,
      galleryUri: uri,
    );
  }

  /// 只取最后一段作文件名(PTP 相机文件名本不含分隔符,防御性处理)。
  static String _safeBasename(String name) {
    final base = name.split('/').last;
    return base.isEmpty ? 'object' : base;
  }
}

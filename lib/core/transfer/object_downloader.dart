/// 单对象流式下载(传输引擎的工作单元)。
///
/// 分工:数据容器按块回调(PtpTransport.execute 的 onData)→ 本类边收
/// 边写目标文件,**不整体驻留内存**;写到哪个目录、下载完之后要不要
/// 进相册,由 TransferEngine 编排(本类不碰 GallerySaver)。
///
/// 两条取数路线(2026-10-09 真机教训定案):
/// - 整档 GetObject 流式([partialChunkBytes] = null,缺省):单事务,
///   数据相位流式分块;取消时停止写盘但继续收块**排空数据流**
///   (保持 USB/PTP 事务状态机干净),排空完毕删除半成品。此路线不挂
///   Cancel-Drain —— 整档排水量不可预估(数百 MB MOV),墙钟阀只会
///   误杀慢链,维持排空即删的旧语义。
/// - GetPartialObject 分块([partialChunkBytes] > 0):每块一个完整
///   事务,块间响应取消/进度。取消双保险:块间旗标停发新块(旧路径,
///   链路不支持时兜底)+ **块在途期间轮询旗标对在途块发 Cancel-Drain**
///   (PTP-IP,私有轮询周期默认 50ms)—— 用户取消即时生效,不必等
///   在途块自然跑完;在途块以 [PtpCancelledException] 收口,本类映射为
///   [DownloadCancelledException](取消成功,不是传输失败)。
///   **iOS IC 通道必须走分块路线**:ImageCaptureCore 把整个数据相位
///   塞进一次 requestSendPTPCommand 回调,多 MB 大档(NEF 24MB / MOV
///   数百 MB)一次回调不可控 —— 真机触发读超时 → 看门狗判链路死亡,
///   整 app 断连(缩略图/点击全挂)。64KB 分块与镜头头读同款(IC 链
///   已验证粒度);ohos/Android 通道内部本就 1MB 流块,保持 GetObject
///   不降速。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../browser/object_entry.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';

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

/// 非 final + 依赖字段私有:widget 测试可 implements(仅 download,
/// 注入假路径,避开真机事务;与 PtpSession/ThumbnailCache 同款纪律)。
class ObjectDownloader {
  ObjectDownloader({
    required PtpSession session,
    this.partialChunkBytes,
    Duration? cancelPollInterval,
  })  : _cancelPollInterval =
            cancelPollInterval ?? const Duration(milliseconds: 50),
        _session = session;

  final PtpSession _session;

  /// GetPartialObject 单块字节;null = 整档 GetObject 流式(见库注释)。
  /// 相机 op 表无 0x101B 时忽略本参数,回落 GetObject。
  final int? partialChunkBytes;

  /// 分块路线的取消轮询周期:块在途期间盯 [download] 的 isCancelled
  /// 旗标,翻真即对在途块发 Cancel-Drain(PTP-IP;链路不支持为 no-op)。
  /// 触发延迟 ≤ 本值;50ms 相对块 RTT(≥100ms)不可感。
  ///
  /// 私有字段是刻意的:公共成员会进 `implements ObjectDownloader` 的
  /// 测试假件接口(widget 测试「仅 download」契约,见类注)。
  final Duration _cancelPollInterval;

  /// 流式下载 [entry] 到 [targetDir](不存在则创建),文件名冲突自动
  /// 加 ` (n)` 序号。[onProgress] 回调累计字节数(整档路线块大小对齐
  /// kUsbStreamChunkBytes,64KB 级;分块路线 = [partialChunkBytes])。
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
    var chunked = false;
    try {
      chunked = partialChunkBytes != null && await _partialReadable();
      if (chunked) {
        // 分块路线:每块是完整事务,取消/失败即停,不再发新命令。
        // 取消双保险:块间旗标(旧路径兜底)+ 块在途轮询旗标对在途块
        // 发 Cancel-Drain(即时生效,不必等在途块跑完)。
        var offset = 0;
        var chunkInFlight = false;
        var cancelFired = false;
        Timer? cancelPoller;
        if (isCancelled != null) {
          final check = isCancelled;
          cancelPoller = Timer.periodic(_cancelPollInterval, (_) {
            if (!chunkInFlight || cancelFired || !check()) return;
            cancelFired = true; // 一块只发一次 Cancel
            unawaited(_cancelInFlightQuietly());
          });
        }
        try {
          while (offset < entry.sizeInBytes) {
            if (isCancelled != null && isCancelled()) {
              cancelled = true;
              break;
            }
            final want =
                math.min(partialChunkBytes!, entry.sizeInBytes - offset);
            chunkInFlight = true;
            final Uint8List chunk;
            try {
              chunk =
                  await _session.getPartialObject(entry.handle, offset, want);
            } finally {
              chunkInFlight = false;
            }
            if (chunk.isEmpty) break; // 相机提前收尾
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received);
            offset += chunk.length;
            if (chunk.length < want) break; // 短读 = EOF
          }
        } finally {
          cancelPoller?.cancel();
        }
      } else {
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
      }
      await sink.flush();
      await sink.close();
    } on PtpCancelledException {
      // 在途块被本端 Cancel-Drain 收口:按「取消成功」收场(不得当
      // 传输失败重试)。半成品照删,异常换成下载管线的取消语义。
      try {
        await sink.close();
      } on Exception {
        // 关闭失败不掩盖取消语义
      }
      await _deleteQuietly(file);
      throw const DownloadCancelledException();
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
    if (chunked && received != entry.sizeInBytes) {
      // 分块路线对账:实收不足(ObjectInfo 谎报/相机中途断流)= 半档,
      // 不能当成功落盘。
      await _deleteQuietly(file);
      throw FormatException(
          '下载数据不完整:${entry.name} 期望 ${entry.sizeInBytes}B,'
          '实收 ${received}B');
    }
    return ObjectDownload(
      path: file.path,
      bytes: received,
      elapsed: watch.elapsed,
      averageBytesPerSecond: received / watch.elapsed.inMicroseconds * 1e6,
    );
  }

  /// 对在途块事务发 Cancel-Drain;取消通道自身异常一律静默 ——
  /// 旧路径(块间旗标停发)已在兜底,取消不该因通道抖动变失败。
  Future<void> _cancelInFlightQuietly() async {
    try {
      await _session.cancelInFlight();
    } on Exception {
      // 静默:见上
    }
  }

  /// 0x101B 能力门禁(op 表在册才走分块;取能力失败也回落整档)。
  Future<bool> _partialReadable() async {
    try {
      return (await _session.getDeviceInfo())
          .supportsOperation(PtpOperationCode.getPartialObject);
    } on Exception {
      return false;
    }
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

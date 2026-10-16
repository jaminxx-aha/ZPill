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
///   事务,块间响应取消/进度;**单块大小由 AIMD 策略演化**(64KB 起步,
///   快块加性升、超时/错误减半、1MB 封顶,见 [AimdChunkPolicy];定值
///   时代 iOS 64KB→1MB 的两次手工调参由此自动化)。取消 = 旗标等
///   **在途块跑完**(≤AIMD 封顶,亚秒级)再停,不发新块 —— **不对在
///   途块发 PTP-IP Cancel 包**(2026-10-16 真机 2.2 定案:Zf 收 Cancel
///   直接掐链,取消即断链;软取消的即时性代价一块,远小于断链代价;
///   曾用 Cancel-Drain 机制留传输层留档,生产已无调用方)。
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
import 'aimd_chunk.dart';

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
    AimdChunkPolicy? chunkPolicy,
  })  : // 每下载器(= 传输会话)一个策略实例:跨 download 调用延续学习,
        // 不跨下载器/会话共享。注入是测试口径(小数值 + 判快阈值可控);
        // 缺省自建,上限随 [partialChunkBytes](生产 iOS = 1MB)。
        _chunkPolicy =
            chunkPolicy ?? AimdChunkPolicy(maxBytes: partialChunkBytes),
        _session = session;

  final PtpSession _session;

  /// 分块路线开关 + 单块上限([AimdChunkPolicy] 缺省自建时的封顶;
  /// 注入策略时本值只当路线开关,大小演化全归策略)。null = 整档
  /// GetObject 流式(见库注释)。相机 op 表无 0x101B 时忽略,回落
  /// GetObject。
  final int? partialChunkBytes;

  /// 分块路线的 AIMD 策略(块大小演化,见库注释)。私有字段是刻意的:
  /// 公共成员会进 `implements ObjectDownloader` 的测试假件接口。
  final AimdChunkPolicy _chunkPolicy;

  /// 流式下载 [entry] 到 [targetDir](不存在则创建),文件名冲突自动
  /// 加 ` (n)` 序号。[onProgress] 回调累计字节数(整档路线块大小对齐
  /// kUsbStreamChunkBytes,64KB 级;分块路线 = AIMD 策略当前块,见
  /// [_chunkPolicy])。
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
        // 分块路线:每块是完整事务,取消/失败即停,不再发新命令。取消 =
        // 旗标等**在途块跑完**(≤AIMD 封顶,亚秒级)再停 —— **不对在途
        // 块发 PTP-IP Cancel 包**:2026-10-16 真机 2.2 定案,Zf 收 Cancel
        // 直接掐链(取消即断链);软取消的即时性代价(一块)远小于断链
        // 代价。Cancel-Drain 机制留传输层留档,生产已无调用方。
        var offset = 0;
        while (offset < entry.sizeInBytes) {
          if (isCancelled != null && isCancelled()) {
            cancelled = true;
            break;
          }
          final want =
              math.min(_chunkPolicy.currentBytes, entry.sizeInBytes - offset);
          final chunkWatch = Stopwatch()..start();
          final Uint8List chunk;
          try {
            chunk =
                await _session.getPartialObject(entry.handle, offset, want);
          } on TimeoutException {
            // 超时(USB 单事务读超时):链路撑不起这个块大小 —— 喂降。
            _chunkPolicy.reportTimeout();
            rethrow;
          } on PtpCancelledException {
            rethrow; // 取消收口(若上层有取消通道):不惩罚(用户行为 ≠ 链路质量)
          } on Exception {
            // 传输错误(相机拒绝应答 / PTP-IP 看门狗断链 / …):喂降。
            _chunkPolicy.reportError();
            rethrow;
          }
          // 成功:带耗时喂策略(快 → 加性升;慢 → 不动,见策略口径)。
          _chunkPolicy.reportSuccess(chunkWatch.elapsed);
          if (chunk.isEmpty) break; // 相机提前收尾
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received);
          offset += chunk.length;
          if (chunk.length < want) break; // 短读 = EOF
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

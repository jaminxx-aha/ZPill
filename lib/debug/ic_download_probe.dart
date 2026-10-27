/// IC 高速下载探针(诊断):requestDownloadWithOptions 三点核验。
///
/// 背景(2026-10-25):iOS 有线下载 13MB/s —— 分块路线每块一次
/// requestSendPTPCommand 守护进程 XPC 往返(块 ~48ms 固定开销占主导);
/// 同类应用 30MB/s。IC 的 requestDownloadFile(iOS 13+ 公开 API,头文件
/// 已核)让守护进程整文件直落盘,无逐块事务 —— 本探针量它的真机
/// 吞吐/进度/取消三点,定夺下载路线是否切换。
///
/// 同靶对照:①基线 = 生产分块路线(0x9431/0x101B,逐块账由下载器自记);
/// ②IC 整档直落盘 + NSProgress 进度采样;③IC 取消试验(1.5s 到点
/// cancel,真停与否看完成错误 + 落盘字节数)。
///
/// 输出走 AppLog(transfer 域)随设置页导出;总闸
/// --dart-define=USB_DL_PROBE=true,常规运行零开销。探针用完不删
/// (诊断惯例,见 nikon_exif_probe.dart)。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../core/browser/object_entry.dart';
import '../core/log/app_log.dart';
import '../core/ptp/ptp_session.dart';
import '../core/ptpip/object_format.dart';
import '../core/ptpip/object_info.dart';
import '../core/transfer/object_downloader.dart';

/// 总闸(--dart-define=USB_DL_PROBE=true)。
const bool kUsbDlProbe = bool.fromEnvironment('USB_DL_PROBE');

final class IcDownloadProbe {
  IcDownloadProbe._();

  static const MethodChannel _usb = MethodChannel('zpill/usb');

  /// IC 取消试验的到点时长(大档取 1.5s 内的采样足以判真停)。
  static const int _cancelAfterMs = 1500;

  /// 连接落定沿入口(受 kUsbDlProbe 总闸,装配在 app_services)。
  static Future<void> run({
    required PtpSession session,
    required ObjectDownloader downloader,
    required Future<String> Function() tempDir,
  }) async {
    try {
      final entry = await pickLargest(session, ObjectKind.image);
      if (entry == null) {
        AppLog.i(AppLog.transfer, 'IC 探针: 卡上无静照对象');
        return;
      }
      AppLog.i(AppLog.transfer,
          'IC 探针选靶: ${entry.name} ${_mb(entry.sizeInBytes)}MB'
          '(0x${entry.handle.toRadixString(16).toUpperCase()})');

      // ① 基线:生产分块路线(逐块账由下载器自记,此处只记汇总)。
      final dl = await downloader.download(entry, targetDir: await tempDir());
      AppLog.i(AppLog.transfer,
          '基线(分块): ${_mb(dl.bytes)}MB ${dl.elapsed.inMilliseconds}ms'
          ' = ${dl.megabytesPerSecond.toStringAsFixed(1)}MB/s');

      // ② IC 整档直落盘(吞吐 + 进度采样)。
      await _icRun(entry.name, cancelAfterMs: 0);

      // ③ IC 取消核验(到点 cancel,看真停与否)。
      await _icRun(entry.name, cancelAfterMs: _cancelAfterMs);

      // ④ 0x9400 高速读裸速探针(下载专态预演):规格明文读卡快于
      //    GetPartialObject;游标式有状态,黑名单命令一律先行,循环内
      //    只发 0x9400,收场 Terminate=1。
      await _highSpeedRun(session);

      // 清扫:基线产物是探针素材,不留(临时目录系统可回收,主动删)。
      try {
        await _deleteQuietly(dl.path);
      } on Exception {
        // 清扫失败不掩盖探针结果
      }
    } on Exception catch (e) {
      AppLog.e(AppLog.transfer, 'IC 探针失败: $e');
    }
  }

  /// 选靶:枚举全卡取指定类目下最大档([kind]=image 静照 / video 视频)。
  static Future<ObjectEntry?> pickLargest(
      PtpSession session, ObjectKind kind) async {
    final handles = await session.getObjectHandles();
    ObjectEntry? pick;
    var pickSize = 0;
    for (final h in handles) {
      final PtpObjectInfo info;
      try {
        info = await session.getObjectInfo(h);
      } on Exception {
        continue; // 个别句柄撤收(0x2009)等,跳过不影响选靶
      }
      var objKind = kindForFormatCode(info.objectFormat);
      if (objKind == ObjectKind.other) {
        objKind = kindForFilename(info.filename); // NEF 0x3000 同款扩展名兜底
      }
      if (objKind != kind) continue;
      if (info.compressedSize <= pickSize) continue;
      pickSize = info.compressedSize;
      pick = ObjectEntry(
        handle: h,
        name: info.filename,
        sizeInBytes: info.compressedSize,
        kind: kind,
        formatCode: info.objectFormat,
      );
    }
    return pick;
  }

  /// 0x9400 裸速探针(§6.2.3.5):游标式顺序整档,每块对账应答游标
  /// (参 2/3 = 执行前 offset,复位篡流当场现形);黑名单命令
  /// (GetObjectHandles/GetObjectInfo 等)一律在游标启动前收口。
  static const int _hsChunkBytes = 16 * 1024 * 1024;

  static Future<void> _highSpeedRun(PtpSession session) async {
    final entry = await pickLargest(session, ObjectKind.video);
    if (entry == null) {
      AppLog.i(AppLog.transfer, '0x9400 探针: 卡上无视频对象');
      return;
    }
    AppLog.i(AppLog.transfer,
        '0x9400 选靶: ${entry.name} ${_mb(entry.sizeInBytes)}MB'
        '(0x${entry.handle.toRadixString(16).toUpperCase()})');
    var received = 0;
    final watch = Stopwatch()..start();
    try {
      var chunks = 0;
      while (received < entry.sizeInBytes) {
        final chunkWatch = Stopwatch()..start();
        final r = await session.getPartialObjectHighSpeed(entry.handle,
            maxBytes: math.min(_hsChunkBytes, entry.sizeInBytes - received));
        chunkWatch.stop();
        if (r.cursorOffset != received) {
          AppLog.w(AppLog.transfer,
              '0x9400 游标错位:应答 cursor=${r.cursorOffset} 期望 $received'
              '(黑名单命令插足/会话被扰?)—— 探针中止');
          return;
        }
        if (r.data.isEmpty) break; // 相机提前收尾
        received += r.data.length;
        chunks++;
        AppLog.i(AppLog.transfer,
            '高速块 0x9400 ${entry.name} cursor=${r.cursorOffset}'
            ' got=${r.data.length} ${chunkWatch.elapsedMilliseconds}ms');
      }
      watch.stop();
      final mbps =
          watch.elapsedMilliseconds > 0 ? received / 1048576 / (watch.elapsedMilliseconds / 1000) : 0.0;
      AppLog.i(AppLog.transfer,
          '0x9400 汇总: ${_mb(received)}MB $chunks 块'
          ' ${watch.elapsedMilliseconds}ms = ${mbps.toStringAsFixed(1)}MB/s');
    } on Exception catch (e) {
      watch.stop();
      AppLog.w(AppLog.transfer,
          '0x9400 探针失败(已收 ${_mb(received)}MB): $e');
    } finally {
      // 收态:Terminate=1(规格:数据相恒 0 字节),游标即刻释放;
      // 失败静默 —— 60s 间隔超时兜底释放。
      try {
        await session.getPartialObjectHighSpeed(entry.handle,
            maxBytes: _hsChunkBytes, terminate: true);
      } on Exception {
        // 收态失败不掩盖探针结果
      }
    }
  }

  /// 单次 IC 下载:'icProbeDownload' → 原生日字典 → AppLog 记账。
  static Future<void> _icRun(String filename, {required int cancelAfterMs}) async {
    try {
      final r = await _usb.invokeMethod<Map<dynamic, dynamic>>('icProbeDownload',
          {'filename': filename, 'cancelAfterMs': cancelAfterMs});
      if (r == null) {
        AppLog.w(AppLog.transfer, 'IC 探针($filename): 空回执');
        return;
      }
      final bytes = (r['bytes'] as num?)?.toInt() ?? 0;
      final ms = (r['ms'] as num?)?.toInt() ?? 0;
      final mbps = ms > 0 ? bytes / 1048576 / (ms / 1000) : 0.0;
      final err = (r['error'] as String?) ?? '';
      AppLog.i(AppLog.transfer,
          'IC ${cancelAfterMs > 0 ? '取消试验' : '吞吐'}: $filename'
          ' ok=${r['ok']} bytes=$bytes ms=$ms = ${mbps.toStringAsFixed(1)}MB/s'
          ' savedAs=${r['savedAs']} dir=${r['dir']}'
          '${err.isEmpty ? '' : ' err=$err'}');
      final samples = r['samples'];
      if (samples is List && samples.isNotEmpty) {
        AppLog.i(AppLog.transfer,
            'IC 进度采样(${samples.length} 点): 首3=${
                samples.take(3).map((s) => s.toString()).join(' | ')}'
            '${samples.length > 3 ? ' … 尾=${samples.last}' : ''}');
      }
    } on Exception catch (e) {
      AppLog.w(AppLog.transfer, 'IC 探针失败($filename): $e');
    }
  }

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  static Future<void> _deleteQuietly(String path) async {
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
    }
  }
}

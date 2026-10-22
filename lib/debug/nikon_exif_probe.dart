/// 快门数探针(诊断):连接沿从最新照片挖 ShutterCount 进日志。
///
/// 解析本体已转正 [parseNikonShutterCount](core/exif/nikon_maker_note
/// .dart,相机信息弹窗现读同源);本文件只留探针壳 —— 取最新句柄、
/// 头部分块读、结果拼日志。SDK 定案(2026-10-22,sdk 全卷):远程协议
/// 全族不公开快门数(0xD101 在 Zf 是 ExternalDC-IN,勿照搬 gphoto2
/// 老机身口径),EXIF MakerNote 0x00A7 是唯一现实来源。
///
/// 输出走 AppLog(protocol 域)随设置页导出;受 kPtpDiagnosticsOn
/// Connect 总闸(--dart-define=PTP_DIAG=true),常规运行零开销。
/// 探针用完不删(诊断惯例,见 ptp_diagnostics.dart)。
library;

import 'dart:typed_data';

import '../core/exif/nikon_maker_note.dart';
import '../core/log/app_log.dart';
import '../core/ptp/ptp_session.dart';

/// 头部读取量。EXIF 链(IFD0→ExifIFD→MakerNote IFD)全在文件前部,
/// NEF 实测 0x00A7 在头 ~38KB;512KB 覆盖 HEIF 盒结构绰绰有余。
const int _kHeadBytes = 512 * 1024;
const int _kFallbackHeadBytes = 64 * 1024;

String _h(int v) => '0x${v.toRadixString(16).toUpperCase()}';

/// 连接沿探针入口(受 PTP_DIAG 总闸,常量 kPtpDiagnosticsOnConnect
/// 在 ptp_diagnostics.dart)。
final class NikonExifProbe {
  NikonExifProbe._();

  /// 枚举全卡取最新句柄 → 头部分块读 → 解析 MakerNote 快门数。
  static Future<void> run(PtpSession session) async {
    try {
      final handles = await session.getObjectHandles();
      if (handles.isEmpty) {
        AppLog.i(AppLog.protocol, '快门数探针: 卡上无对象');
        return;
      }
      var handle = handles.first;
      for (final v in handles) {
        if (v > handle) handle = v; // PTP 句柄随拍摄递增,最大 = 最新
      }
      final info = await session.getObjectInfo(handle);
      Uint8List head;
      var headNote = '${_kHeadBytes ~/ 1024}KB';
      try {
        head = await session.getPartialObject(handle, 0, _kHeadBytes);
      } catch (_) {
        head = await session.getPartialObject(handle, 0, _kFallbackHeadBytes);
        headNote = '${_kFallbackHeadBytes ~/ 1024}KB(512KB 被拒降级)';
      }
      final r = parseNikonShutterCount(head);
      final parts = [
        '句柄=${_h(handle)}',
        '文件=${info.filename}',
        '格式=${_h(info.objectFormat)}',
        '大小=${info.compressedSize}B',
        if (info.captureDate != null) '拍摄=${info.captureDate}',
        '读档=$headNote',
        'EXIF=${r.exifFound}',
        'MakerNote=${r.makerNoteFound}',
        if (r.makerNoteVersion != null) '版本=${r.makerNoteVersion}',
        '快门数=${r.shutterCount ?? '未见'}',
        if (r.dateTimeOriginal != null) '原时=${r.dateTimeOriginal}',
        '路径=${r.note}',
        if (r.makerNoteHex != null) 'MakerNote头=${r.makerNoteHex}',
      ];
      AppLog.i(AppLog.protocol, '快门数探针: ${parts.join(' | ')}');
      // v8:全 tag dump 单独一条,拍摄前后 diff 找会涨的计数 tag。
      if (r.nikonTagDump != null) {
        AppLog.i(AppLog.protocol, '快门数探针 tags: ${r.nikonTagDump}');
      }
    } catch (e) {
      AppLog.i(AppLog.protocol, '快门数探针异常: $e');
    }
  }
}

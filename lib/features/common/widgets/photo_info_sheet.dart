/// 照片信息底单(查看器共用:相机相册 + 图库)。
///
/// 两段内容:①调用方给的文件级信息(文件名/大小/连拍/兜底时间)——
/// 立即显示;②EXIF 摘要(机身/镜头/参数/拍摄时间)—— [loadExif]
/// 懒加载(相机侧 64KB 头读走 ThumbnailCache.exifCardOf,图库侧本地
/// 读头 [readExifCardFromFile]),在途一行小转圈,无 EXIF/失败静默
/// 收起(文件级信息不缺;EXIF 无拍摄时间时回落兜底时间)。视频组只走
/// 第一段(loadExif 传 null)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/media/watermark.dart' show ExifCardData, exifCardFromHead;
import '../../../l10n/l10n.dart';
import 'kv_row.dart';
import '../format.dart' show formatBytes, formatDateTime;

/// 本地文件的 EXIF 头读(JPG APP1 / NEF TIFF 头同路,≤64KB)。
/// 按 路径+修改时间+大小 记忆:同一文件编辑/重写后键变,自动重读。
final Map<String, Future<ExifCardData?>> _fileCards = {};

Future<ExifCardData?> readExifCardFromFile(File file) {
  final key = '${file.path}|${file.lastModifiedSync().millisecondsSinceEpoch}'
      '|${file.lengthSync()}';
  return _fileCards.putIfAbsent(key, () async {
    Uint8List head;
    try {
      final raf = file.openSync();
      try {
        final stat = raf.lengthSync();
        head = raf.readSync(stat < 64 * 1024 ? stat : 64 * 1024);
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      unawaited(_fileCards.remove(key)); // 读失败不驻留:下次再试
      return null;
    }
    return exifCardFromHead(head);
  });
}

/// 弹照片信息底单。见 library 注释。
Future<void> showPhotoInfoSheet(
  BuildContext context, {
  required String filename,
  int? sizeBytes,
  String? burstLabel,
  String? fallbackTime,
  Future<ExifCardData?> Function()? loadExif,
}) {
  // build 外取一次:FutureBuilder 的 future 必须稳定,重建不重发。
  final exifFuture = loadExif?.call();
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      // 标签列宽:全量标签(文件级 + EXIF 两段)取最长实测,两段行共用
      // 一宽列对齐;zh 短标签落 64 下限观感不变(原钉宽),EN 长词
      // (Captured/Exposure)放行不折行不省略。
      final labelWidth = kvLabelWidth(
        context,
        labels: [
          context.t('info.file'),
          context.t('info.size'),
          context.t('info.burst'),
          context.t('info.time'),
          context.t('info.captured'),
          context.t('info.body'),
          context.t('info.lens'),
          context.t('info.exposure'),
        ],
        style: const TextStyle(fontSize: 13),
        minWidth: 64,
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                context.t('info.title'),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _row(context, context.t('info.file'), filename, labelWidth),
            if (sizeBytes != null)
              _row(context, context.t('info.size'), formatBytes(sizeBytes),
                  labelWidth),
            if (burstLabel != null)
              _row(context, context.t('info.burst'), burstLabel, labelWidth),
            if (exifFuture == null)
              _row(context, context.t('info.time'), fallbackTime ?? '—',
                  labelWidth)
            else
              FutureBuilder<ExifCardData?>(
                future: exifFuture,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final card = snap.data;
                  final time =
                      formatDateTime(card?.takenAt) ?? fallbackTime;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (time != null)
                        _row(
                            context,
                            context.t(card?.takenAt != null
                                ? 'info.captured'
                                : 'info.time'),
                            time,
                            labelWidth),
                      if (card?.titleLine.isNotEmpty == true)
                        _row(context, context.t('info.body'), card!.titleLine,
                            labelWidth),
                      if (card?.lens != null)
                        _row(
                            context, context.t('info.lens'), card!.lens!, labelWidth),
                      if (card?.paramLine.isNotEmpty == true)
                        _row(context, context.t('info.exposure'),
                            card!.paramLine, labelWidth),
                    ],
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 底单行(KvRow 收编):标签列共用 [labelWidth](见 showPhotoInfoSheet
/// 内的整组实测);标签单行省略、色 token 化(onSurfaceVariant,原
/// Colors.grey 对比度不过 AA),行高/行距/边距与旧布局一致。
Widget _row(BuildContext context, String label, String value,
    double labelWidth) {
  return KvRow(
    labelWidth: labelWidth,
    label: label,
    labelStyle: TextStyle(
        fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
    value: Text(value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14)),
    crossAxisAlignment: CrossAxisAlignment.start,
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
  );
}

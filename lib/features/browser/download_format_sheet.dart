/// 下载格式选择面板(单张/多选共用)。
///
/// 批次含双格式(RAW+JPG)组或照片视频混选时,下载前让用户选格式;纯
/// 单一格式批次不弹(直接下载)。多选时缺所选格式的组会被跳过,由面板
/// 文案预告。
library;

import 'package:flutter/material.dart';

import '../../core/browser/photo_group.dart';
import '../../l10n/l10n.dart';

/// 弹出格式选择;返回 null = 用户取消。
Future<PhotoDownloadFormat?> showDownloadFormatSheet(BuildContext context,
    {required String subtitle}) {
  return showModalBottomSheet<PhotoDownloadFormat>(
    context: context,
    // shrinkWrap ListView:选项多(或辅助功能大字体)时面板可滚,
    // 不因超出底部弹层高度而溢出。
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(context.t('fmt.chooseTitle'),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              // subtitle 由调用方预翻译(context.t)后传入
              child: Text(subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor)),
            ),
          ),
          for (final format in PhotoDownloadFormat.values)
            ListTile(
              // label 的键存 core 的 PhotoDownloadFormat 枚举(本波不动
              // 枚举),显示点包 t;「JPG + RAW」纯拉丁未命中原文直返
              title: Text(context.t(format.label)),
              subtitle: switch (format) {
                PhotoDownloadFormat.jpg =>
                  Text(context.t('fmt.jpgSkipNote')),
                PhotoDownloadFormat.raw =>
                  Text(context.t('fmt.rawSkipNote')),
                PhotoDownloadFormat.both =>
                  Text(context.t('fmt.anyNote')),
                PhotoDownloadFormat.video => Text(context.t('fmt.videoOnlyNote')),
              },
              onTap: () => Navigator.pop(context, format),
            ),
        ],
      ),
    ),
  );
}

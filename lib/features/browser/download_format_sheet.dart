/// 下载格式选择面板(单张/多选共用)。
///
/// 批次含双格式(RAW+JPG)组或照片视频混选时,下载前让用户选格式;纯
/// 单一格式批次不弹(直接下载)。多选时缺所选格式的组会被跳过,由面板
/// 文案预告。
library;

import 'package:flutter/material.dart';

import '../../core/browser/photo_group.dart';

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
              child: Text('选择下载格式',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor)),
            ),
          ),
          for (final format in PhotoDownloadFormat.values)
            ListTile(
              title: Text(format.label),
              subtitle: switch (format) {
                PhotoDownloadFormat.jpg => const Text('没有 JPG 的照片会跳过(视频照常)'),
                PhotoDownloadFormat.raw => const Text('没有 RAW 的照片会跳过(视频照常)'),
                PhotoDownloadFormat.both => const Text('有什么下什么(缺哪个格式就只下另一个)'),
                PhotoDownloadFormat.video => const Text('只下视频,照片全部跳过'),
              },
              onTap: () => Navigator.pop(context, format),
            ),
        ],
      ),
    ),
  );
}

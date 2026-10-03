/// 下载格式选择面板(单张/多选共用)。
///
/// 双格式(RAW+JPG)照片组下载前让用户选格式;单格式组与视频不弹
/// (直接下载)。多选时缺所选格式的组会被跳过,由面板文案预告。
library;

import 'package:flutter/material.dart';

import '../../core/browser/photo_group.dart';

/// 弹出格式选择;返回 null = 用户取消。
Future<PhotoDownloadFormat?> showDownloadFormatSheet(
    BuildContext context, {required String subtitle}) {
  return showModalBottomSheet<PhotoDownloadFormat>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                PhotoDownloadFormat.jpg => const Text('没有 JPG 的照片会跳过'),
                PhotoDownloadFormat.raw => const Text('没有 RAW 的照片会跳过'),
                PhotoDownloadFormat.both =>
                  const Text('有什么下什么(缺哪个格式就只下另一个)'),
              },
              onTap: () => Navigator.pop(context, format),
            ),
        ],
      ),
    ),
  );
}

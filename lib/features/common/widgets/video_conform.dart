/// 顺帧播放帮手(浏览/图库查看器共用):
/// 高帧率(>30.5fps)素材播放前弹「实时 / 24fps 顺帧」二选一 ——
/// 顺帧 = 播放速率 24/fps(60fps 素材 = 0.4,即 OpenZCine conform
/// 口径的「60 → 24 fps · 40%」);≤30fps 或帧率未知直接实时播,
/// 不多一道门。
///
/// 帧率探测失败/平台无通道([VideoPlayer.frameRate] 回 null)按实时
/// 处理 —— 顺帧是可选增强,不拦播放路径。对话框栏外点按 = 取消
/// (不播)。
library;

import 'package:flutter/material.dart';

import '../../../platform/video_player.dart';

/// 顺帧门槛:标称帧率高于此值才算高帧率素材(30 与 29.97 都不算)。
const double kConformFpsGate = 30.5;

/// 顺帧目标帧率(24fps 影视口径)。
const double kConformTargetFps = 24;

/// 播放 [path]:高帧率素材先问实时还是顺帧。
///
/// 返回是否真正发起播放(用户取消顺帧选择 = false);[onPlayed]
/// 在选定期望速率后、播放调用前回调(测试观测用)。
Future<bool> playVideoWithConform(
  BuildContext context, {
  required VideoPlayer player,
  required String path,
  void Function(double rate)? onPlayed,
}) async {
  final fps = await player.frameRate(path);
  if (!context.mounted) return false;
  var rate = 1.0;
  if (fps != null && fps > kConformFpsGate) {
    final conform = await showDialog<bool>(
      context: context,
      builder: (context) => _ConformDialog(fps: fps),
    );
    if (conform == null) return false; // 栏外取消
    if (conform) rate = kConformTargetFps / fps;
  }
  onPlayed?.call(rate);
  await player.play(path, rate: rate);
  return true;
}

class _ConformDialog extends StatelessWidget {
  const _ConformDialog({required this.fps});

  final double fps;

  @override
  Widget build(BuildContext context) {
    final shownFps = fps.round();
    final percent = (kConformTargetFps / fps * 100).round();
    return AlertDialog(
      title: const Text('高帧率素材'),
      content: Text(
          '该视频为 $shownFps fps。按 24fps 顺帧播放可看慢动作细节'
          '($shownFps → 24 fps · $percent%)。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('实时播放'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('24fps 顺帧 · $percent%'),
        ),
      ],
    );
  }
}

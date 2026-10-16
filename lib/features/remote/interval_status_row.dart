import 'package:flutter/material.dart';

import '../../core/remote/intervalometer.dart';
import '../../l10n/l10n.dart';
import 'live_design.dart';
import 'remote_controller.dart';

/// 间隔拍摄运行状态行(贴取景画面下沿,横幅同位、恒暗面玻璃 —— 叠在
/// 取景画面上的内容层,不随应用主题,同 [LiveBanner] 口径):进度
/// 「第 x/y 张」(y = ∞ 无限轮)+ 失败计数 + 暂停/恢复 + 停止。
/// 常驻到轮子收口([stopReason] 摘要走 notice 横幅);key 供测试定位。
class IntervalStatusRow extends StatelessWidget {
  const IntervalStatusRow({
    super.key,
    required this.controller,
    this.bottomInset = 0,
  });

  final RemoteController controller;

  /// 让位底部浮层(动作行等;与横幅同款口径)。
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.dark;
    final paused = controller.intervalStatus == IntervalometerStatus.paused;
    final total = controller.intervalShotCount;
    final totalLabel = total == null ? '∞' : '$total';
    Widget action({
      required String key,
      required IconData icon,
      required Color color,
      required String tooltip,
      required VoidCallback onTap,
    }) =>
        Tooltip(
          message: tooltip,
          child: InkWell(
            key: ValueKey(key),
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(icon, size: 20, color: color),
          ),
        );
    return Container(
      key: const ValueKey('interval-status-row'),
      margin: EdgeInsets.fromLTRB(16, 0, 16, 10 + bottomInset),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: live.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timelapse, size: 14, color: live.accent),
          const SizedBox(width: 6),
          Text(
            paused
                ? context.t('interval.shotsPaused',
                    {'a': '${controller.intervalTaken}', 'b': totalLabel})
                : context.t('interval.shotsProgress',
                    {'a': '${controller.intervalTaken}', 'b': totalLabel}),
            style: TextStyle(
                fontSize: 12,
                color: live.accent,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (controller.intervalFailed > 0) ...[
            const SizedBox(width: 6),
            Text(
              context.t('interval.failedCount', {'n': '${controller.intervalFailed}'}),
              style: TextStyle(fontSize: 11, color: live.bad),
            ),
          ],
          const SizedBox(width: 8),
          action(
            key: 'interval-pause',
            icon: paused ? Icons.play_arrow : Icons.pause,
            color: live.accent,
            tooltip: paused
                ? context.t('interval.resume')
                : context.t('interval.pause'),
            onTap: paused ? controller.resumeInterval : controller.pauseInterval,
          ),
          const SizedBox(width: 4),
          action(
            key: 'interval-stop',
            icon: Icons.stop_circle_outlined,
            color: live.bad,
            tooltip: context.t('interval.stop'),
            onTap: controller.stopInterval,
          ),
        ],
      ),
    );
  }
}

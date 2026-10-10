/// 连接页状态卡与存储余量卡:连接状态的进度感(connecting/pairing
/// 内嵌 spinner)、失败原因两段排版 + 重试;双卡槽余量条。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/storage_info.dart';
import '../../core/camera/camera_connection.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../common/format.dart';

/// 连接状态卡:状态色一行 + 阶段文案;connecting/pairing/detecting
/// 尾槽 14px spinner(死 IP 的 TCP 超时最长 ~5s,转圈才有「在干活」的
/// 可感知进度);失败态副文显示 [hint](首句加粗、详情换行,错误字符串
/// 本身不动)+ 重试钮。
class ConnectionStatusCard extends StatelessWidget {
  const ConnectionStatusCard({
    super.key,
    required this.state,
    this.waitingConfirm = false,
    this.hint,
    this.onRetry,
  });

  final CameraLinkState state;

  /// 配对后的机身确认等待窗(真机:相机弹「配对完成」等按 OK)——
  /// 期间状态保持 connecting,用专属文案替代「连接中…」。
  final bool waitingConfirm;

  /// 状态提示(失败原因/配对等待指引);null 不占位。
  final String? hint;

  /// 失败重试(重放最近一次连接尝试)。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = switch (state) {
      CameraLinkState.detecting ||
      CameraLinkState.connecting ||
      CameraLinkState.pairing ||
      CameraLinkState.reconnecting => true,
      _ => false,
    };
    final (label, color) = switch (state) {
      CameraLinkState.disconnected => ('未连接', scheme.onSurfaceVariant),
      CameraLinkState.detecting => ('检测相机 WiFi…', scheme.primary),
      CameraLinkState.connecting when waitingConfirm =>
        ('等待相机上确认配对…', scheme.secondary),
      CameraLinkState.connecting => ('连接中…', scheme.primary),
      CameraLinkState.pairing => ('等待配对确认…', scheme.secondary),
      CameraLinkState.connected => ('已连接', AppColors.success(context)),
      CameraLinkState.reconnecting => ('正在重连…', scheme.secondary),
      CameraLinkState.failed => ('连接失败', scheme.error),
    };
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lan, color: color),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color),
                  )
                else
                  Icon(Icons.circle, color: color, size: 12),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _HintText(
                text: hint!,
                color: state == CameraLinkState.failed
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ],
            if (state == CameraLinkState.failed && onRetry != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// hint 两段排版:按首个「:」拆首句/详情(「连不上 x.x.x.x:…」/
/// 「相机拒绝了连接(InitFail…):…」)。无冒号整行直出。
class _HintText extends StatelessWidget {
  const _HintText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style =
        TextStyle(color: color, fontSize: 13, height: 1.45);
    final idx = text.indexOf(':');
    if (idx < 0) {
      return Text(text, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text.substring(0, idx + 1),
            style: style.copyWith(fontWeight: FontWeight.w600)),
        Text(text.substring(idx + 1), style: style),
      ],
    );
  }
}

/// 双卡槽余量卡:每槽一行(名 + 剩余/总容量 + 余量进度条)。相机未上报
/// 容量只显示名字;无槽不占位。(相册页删除后随相机信息卡组落户此处。)
class StoragePanel extends StatelessWidget {
  const StoragePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final overview = AppServices.instance.storageOverview;
    return ListenableBuilder(
      listenable: overview,
      builder: (context, _) {
        final storages = overview.storages;
        if (storages.isEmpty) {
          return const SizedBox.shrink();
        }
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Column(
              children: [
                for (final storage in storages)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: _StorageRow(storage: storage),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.storage});

  final CameraStorage storage;

  @override
  Widget build(BuildContext context) {
    final ratio = storage.freeRatio;
    final colorScheme = Theme.of(context).colorScheme;
    // 低余量(<10%)转警示色。
    final barColor =
        ratio != null && ratio < 0.1 ? colorScheme.error : colorScheme.primary;
    return Row(
      children: [
        Icon(Icons.sd_card_outlined,
            size: 20, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(storage.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium),
              if (ratio != null) ...[
                const SizedBox(height: AppSpacing.xs),
                LinearProgressIndicator(
                  value: 1 - ratio, // 已用占比
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Text(
          storage.maxCapacityBytes > 0
              ? '${formatBytes(storage.freeSpaceBytes)} 可用 / ${formatBytes(storage.maxCapacityBytes)}'
              : '容量未知',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

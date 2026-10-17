/// 连接页状态卡:连接状态的进度感(connecting/pairing 内嵌 spinner)、
/// 失败原因两段排版 + 重试。未连接视图专用 —— 已连接总览(bento 卡)
/// 见 connected_overview.dart,存储余量组随其迁出。
library;

import 'package:flutter/material.dart';

import '../../core/camera/camera_connection.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';

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
      CameraLinkState.disconnected => ('conn.notConnected', scheme.onSurfaceVariant),
      CameraLinkState.detecting => ('conn.detectingWifi', scheme.primary),
      CameraLinkState.connecting when waitingConfirm =>
        ('conn.waitingPairConfirm', scheme.secondary),
      CameraLinkState.connecting => ('conn.connecting', scheme.primary),
      CameraLinkState.pairing => ('conn.waitingPairing', scheme.secondary),
      CameraLinkState.connected => ('conn.connected', AppColors.success(context)),
      CameraLinkState.reconnecting => ('conn.reconnecting', scheme.secondary),
      CameraLinkState.failed => ('conn.failed', scheme.error),
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
                  // label 即 t() 键(switch 内吐抽象键),显示点统一包 t()。
                  child: Text(
                    context.t(label),
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
                  label: Text(context.t('common.retry')),
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
    // 消费点统一包 t():静态文案在控制器/连接层吐抽象键,带 $e 插值的
    // 运行期串不是键,两表未命中经直通原样回落中文。
    final localized = context.t(text);
    final idx = localized.indexOf(':');
    if (idx < 0) {
      return Text(localized, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localized.substring(0, idx + 1),
            style: style.copyWith(fontWeight: FontWeight.w600)),
        Text(localized.substring(idx + 1), style: style),
      ],
    );
  }
}

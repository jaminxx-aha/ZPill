import 'package:flutter/material.dart';

import '../../../design/app_dimens.dart';
import '../../../l10n/l10n.dart';
import '../../../l10n/message.dart';

/// 居中加载态:spinner + 说明文案。
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.lg),
            // 调用方给中文原文,显示端统一 t()(重复包裹无害,未命中原文直返)
            Text(context.t(message!), textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

/// 空态:低强调图标 + 主文案(+ 可选动作按钮)。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData? icon;
  final String message;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
          ],
          Text(context.t(message),
              textAlign: TextAlign.center, style:
                  TextStyle(color: scheme.onSurfaceVariant)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonal(
              onPressed: onAction,
              child: Text(context.t(actionLabel!)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 硬错误面板:错误文案 + 重试按钮(列表拉不动、页级失败时整页顶替)。
class ErrorRetryPanel extends StatelessWidget {
  const ErrorRetryPanel({
    super.key,
    required this.message,
    required this.onRetry,
  });

  /// 键+参记录,tm() 一次落地(含 {e} 运行期插值参)。
  final L10nMessage message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.tm(message), textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(onPressed: onRetry, child: Text(context.t('common.retry'))),
          ],
        ),
      ),
    );
  }
}

/// 贴顶内嵌提示条(如同步失败横幅):淡 error 底 + 文案 + 可选动作钮。
class InlineHint extends StatelessWidget {
  const InlineHint({
    super.key,
    required this.message,
    this.icon = Icons.sync_problem,
    this.actionLabel,
    this.onAction,
  });

  /// 键+参记录,tm() 一次落地(含 {e} 运行期插值参)。
  final L10nMessage message;
  final IconData? icon;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: scheme.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Text(context.tm(message),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onErrorContainer)),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(context.t(actionLabel!)),
            ),
        ],
      ),
    );
  }
}

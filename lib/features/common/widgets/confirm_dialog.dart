import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// 统一确认对话框:标题 + 正文 + 取消/确认。destructive 操作
/// (删除/忘记)的确认钮用 error 实底,与普通确认视觉区分。
///
/// 标题/正文/确认钮文案由调用方给中文原文,此处显示端统一走 t()
/// (消费端收口:调用方无需自包;重复包裹亦无害,enCatalog 未命中原文
/// 直返)。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(dialogContext.t(title)),
        content: Text(dialogContext.t(content)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.t('取消')),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t(confirmLabel)),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// 全屏加载遮罩(拉原图等长操作):黑遮罩 + spinner + 白字,
/// 不可点散、不可返回。调用方在完成后自行 pop。
Future<void> showLoadingOverlay(
  BuildContext context, {
  required String message,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 12),
            // 调用方给中文原文,显示端统一 t()(未命中原文直返)
            Text(dialogContext.t(message),
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    ),
  );
}

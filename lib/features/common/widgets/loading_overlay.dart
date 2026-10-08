import 'package:flutter/material.dart';

/// 全屏加载遮罩(拉原图等长操作):黑遮罩 + spinner + 白字,
/// 不可点散、不可返回。调用方在完成后自行 pop。
Future<void> showLoadingOverlay(
  BuildContext context, {
  required String message,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 12),
            Text(message, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    ),
  );
}

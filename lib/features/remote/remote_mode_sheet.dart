import 'dart:async';

import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';
import 'remote_param_sheet.dart' show TakeoverSection;

/// 模式条点按的接管门(**未接管时**弹出):点「照片/视频」段即已表达
/// 切换意图(不弹选择列表,2026-10-12 用户定案),这里只补接管这道门
/// —— 与拍摄参数底单的接管区([TakeoverSection])同款文案与交互(点
/// ISO 未接管时同款观感)。「启用」成功后底单收口、自动走切换链
/// ([RemoteController.switchMode]);启用失败提示随控制器横幅,面板
/// 留着可重试。已接管时模式条点按**不弹任何面板**(直切)。
Future<void> showModeTakeoverSheet(
    BuildContext context, RemoteController controller,
    {required CaptureMode target}) async {
  var enabling = false;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: LiveDesign.of(context).surface,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final live = LiveDesign.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('拍摄模式',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: live.muted)),
              ),
              TakeoverSection(
                busy: enabling,
                onEnable: () {
                  enabling = true;
                  unawaited(() async {
                    final ok = await controller.enableTakeover();
                    enabling = false;
                    if (!ok) return; // 失败:控制器已置 error(横幅),面板留着重试
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                    await controller.switchMode(target);
                  }());
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

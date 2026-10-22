import 'package:flutter/material.dart';

import '../../design/app_haptics.dart';
import '../../l10n/l10n.dart';
import 'live_design.dart';
import 'remote_controller.dart';

/// 模式条(iPhone 相机语言,快门上方「照片 | 视频」):38 高玻璃胶囊
/// 双等宽段,选中段金底金字金描边;[enabled] = false(录制中/切换中)
/// 整体置灰且不吃点按 —— 录制里锁模式,保证停录钮(同一颗快门)不被
/// 模式切换甩在身后。
///
/// [mode] 是**相机真状态**([RemoteController.cameraMode],0xD1A6 镜像,
/// null 时页面回落本地态);[switchableTo] 标各段可否远程切到 —— 不可
/// 的非选中段按 live.faint 弱化(此机身模式写被拒过时两方向全灰,此外
/// 两方向都可切:2026-10-11 Zf 实证覆写两向都被接受),点按仍回调(未
/// 接管弹「启用 APP 接管控制?」接管门、已接管直切,remote_mode_sheet)。
class CaptureModeStrip extends StatelessWidget {
  const CaptureModeStrip({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onModeChanged,
    this.switchableTo = const {
      CaptureMode.photo,
      CaptureMode.video,
    },
  });

  final CaptureMode mode;

  /// 录制中锁条(置灰 + 忽略点按)。
  final bool enabled;

  final ValueChanged<CaptureMode> onModeChanged;

  /// 可远程切到的段集合(相机门控;表外段灰显但可点 —— 提示归控制器)。
  final Set<CaptureMode> switchableTo;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    Widget segment(CaptureMode m, String label) {
      final selected = mode == m;
      final dimmed = !selected && !switchableTo.contains(m);
      return InkWell(
        onTap: enabled && !selected
            ? () {
                AppHaptics.selection(); // 切档确认沿(轻点)
                onModeChanged(m);
              }
            : null,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected ? live.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: selected
                ? Border.all(color: live.accent.withValues(alpha: 0.5))
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color:
                    selected ? live.accent : (dimmed ? live.faint : live.muted),
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Container(
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: live.glass,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: live.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              segment(CaptureMode.photo, context.t('common.photo')),
              segment(CaptureMode.video, context.t('common.video')),
            ],
          ),
        ),
      ),
    );
  }
}

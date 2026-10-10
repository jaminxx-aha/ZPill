import 'package:flutter/material.dart';

import 'live_design.dart';

/// 拍摄模式(页面级 UI 态,2026-10-10 拍照/录像合并为一颗快门起):
/// 照片 = 按下/抬起语义(B 门/连拍按住/自拍,见快门钮);视频 = 整段
/// 点按起/停录像(红芯)。控制器**没有**模式概念 —— Zf 实体拨杆决定
/// 机身侧档位,`toggleRecord` 遇 0xA004 自会提示「拨杆未切录像」。
enum CaptureMode { photo, video }

/// 模式条(iPhone 相机语言,快门上方「照片 | 视频」):38 高玻璃胶囊
/// 双等宽段,选中段金底金字金描边;[enabled] = false(录制中)整体
/// 置灰且不吃点按 —— 录制里锁模式,保证停录钮(同一颗快门)不被
/// 模式切换甩在身后。状态随页面([mode] 由页面 State 持有,横竖屏
/// 重建不丢),录制态由外层 AnimatedBuilder 驱动重绘。
class CaptureModeStrip extends StatelessWidget {
  const CaptureModeStrip({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onModeChanged,
  });

  final CaptureMode mode;

  /// 录制中锁条(置灰 + 忽略点按)。
  final bool enabled;

  final ValueChanged<CaptureMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    Widget segment(CaptureMode m, String label) {
      final selected = mode == m;
      return InkWell(
        onTap: enabled && !selected ? () => onModeChanged(m) : null,
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
                color: selected ? live.accent : live.muted,
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
              segment(CaptureMode.photo, '照片'),
              segment(CaptureMode.video, '视频'),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_controller.dart';

/// 对焦浮层(2026-10-10 iPhone 相机式重排:控制行「对焦」钮的非模态
/// 玻璃浮层,竖屏底锚居中/横屏让位右缘快门柱):AF 自动对焦(0x90C1,
/// 对焦中转圈)| MF 向近/向远步进(0x9204 相对量,跟焦环语义;近在
/// 左、远在右,同镜头距离刻度)| 拉焦轮开关(取景画面右缘竖条,拖动
/// = 连续拉焦;重开清失败预算从可用态起步)。点取景画面或再点对焦钮
/// 即收(见 RemotePage);状态随控制器 + [toggles](页面级视图偏好),
/// 监听由外层 AnimatedBuilder 驱动。
class CaptureFocusPanel extends StatelessWidget {
  const CaptureFocusPanel({
    super.key,
    required this.controller,
    required this.toggles,
    required this.onTogglesChanged,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final void Function(MonitorToggles toggles) onTogglesChanged;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _afButton(live, controller),
          const SizedBox(width: 14),
          _mfStepButtons(live, controller),
          const SizedBox(width: 14),
          _focusDialToggle(live),
        ],
      ),
    );
  }

  /// AF 钮:驱动一次自动对焦(0x90C1;取景开启是前置 —— 未开取景机身
  /// 回 0xA00B)。40px 玻璃方 + 10px 下标签,对焦中转圈禁点。
  Widget _afButton(LivePalette live, RemoteController controller) {
    final usable = controller.linkUp && controller.liveViewActive;
    return InkWell(
      onTap: usable && !controller.focusing ? controller.afDriveNow : null,
      customBorder:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: !usable || controller.focusing
                  ? live.surface
                  : live.glass,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: live.hairline),
            ),
            child: Center(
              child: controller.focusing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: live.accent),
                    )
                  : Icon(Icons.center_focus_strong,
                      size: 20,
                      color: usable ? live.text : live.muted),
            ),
          ),
          const SizedBox(height: 3),
          Text(controller.focusing ? '对焦中' : 'AF 对焦',
              style: TextStyle(fontSize: 10, color: live.muted)),
        ],
      ),
    );
  }

  /// MF 步进(0x9204 相对量,跟焦环语义;近在左、远在右,同镜头距离
  /// 刻度):34×40 横排小钮对 + MF 小标。
  Widget _mfStepButtons(LivePalette live, RemoteController controller) {
    final usable = controller.linkUp && controller.liveViewActive;
    Widget step(IconData icon, bool towardNear, String tip) {
      return Tooltip(
        message: tip,
        child: SizedBox(
          width: 34,
          height: 40,
          child: Material(
            color: live.glass,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: live.hairline),
            ),
            child: InkWell(
              onTap: usable
                  ? () => controller.mfDriveStep(towardNear: towardNear)
                  : null,
              child: Icon(icon,
                  size: 16, color: usable ? live.text : live.faint),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            step(Icons.remove, true, 'MF 向近(步进)'),
            const SizedBox(width: 3),
            step(Icons.add, false, 'MF 向远(步进)'),
          ],
        ),
        const SizedBox(height: 3),
        Text('MF', style: TextStyle(fontSize: 10, color: live.faint)),
      ],
    );
  }

  /// 拉焦轮开关(取景画面右缘竖条):40×34 图标盒,开 = 金;重开清
  /// 失败预算(resetFocusDial),从可用态起步。
  Widget _focusDialToggle(LivePalette live) {
    final current = toggles.focusDial;
    return InkWell(
      onTap: () {
        if (!current) controller.resetFocusDial();
        onTogglesChanged(toggles.copyWith(focusDial: !current));
      },
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 34,
              child: Material(
                color: current ? live.accentDim : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: current
                        ? live.accent.withValues(alpha: 0.5)
                        : live.hairline,
                  ),
                ),
                child: Icon(Icons.vertical_align_center,
                    size: 18,
                    color: current ? live.accent : live.muted),
              ),
            ),
            const SizedBox(height: 2),
            Text('拉焦轮',
                style: TextStyle(
                    fontSize: 10,
                    color: current ? live.accent : live.faint)),
          ],
        ),
      ),
    );
  }
}

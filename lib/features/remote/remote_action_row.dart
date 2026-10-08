import 'dart:async';

import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';
import 'remote_info_pill.dart';

/// 竖屏动作行:取景开关 / 对焦 / 录制 / MF 步进 / 快门(状态随控制器,
/// 监听由外层 AnimatedBuilder 驱动)。颜色随应用主题(LiveDesign.of)。
class CaptureRow extends StatelessWidget {
  const CaptureRow({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _liveViewToggle(live, controller),
          _focusButton(live, controller),
          _recordButton(live, controller),
          _mfNearFarButtons(live, controller),
          _shutterButton(live, controller),
        ],
      ),
    );
  }
}

/// 横屏右动作栏:竖排 取景/对焦/录制 + MF 步进对 + 快门沉底,
/// spaceBetween 分布。图标 + Tooltip(横屏屏面窄,不带下标签);
/// 录制中钮下补时长小字(事件驱动刷新,同信息胶囊)。
class LandscapeActionRail extends StatelessWidget {
  const LandscapeActionRail({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final usable = controller.linkUp && controller.liveViewActive;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        ChromeIconButton(
          icon: controller.liveViewActive
              ? Icons.videocam
              : Icons.videocam_off_outlined,
          tooltip: controller.liveViewActive ? '取景中(点按关闭)' : '取景',
          dimmed: !controller.liveViewActive,
          size: 44,
          onTap: controller.toggleLiveView,
        ),
        ChromeIconButton(
          icon: Icons.center_focus_strong,
          tooltip: controller.focusing ? '对焦中' : '对焦(驱动一次自动对焦)',
          dimmed: !usable,
          size: 44,
          onTap: usable && !controller.focusing ? controller.afDriveNow : null,
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChromeIconButton(
              icon: controller.recording ? Icons.stop : Icons.fiber_manual_record,
              tooltip: controller.recording ? '停录' : '录制',
              dimmed: !usable,
              size: 44,
              onTap: usable && !controller.capturing
                  ? controller.toggleRecord
                  : null,
            ),
            if (controller.recording)
              Text(recDurationLabel(controller.recordingSeconds),
                  style: TextStyle(
                      fontSize: 10,
                      color: live.bad,
                      fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
        _mfNearFarButtons(live, controller),
        _shutterButton(live, controller, size: 64),
      ],
    );
  }
}

/// 玻璃圆角图标钮(横屏 chrome 专用):玻璃底 + 描边 + Tooltip;
/// [selected] 金 accent 高亮(辅助面板开等),[dimmed] 随可用性置灰。
class ChromeIconButton extends StatelessWidget {
  const ChromeIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.size = 36,
    this.selected = false,
    this.dimmed = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool selected;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: selected ? live.accentDim : live.glass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected
                  ? live.accent.withValues(alpha: 0.5)
                  : live.hairline,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Icon(icon,
                size: size * 0.5,
                color: dimmed
                    ? live.faint
                    : selected
                        ? live.accent
                        : live.text),
          ),
        ),
      ),
    );
  }
}

Widget _liveViewToggle(LivePalette live, RemoteController controller) {
  final active = controller.liveViewActive;
  return _actionButton(
    live: live,
    icon: active ? Icons.videocam : Icons.videocam_off_outlined,
    label: active ? '取景中' : '取景',
    dimmed: !active,
    onTap: controller.toggleLiveView,
  );
}

/// 对焦按钮:驱动一次自动对焦(0x90C1,候选码待真机核对;
/// 取景开启是前置条件 —— 未开取景机身回 0xA00B)。
Widget _focusButton(LivePalette live, RemoteController controller) {
  final usable = controller.linkUp && controller.liveViewActive;
  return _actionButton(
    live: live,
    icon: Icons.center_focus_strong,
    label: controller.focusing ? '对焦中' : '对焦',
    onTap: usable && !controller.focusing ? controller.afDriveNow : null,
    spinning: controller.focusing,
  );
}

/// 录制钮(0x920A/0x920B):红点起录 / 红方块停录;取景开启为前置。
Widget _recordButton(LivePalette live, RemoteController controller) {
  final usable = controller.linkUp && controller.liveViewActive;
  final rec = controller.recording;
  return _actionButton(
    live: live,
    icon: rec ? Icons.stop : Icons.fiber_manual_record,
    label: rec ? recDurationLabel(controller.recordingSeconds) : '录制',
    dimmed: !usable,
    onTap: usable && !controller.capturing ? controller.toggleRecord : null,
  );
}

/// MF 步进(0x9204):向近/向远两粒竖排小钮(跟焦环语义,相对量)。
Widget _mfNearFarButtons(LivePalette live, RemoteController controller) {
  final usable = controller.linkUp && controller.liveViewActive;
  Widget step(IconData icon, bool towardNear, String tip) {
    return Tooltip(
      message: tip,
      child: SizedBox(
        width: 40,
        height: 32,
        child: Material(
          color: live.glass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(color: live.hairline),
          ),
          child: InkWell(
            onTap: usable
                ? () => controller.mfDriveStep(towardNear: towardNear)
                : null,
            child: Icon(icon,
                size: 18, color: usable ? live.text : live.faint),
          ),
        ),
      ),
    );
  }

  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      step(Icons.add, false, 'MF 向远(步进)'),
      const SizedBox(height: 4),
      step(Icons.remove, true, 'MF 向近(步进)'),
      const SizedBox(height: 4),
      Text('MF', style: TextStyle(fontSize: 10, color: live.faint)),
    ],
  );
}

/// 快门钮(OpenZCine PhotographyShutterButton 同款):亮圈 + 亮芯,
/// 按下变半透明(拍照中)。深色 = 白圈白芯(现状);浅色 = 墨圈 +
/// 统一黄芯(v8「统一令」的按钮黄)。**按下即拍 + 按住连拍**(连续
/// 释放档时按住 = 连拍括持链发,抬起终止;普通档点按 = 单张)。
/// [size] 默认竖屏动作行 72,横屏右栏 64。
Widget _shutterButton(LivePalette live, RemoteController controller,
    {double size = 72}) {
  final usable = controller.linkUp;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) {
      if (controller.linkUp && !controller.capturing) {
        unawaited(controller.capturePressed());
      }
    },
    onTapUp: (_) => unawaited(controller.captureReleased()),
    child: Opacity(
      opacity: usable ? 1 : 0.35,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: live.shutterRing.withValues(alpha: 0.92), width: 4),
              ),
            ),
            Container(
              width: size - 18,
              height: size - 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: controller.capturing
                    ? live.shutterCoreBusy
                    : live.shutterCore,
              ),
              child: Center(
                child: controller.selfTimerCountdown != null
                    ? Text('${controller.selfTimerCountdown}',
                        style: TextStyle(
                            fontSize: size >= 72 ? 24 : 20,
                            fontWeight: FontWeight.bold,
                            color: live.onAccent))
                    : controller.capturing
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: live.onAccent),
                          )
                        : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 动作行按钮:玻璃圆角方块 + 图标 + 下标签(取景/对焦);
/// 整块(含标签)都是点击区。
Widget _actionButton({
  required LivePalette live,
  required IconData icon,
  required String label,
  required VoidCallback? onTap,
  bool dimmed = false,
  bool spinning = false,
}) {
  return InkWell(
    onTap: onTap,
    customBorder:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: onTap == null ? live.surface : live.glass,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: live.hairline),
          ),
          child: Center(
            child: spinning
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: live.accent),
                  )
                : Icon(icon,
                    size: 26, color: dimmed ? live.muted : live.text),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 11, color: live.muted)),
      ],
    ),
  );
}

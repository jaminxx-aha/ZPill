import 'dart:async';

import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';
import 'remote_info_pill.dart';

/// 底部动作行(竖屏读出行与快门行之间 / 横屏贴底,2026-10-08 手机
/// 原生相机式排版):取景 / 对焦 / 录制 / MF 步进对,40px 玻璃小方块
/// + 10px 标签。状态随控制器,监听由外层 AnimatedBuilder 驱动;颜色
/// 随应用主题(LiveDesign.of)。
class CaptureActionBar extends StatelessWidget {
  const CaptureActionBar({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _liveViewToggle(live, controller),
          _focusButton(live, controller),
          _recordButton(live, controller),
          _mfCompactButtons(live, controller),
        ],
      ),
    );
  }
}

/// 竖屏快门行(2026-10-08 手机原生相机式排版):相机相册缩略图 |
/// 大圆环快门 | 纯净监看圆钮。缩略图钮显示最近一拍
/// ([RemoteController.reviewThumb],即拍即览同源),无图时相册图标
/// 占位;点按进相机相册。横屏的竖排同组三件见 [CaptureShutterColumn]。
class CaptureShutterRow extends StatelessWidget {
  const CaptureShutterRow({
    super.key,
    required this.controller,
    required this.onOpenAlbum,
    required this.onHideChrome,
  });

  final RemoteController controller;

  /// 点按缩略图钮 → 打开相机相册(页面侧路由)。
  final VoidCallback onOpenAlbum;

  /// 纯净监看:隐去全部控制浮层(竖屏 = 顶部胶囊/浮层 + 底部三行),
  /// 只留画面与监看叠层。
  final VoidCallback onHideChrome;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _albumThumbButton(live, controller, onOpenAlbum),
          _shutterButton(live, controller, size: 78),
          _circleAction(live, Icons.visibility_off,
              tooltip: '纯净监看(隐藏全部控制,只留画面)', onTap: onHideChrome),
        ],
      ),
    );
  }
}

/// 横屏快门柱(2026-10-08 用户定案「拍照按钮在右侧中间」):竖排
/// 相册缩略图 / 大圆环快门 / 纯净监看,锚在右缘纵向中点 —— 手机相机
/// 横屏的快门位(竖屏快门行旋转 90° 的同组三件)。状态随控制器,
/// 监听由外层 AnimatedBuilder 驱动;颜色随应用主题(LiveDesign.of)。
class CaptureShutterColumn extends StatelessWidget {
  const CaptureShutterColumn({
    super.key,
    required this.controller,
    required this.onOpenAlbum,
    required this.onHideChrome,
  });

  final RemoteController controller;

  /// 点按缩略图钮 → 打开相机相册(页面侧路由)。
  final VoidCallback onOpenAlbum;

  /// 纯净监看:隐去全部控制浮层(横屏 = 顶栏/参数栏/快门柱/动作行),
  /// 只留画面与监看叠层。
  final VoidCallback onHideChrome;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _albumThumbButton(live, controller, onOpenAlbum),
        const SizedBox(height: 8),
        _shutterButton(live, controller, size: 78),
        const SizedBox(height: 8),
        _circleAction(live, Icons.visibility_off,
            tooltip: '纯净监看(隐藏全部控制,只留画面)', onTap: onHideChrome),
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
  return _compactButton(
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
  return _compactButton(
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
  return _compactButton(
    live: live,
    icon: rec ? Icons.stop : Icons.fiber_manual_record,
    label: rec ? recDurationLabel(controller.recordingSeconds) : '录制',
    dimmed: !usable,
    onTap: usable && !controller.capturing ? controller.toggleRecord : null,
  );
}

/// MF 步进(竖屏紧凑动作行):向近/向远两粒横排小钮 + MF 小标
/// (0x9204 相对量,跟焦环语义;近在左、远在右,同镜头距离刻度)。
Widget _mfCompactButtons(LivePalette live, RemoteController controller) {
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

/// 快门钮(OpenZCine PhotographyShutterButton 同款):亮圈 + 亮芯,
/// 按下变半透明(拍照中)。深色 = 白圈白芯(现状);浅色 = 墨圈 +
/// 统一黄芯(v8「统一令」的按钮黄)。**按下即拍 + 按住连拍**(连续
/// 释放档时按住 = 连拍括持链发,抬起终止;普通档点按 = 单张)。
/// [size] 默认竖屏快门行 78,横屏右栏 64。
Widget _shutterButton(LivePalette live, RemoteController controller,
    {double size = 78}) {
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

/// 紧凑动作行按钮(竖屏):40px 玻璃圆角方块 + 图标 + 10px 下标签;
/// 整块(含标签)都是点击区。
Widget _compactButton({
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
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: onTap == null ? live.surface : live.glass,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: live.hairline),
          ),
          child: Center(
            child: spinning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: live.accent),
                  )
                : Icon(icon,
                    size: 20, color: dimmed ? live.muted : live.text),
          ),
        ),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(fontSize: 10, color: live.muted)),
      ],
    ),
  );
}

/// 相册缩略图钮(快门行左):最近一拍的即拍图,无图时相册图标占位;
/// 点按进相机相册(手机相机语言 —— 拍完即看)。
Widget _albumThumbButton(
    LivePalette live, RemoteController controller, VoidCallback onOpenAlbum) {
  final thumb = controller.reviewThumb;
  return Tooltip(
    message: '相机相册',
    child: SizedBox(
      width: 54,
      height: 54,
      child: Material(
        color: live.glass,
        shape: CircleBorder(side: BorderSide(color: live.hairline)),
        child: InkWell(
          onTap: onOpenAlbum,
          customBorder: const CircleBorder(),
          child: thumb != null
              ? ClipOval(
                  child: Image.memory(thumb,
                      fit: BoxFit.cover, gaplessPlayback: true))
              : Icon(Icons.photo_library_outlined,
                  size: 22, color: live.text),
        ),
      ),
    ),
  );
}

/// 圆形玻璃功能钮(快门行非主操作位):54px 圆 + 图标 + Tooltip。
Widget _circleAction(LivePalette live, IconData icon,
    {required String tooltip, required VoidCallback onTap}) {
  return Tooltip(
    message: tooltip,
    child: SizedBox(
      width: 54,
      height: 54,
      child: Material(
        color: live.glass,
        shape: CircleBorder(side: BorderSide(color: live.hairline)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(icon, size: 22, color: live.text),
        ),
      ),
    ),
  );
}

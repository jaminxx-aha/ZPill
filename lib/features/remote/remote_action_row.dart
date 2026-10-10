import 'dart:async';

import 'package:flutter/material.dart';

import 'live_design.dart';
import 'remote_controller.dart';
import 'remote_mode_strip.dart';

/// 竖屏控制行(2026-10-10 iPhone 相机式重排:取景/对焦/录制动作行撤
/// 除 —— 取景默认开、对焦/设置各有浮层、录像并进快门):相机相册缩略
/// 图 | 对焦 | 大圆环快门(模式感知:视频模式红芯)| 设置 | 方向旋转。
/// 缩略图钮显示最近一拍([RemoteController.reviewThumb],即拍即览同
/// 源),无图时相册图标占位,点按进相机相册;对焦/设置钮开各自非模态
/// 浮层(页面态单开,见 RemotePage);旋转钮横竖直切。横屏右缘竖排的
/// 同组四件(无旋转)见 [CaptureShutterColumn]。
class CaptureControlRow extends StatelessWidget {
  const CaptureControlRow({
    super.key,
    required this.controller,
    required this.mode,
    required this.onOpenAlbum,
    required this.onOpenFocus,
    required this.onOpenSettings,
    required this.onToggleOrientation,
  });

  final RemoteController controller;

  /// 拍摄模式(照片/视频)—— 快门钮据此分支。
  final CaptureMode mode;

  /// 点按缩略图钮 → 打开相机相册(页面侧路由)。
  final VoidCallback onOpenAlbum;

  /// 点按对焦钮 → 开/关对焦浮层(AF / MF 步进 / 拉焦轮)。
  final VoidCallback onOpenFocus;

  /// 点按设置钮 → 开/关拍摄设置浮层(参数 / 监看 / 辅助)。
  final VoidCallback onOpenSettings;

  /// 方向旋转:横↔竖直切(页面侧 SystemChrome)。
  final VoidCallback onToggleOrientation;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      // 12 边距:五键一行在 360pt 窄屏也要有余隙(54×4+78=294)。
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _albumThumbButton(live, controller, onOpenAlbum),
          CaptureCircleButton(
            icon: Icons.center_focus_strong,
            tooltip: '对焦辅助(AF / MF 步进 / 拉焦轮)',
            onTap: onOpenFocus,
          ),
          _shutterButton(live, controller, mode: mode, size: 78),
          CaptureCircleButton(
            icon: Icons.tune,
            tooltip: '拍摄设置(参数 / 网格斑马纹 / 辅助)',
            onTap: onOpenSettings,
          ),
          CaptureCircleButton(
            // 方向钮不包 Tooltip(见类注:长按抬起须等同点按)
            icon: Icons.screen_rotation,
            onTap: onToggleOrientation,
          ),
        ],
      ),
    );
  }
}

/// 横屏快门柱(2026-10-10 随竖屏 iPhone 相机式重排:动作行撤除后竖排
/// 四件):相机相册缩略图 / 对焦 / 大圆环快门(64,四件竖排的高度账
/// 54+8+54+8+64+8+54=250,390pt 屏右列区 390-64-64=262 可容)/ 设置,
/// 锚在右缘纵向中点。状态随控制器,监听由外层 AnimatedBuilder 驱动;
/// 颜色随应用主题(LiveDesign.of)。方向旋转在贴底条右端(页面装配)。
class CaptureShutterColumn extends StatelessWidget {
  const CaptureShutterColumn({
    super.key,
    required this.controller,
    required this.mode,
    required this.onOpenAlbum,
    required this.onOpenFocus,
    required this.onOpenSettings,
  });

  final RemoteController controller;

  /// 拍摄模式(照片/视频)—— 快门钮据此分支。
  final CaptureMode mode;

  /// 点按缩略图钮 → 打开相机相册(页面侧路由)。
  final VoidCallback onOpenAlbum;

  /// 点按对焦钮 → 开/关对焦浮层(AF / MF 步进 / 拉焦轮)。
  final VoidCallback onOpenFocus;

  /// 点按设置钮 → 开/关拍摄设置浮层(参数 / 监看 / 辅助)。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _albumThumbButton(live, controller, onOpenAlbum),
        const SizedBox(height: 8),
        CaptureCircleButton(
          icon: Icons.center_focus_strong,
          tooltip: '对焦辅助(AF / MF 步进 / 拉焦轮)',
          onTap: onOpenFocus,
        ),
        const SizedBox(height: 8),
        _shutterButton(live, controller, mode: mode, size: 64),
        const SizedBox(height: 8),
        CaptureCircleButton(
          icon: Icons.tune,
          tooltip: '拍摄设置(参数 / 网格斑马纹 / 辅助)',
          onTap: onOpenSettings,
        ),
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

/// 圆形玻璃功能钮(控制行/右列非主操作位,2026-10-10 公开供页面横屏
/// 底条旋转钮复用):默认 54px 圆 + 图标 + Tooltip;无 onTap 时置灰。
/// [tooltip] 可空 —— 方向旋转钮单列不包 Tooltip(2026-10-08 用户点名
/// 单删:长按不得弹提示,长按抬起须等同点按;包了 Tooltip 它的长按
/// 手势会抢走 tap)。
class CaptureCircleButton extends StatelessWidget {
  const CaptureCircleButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onTap,
    this.size = 54,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: live.glass,
        shape: CircleBorder(side: BorderSide(color: live.hairline)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(
            icon,
            size: 22,
            color: onTap == null ? live.faint : live.text,
          ),
        ),
      ),
    );
    return tooltip == null
        ? button
        : Tooltip(message: tooltip!, child: button);
  }
}

/// 快门钮(OpenZCine PhotographyShutterButton 同款,2026-10-10
/// 拍照/录像合并):亮圈 + 亮芯,按下变半透明(拍照中)。深色 = 白圈
/// 白芯(现状);浅色 = 墨圈 + 统一黄芯。**照片模式**:按下即拍 +
/// 按住连拍(连续释放档按住 = 连拍括持链发、抬起终止;B 门/Time 按住
/// = 开闩曝光;普通档点按 = 自拍倒计时后单张)—— onTapDown/Up 语义
/// 全不变。**视频模式**(iPhone 语义):红芯(进入即红,非仅录制中),
/// 整段点按起/停录像(onTap,不挂按下/抬起);录制中芯上叠白色停止
/// 方块且保持全不透明(停录要醒目)。取景开启是录像前置(toggleRecord
/// 的门,提前到视觉层降透明)。[size] 竖屏控制行 78 / 横屏右列 64。
Widget _shutterButton(LivePalette live, RemoteController controller,
    {required CaptureMode mode, double size = 78}) {
  final photo = mode == CaptureMode.photo;
  final usable = photo
      ? controller.linkUp
      : controller.linkUp && controller.liveViewActive;
  final rec = controller.recording;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: photo
        ? (_) {
            if (controller.linkUp && !controller.capturing) {
              unawaited(controller.capturePressed());
            }
          }
        : null,
    onTapUp: photo ? (_) => unawaited(controller.captureReleased()) : null,
    onTap: photo
        ? null
        : () {
            if (controller.linkUp &&
                controller.liveViewActive &&
                !controller.capturing) {
              unawaited(controller.toggleRecord());
            }
          },
    child: Opacity(
      // 录制中不降透明:停录入口要够醒目。
      opacity: usable || rec ? 1 : 0.35,
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
                color: !photo
                    ? live.bad
                    : controller.capturing
                        ? live.shutterCoreBusy
                        : live.shutterCore,
              ),
              child: Center(
                child: photo
                    ? (controller.selfTimerCountdown != null
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
                            : null)
                    : (rec
                        ? Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          )
                        : null),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 相册缩略图钮(控制行左/右列顶):最近一拍的即拍图,无图时相册图标
/// 占位;点按进相机相册(手机相机语言 —— 拍完即看)。
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

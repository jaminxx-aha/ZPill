import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/app_haptics.dart';
import '../../l10n/l10n.dart';
import 'live_design.dart';
import 'remote_controller.dart';

/// 竖屏控制行(2026-10-12 底区重排:模式条/相册/旋转迁底行,控制行
/// 只留快门双翼):对焦 | 大圆环快门(模式感知:视频模式红芯)| 设置。
/// 对焦钮**点按即驱动一次 AF**(用户定案:只负责对焦,MF 步进/拉焦轮
/// 在拍摄设置浮层);设置钮开非模态浮层。横屏右缘竖排的五件(含旋转,
/// 2026-10-12 用户定案自上而下 旋转/设置/快门/对焦/相册)见
/// [CaptureShutterColumn];模式条的贴底条在页面装配(RemotePage)。
class CaptureControlRow extends StatelessWidget {
  const CaptureControlRow({
    super.key,
    required this.controller,
    required this.mode,
    required this.onOpenSettings,
  });

  final RemoteController controller;

  /// 拍摄模式(照片/视频)—— 快门钮据此分支。
  final CaptureMode mode;

  /// 点按设置钮 → 开/关拍摄设置浮层(参数 / 对焦 / 监看 / 辅助)。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Padding(
      // 左右边距 20(2026-10-12 九轮:与距物理屏底 20 统一,用户「左右
      // 两侧按钮离边的距离和离下方的距离保持一致」)。
      padding: const EdgeInsets.fromLTRB(
          kScreenEdgePadding, 6, kScreenEdgePadding, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _focusButton(context, live, controller),
          _shutterButton(context, live, controller, mode: mode),
          CaptureCircleButton(
            icon: Icons.tune,
            tooltip: context.t('remote.settingsTooltip'),
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

/// 横屏快门柱(2026-10-12 用户定案柱序自上而下:**旋转 / 设置 / 快门
/// (78,同竖屏)/ 对焦 / 相册**—— 方向钮自贴底条迁入柱顶,相册坠底;
/// 快门两向同大 = 用户定案「横屏按钮保持和竖屏大小一样」):五件
/// 竖排高度账 54+8+54+8+78+8+54+8+54=326,402pt 级横屏可容,锚右缘
/// 纵向居中。**crossAxisAlignment: center 五件共轴**(2026-10-12 十轮
/// 用户定案「以拍照按钮居中对齐,而不是右边对齐」—— 柱宽即快门 78,
/// 四枚 54 钮以快门心对中;废除六轮的右缘齐平/快门凸左)。柱右距
/// **物理屏缘 [kScreenEdgePadding]**(六轮破安全区;值经手调)。
/// 状态随控制器,监听由外层 AnimatedBuilder 驱动;颜色随
/// 应用主题(LiveDesign.of)。旋转钮不包 Tooltip(长按抬起须等同点按,
/// 见 [CaptureCircleButton] 类注)。
class CaptureShutterColumn extends StatelessWidget {
  const CaptureShutterColumn({
    super.key,
    required this.controller,
    required this.mode,
    required this.onOpenAlbum,
    required this.onOpenSettings,
    required this.onRotate,
  });

  final RemoteController controller;

  /// 拍摄模式(照片/视频)—— 快门钮据此分支。
  final CaptureMode mode;

  /// 点按缩略图钮 → 打开相机相册(页面侧路由)。
  final VoidCallback onOpenAlbum;

  /// 点按设置钮 → 开/关拍摄设置浮层(参数 / 监看 / 辅助)。
  final VoidCallback onOpenSettings;

  /// 点按方向钮 → 横↔竖直切(页面侧方向锁循环)。
  final VoidCallback onRotate;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      // 十轮用户定案「以拍照按钮居中对齐,而不是右边对齐」:五件共轴
      // 于快门心(柱宽 78),废除右缘齐平。
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 方向钮不包 Tooltip(长按抬起须等同点按,见类注)
        CaptureCircleButton(
          icon: Icons.screen_rotation,
          onTap: onRotate,
        ),
        const SizedBox(height: 8),
        CaptureCircleButton(
          icon: Icons.tune,
          tooltip: context.t('remote.settingsTooltip'),
          onTap: onOpenSettings,
        ),
        const SizedBox(height: 8),
        _shutterButton(context, live, controller, mode: mode),
        const SizedBox(height: 8),
        _focusButton(context, live, controller),
        const SizedBox(height: 8),
        AlbumThumbButton(controller: controller, onTap: onOpenAlbum),
      ],
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

/// 对焦钮(快门左侧):**只负责对焦,点按即驱动一次 AF**(0x90C1,
/// [RemoteController.afDriveNow];2026-10-12 用户定案 —— 原对焦浮层的
/// MF 步进/拉焦轮移拍摄设置浮层)。对焦中仍可点 = 如实提示「对焦进行中」
/// (2026-10-17 真机定案:Zf 扣 0x90C1 应答至 AF 结束,远程打断结构性
/// 不可能 —— 旧「对焦中禁点」把提示路堵死,点按哑掉,用户不明所以);
/// 未连接/未开取景/机身 MF 档灰化(控制器拦截是第二道,这里先不给出
/// 可点姿态)。
Widget _focusButton(BuildContext context, LivePalette live, RemoteController controller) {
  final usable = controller.linkUp &&
      controller.liveViewActive &&
      !controller.focusModeIsMf;
  return Tooltip(
    message: context.t('remote.autofocus'),
    child: SizedBox(
      width: 54,
      height: 54,
      child: Material(
        color: live.glass,
        shape: CircleBorder(side: BorderSide(color: live.hairline)),
        child: InkWell(
          onTap: usable ? controller.afDriveNow : null,
          customBorder: const CircleBorder(),
          child: Center(
            child: controller.focusing
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: live.accent),
                  )
                : Icon(Icons.center_focus_strong,
                    size: 22, color: usable ? live.text : live.faint),
          ),
        ),
      ),
    ),
  );
}

/// 快门钮(OpenZCine PhotographyShutterButton 同款,2026-10-10
/// 拍照/录像合并):亮圈 + 亮芯,按下变半透明(拍照中)。深色 = 白圈
/// 白芯(现状);浅色 = 墨圈 + 统一黄芯。**照片模式**:按下即拍 +
/// 按住连拍(连续释放档按住 = 连拍括持链发、抬起终止;B 门/Time 按住
/// = 开闩曝光,自拍定时组合 = 定时 B 门:倒计时到点开门 → 曝光倒计时
/// → 到点自动收门;普通档点按 = 自拍倒计时后单张)—— onTapDown/Up
/// 语义全不变。钮芯倒计时:两段各带段位小标(延时=芯色不变 / 曝光=
/// 红芯白字,2026-10-17 用户实测两段裸数字连跑分不清「在等」还是
/// 「在拍」,红芯取录像 REC 同语义)+ 拍照 spinner。**视频模式**(iPhone 语义):红芯(进入即红,非仅录制中),
/// 整段点按起/停录像(onTap,不挂按下/抬起);录制中芯上叠白色停止
/// 方块且保持全不透明(停录要醒目)。取景开启是录像前置(toggleRecord
/// 的门,提前到视觉层降透明)。尺寸两向同 78(2026-10-12 用户定案
/// 「横屏按钮保持和竖屏大小一样」,原横屏 64 废除)。
Widget _shutterButton(BuildContext context, LivePalette live,
    RemoteController controller,
    {required CaptureMode mode}) {
  const size = 78.0;
  final photo = mode == CaptureMode.photo;
  // 照片档:间隔拍摄运行中让位(灰化;调度器按间隔驱动快门,手动
  // 按下/按住会被控制器拒并提示)。
  final usable = photo
      ? controller.linkUp && !controller.intervalActive
      : controller.linkUp && controller.liveViewActive;
  final rec = controller.recording;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: photo
        ? (_) {
            if (controller.linkUp &&
                !controller.capturing &&
                !controller.intervalActive) {
              AppHaptics.shutter(); // 按下即震(本地确认沿,不等相机应答)
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
              AppHaptics.recordToggle(); // 起/停录确认沿
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
                    : controller.bulbExposureCountdown != null
                        ? live.bad
                        : controller.capturing
                            ? live.shutterCoreBusy
                            : live.shutterCore,
              ),
              child: Center(
                child: photo
                    ? (controller.selfTimerCountdown != null
                        ? _shutterCountdown(
                            context, '${controller.selfTimerCountdown}',
                            'remote.countdownDelay',
                            color: live.onAccent)
                        : controller.bulbExposureCountdown != null
                            ? _shutterCountdown(context,
                                '${controller.bulbExposureCountdown}',
                                'remote.countdownExposure',
                                color: Colors.white)
                            : controller.capturing
                                ? SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: live.onAccent),
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

/// 钮芯倒计时:大数字 + 段位小标(延时/曝光)。定时 B 门两段连跑,
/// 2026-10-17 用户实测「等了两倍时间」分不清哪段在等哪段在拍;
/// 曝光段另配红芯(快门开着在拍,录像 REC 同语义)。
Widget _shutterCountdown(BuildContext context, String value, String labelKey,
    {required Color color}) {
  return Column(mainAxisSize: MainAxisSize.min, children: [
    Text(value,
        style: TextStyle(
            fontSize: 24, fontWeight: FontWeight.bold, color: color)),
    Text(context.t(labelKey),
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: color)),
  ]);
}

/// 相册缩略图钮:最近一拍的即拍图([RemoteController.reviewThumb],
/// 即拍即览同源),无图时相册图标占位;点按进相机相册(手机相机语言
/// —— 拍完即看)。竖屏底行左端(2026-10-12 自控制行迁出)与横屏快门
/// 柱底共用。
class AlbumThumbButton extends StatelessWidget {
  const AlbumThumbButton({super.key, required this.controller, this.onTap});

  final RemoteController controller;

  /// 点按 → 打开相机相册(页面侧路由);null 置灰。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final thumb = controller.reviewThumb;
    return Tooltip(
      message: context.t('conn.cameraAlbum'),
      child: SizedBox(
        width: 54,
        height: 54,
        child: Material(
          color: live.glass,
          shape: CircleBorder(side: BorderSide(color: live.hairline)),
          child: InkWell(
            onTap: onTap,
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
}

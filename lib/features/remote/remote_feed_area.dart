import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/live_view_header.dart';
import '../../platform/motion_host.dart';
import 'live_design.dart';
import 'live_view_overlays.dart';
import 'monitor_toggles.dart';
import 'remote_banner.dart';
import 'remote_controller.dart';

/// 取景区:帧 + 监看叠层 + 底边横幅(帧到达与状态由外层
/// AnimatedBuilder merge(controller+frame+status) 驱动重建)。
///
/// [topInset]/[bottomInset]/[leftInset] 供横屏侧栏布局把贴边元素
/// (即拍即览卡/直方图/横幅)让位给顶栏/底浮层/左参数栏。
/// [phoneAttitudes] 为手机姿态流取值(页面缓存的单实例 —— MovtionHost
/// 的 getter 每次返回**新**流,取景期每帧重建会让 StreamBuilder 反复
/// 拆装 EventChannel);相机帧头带虚拟水平仪时优先用它,本流只作兜底。
/// 传**取值函数**而非流:流字段在页面是 late final(平台通道宿主),
/// 只有水平仪兜底真正要建 StreamBuilder 时才取值 —— 提前取值会在无
/// 平台通道的测试环境炸 LateInitializationError。
/// [onTapFocus] 点按取景画面 = 触控对焦(含横屏辅助浮层收起联动)。
class RemoteFeedArea extends StatelessWidget {
  const RemoteFeedArea({
    super.key,
    required this.controller,
    required this.toggles,
    required this.phoneAttitudes,
    required this.onTapFocus,
    this.topInset = 0,
    this.bottomInset = 0,
    this.leftInset = 0,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final Stream<MotionOrientation> Function() phoneAttitudes;
  final void Function(TapUpDetails details, Rect? imageRect) onTapFocus;
  final double topInset;
  final double bottomInset;
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    // 无帧占位随主题(它在页面底色上);画面上的内容层(即拍即览卡/
    // 横幅/监看叠层)恒用暗面(LiveDesign.dark),不随主题。
    final live = LiveDesign.of(context);
    final Uint8List? frame = controller.engine.frame.value;
    final status = controller.engine.status;
    return LayoutBuilder(builder: (context, constraints) {
      // 取景图像在画面里的实际显示矩形(BoxFit.contain 数学):
      // 点按坐标 → 归一化帧坐标、对焦框回投,共用这一份映射。
      final boxSize = constraints.biggest;
      final frameSize = controller.frameSize.value;
      Rect? imageRect;
      if (frameSize != null && frameSize.width > 0 && frameSize.height > 0) {
        final iw = frameSize.width.toDouble();
        final ih = frameSize.height.toDouble();
        final scale =
            boxSize.width / iw < boxSize.height / ih ? boxSize.width / iw : boxSize.height / ih;
        imageRect = Rect.fromLTWH((boxSize.width - iw * scale) / 2,
            (boxSize.height - ih * scale) / 2, iw * scale, ih * scale);
      }
      return GestureDetector(
        // 点按取景画面 = 触控对焦(无帧/未取景时控制器内静默忽略)
        onTapUp: (d) => onTapFocus(d, imageRect),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null)
              Image.memory(frame, fit: BoxFit.contain,
                  gaplessPlayback: true) // 换帧不闪黑
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 等待首帧:取景机图标 + 金色细进度条(不定进度);
                    // 失败:警示图标 + 重试钮。已关闭:纯文案(原样)。
                    if (status.value == LiveViewStatus.running) ...[
                      Icon(Icons.videocam_outlined,
                          size: 44, color: live.faint),
                      const SizedBox(height: 10),
                    ] else if (status.value == LiveViewStatus.failed) ...[
                      Icon(Icons.error_outline,
                          size: 44, color: live.bad),
                      const SizedBox(height: 10),
                    ],
                    Text(
                      status.value == LiveViewStatus.running
                          ? '取景中…(等待首帧)'
                          : status.value == LiveViewStatus.failed
                              ? '取景失败(${controller.engine.lastError ?? "未知错误"})'
                              : '取景已关闭\n开启「取景」查看实时画面\n点按画面可触控对焦',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: live.faint),
                    ),
                    if (status.value == LiveViewStatus.running) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(
                            minHeight: 2, color: live.accent),
                      ),
                    ],
                    if (status.value == LiveViewStatus.failed) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: controller.toggleLiveView,
                        style: TextButton.styleFrom(
                          foregroundColor: live.bad,
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        icon: Icon(Icons.refresh,
                            size: 16, color: live.bad),
                        label: const Text('重试取景'),
                      ),
                    ],
                  ],
                ),
              ),
            if (toggles.grid)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) => GridOverlay(
                    aspect: analysis == null
                        ? null
                        : analysis.width / analysis.height),
              ),
            if (toggles.zebra)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    ZebraOverlay(analysis: analysis),
              ),
            if (toggles.falseColor)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    FalseColorOverlay(analysis: analysis),
              ),
            if (toggles.peaking)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    PeakingOverlay(analysis: analysis),
              ),
            // 即拍即览:新照片缩略图小卡(几秒后自动撤)—— 画面上的
            // 内容层,恒用暗面玻璃。
            if (controller.reviewThumb != null)
              Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: EdgeInsets.fromLTRB(
                      10 + leftInset, 10 + topInset, 10, 10),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: LiveDesign.dark.glass,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: LiveDesign.dark.hairline),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(controller.reviewThumb!,
                        width: 96, height: 64, fit: BoxFit.cover),
                  ),
                ),
              ),
            if (toggles.histogram)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      8 + leftInset, 8, 8, 8 + bottomInset),
                  child: ValueListenableBuilder(
                    valueListenable: controller.analyzer.analysis,
                    builder: (context, FrameAnalysis? analysis, _) =>
                        HistogramView(analysis: analysis),
                  ),
                ),
              ),
            // 水平仪优先用**相机帧头**的虚拟水平仪(Zf 机身侧水平仪,
            // OpenZCine 同源字段;Gen-1 短头/相机未报时落回手机姿态)。
            if (toggles.level)
              ValueListenableBuilder<LiveViewHeader?>(
                valueListenable: controller.engine.header,
                builder: (context, LiveViewHeader? h, _) {
                  final level = h?.level;
                  if (level != null) {
                    const d2r = 3.141592653589793 / 180;
                    return LevelOverlay(
                      orientation: MotionOrientation(
                        // 帧头角为相机视角、度;符号换算待真机核对。
                        pitchRad: level.signedPitch * d2r,
                        rollRad: -level.signedRoll * d2r,
                      ),
                    );
                  }
                  return StreamBuilder<MotionOrientation>(
                    stream: phoneAttitudes(),
                    builder: (context, snapshot) => snapshot.hasData
                        ? LevelOverlay(orientation: snapshot.data!)
                        : const SizedBox.shrink(),
                  );
                },
              ),
            // 相机自报 AF 框组(真实尺寸随 AF 区域设置:单点小框/动态大框;
            // 主体检测开着时附人脸/眼睛框)—— 头在册即替代点按占位框。
            ValueListenableBuilder<LiveViewHeader?>(
              valueListenable: controller.engine.header,
              builder: (context, LiveViewHeader? h, _) => h == null ||
                      imageRect == null ||
                      !controller.liveViewActive
                  ? const SizedBox.shrink()
                  : AfAreasOverlay(header: h, imageRect: imageRect),
            ),
            // 点按占位框只在**拿不到相机自报框**时兜底(0x9203 旧码裸
            // JPEG / 头框数组空):头在册即让位,否则同屏双框。
            ValueListenableBuilder<LiveViewHeader?>(
              valueListenable: controller.engine.header,
              builder: (context, LiveViewHeader? h, _) =>
                  controller.afBox != null &&
                          imageRect != null &&
                          (h == null || h.boxes.isEmpty)
                      ? _afBoxOverlay(imageRect, controller.afBox!)
                      : const SizedBox.shrink(),
            ),
            // 横幅贴画面底边(OpenZCine「坐在画面下沿」口径)—— 画面
            // 上的内容层,恒用暗面玻璃与暗面语义色,不随主题。
            // 未连接横幅常驻;错误 8s 收圆丸点按展开、提示 4s 淡出
            // (节律在 LiveBannerHost 视图层,不侵入控制器)。
            if (!controller.linkUp)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner('未连接相机 —— 请先在「相机」页建立连接',
                    LiveDesign.dark.accent,
                    bottomInset: bottomInset),
              )
            else if (controller.error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.error!, LiveDesign.dark.bad,
                    bottomInset: bottomInset),
              ),
            if (controller.notice != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.notice!, LiveDesign.dark.good,
                    bottomInset: bottomInset, autoDismiss: true),
              ),
          ],
        ),
      );
    });
  }

  /// 触控对焦框:回投 contain 矩形;尺寸是视觉占位(相机侧实际对焦
  /// 区域大小无从得知)。
  Widget _afBoxOverlay(Rect imageRect, AfBox box) {
    final side = imageRect.width * 0.18;
    return Positioned(
      left: imageRect.left + box.nx * imageRect.width - side / 2,
      top: imageRect.top + box.ny * imageRect.height - side / 2,
      width: side,
      height: side,
      child: const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.fromBorderSide(
                BorderSide(color: Color(0xFFFFC107), width: 2)),
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
      ),
    );
  }
}

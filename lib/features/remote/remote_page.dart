/// 拍摄页(底部导航 tab):Live View 监看 + 相机控制。
///
/// **界面语言源自 OpenZCine**(MonitorShell / MonitorCaptureStrip /
/// CaptureSettingButton / PhotographyShutterButton / LiveDesign,MIT):
/// 暖黑监看底色 + 金色 accent、玻璃胶囊条、等宽数字读出 tile(小标签 +
/// 大号等宽值)、白圈白芯快门钮、横向读出条边缘渐隐 + 金色箭头提示。
/// 功能层为本仓 [RemoteController](拨盘级接管/曝光变量模式门/值回读
/// 路由/连拍按住,见其头注)—— 本页只做视图,交互全部走控制器。
///
/// 布局(竖屏,自上而下):
/// - 信息胶囊:链路点 + 设备名 + 接管徽标;
/// - 取景区(Expanded):取景帧 + 网格/斑马纹/直方图/水平仪 + 触控对焦,
///   错误/提示横幅贴画面底边(OpenZCine「坐在画面下沿」的口径);
/// - 动作行:取景开关 / 对焦 / 快门(按下即拍、按住连拍);
/// - 拍摄读出条:全部拍摄参数 tile 横滚(自动变量标「(自动)」置灰,
///   顺序对齐 OpenZCine photographyCaptureValues:MODE/ISO/SHUTTER/
///   IRIS/DRIVE/FOCUS/WB/METER/PROFILE,其余随后);
/// - 辅助条:监看开关 + 「对焦后拍」+「APP 接管」。
///
/// 横屏转**监看布局**(OpenZCine MonitorLayoutPolicy):取景画面全幅铺底
/// 占大块屏幕,信息胶囊/辅助条浮顶、读出条/动作行浮底,贴边元素(横幅/
/// 直方图/即拍即览卡)按浮层高度让位。
///
/// 水平仪数据源:相机帧头虚拟水平仪(LiveViewHeader.level,机身侧水平
/// 仪,OpenZCine 同源)优先,手机姿态流只作相机未报时的兜底。
///
/// tab 模式:IndexedStack 常驻挂载,离开 tab([active] 变 false)即
/// 挂起帧轮询(取景生命周期跟连接走 —— 0x9201 已随连接沿发出、相机
/// 保持取景,这里只停 USB 帧流量,不发 0x9202;回台恢复轮询并对表
/// 刷一次参数)。取景的显式开关仍在动作行;连接即取景由 HomeShell
/// 在 connected 沿驱动(RemoteController.autoLiveViewOnConnect)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/live_view_header.dart';
import '../../platform/motion_host.dart';
import '../../platform/services.dart';
import 'live_view_overlays.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// OpenZCine LiveDesign 的 Flutter 移植(暖黑 + 金 accent;监看页不随
/// 应用主题,恒定深色)。全部 const(可在 const 上下文使用)。
abstract final class _LiveDesign {
  static const background = Color(0xFF12100E);
  static const surface = Color(0xFF25211A);
  static const glass = Color(0xB81B1713); // 暖黑玻璃 @72%
  static const hairline = Color(0x24F7EFE1); // 暖白描边 @14%
  static const text = Color(0xFFF4EEE2);
  static const muted = Color(0xFFA49988);
  static const faint = Color(0xFF746B5D);
  static const accent = Color(0xFFE9AC35);
  static const accentDim = Color(0x29E9AC35); // 金 @16%
  static const good = Color(0xFF2EC76B);
  static const bad = Color(0xFFD13437);
}

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, this.controller, this.active = true});

  final RemoteController? controller;

  /// tab 是否在前台(IndexedStack 常驻):false 时挂起帧轮询(相机侧
  /// 取景保持 —— 生命周期跟连接走,只停 USB 流量)。
  final bool active;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final RemoteController controller;

  // 监看辅助开关(页面级视图偏好,不入持久化设置)。
  bool _showGrid = false;
  bool _showZebra = false;
  bool _showHistogram = false;
  bool _showLevel = false;
  bool _showFalseColor = false;
  bool _showPeaking = false;

  /// 读出条中当前打开面板的参数(金高亮 tile)。
  int? _activeParam;

  /// 手机姿态流(缓存单实例:MovtionHost 的 getter 每次返回**新**流,
  /// 取景期页面每帧重建会让 StreamBuilder 反复拆装 EventChannel)。
  /// 相机帧头带虚拟水平仪时优先用它,本流只作兜底。
  late final Stream<MotionOrientation> _phoneAttitudes =
      PlatformServices.motion.attitudes;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
    controller.setViewerVisible(widget.active);
  }

  @override
  void didUpdateWidget(RemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tab 离台/回台:挂起/恢复帧轮询(相机侧取景保持,不发 0x9202)。
    if (widget.active != oldWidget.active) {
      controller.setViewerVisible(widget.active);
    }
    // 回台对表刷一次参数(机身侧拨盘/菜单改动的事件不一定送达)。
    if (widget.active && !oldWidget.active && controller.linkUp) {
      unawaited(controller.refreshParams());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离页只挂起轮询(取景生命周期跟连接走,不因拆页发 0x9202)。
    controller.setViewerVisible(false);
    super.dispose();
  }

  /// 斑马纹/直方图/伪色/峰值共享同一份帧分析:任一开启即启用分析器。
  void _syncAnalyzerEnabled() {
    final want =
        _showZebra || _showHistogram || _showFalseColor || _showPeaking;
    if (controller.analyzer.enabled.value != want) {
      controller.analyzer.enabled.value = want;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台/回前台:挂起/恢复帧轮询(相机侧取景保持 —— 取景生命周期
    // 跟连接走;后台不保活的是 iOS/ohos 的传输面,不再给相机发 0x9202)。
    if (state == AppLifecycleState.paused) {
      controller.setViewerVisible(false);
    }
    if (state == AppLifecycleState.resumed) {
      if (widget.active) controller.setViewerVisible(true);
      // 回前台:参数对表刷一次(后台期间机身侧改动兜底,同切回 tab)。
      if (controller.linkUp) {
        unawaited(controller.refreshParams());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 横屏 = 监看布局(OpenZCine MonitorLayoutPolicy 口径):取景画面
    // 全幅铺底占大块屏幕,控制件(信息胶囊/辅助条/读出条/动作行)以
    // 玻璃浮层叠在画面上,而不是竖屏的「上下挤出」。
    final body = MediaQuery.orientationOf(context) == Orientation.landscape
        ? _landscapeBody(context)
        : _portraitBody(context);
    return Scaffold(
      backgroundColor: _LiveDesign.background,
      body: SafeArea(child: body),
    );
  }

  Widget _portraitBody(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        controller.engine.frame,
        controller.engine.status,
      ]),
      builder: (context, _) => Column(
        children: [
          _infoPill(context),
          Expanded(child: _feedArea(context)),
          _captureRow(context),
          _captureStrip(context),
          _assistStrip(context),
        ],
      ),
    );
  }

  /// 横屏监看:全幅取景打底,顶栏(信息胶囊 + 辅助条)与底栏(读出条 +
  /// 动作行)悬浮;横幅/直方图/即拍即览经 [ bannerBottomInset]/[topInset]
  /// 让位浮层。
  Widget _landscapeBody(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        controller.engine.frame,
        controller.engine.status,
      ]),
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [
          _feedArea(context, topInset: 72, bannerBottomInset: 168),
          Positioned(
            top: 4,
            left: 10,
            right: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _infoPill(context, margin: EdgeInsets.zero)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child:
                      _assistStrip(context, margin: EdgeInsets.zero),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 4,
            left: 10,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _captureStrip(context, margin: EdgeInsets.zero),
                const SizedBox(height: 4),
                _captureRow(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 信息胶囊:链路 + 设备名 + 接管徽标 ──────────────────────────

  Widget _infoPill(BuildContext context, {EdgeInsetsGeometry? margin}) {
    final linked = controller.linkUp;
    final name = controller.connection?.deviceName;
    return Container(
      width: double.infinity,
      margin: margin ?? const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8,
              color: linked ? _LiveDesign.good : _LiveDesign.bad),
          const SizedBox(width: 8),
          // 横屏顶栏与辅助条分宽,名字可能被挤 —— 省略号收尾
          Flexible(
            child: Text(
              linked ? (name ?? '已连接') : '未连接相机',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _LiveDesign.text),
            ),
          ),
          if (linked && controller.shotsRemaining != null) ...[
            const SizedBox(width: 10),
            Text('${controller.shotsRemaining} 张',
                style: const TextStyle(
                    fontSize: 12,
                    color: _LiveDesign.muted,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
          if (controller.recording) ...[
            const SizedBox(width: 10),
            Icon(Icons.circle, size: 8, color: _LiveDesign.bad),
            const SizedBox(width: 4),
            Text('REC ${_recDurationLabel()}',
                style: const TextStyle(
                    fontSize: 12,
                    color: _LiveDesign.bad,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
          const Spacer(),
          if (controller.takeoverActive) ...[
            Icon(Icons.lock, size: 13, color: _LiveDesign.accent),
            const SizedBox(width: 4),
            const Text('APP 接管中',
                style:
                    TextStyle(fontSize: 12, color: _LiveDesign.accent)),
          ],
        ],
      ),
    );
  }

  /// 录制时长标签(m:ss;展示就近取值,事件/交互驱动刷新)。
  String _recDurationLabel() {
    final s = controller.recordingSeconds ?? 0;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  // ── 取景区:帧 + 监看叠层 + 底边横幅 ────────────────────────────

  /// 取景区:帧 + 监看叠层 + 底边横幅。[topInset]/[bannerBottomInset] 供
  /// 横屏浮层布局把贴边元素(即拍即览卡/直方图/横幅)让位给顶/底控制条。
  Widget _feedArea(BuildContext context,
      {double topInset = 0, double bannerBottomInset = 0}) {
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
        onTapUp: (d) => _handleTapFocus(d, imageRect),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null)
              Image.memory(frame, fit: BoxFit.contain,
                  gaplessPlayback: true) // 换帧不闪黑
            else
              Center(
                child: Text(
                  status.value == LiveViewStatus.running
                      ? '取景中…(等待首帧)'
                      : status.value == LiveViewStatus.failed
                          ? '取景失败(${controller.engine.lastError ?? "未知错误"})'
                          : '取景已关闭\n开启「取景」查看实时画面\n点按画面可触控对焦',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _LiveDesign.faint),
                ),
              ),
            if (_showGrid)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) => GridOverlay(
                    aspect: analysis == null
                        ? null
                        : analysis.width / analysis.height),
              ),
            if (_showZebra)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    ZebraOverlay(analysis: analysis),
              ),
            if (_showFalseColor)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    FalseColorOverlay(analysis: analysis),
              ),
            if (_showPeaking)
              ValueListenableBuilder(
                valueListenable: controller.analyzer.analysis,
                builder: (context, FrameAnalysis? analysis, _) =>
                    PeakingOverlay(analysis: analysis),
              ),
            // 即拍即览:新照片缩略图小卡(几秒后自动撤)
            if (controller.reviewThumb != null)
              Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: EdgeInsets.fromLTRB(10, 10 + topInset, 10, 10),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: _LiveDesign.glass,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _LiveDesign.hairline),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(controller.reviewThumb!,
                        width: 96, height: 64, fit: BoxFit.cover),
                  ),
                ),
              ),
            if (_showHistogram)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding:
                      EdgeInsets.fromLTRB(8, 8, 8, 8 + bannerBottomInset),
                  child: ValueListenableBuilder(
                    valueListenable: controller.analyzer.analysis,
                    builder: (context, FrameAnalysis? analysis, _) =>
                        HistogramView(analysis: analysis),
                  ),
                ),
              ),
            // 水平仪优先用**相机帧头**的虚拟水平仪(Zf 机身侧水平仪,
            // OpenZCine 同源字段;Gen-1 短头/相机未报时落回手机姿态)。
            if (_showLevel)
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
                    stream: _phoneAttitudes,
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
            // 横幅贴画面底边(OpenZCine「坐在画面下沿」口径)
            if (!controller.linkUp)
              Align(
                alignment: Alignment.bottomCenter,
                child: _banner('未连接相机 —— 请先在「相机」页建立连接',
                    _LiveDesign.accent,
                    bottomInset: bannerBottomInset),
              )
            else if (controller.error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: _banner(controller.error!, _LiveDesign.bad,
                    bottomInset: bannerBottomInset),
              ),
            if (controller.notice != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: _banner(controller.notice!, _LiveDesign.good,
                    bottomInset: bannerBottomInset),
              ),
          ],
        ),
      );
    });
  }

  /// 点按 → 触控对焦:屏幕坐标经 contain 矩阵归一化到取景帧坐标系。
  void _handleTapFocus(TapUpDetails d, Rect? imageRect) {
    if (imageRect == null) return;
    final nx = ((d.localPosition.dx - imageRect.left) / imageRect.width)
        .clamp(0.0, 1.0);
    final ny = ((d.localPosition.dy - imageRect.top) / imageRect.height)
        .clamp(0.0, 1.0);
    unawaited(controller.touchFocus(nx, ny));
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

  Widget _banner(String text, Color color, {double bottomInset = 0}) {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, 10 + bottomInset),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 12),
          textAlign: TextAlign.center),
    );
  }

  // ── 动作行:取景开关 / 对焦 / 快门 ──────────────────────────────

  Widget _captureRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _liveViewToggle(context),
          _focusButton(context),
          _recordButton(context),
          _mfNearFarButtons(context),
          _shutterButton(context),
        ],
      ),
    );
  }

  Widget _liveViewToggle(BuildContext context) {
    final active = controller.liveViewActive;
    return _actionButton(
      icon: active ? Icons.videocam : Icons.videocam_off_outlined,
      label: active ? '取景中' : '取景',
      dimmed: !active,
      onTap: controller.toggleLiveView,
    );
  }

  /// 对焦按钮:驱动一次自动对焦(0x90C1,候选码待真机核对;
  /// 取景开启是前置条件 —— 未开取景机身回 0xA00B)。
  Widget _focusButton(BuildContext context) {
    final usable = controller.linkUp && controller.liveViewActive;
    return _actionButton(
      icon: Icons.center_focus_strong,
      label: controller.focusing ? '对焦中' : '对焦',
      onTap: usable && !controller.focusing ? controller.afDriveNow : null,
      spinning: controller.focusing,
    );
  }

  /// 录制钮(0x920A/0x920B):红点起录 / 红方块停录;取景开启为前置。
  Widget _recordButton(BuildContext context) {
    final usable = controller.linkUp && controller.liveViewActive;
    final rec = controller.recording;
    return _actionButton(
      icon: rec ? Icons.stop : Icons.fiber_manual_record,
      label: rec ? _recDurationLabel() : '录制',
      dimmed: !usable,
      onTap: usable && !controller.capturing ? controller.toggleRecord : null,
    );
  }

  /// MF 步进(0x9204):向近/向远两粒竖排小钮(跟焦环语义,相对量)。
  Widget _mfNearFarButtons(BuildContext context) {
    final usable = controller.linkUp && controller.liveViewActive;
    Widget step(IconData icon, bool towardNear, String tip) {
      return Tooltip(
        message: tip,
        child: SizedBox(
          width: 40,
          height: 32,
          child: Material(
            color: _LiveDesign.glass,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
              side: const BorderSide(color: _LiveDesign.hairline),
            ),
            child: InkWell(
              onTap: usable
                  ? () => controller.mfDriveStep(towardNear: towardNear)
                  : null,
              child: Icon(icon,
                  size: 18,
                  color: usable ? _LiveDesign.text : _LiveDesign.faint),
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
        const Text('MF',
            style: TextStyle(fontSize: 10, color: _LiveDesign.faint)),
      ],
    );
  }

  /// 快门钮(OpenZCine PhotographyShutterButton 同款):白圈 + 白芯,
  /// 按下变半透明白(拍照中)。**按下即拍 + 按住连拍**(连续释放档时
  /// 按住 = 连拍括持链发,抬起终止;普通档点按 = 单张)。
  Widget _shutterButton(BuildContext context) {
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
          width: 72,
          height: 72,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.92), width: 4),
                ),
              ),
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: controller.capturing
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white,
                ),
                child: Center(
                  child: controller.selfTimerCountdown != null
                      ? Text('${controller.selfTimerCountdown}',
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: _LiveDesign.background))
                      : controller.capturing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: _LiveDesign.background),
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

  /// 动作行按钮:暗底圆角方块 + 图标 + 下标签(取景/对焦);
  /// 整块(含标签)都是点击区。
  Widget _actionButton({
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
              color:
                  onTap == null ? _LiveDesign.surface : _LiveDesign.glass,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _LiveDesign.hairline),
            ),
            child: Center(
              child: spinning
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: _LiveDesign.accent),
                    )
                  : Icon(icon,
                      size: 26,
                      color:
                          dimmed ? _LiveDesign.muted : _LiveDesign.text),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style:
                  const TextStyle(fontSize: 11, color: _LiveDesign.muted)),
        ],
      ),
    );
  }

  // ── 拍摄读出条(相机控制核心)───────────────────────────────────

  /// 读出条 tile 顺序:对齐 OpenZCine photographyCaptureValues
  /// (MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/METER/PROFILE),其余随后。
  static const _stripOrder = <int>[
    PtpDevicePropCode.exposureProgramMode,
    PtpDevicePropCode.exposureIndex,
    PtpDevicePropCode.exposureTime,
    PtpDevicePropCode.fNumber,
    PtpDevicePropCode.stillCaptureMode,
    PtpDevicePropCode.stillFocusMode,
    PtpDevicePropCode.whiteBalance,
    PtpDevicePropCode.wbColorTemp,
    PtpDevicePropCode.exposureMeteringMode,
    PtpDevicePropCode.exposureBiasCompensation,
    PtpDevicePropCode.flashMode,
    PtpDevicePropCode.compressionSetting,
    PtpDevicePropCode.rawCompressionType,
    PtpDevicePropCode.captureAreaCrop,
    PtpDevicePropCode.activePicCtrlItem,
  ];

  Widget _captureStrip(BuildContext context, {EdgeInsetsGeometry? margin}) {
    final params = [
      for (final code in _stripOrder)
        if (shootingParamByCode[code] != null) shootingParamByCode[code]!,
    ];
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: Stack(
        children: [
          // 边缘渐隐(OpenZCine edge fade 同款):两侧各 ~12px 融入玻璃
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [
                Color(0x00000000),
                Color(0xFF000000),
                Color(0xFF000000),
                Color(0x00000000),
              ],
              stops: [0, 0.035, 0.965, 1],
            ).createShader(bounds),
            blendMode: BlendMode.dstIn,
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final p in params)
                    _CaptureTile(
                      param: p,
                      state: controller.paramProps[p.code],
                      auto: controller.paramAutoControlled(p.code),
                      writable: controller.propWritable(p.code),
                      active: _activeParam == p.code,
                      writing: controller.writing,
                      locked: controller.lockedProps.contains(p.code),
                      onTap: () => _editParam(context, p),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 辅助条:监看开关 + 对焦后拍 + APP 接管 ──────────────────────

  Widget _assistStrip(BuildContext context, {EdgeInsetsGeometry? margin}) {
    Widget toggle(IconData icon, String label, bool current,
        void Function(bool) set) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 34,
              child: Material(
                color: current ? _LiveDesign.accentDim : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                      color: current
                          ? _LiveDesign.accent.withValues(alpha: 0.5)
                          : _LiveDesign.hairline),
                ),
                child: InkWell(
                  onTap: () => set(!current),
                  customBorder: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon,
                      size: 18,
                      color: current ? _LiveDesign.accent : _LiveDesign.muted),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: current ? _LiveDesign.accent : _LiveDesign.faint)),
          ],
        ),
      );
    }

    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: Wrap(
        spacing: 2,
        runSpacing: 4,
        children: [
          toggle(Icons.grid_on, '网格', _showGrid, (v) => setState(() => _showGrid = v)),
          // 四个分析类开关改完须同步分析器启停(共享一份帧分析;
          // 开而分析器未启 = 直方图无数据一类静默失效)。
          toggle(Icons.warning_amber, '斑马纹', _showZebra, (v) {
            setState(() => _showZebra = v);
            _syncAnalyzerEnabled();
          }),
          toggle(Icons.bar_chart, '直方图', _showHistogram, (v) {
            setState(() => _showHistogram = v);
            _syncAnalyzerEnabled();
          }),
          toggle(Icons.linear_scale, '水平仪', _showLevel,
              (v) => setState(() => _showLevel = v)),
          toggle(Icons.palette_outlined, '伪色', _showFalseColor, (v) {
            setState(() => _showFalseColor = v);
            _syncAnalyzerEnabled();
          }),
          toggle(Icons.blur_on, '峰值', _showPeaking, (v) {
            setState(() => _showPeaking = v);
            _syncAnalyzerEnabled();
          }),
          const SizedBox(width: 6),
          _smallChip(
            label: '对焦后拍',
            selected: controller.focusBeforeCapture,
            onTap: () => controller.focusBeforeCapture =
                !controller.focusBeforeCapture,
            tooltip: '释放快门前先自动对焦(半按-全按;候选参数,待真机核对)',
          ),
          _smallChip(
            label: controller.selfTimerSeconds == 0
                ? '自拍'
                : '自拍 ${controller.selfTimerSeconds}s',
            selected: controller.selfTimerSeconds > 0,
            onTap: () {
              const cycle = [0, 2, 5, 10];
              final next = cycle[(cycle.indexOf(controller.selfTimerSeconds) +
                      1) %
                  cycle.length];
              controller.setSelfTimer(next);
            },
            tooltip: '自拍定时:关 → 2s → 5s → 10s 循环;倒计时中再点取消',
          ),
          _takeoverChip(context),
        ],
      ),
    );
  }
  /// 辅助条小芯片(对焦后拍 / APP 接管)。
  Widget _smallChip({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    String? tooltip,
  }) {
    final chip = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected ? _LiveDesign.accentDim : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
              color: selected
                  ? _LiveDesign.accent.withValues(alpha: 0.5)
                  : _LiveDesign.hairline),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                  fontSize: 12,
                  color: selected ? _LiveDesign.accent : _LiveDesign.muted),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  /// APP 接管控制状态芯片:未接管 = 点按弹确认启用;已接管 = 点按解除
  /// (0x90C2 remote 模式;机身拨盘锁定,host 写入保值)。
  Widget _takeoverChip(BuildContext context) {
    final active = controller.takeoverActive;
    return _smallChip(
      label: active ? 'APP 接管中' : 'APP 接管',
      selected: active,
      onTap: !controller.linkUp
          ? null
          : (active
              ? controller.releaseTakeover
              : () => _confirmTakeover(context)),
      tooltip: '拨盘级参数(快门/模式/ISO/光圈)需先接管才能遥控调整',
    );
  }

  // ── 参数面板(弹层)与接管确认 ──────────────────────────────────

  /// 拍摄参数编辑面板:取值域 = 相机 PropDesc 枚举(权威)或目录
  /// pickValues 直供(快门:标准档打包表等厂商码场景);范围域 → 滑条;
  /// 域未知 → 只读提示。选中即写(0x1016)并按读码路由回读刷新,不额外
  /// 确认 —— 相机侧可随时再调。拨盘拥有参数(快门/模式/ISO/光圈)先过
  /// 「APP 接管控制」确认。**列表打开即定位到当前值**(不从列表头开始
  /// —— 长列表如快门 54 档)。
  Future<void> _editParam(BuildContext context, ShootingParam p) async {
    if (p.dialOwned && !controller.takeoverActive) {
      if (!await _confirmTakeover(context) || !context.mounted) return;
    }
    setState(() => _activeParam = p.code);
    try {
      final state = controller.paramProps[p.code];
      final desc = state?.desc;
      // 取值域:相机 PropDesc 枚举优先(权威),拒答/无 FORM 时目录
      // pickValues 直供(快门/对焦模式/图像区域等厂商码场景)。
      final enums =
          desc?.enumValues?.whereType<int>().toList(growable: false) ??
              p.pickValues;
      final rangeMin = desc?.rangeMin as int?;
      final rangeMax = desc?.rangeMax as int?;
      final rangeStep = desc?.rangeStep as int? ?? 1;
      // 定位:当前值在列表中的序号(ISO 面板有置顶的「自动 ISO」条目,+1)
      final hasIsoAutoTile = p.code == PtpDevicePropCode.exposureIndex &&
          controller.isoAuto != null;
      final currentIndex = (enums?.indexOf(state?.value ?? -1) ?? -1) +
          (hasIsoAutoTile ? 1 : 0);
      final listCtrl = ScrollController();
      var centered = false;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: _LiveDesign.surface,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final current = controller.paramProps[p.code]?.value;
              final writing = controller.writing; // 写中防连点
              if (!centered && currentIndex > 2) {
                // 首帧布局后跳到当前值(顶上留两行上下文)
                centered = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (listCtrl.hasClients) {
                    listCtrl.jumpTo(
                        (currentIndex - 2) * _paramSheetItemExtent);
                  }
                });
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(p.label,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _LiveDesign.muted)),
                  ),
                  if (enums != null && enums.isNotEmpty)
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        controller: listCtrl,
                        itemExtent: _paramSheetItemExtent,
                        children: [
                          // ISO 面板置顶「自动 ISO」开关(0xD054;与手动
                          // 值互不干扰 —— 开关只在这里显式控制)。
                          if (hasIsoAutoTile)
                            ListTile(
                              title: const Text('自动 ISO',
                                  style:
                                      TextStyle(color: _LiveDesign.text)),
                              trailing: controller.isoAuto == true
                                  ? const Icon(Icons.check,
                                      color: _LiveDesign.accent)
                                  : null,
                              onTap: writing
                                  ? null
                                  : () {
                                      Navigator.of(sheetContext).pop();
                                      controller
                                          .setIsoAuto(!(controller.isoAuto!));
                                    },
                            ),
                          for (final v in enums)
                            ListTile(
                              title: Text(p.display(v),
                                  style: const TextStyle(
                                      color: _LiveDesign.text)),
                              trailing: v == current
                                  ? const Icon(Icons.check,
                                      color: _LiveDesign.accent)
                                  : null,
                              onTap: writing
                                  ? null
                                  : () {
                                      Navigator.of(sheetContext).pop();
                                      controller.setParam(p.code, v);
                                    },
                            ),
                        ],
                      ),
                    )
                  else if (rangeMin != null &&
                      rangeMax != null &&
                      rangeMax > rangeMin &&
                      current != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Column(
                        children: [
                          Text(p.display(current),
                              style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w500,
                                  color: _LiveDesign.text)),
                          Slider(
                            value: (current.clamp(rangeMin, rangeMax))
                                .toDouble(),
                            min: rangeMin.toDouble(),
                            max: rangeMax.toDouble(),
                            divisions:
                                ((rangeMax - rangeMin) ~/ rangeStep).clamp(1, 1 << 20),
                            label: p.display(current),
                            activeColor: _LiveDesign.accent,
                            onChanged: writing ? null : (_) {},
                            onChangeEnd: (v) =>
                                controller.setParam(p.code, v.round()),
                          ),
                        ],
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('该属性的取值域未知,暂不可调(待真机核对)',
                          style: TextStyle(color: _LiveDesign.muted)),
                    ),
                ],
              );
            },
          ),
        ),
      );
      // 面板关闭后释放列表控制器(等一帧,避开退出动画中的惯性访问)
      WidgetsBinding.instance.addPostFrameCallback((_) => listCtrl.dispose());
    } finally {
      if (mounted) setState(() => _activeParam = null);
    }
  }

  /// 「启用 APP 接管控制」确认(影控台同款语义):受机身物理拨盘控制
  /// 的参数需先接管(0x90C2 remote 模式)才能遥控调整;接管期间机身
  /// 拨盘可能被锁定、机身屏幕可能熄灭。返回是否已接管(含已激活直通)。
  Future<bool> _confirmTakeover(BuildContext context) async {
    if (controller.takeoverActive) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('启用 APP 接管控制?'),
        content: const Text('该设置项受相机物理拨盘控制,启用接管后应用才能调整。'
            '接管期间机身拨盘可能被锁定、机身屏幕可能熄灭;'
            '点按「APP 接管中」或断开连接可解除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('启用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    return controller.enableTakeover();
  }
}

/// 参数面板列表条目高(ListTile 单行 = 48;itemExtent 固定后
/// 「打开定位到当前值」的偏移量才可计算)。
const _paramSheetItemExtent = 48.0;

/// 拍摄读出条的单个 tile(OpenZCine CaptureSettingButton 同款):
/// 小标签(9pt,faint;面板打开时金色)+ 大号等宽数字值(自动变量加
/// 「(自动)」后缀并置灰)。不可调(总闸关断/模式门锁定/相机只读)时
/// 整体降透明度且不可点。
class _CaptureTile extends StatelessWidget {
  const _CaptureTile({
    required this.param,
    required this.state,
    required this.auto,
    required this.writable,
    required this.active,
    required this.writing,
    required this.locked,
    required this.onTap,
  });

  final ShootingParam param;
  final PropState? state;
  final bool auto;
  final bool writable;
  final bool active;
  final bool writing;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = param.display(state?.value);
    return InkWell(
      onTap: writable && !writing ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: writable ? 1 : 0.38,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? _LiveDesign.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: active
                ? Border.all(
                    color: _LiveDesign.accent.withValues(alpha: 0.5))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    param.label,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? _LiveDesign.accent.withValues(alpha: 0.85)
                          : _LiveDesign.faint,
                    ),
                  ),
                  if (locked) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.lock, size: 8, color: _LiveDesign.accent),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '$value${auto ? '(自动)' : ''}',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: auto ? _LiveDesign.muted : _LiveDesign.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

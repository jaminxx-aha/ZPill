/// 取景区:帧 + 监看叠层 + 底边横幅(帧到达与状态由外层
/// AnimatedBuilder merge(controller+frame+status) 驱动重建)。
///
/// 画面与全部图像系叠层(网格/斑马纹/伪色/峰值/AF 框)画在**图像
/// 坐标系**的盒子里,外层一个 [Transform] 应用 [FeedTransform]
/// (contain 适配 → 持机旋转 → 变宽还原 → 双指缩放/拖移)—— 叠层件
/// 零改动即随画面旋转/拉伸/缩放;点按对焦坐标经 [FeedTransform.screenToNorm]
/// 逆映射一次收口(见 feed_transform.dart 头注)。直方图/水平仪/即拍
/// 即览/横幅/倍率角标/拉焦轮是屏幕坐标层,不随画面变换。
///
/// [topInset]/[bottomInset]/[leftInset] 供横屏侧栏布局把贴边元素
/// (即拍即览卡/直方图/横幅)让位给顶栏/底浮层/左参数栏。
/// [phoneAttitudes] 为手机姿态流取值(页面缓存的单实例 —— MovtionHost
/// 的 getter 每次返回**新**流,取景期每帧重建会让 StreamBuilder 反复
/// 拆装 EventChannel);相机帧头带虚拟水平仪时优先用它,本流只作兜底。
/// 传**取值函数**而非流:流字段在页面是 late final(平台通道宿主),
/// 只有水平仪兜底真正要建 StreamBuilder 时才取值 —— 提前取值会在无
/// 平台通道的测试环境炸 LateInitializationError。
/// [onTapFocus] 点按取景画面 = 触控对焦:第二参为该点的**归一化图像
/// 坐标**(已含缩放/旋转/变宽逆映射;null = 无画面)。
/// [settingsListenable] 提供画面自动旋转/变宽还原设置(null = AppServices
/// 单例);[dialAlignment] 为拉焦轮锚位(横屏快门柱占右缘中带,页面上移)。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/live_view_header.dart';
import '../../data/settings_store.dart';
import '../../platform/motion_host.dart';
import 'feed_quality.dart';
import 'feed_transform.dart';
import 'live_design.dart';
import 'live_view_overlays.dart';
import 'monitor_toggles.dart';
import 'remote_banner.dart';
import 'remote_controller.dart';

class RemoteFeedArea extends StatefulWidget {
  const RemoteFeedArea({
    super.key,
    required this.controller,
    required this.toggles,
    required this.phoneAttitudes,
    required this.onTapFocus,
    this.topInset = 0,
    this.bottomInset = 0,
    this.leftInset = 0,
    this.settingsListenable,
    this.hideChrome = false,
    this.dialAlignment = Alignment.centerRight,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final Stream<MotionOrientation> Function() phoneAttitudes;
  final void Function(TapUpDetails details, Offset? norm) onTapFocus;
  final double topInset;
  final double bottomInset;
  final double leftInset;

  /// 取景设置(画面自动旋转/变宽还原);null = AppServices 单例。
  final ValueListenable<AppSettings>? settingsListenable;

  /// 纯净监看:隐去交互浮层(倍率角标/拉焦轮);画面与监看叠层保留。
  final bool hideChrome;

  /// 拉焦轮锚位(竖屏右缘居中;横屏快门柱占右缘中带 → 页面传 topRight)。
  final Alignment dialAlignment;

  @override
  State<RemoteFeedArea> createState() => _RemoteFeedAreaState();
}

class _RemoteFeedAreaState extends State<RemoteFeedArea> {
  // ── 双指缩放/拖移(状态在 State:外层 AnimatedBuilder 逐帧重建不丢)──
  static const double _zoomMax = 8.0;

  double _zoom = 1.0;
  Offset _pan = Offset.zero;

  /// 手势基线(scale start 时刻的 zoom/pan/焦点;focal 稳定公式用)。
  double _gZoom = 1.0;
  Offset _gPan = Offset.zero;
  Offset _gFocal = Offset.zero;

  /// 手动双击检测(双击 = 复位缩放)。不注册 onDoubleTap:它会让单击
  /// 等双击超时才派发,点按对焦的响应不能等。
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  late final ValueListenable<AppSettings> _settings =
      widget.settingsListenable ?? AppServices.instance.settingsController;

  @override
  void initState() {
    super.initState();
    // 帧头旋转位的变化不一定伴随帧通知(解析成功的头重设),单独听。
    widget.controller.engine.header.addListener(_rebuild);
    _settings.addListener(_rebuild);
  }

  @override
  void dispose() {
    _settings.removeListener(_rebuild);
    widget.controller.engine.header.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _handleTapUp(TapUpDetails d, FeedTransform t) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final lastPos = _lastTapPos;
    _lastTapAt = now;
    _lastTapPos = d.localPosition;
    if (last != null &&
        lastPos != null &&
        now.difference(last) <= const Duration(milliseconds: 300) &&
        (d.localPosition - lastPos).distance <= 48) {
      // 双击复位(第二击不再对焦 —— 第一击已对过)。
      if (_zoom != 1.0 || _pan != Offset.zero) {
        setState(() {
          _zoom = 1.0;
          _pan = Offset.zero;
        });
      }
      return;
    }
    widget.onTapFocus(d, t.hasImage ? t.screenToNorm(d.localPosition) : null);
  }

  void _handleScaleStart(ScaleStartDetails d) {
    _gZoom = _zoom;
    _gPan = _pan;
    _gFocal = d.localFocalPoint;
  }

  /// focal 稳定:手势起点的画面点在缩放过程中保持在手指下 ——
  /// pan₁ = f₁ − c − (z₁/z₀)·(f₀ − c − p₀);z=1 恒零(不缩出 letterbox)。
  void _handleScaleUpdate(Size boxSize, ScaleUpdateDetails d) {
    final z0 = _gZoom;
    final z1 = (z0 * d.scale).clamp(1.0, _zoomMax);
    final Offset pan1;
    if (z1 <= 1.0) {
      pan1 = Offset.zero;
    } else {
      final c = Offset(boxSize.width / 2, boxSize.height / 2);
      final k = z1 / z0;
      pan1 = d.localFocalPoint -
          c -
          Offset(
            (_gFocal.dx - c.dx - _gPan.dx) * k,
            (_gFocal.dy - c.dy - _gPan.dy) * k,
          );
    }
    if (z1 == _zoom && pan1 == _pan) return;
    setState(() {
      _zoom = z1;
      _pan = pan1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 无帧占位随主题(它在页面底色上);画面上的内容层(即拍即览卡/
    // 横幅/监看叠层)恒用暗面(LiveDesign.dark),不随主题。
    final live = LiveDesign.of(context);
    final controller = widget.controller;
    final Uint8List? frame = controller.engine.frame.value;
    final status = controller.engine.status;
    return LayoutBuilder(builder: (context, constraints) {
      final boxSize = constraints.biggest;
      final fs = controller.frameSize.value;
      final imageSize = fs == null || fs.width <= 0 || fs.height <= 0
          ? Size.zero
          : Size(fs.width.toDouble(), fs.height.toDouble());
      final settings = _settings.value;
      final t = FeedTransform(
        imageSize: imageSize,
        boxSize: boxSize,
        quarter: settings.autoRotateFeed
            ? feedQuarterFromRotationRaw(
                controller.engine.header.value?.rotationRaw ?? 0)
            : 0,
        deSqueeze: settings.deSqueeze,
        zoom: _zoom,
        pan: _pan,
      );
      return GestureDetector(
        // opaque:letterbox 空白区也要收点按(对焦坐标钳到画面边)。
        behavior: HitTestBehavior.opaque,
        // 点按取景画面 = 触控对焦(无帧/未取景时控制器内静默忽略)
        onTapUp: (d) => _handleTapUp(d, t),
        onScaleStart: _handleScaleStart,
        onScaleUpdate: (d) => _handleScaleUpdate(boxSize, d),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 画面子树(图像坐标系;外层 Transform 一次收口)──────
            if (frame != null && t.hasImage)
              ClipRect(
                child: Transform(
                  transform: t.imageToScreen,
                  // 命中测试不走变换:对焦点按由上面的外层手势在屏幕系
                  // 收口(screenToNorm),子树全是非交互视觉件。
                  transformHitTests: false,
                  child: OverflowBox(
                    // StackFit.expand 的紧约束会经 enforce 顶掉
                    // SizedBox 的帧尺寸(minWidth 继承自父级):min 归
                    // 零 + max 放开,子树才能按帧尺寸布局。
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: SizedBox(
                      width: imageSize.width,
                      height: imageSize.height,
                      // expand:Image 解码完成前按 RenderImage 内在规则
                      // 出 0×0(loose 最小约束),紧约束立即填满图像系
                      // 盒;叠层件同样定尺寸。画质档路由:关 = 低采样
                      // (最省)、快速 = 双线性 high、高质量 = shader
                      // (Catmull-Rom + 可选时域降噪,不可用自动回落
                      // high,见 feed_quality.dart)。
                      child: Stack(fit: StackFit.expand, children: [
                          switch (settings.feedUpscaler) {
                            FeedUpscaler.off => Image.memory(frame,
                                fit: BoxFit.fill,
                                gaplessPlayback: true, // 换帧不闪黑
                                filterQuality: FilterQuality.low),
                            FeedUpscaler.fast => Image.memory(frame,
                                fit: BoxFit.fill,
                                gaplessPlayback: true, // 换帧不闪黑
                                filterQuality: FilterQuality.high),
                            FeedUpscaler.quality => ShaderFeed(
                                frame: frame,
                                temporalDenoise: settings.temporalDenoise),
                          },
                        if (widget.toggles.grid)
                          ValueListenableBuilder(
                            valueListenable: controller.analyzer.analysis,
                            builder: (context, FrameAnalysis? analysis, _) =>
                                GridOverlay(
                                    aspect: analysis == null
                                        ? null
                                        : analysis.width /
                                            analysis.height),
                          ),
                        if (widget.toggles.zebra)
                          ValueListenableBuilder(
                            valueListenable: controller.analyzer.analysis,
                            builder: (context, FrameAnalysis? analysis, _) =>
                                ZebraOverlay(analysis: analysis),
                          ),
                        if (widget.toggles.falseColor)
                          ValueListenableBuilder(
                            valueListenable: controller.analyzer.analysis,
                            builder: (context, FrameAnalysis? analysis, _) =>
                                FalseColorOverlay(analysis: analysis),
                          ),
                        if (widget.toggles.peaking)
                          ValueListenableBuilder(
                            valueListenable: controller.analyzer.analysis,
                            builder: (context, FrameAnalysis? analysis, _) =>
                                PeakingOverlay(analysis: analysis),
                          ),
                        // 相机自报 AF 框组(真实尺寸随 AF 区域设置:单点
                        // 小框/动态大框;主体检测开着时附人脸/眼睛框)——
                        // 头在册即替代点按占位框。whole-size 坐标按帧尺寸
                        // 等比投到图像系,随外层变换上屏。
                        ValueListenableBuilder<LiveViewHeader?>(
                          valueListenable: controller.engine.header,
                          builder: (context, LiveViewHeader? h, _) => h ==
                                  null ||
                                  !controller.liveViewActive
                              ? const SizedBox.shrink()
                              : AfAreasOverlay(
                                  header: h,
                                  imageRect:
                                      Offset.zero & imageSize),
                        ),
                        // 点按占位框只在**拿不到相机自报框**时兜底
                        // (0x9203 旧码裸 JPEG / 头框数组空):头在册即
                        // 让位,否则同屏双框。
                        ValueListenableBuilder<LiveViewHeader?>(
                          valueListenable: controller.engine.header,
                          builder: (context, LiveViewHeader? h, _) =>
                              controller.afBox != null &&
                                      (h == null || h.boxes.isEmpty)
                                  ? _afBoxOverlay(imageSize, controller.afBox!)
                                  : const SizedBox.shrink(),
                        ),
                      ]),
                    ),
                  ),
                ),
              )
            else if (frame != null)
              // 帧尺寸嗅探失败(非 JPEG 帧,基本不发生):contain 直铺,
              // 叠层无从对位不上。
              Image.memory(frame, fit: BoxFit.contain,
                  gaplessPlayback: true) // 换帧不闪黑
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 等待首帧:取景机图标 + 金色细进度条(不定进度);
                    // 失败:警示图标 + 重试钮。未开启:纯文案(2026-10-10
                    // 取景默认开后近乎不可达,留作引擎态穷举;真恢复路径
                    // 是失败态「重试取景」)。
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
                              : '取景未开启\n点按画面可触控对焦',
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
            // 自动重连期压暗画面(冻结帧非实时的视觉暗示;不挡手势 ——
            // ColoredBox 不吃命中,点按对焦照常上浮)。
            if (controller.reconnecting)
              const ColoredBox(color: Colors.black26),
            // ── 屏幕坐标层(不随画面变换)─────────────────────────
            // 即拍即览:新照片缩略图小卡(几秒后自动撤)—— 画面上的
            // 内容层,恒用暗面玻璃。
            if (controller.reviewThumb != null)
              Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: EdgeInsets.fromLTRB(
                      10 + widget.leftInset, 10 + widget.topInset, 10, 10),
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
            if (widget.toggles.histogram)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      8 + widget.leftInset, 8, 8, 8 + widget.bottomInset),
                  child: ValueListenableBuilder(
                    valueListenable: controller.analyzer.analysis,
                    builder: (context, FrameAnalysis? analysis, _) =>
                        HistogramView(analysis: analysis),
                  ),
                ),
              ),
            // 水平仪优先用**相机帧头**的虚拟水平仪(Zf 机身侧水平仪,
            // OpenZCine 同源字段;Gen-1 短头/相机未报时落回手机姿态)。
            // 屏幕坐标层不随画面旋转 —— 地平线参考系是手机。
            if (widget.toggles.level)
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
                    stream: widget.phoneAttitudes(),
                    builder: (context, snapshot) => snapshot.hasData
                        ? LevelOverlay(orientation: snapshot.data!)
                        : const SizedBox.shrink(),
                  );
                },
              ),
            // 横幅贴画面底边(OpenZCine「坐在画面下沿」口径)—— 画面
            // 上的内容层,恒用暗面玻璃与暗面语义色,不随主题。
            // 未连接横幅常驻;错误 8s 收圆丸点按展开、提示 4s 淡出
            // (节律在 LiveBannerHost 视图层,不侵入控制器)。
            // **自动重连横幅排最前**(恢复期 linkUp 已闩 false,「未
            // 连接」不得抢屏):常驻不走 LiveBannerHost 节律,重连成功
            // 沿自动消失;相机忙横幅同源(看门狗 BUSY 保持)。
            if (controller.reconnecting)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner(
                    '连接中断 —— 正在自动重连;画面为断开前的保持帧,非实时',
                    LiveDesign.dark.accent,
                    bottomInset: widget.bottomInset),
              )
            else if (controller.liveViewBusyHold)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner('相机忙(写卡/下载中),取景画面保持',
                    LiveDesign.dark.accent,
                    bottomInset: widget.bottomInset),
              )
            else if (!controller.linkUp)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner('未连接相机 —— 请先在「相机」页建立连接',
                    LiveDesign.dark.accent,
                    bottomInset: widget.bottomInset),
              )
            else if (controller.error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.error!, LiveDesign.dark.bad,
                    bottomInset: widget.bottomInset),
              ),
            if (controller.notice != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.notice!, LiveDesign.dark.good,
                    bottomInset: widget.bottomInset, autoDismiss: true),
              ),
            // 缩放倍率角标(>1 才现身;点按复位)。
            if (!widget.hideChrome && _zoom > 1.01)
              Positioned(
                key: const ValueKey('feed-zoom-badge'),
                top: widget.topInset + 8,
                left: 0,
                right: 0,
                child: Center(
                  child: _ZoomBadge(zoom: _zoom, onReset: _resetZoom),
                ),
              ),
            // 拉焦轮(右缘竖条:上下拖 = 向近/向远连续驱动 0x9204)。
            if (!widget.hideChrome && widget.toggles.focusDial)
              Positioned.fill(
                child: Align(
                  alignment: widget.dialAlignment,
                  child: Padding(
                    padding: EdgeInsets.only(
                        right: 12, top: 8 + widget.topInset),
                    child: _FocusDialRail(
                        key: const ValueKey('focus-dial-rail'),
                        // 机身对焦模式为 MF 时远程拉焦失效:轮子压暗
                        // (拖动被控制器静默丢弃,姿态不消失)。
                        enabled: !controller.focusModeIsMf,
                        onDrag: controller.focusDialDrag),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  void _resetZoom() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  /// 触控对焦框:图像系回投;尺寸是视觉占位(相机侧实际对焦区域
  /// 大小无从得知)。随外层 Transform 上屏(变宽时横向同比拉伸)。
  Widget _afBoxOverlay(Size imageSize, AfBox box) {
    final side = imageSize.width * 0.18;
    return Positioned(
      left: box.nx * imageSize.width - side / 2,
      top: box.ny * imageSize.height - side / 2,
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

/// 缩放倍率角标:暗面玻璃胶囊,点按复位(双击画面同效)。
class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({required this.zoom, required this.onReset});

  final double zoom;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 自吃点按:不落到画面手势(复位而非对焦)。
      onTap: onReset,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: LiveDesign.dark.glass,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LiveDesign.dark.hairline),
        ),
        child: Text(
          '${zoom.toStringAsFixed(1)}×',
          style: TextStyle(
            fontSize: 13,
            color: LiveDesign.dark.text,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// 拉焦轮:取景画面右缘竖条,竖向拖动 = 连续手动对焦(0x9204,步进
/// 标定见 RemoteController.focusDialDrag)。自吃竖拖与点按,不落到画面
/// 手势;近/远方向 = 下/上(跟焦轮手感的「向自己转 = 向近」)。
/// [enabled] = false(机身对焦模式为 MF)时压暗且不回调,手势照旧
/// 自吃(松手漏给缩放手势反而更怪)。
class _FocusDialRail extends StatelessWidget {
  const _FocusDialRail(
      {super.key, this.enabled = true, required this.onDrag});

  final bool enabled;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // 自吃点按:点轮子不触发对焦
      onVerticalDragUpdate: enabled ? (d) => onDrag(d.delta.dy) : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Container(
          width: 44,
          height: 180,
          decoration: BoxDecoration(
            color: LiveDesign.dark.glass,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: LiveDesign.dark.hairline),
          ),
          child: CustomPaint(painter: _DialTicksPainter()),
        ),
      ),
    );
  }
}

/// 拉焦轮刻度:中线 + 均匀横档,中心的金色双档 = 拖动把手暗示。
final class _DialTicksPainter extends CustomPainter {
  const _DialTicksPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final dark = LiveDesign.dark;
    final cx = size.width / 2;
    final paint = Paint()
      ..color = dark.muted.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 8; i++) {
      final y = 14 + (size.height - 28) * i / 8;
      final half = (i % 4 == 0) ? 9.0 : 5.0;
      canvas.drawLine(Offset(cx - half, y), Offset(cx + half, y), paint);
    }
    final grip = Paint()
      ..color = dark.accent.withValues(alpha: 0.9)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - 11, size.height / 2 - 2),
        Offset(cx - 11, size.height / 2 + 2), grip);
    canvas.drawLine(Offset(cx + 11, size.height / 2 - 2),
        Offset(cx + 11, size.height / 2 + 2), grip);
  }

  @override
  bool shouldRepaint(_DialTicksPainter oldDelegate) => false;
}

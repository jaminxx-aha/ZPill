/// 取景区:帧 + 监看叠层 + 底边横幅(控制器/状态沿由外层
/// AnimatedBuilder merge(controller+status) 驱动整树重建;帧沿在本件
/// 自订收口 —— 首帧出现/清空与帧尺寸变化才整树重建,逐帧字节更替只走
/// 画面子树的 ValueListenableBuilder,叠层与浮层不随帧率重建)。
///
/// 画面与全部图像系叠层(网格/斑马纹/伪色/峰值/AF 框)画在**图像
/// 坐标系**的盒子里,外层一个 [Transform] 应用 [FeedTransform]
/// (contain 适配 → 持机旋转 → 变宽还原 → 双指缩放/拖移)—— 叠层件
/// 零改动即随画面旋转/拉伸/缩放;点按对焦坐标经 [FeedTransform.screenToNorm]
/// 逆映射一次收口(见 feed_transform.dart 头注)。直方图/水平仪/即拍
/// 即览/横幅/倍率角标/拉焦轮/录制读出(时间码+电平表)是屏幕坐标层,
/// 不随画面变换。
///
/// [topInset]/[bottomInset] 供布局把贴边元素(即拍即览卡/直方图/横幅)
/// 让位给顶栏/底条(横屏顶底条/竖屏底部两行浮层);[rightInset] 供横屏
/// 快门柱贴右缘时把贴右叠层(录制读出/拉焦轮)左移让位。[fit] 为适配
/// 模式(竖屏满宽/横屏满高,2026-10-12「不留黑边」定案,见 [FeedFit])。
/// [onTapFocus] 点按取景画面 = 触控对焦:第二参为该点的**归一化图像
/// 坐标**(已含缩放/旋转/变宽逆映射;null = 无画面/点在画面外 ——
/// 页面侧以 null 分流纯净监看的「点空白隐藏/恢复」,2026-10-17)。
/// [settingsListenable] 提供画面自动旋转/变宽还原设置(null = AppServices
/// 单例);[dialAlignment] 为拉焦轮锚位(横屏右上角让给录制读出、右缘
/// 被快门柱占用 → 页面传 bottomRight)。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/live_view_header.dart';
import '../../data/settings_store.dart';
import '../../l10n/l10n.dart';
import '../../platform/motion_host.dart';
import 'feed_quality.dart';
import 'feed_transform.dart';
import 'interval_status_row.dart';
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
    required this.onTapFocus,
    this.topInset = 0,
    this.bottomInset = 0,
    this.rightInset = 0,
    this.fit = FeedFit.contain,
    this.settingsListenable,
    this.hideChrome = false,
    this.dialAlignment = Alignment.centerRight,
  });

  final RemoteController controller;
  final MonitorToggles toggles;
  final void Function(TapUpDetails details, Offset? norm) onTapFocus;
  final double topInset;
  final double bottomInset;

  /// 贴右屏幕坐标叠层(录制读出/拉焦轮)的右让位(横屏快门柱 78)。
  final double rightInset;

  /// 横幅底让位:间隔拍摄状态行占贴边位时抬高一行(状态行高 32 +
  /// 间隙 10)。
  double get bannerInset => bottomInset + (controller.intervalActive ? 42 : 0);

  /// 适配模式(2026-10-12 用户定案「不留黑边」):竖屏传
  /// [FeedFit.widthFill](画面恒满宽,两侧无黑边)、横屏传
  /// [FeedFit.heightFill](恒满高,上下无黑边)—— 越出取景盒的内容居中
  /// 裁掉(本件 ClipRect 收口);默认 contain 为旧短板适配。
  final FeedFit fit;

  /// 取景设置(画面自动旋转/变宽还原);null = AppServices 单例。
  final ValueListenable<AppSettings>? settingsListenable;

  /// 纯净监看:隐去交互浮层(倍率角标/拉焦轮);画面与监看叠层保留。
  final bool hideChrome;

  /// 拉焦轮锚位(竖屏右缘居中;横屏快门柱占右缘中带 → 页面传 topRight)。
  final Alignment dialAlignment;

  @override
  State<RemoteFeedArea> createState() => _RemoteFeedAreaState();
}

class _RemoteFeedAreaState extends State<RemoteFeedArea>
    with TickerProviderStateMixin {
  // ── 双指缩放/拖移(状态在 State:任何重建路径都不丢)──
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

  /// 首帧入场淡入时长(等待态→首帧的存在沿恰一次;后续帧更替不再淡入)。
  static const Duration _fadeInDuration = Duration(milliseconds: 180);

  /// 入场淡入驱动。重进页(引擎已持有冻结帧)非「等待→首帧」沿,
  /// initState 直取 1.0 全显,不重放。
  late final AnimationController _fadeIn;

  /// 帧存在性镜像:引擎 frame 不回 null(pause/failed 都保留末帧),
  /// 常态只在首帧翻转一次;翻转沿 = 唯一触发整树重建的帧事件。
  bool _framePresent = false;

  /// 帧头旋转四分之一圈数缓存(header 逐帧换新对象逐帧 notify,只认
  /// quarter 真变化才重建 —— 旧路每帧 setState 同一子树重建两遍)。
  int _headerQuarter = 0;

  late final ValueListenable<AppSettings> _settings =
      widget.settingsListenable ?? AppServices.instance.settingsController;

  @override
  void initState() {
    super.initState();
    final engine = widget.controller.engine;
    _framePresent = engine.frame.value != null;
    _fadeIn = AnimationController(
        vsync: this,
        duration: _fadeInDuration,
        value: _framePresent ? 1.0 : 0.0);
    _headerQuarter =
        feedQuarterFromRotationRaw(engine.header.value?.rotationRaw ?? 0);
    // 帧沿只订**存在性**(等待占位↔画面切换):逐帧字节更替由画面子树
    // 的 ValueListenableBuilder 自取,不整树 setState。
    engine.frame.addListener(_onFramePresence);
    // 帧尺寸沿(SOF 嗅探,尺寸真变才 notify):画面布局重算的合法触发,
    // 不随帧率走(旧路借外层逐帧重建捎带,收口后须自订)。
    widget.controller.frameSize.addListener(_rebuild);
    // 帧头旋转位的变化不一定伴随帧通知(解析成功的头重设),单独听 ——
    // 但收窄为 quarter 变化沿(AF 框/录制读出/水平仪已各自
    // ValueListenableBuilder 局部化,不经本层)。
    engine.header.addListener(_onHeaderQuarter);
    _settings.addListener(_rebuild);
  }

  @override
  void dispose() {
    _settings.removeListener(_rebuild);
    widget.controller.engine.header.removeListener(_onHeaderQuarter);
    widget.controller.frameSize.removeListener(_rebuild);
    widget.controller.engine.frame.removeListener(_onFramePresence);
    _fadeIn.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// 帧存在性沿:首帧出现 = 等待占位切画面,同时放行入场淡入(从零
  /// 180ms,只此一次 —— 引擎不回 null,重连/失败都保留冻结帧)。
  void _onFramePresence() {
    if (!mounted) return;
    final present = widget.controller.engine.frame.value != null;
    if (present == _framePresent) return;
    _framePresent = present;
    if (present) _fadeIn.forward(from: 0);
    setState(() {});
  }

  /// 帧头沿收窄:只认旋转四分之一圈数变化,且仅在自动旋转开着时重建
  /// (关着 quarter 不进变换);缓存无条件更新,开关翻开那一下由设置
  /// 监听的整树重建吃到新值。
  void _onHeaderQuarter() {
    if (!mounted) return;
    final quarter = feedQuarterFromRotationRaw(
        widget.controller.engine.header.value?.rotationRaw ?? 0);
    if (quarter == _headerQuarter) return;
    _headerQuarter = quarter;
    if (_settings.value.autoRotateFeed) setState(() {});
  }

  void _handleTapUp(TapUpDetails d, FeedTransform t) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final lastPos = _lastTapPos;
    _lastTapAt = now;
    _lastTapPos = d.localPosition;
    // 纯净监看隐藏中不走双击检测:任意点按都须送达页面恢复 chrome
    // (2026-10-17 「再点击出现」—— 隐藏态连点两下同位若被双击吞掉,
    // chrome 就再也回不来);隐藏态无缩放,双击复位本无从谈起。
    // 双击拦截只在缩放/平移态吞第二击(复位缩放);原倍态第二击放行
    // —— 同点再点 = 对焦(2026-10-17 用户定案「点两下 = 移动 + 对焦」
    // 正要这一击;旧口径吞击是因为第一击已自动对过,挪框不自动 AF 后
    // 第二击就是那次对焦)。
    if (!widget.hideChrome &&
        last != null &&
        lastPos != null &&
        now.difference(last) <= const Duration(milliseconds: 300) &&
        (d.localPosition - lastPos).distance <= 48 &&
        (_zoom != 1.0 || _pan != Offset.zero)) {
      setState(() {
        _zoom = 1.0;
        _pan = Offset.zero;
      });
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
    // 帧只看存在性(null↔有帧):决定占位/画面分支。字节更替由画面
    // 子树的 ValueListenableBuilder 自取,不触发本层重建。
    final bool hasFrame = controller.engine.frame.value != null;
    final status = controller.engine.status;
    return LayoutBuilder(builder: (context, constraints) {
      final boxSize = constraints.biggest;
      final fs = controller.frameSize.value;
      final imageSize = fs == null || fs.width <= 0 || fs.height <= 0
          ? Size.zero
          : Size(fs.width.toDouble(), fs.height.toDouble());
      final settings = _settings.value;
      // 监看 LUT:选中即自动走高质量渲染管线(仅 shader 路径能查表;
      // 设备不支持时 ShaderFeed 自行回落,无 LUT 但画面照常)。
      final lut = monitorLutOf(settings);
      final t = FeedTransform(
        imageSize: imageSize,
        boxSize: boxSize,
        fit: widget.fit,
        // 旋转四分之一圈数由 header 监听沿缓存(_onHeaderQuarter):
        // 逐帧头对象不再触发整树 setState,旋转真翻转才重建。
        quarter: settings.autoRotateFeed ? _headerQuarter : 0,
        deSqueeze: settings.deSqueeze,
        zoom: _zoom,
        pan: _pan,
      );
      return GestureDetector(
        // opaque:letterbox 空白区点按也收下(不落穿透),出界点
        // screenToNorm 回 null —— 不挪对焦框(2026-10-16 用户定案)。
        behavior: HitTestBehavior.opaque,
        // 点按取景画面 = 触控对焦(无帧/未取景时控制器内静默忽略)
        onTapUp: (d) => _handleTapUp(d, t),
        onScaleStart: _handleScaleStart,
        onScaleUpdate: (d) => _handleScaleUpdate(boxSize, d),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 画面子树(图像坐标系;外层 Transform 一次收口)──────
            // 帧沿收口(2026-10-22):① 首帧入场淡入 —— 等待占位→画面
            // 的存在沿恰一次 FadeTransition(重进页/断连冻结帧直接全显,
            // 后续帧更替不再淡入);② 重绘收口 —— RepaintBoundary 包整幅
            // 画面子树,帧更替的重绘不外溢(叠层各有自己的边界)。边界
            // 刻意在 Transform **之外**:ShaderFeed 的解码降采样目标量测
            // 读 canvas.getTransform(),画布路径才折有适配/旋转/缩放;
            // 边界落进 Transform 内会让子树改走 TransformLayer 合成路径,
            // 子画布 CTM 归零、量测失效。
            if (hasFrame && t.hasImage)
              FadeTransition(
                opacity: _fadeIn,
                child: RepaintBoundary(
                  child: ClipRect(
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
                            // 逐帧消费收口:engine.frame 每帧 notify 只重建
                            // 这一格(帧 Image/ShaderFeed 换字节),取景区
                            // 整树与全部叠层不随帧率重建。
                            ValueListenableBuilder<Uint8List?>(
                              valueListenable: controller.engine.frame,
                              builder: (context, liveFrame, _) => liveFrame ==
                                      null
                                  ? const SizedBox.shrink()
                                  : switch (settings.feedUpscaler) {
                                      // LUT 开 → shader 档(查表只在
                                      // 片元路径;off/fast 仅在无 LUT
                                      // 时维持原路)。
                                      FeedUpscaler.off when lut == null =>
                                        Image.memory(liveFrame,
                                            fit: BoxFit.fill,
                                            gaplessPlayback: true, // 换帧不闪黑
                                            filterQuality: FilterQuality.low),
                                      FeedUpscaler.fast when lut == null =>
                                        Image.memory(liveFrame,
                                            fit: BoxFit.fill,
                                            gaplessPlayback: true, // 换帧不闪黑
                                            filterQuality: FilterQuality.high),
                                      _ => ShaderFeed(
                                          frame: liveFrame,
                                          temporalDenoise:
                                              settings.temporalDenoise,
                                          lut: lut,
                                        ),
                                    },
                            ),
                            if (widget.toggles.grid)
                              ValueListenableBuilder(
                                valueListenable: controller.analyzer.analysis,
                                builder: (context, FrameAnalysis? analysis,
                                        _) =>
                                    GridOverlay(
                                        aspect: analysis == null
                                            ? null
                                            : analysis.width / analysis.height),
                              ),
                            if (widget.toggles.zebra)
                              ValueListenableBuilder(
                                valueListenable: controller.analyzer.analysis,
                                builder:
                                    (context, FrameAnalysis? analysis, _) =>
                                        ZebraOverlay(analysis: analysis),
                              ),
                            if (widget.toggles.falseColor)
                              ValueListenableBuilder(
                                valueListenable: controller.analyzer.analysis,
                                builder:
                                    (context, FrameAnalysis? analysis, _) =>
                                        FalseColorOverlay(analysis: analysis),
                              ),
                            if (widget.toggles.peaking)
                              ValueListenableBuilder(
                                valueListenable: controller.analyzer.analysis,
                                builder:
                                    (context, FrameAnalysis? analysis, _) =>
                                        PeakingOverlay(
                                  analysis: analysis,
                                  // 色档(金/白/红)随持久化设置,表外档回落金。
                                  color: peakingColorOf(
                                      widget.toggles.peakingColor),
                                ),
                              ),
                            // 构图框(遮幅/安全框/中心标;纯显示层,不占
                            // 分析器 —— 叠层随外层变换上屏)。
                            if (widget.toggles.framingAspect !=
                                    FramingAspect.off ||
                                widget.toggles.framingSafeArea ||
                                widget.toggles.framingCenterMark)
                              FramingOverlay(
                                aspect: widget.toggles.framingAspect.ratio,
                                deSqueeze: settings.deSqueeze,
                                safeArea: widget.toggles.framingSafeArea,
                                centerMark: widget.toggles.framingCenterMark,
                              ),
                            // 相机自报 AF 框组(真实尺寸随 AF 区域设置:单点
                            // 小框/动态大框;主体检测开着时附人脸/眼睛框)——
                            // 头在册即替代点按占位框。whole-size 坐标按帧尺寸
                            // 等比投到图像系,随外层变换上屏。
                            ValueListenableBuilder<LiveViewHeader?>(
                              valueListenable: controller.engine.header,
                              builder: (context, LiveViewHeader? h, _) =>
                                  h == null || !controller.liveViewActive
                                      ? const SizedBox.shrink()
                                      : AfAreasOverlay(
                                          header: h,
                                          imageRect: Offset.zero & imageSize),
                            ),
                            // 点按占位框只在**拿不到相机自报框**时兜底
                            // (0x9203 旧码裸 JPEG / 头框数组空):头在册即
                            // 让位,否则同屏双框。
                            ValueListenableBuilder<LiveViewHeader?>(
                              valueListenable: controller.engine.header,
                              builder: (context, LiveViewHeader? h, _) =>
                                  controller.afBox != null &&
                                          (h == null || h.boxes.isEmpty)
                                      ? _afBoxOverlay(
                                          imageSize, controller.afBox!)
                                      : const SizedBox.shrink(),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else if (hasFrame)
              // 帧尺寸嗅探失败(非 JPEG 帧,基本不发生):contain 直铺,
              // 叠层无从对位不上。同样吃入场淡入 + 重绘收口 + 帧局部消费。
              FadeTransition(
                opacity: _fadeIn,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: controller.engine.frame,
                    builder: (context, liveFrame, _) => liveFrame == null
                        ? const SizedBox.shrink()
                        : Image.memory(liveFrame,
                            fit: BoxFit.contain,
                            gaplessPlayback: true), // 换帧不闪黑
                  ),
                ),
              )
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
                      Icon(Icons.error_outline, size: 44, color: live.bad),
                      const SizedBox(height: 10),
                    ],
                    Text(
                      status.value == LiveViewStatus.running
                          ? context.t('live.waitingFirstFrame')
                          : status.value == LiveViewStatus.failed
                              ? context.tm((
                                  key: 'live.failed',
                                  args: {
                                    'e': controller.engine.lastError ??
                                        const (
                                          key: 'common.unknownError',
                                          args: null
                                        ),
                                  }
                                ))
                              : context.t('live.offHint'),
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
                      // AP 失败 + 接管未开:引导兜底(2026-10-15 深夜起
                      // 连接沿已主动接管 —— 落到此处 = 连接沿开闩被拒/
                      // 取景总闸关;STA 门天然开、USB 连接流已开闩,均不
                      // 出此引导)。
                      if (controller.apMode && !controller.takeoverActive) ...[
                        Text(
                          context.t('live.needsTakeover'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: live.faint, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        FilledButton.tonalIcon(
                          onPressed: controller.enableTakeoverAndRetryLiveView,
                          style: FilledButton.styleFrom(
                            foregroundColor: live.bad,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          icon:
                              const Icon(Icons.screen_lock_portrait, size: 16),
                          label: Text(context.t('live.enableTakeoverRetry')),
                        ),
                      ] else
                        TextButton.icon(
                          onPressed: controller.toggleLiveView,
                          style: TextButton.styleFrom(
                            foregroundColor: live.bad,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          icon: Icon(Icons.refresh, size: 16, color: live.bad),
                          label: Text(context.t('live.retry')),
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
                  margin: EdgeInsets.fromLTRB(10, 10 + widget.topInset, 10, 10),
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
                  padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + widget.bottomInset),
                  child: ValueListenableBuilder(
                    valueListenable: controller.analyzer.analysis,
                    builder: (context, FrameAnalysis? analysis, _) =>
                        HistogramView(analysis: analysis),
                  ),
                ),
              ),
            // 示波器族(波形/RGB Parade/矢量/红绿灯四选一):与直方图
            // 同锚(左下),双开时上移让位(直方图盒 64 + 贴边 8 + 间隙 4;
            // 红绿灯盒 58 较矮,同让位口径从简,不差那 4px)。
            if (widget.toggles.scope != ScopeKind.off)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      8,
                      8,
                      8,
                      8 +
                          widget.bottomInset +
                          (widget.toggles.histogram ? 76 : 0)),
                  child: ValueListenableBuilder(
                    valueListenable: controller.analyzer.analysis,
                    // 红绿灯带标签由 TrafficLightsView 自行 t() 落地。
                    builder: (context, FrameAnalysis? analysis, _) => ScopeView(
                      kind: widget.toggles.scope,
                      analysis: analysis,
                      nLogScale: widget.toggles.scopeNLog,
                    ),
                  ),
                ),
              ),
            // ── 录制读出:时间码 + 声音电平表 + 过热警告(贴右上;可见
            // 性见 recordingReadoutOf —— 时间码随机身显示开关,电平表录制
            // 常驻,过热随机身自报温度)。监看信息非交互浮层:纯净监看
            // 保留、点按透传。
            ValueListenableBuilder<LiveViewHeader?>(
              valueListenable: controller.engine.header,
              builder: (context, LiveViewHeader? h, _) {
                final v = recordingReadoutOf(h,
                    liveViewActive: controller.liveViewActive);
                if (!v.timecode && !v.meters && v.overheat == null) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  top: widget.topInset + 8,
                  right: 12 + widget.rightInset,
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (v.overheat != null) ...[
                          OverheatBadge(
                              level: v.overheat!,
                              countdownSeconds: v.countdownSeconds),
                          const SizedBox(height: 6),
                        ],
                        if (v.timecode) TimecodeView(timecode: h!.timecode!),
                        if (v.meters) ...[
                          if (v.timecode) const SizedBox(height: 6),
                          AudioMetersView(sound: h!.sound!),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
            // 水平仪只用**相机帧头**的虚拟水平仪(Zf 机身侧水平仪,
            // OpenZCine 同源字段)。无帧(取景未开/失败/Gen-1 短头)
            // 不显示 —— 手机姿态回落已撤(2026-10-16 用户定案:手机
            // 水平线误导,宁缺勿错)。屏幕坐标层不随画面旋转 —— 地平线
            // 参考系是手机。
            if (widget.toggles.level)
              ValueListenableBuilder<LiveViewHeader?>(
                valueListenable: controller.engine.header,
                builder: (context, LiveViewHeader? h, _) {
                  final level = h?.level;
                  if (level == null) return const SizedBox.shrink();
                  const d2r = 3.141592653589793 / 180;
                  return LevelOverlay(
                    orientation: MotionOrientation(
                      // 帧头角为相机视角、度;符号换算待真机核对。
                      pitchRad: level.signedPitch * d2r,
                      rollRad: -level.signedRoll * d2r,
                    ),
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
            // **间隔拍摄状态行占最底层贴边位**(常驻 + 停止钮,安全
            // 优先不随纯净监看隐藏):横幅让位其上(inset 抬高)。
            if (controller.intervalActive)
              Align(
                alignment: Alignment.bottomCenter,
                child: IntervalStatusRow(
                    controller: controller, bottomInset: widget.bottomInset),
              ),
            if (controller.reconnecting)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner(
                    context.t('live.frozenFrame'), LiveDesign.dark.accent,
                    bottomInset: widget.bannerInset),
              )
            else if (controller.liveViewBusyHold)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner(
                    context.t('live.cameraBusy'), LiveDesign.dark.accent,
                    bottomInset: widget.bannerInset),
              )
            else if (!controller.linkUp)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBanner(
                    context.t('live.notConnected'), LiveDesign.dark.accent,
                    bottomInset: widget.bannerInset),
              )
            else if (controller.error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.error!, LiveDesign.dark.bad,
                    bottomInset: widget.bannerInset),
              ),
            if (controller.notice != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LiveBannerHost(controller.notice!, LiveDesign.dark.good,
                    bottomInset: widget.bannerInset, autoDismiss: true),
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
                        right: 12 + widget.rightInset,
                        top: 8 + widget.topInset),
                    child: _FocusDialRail(
                        key: const ValueKey('focus-dial-rail'),
                        // 机身对焦模式为 MF 时远程拉焦失效:轮子压暗
                        // (拖动被控制器静默丢弃,姿态不消失)。
                        enabled: !controller.focusModeIsMf,
                        // 端点态(0xA00C 方向归因):轮身压暗反馈 ——
                        // 锁定方向增量被控制器静默丢弃,反向拖动照常
                        // 驱动、首步请求即解锁(压暗随之解除)。
                        dimmed: controller.mfNearEnd || controller.mfFarEnd,
                        onDrag: controller.focusDialDrag,
                        netPulses: controller.dialNetPulses),
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
  /// 颜色跟机身屏对齐,只有红绿两色(2026-10-12 用户定案):合焦
  /// ([AfBox.focused] == true,0x90C1 应答 OK)绿,其余(未合焦
  /// 0xA002/对焦中/未知)红。
  Widget _afBoxOverlay(Size imageSize, AfBox box) {
    final side = imageSize.width * 0.18;
    return Positioned(
      left: box.nx * imageSize.width - side / 2,
      top: box.ny * imageSize.height - side / 2,
      width: side,
      height: side,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.fromBorderSide(BorderSide(
                color: box.focused == true
                    ? const Color(0xFF2EC76B)
                    : LiveDesign.dark.bad,
                width: 2)),
            borderRadius: const BorderRadius.all(Radius.circular(6)),
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
/// 自吃(松手漏给缩放手势反而更怪)。[dimmed](端点态:近端/远端已到)
/// 仅压暗轮身 —— 反向拖动仍须能驱动(那是解锁路径),方向过滤在
/// 控制器端点锁。压暗同款 0.35(既有 MF 门控形态)。
/// [netPulses] 驱动刻度鼓(净脉冲乐观账本,见
/// RemoteController.dialNetPulses):刻度随驱动滚动,拖动中轮身高亮
/// (OpenZCine MFDriveStrip 同款)。
class _FocusDialRail extends StatefulWidget {
  const _FocusDialRail(
      {super.key,
      this.enabled = true,
      this.dimmed = false,
      required this.onDrag,
      required this.netPulses});

  final bool enabled;
  final bool dimmed;
  final ValueChanged<double> onDrag;
  final ValueListenable<int> netPulses;

  @override
  State<_FocusDialRail> createState() => _FocusDialRailState();
}

class _FocusDialRailState extends State<_FocusDialRail> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final dark = LiveDesign.dark;
    final enabled = widget.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // 自吃点按:点轮子不触发对焦
      onVerticalDragStart:
          enabled ? (_) => setState(() => _dragging = true) : null,
      onVerticalDragUpdate: enabled ? (d) => widget.onDrag(d.delta.dy) : null,
      onVerticalDragEnd:
          enabled ? (_) => setState(() => _dragging = false) : null,
      onVerticalDragCancel:
          enabled ? () => setState(() => _dragging = false) : null,
      child: Opacity(
        opacity: enabled && !widget.dimmed ? 1 : 0.35,
        child: Container(
          width: 44,
          height: 180,
          clipBehavior: Clip.hardEdge, // 滚动刻度出圆角即裁(不溢出轮身)
          decoration: BoxDecoration(
            color: _dragging
                ? Color.alphaBlend(const Color(0x24FFFFFF), dark.glass)
                : dark.glass,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
                color: _dragging ? dark.accent : dark.hairline,
                width: _dragging ? 1.5 : 1),
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: widget.netPulses,
            builder: (context, net, _) =>
                CustomPaint(painter: _DialDrumPainter(netPulses: net)),
          ),
        ),
      ),
    );
  }
}

/// 拉焦轮刻度鼓:刻度随净脉冲滚动 —— 标定 24px 拖动 = 300 脉冲,刻度
/// 间距取 24px(300 脉冲滚一档,跟手 1:1);中心金色双档固定作指针,
/// 刻度从其下滚过。滚轮路径派发即入账(乐观),鼓面跟手不空转;按钮
/// 路径按结果入账(拒答/步进过小 = 镜头未动,鼓面不动)。
final class _DialDrumPainter extends CustomPainter {
  const _DialDrumPainter({required this.netPulses});

  final int netPulses;

  static const double _spacing = 24.0;
  static const double _pxPerPulse = _spacing / 300;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = LiveDesign.dark;
    final cx = size.width / 2;
    final offset = (netPulses * _pxPerPulse) % _spacing;
    final paint = Paint()
      ..color = dark.muted.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    // 绝对档号 k:长短档花式跟刻度一起滚(不是屏幕位置定式样)。
    final kStart = ((-offset - _spacing) / _spacing).floor();
    final kEnd = ((size.height + _spacing - offset) / _spacing).ceil();
    for (var k = kStart; k <= kEnd; k++) {
      final y = offset + k * _spacing;
      final half = (k % 4 == 0) ? 9.0 : 5.0;
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
  bool shouldRepaint(_DialDrumPainter oldDelegate) =>
      oldDelegate.netPulses != netPulses;
}

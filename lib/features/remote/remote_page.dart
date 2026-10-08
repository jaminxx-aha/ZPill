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
/// - 信息胶囊:链路点 + 设备名 + 接管徽标 + 方向切换钮;
/// - 取景区(Expanded):取景帧 + 网格/斑马纹/直方图/水平仪 + 触控对焦,
///   错误/提示横幅贴画面底边(OpenZCine「坐在画面下沿」的口径);
/// - 动作行:取景开关 / 对焦 / 快门(按下即拍、按住连拍);
/// - 拍摄读出条:全部拍摄参数 tile 横滚(自动变量标「(自动)」置灰,
///   顺序对齐 OpenZCine photographyCaptureValues:MODE/ISO/SHUTTER/
///   IRIS/DRIVE/FOCUS/WB/METER/PROFILE,其余随后);
/// - 辅助条:监看开关 + 「对焦后拍」+「APP 接管」。
///
/// 横屏转**侧栏监看布局**:取景画面全幅铺底,顶栏一条(信息胶囊 +
/// 辅助面板/纯净监看按钮),参数读出竖列贴左、动作竖列贴右 —— 横屏
/// 屏高仅 ~390px,「浮顶 + 浮底」布局会盖掉约六成画面(2026-10-08
/// 用户反馈),侧栏大部分落在取景画幅的左右黑边上;辅助开关收进顶栏
/// tune 按钮的非模态浮层;纯净监看(眼睛)隐去全部控制浮层,只留画面
/// 与监看叠层。方向按钮三态(跟随系统/锁横屏/锁竖屏)经 SystemChrome
/// 强制,系统转屏锁开着也能切,不依赖系统自动横竖屏设置。
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// 应用内方向锁定(拍摄页方向按钮三态):auto 跟随系统;landscape/
/// portrait 经 [SystemChrome.setPreferredOrientations] 强制 —— 系统
/// 转屏锁开着也能切(iOS Info.plist 已声明全方向、Android configChanges
/// 已含 orientation,均无平台工程改动)。app 全局生效,页面销毁时复位。
enum _OrientationLock { auto, landscape, portrait }

/// 横屏侧栏监看几何:顶栏一条(高 48)+ 左参数栏(宽 96)/右动作栏
/// (宽 72)分贴两侧;贴边元素(横幅/直方图/即拍即览)经 _feedArea 的
/// inset 让位。
const _kLandscapeTopBarHeight = 48.0;
const _kParamRailWidth = 96.0;
/// 顶栏下沿的纵深(8 边距 + 48 栏高):侧栏/贴顶叠层由此起让位。
const _kLandscapeTopInset = 56.0;
/// 左栏右沿(10 边距 + 96 栏宽 + 8 间隙):左下角叠层(直方图/即拍
/// 即览)由此起让位。
const _kLandscapeLeftInset = 114.0;

/// 横屏辅助浮层宽(监看开关 + 芯片组,两列 Wrap 的舒适宽)。
const _kLandscapeAssistPanelWidth = 300.0;

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

  /// 方向锁定(页面级视图偏好,不入持久化设置;重启回 auto)。
  _OrientationLock _orientationLock = _OrientationLock.auto;

  /// 横屏辅助浮层(监看开关 + 芯片组)是否展开。
  bool _assistPanelOpen = false;

  /// 横屏纯净监看:隐去全部控制浮层(横幅/监看叠层/触控对焦保留)。
  bool _chromeHidden = false;

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
    // 方向锁定随页拆除复位(仅锁定态发 —— auto 本就未动系统)。
    if (_orientationLock != _OrientationLock.auto) {
      _applyOrientationLock(_OrientationLock.auto);
    }
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

  /// 横屏侧栏监看:全幅取景打底,控制件收两侧 —— 顶栏一条(信息胶囊
  /// + 辅助面板/纯净监看按钮)、左参数栏、右动作栏;辅助开关收进顶栏
  /// tune 按钮的非模态浮层。chrome 整体(顶栏 + 双栏 + 浮层)经
  /// IgnorePointer + AnimatedOpacity 支持纯净监看淡出。
  ///
  /// 监听拆两层:feed 区照旧 merge(controller+frame+status)逐帧刷;
  /// chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,侧栏的 20 来个 tile/按钮不必逐帧重建。
  Widget _landscapeBody(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // feed 区不能裸放:帧到达只写 ValueNotifier 不 notifyListeners,
        // 没有这层 merge 监听,首帧永远停在「等待首帧」。
        AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            controller.engine.frame,
            controller.engine.status,
          ]),
          builder: (context, _) => _feedArea(context,
              topInset: _kLandscapeTopInset, leftInset: _kLandscapeLeftInset),
        ),
        Positioned.fill(
          child: IgnorePointer(
            // key 供测试定位:Navigator 转场页自己也包 IgnorePointer,
            // 全树按类型找不到「chrome 这一层」。
            key: const ValueKey('landscape-chrome'),
            ignoring: _chromeHidden,
            child: AnimatedOpacity(
              opacity: _chromeHidden ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Stack(
                  children: [
                    // 顶栏:信息胶囊收缩包内容(中部透出画面)+ 两个按钮。
                    Positioned(
                      top: 8,
                      left: 10,
                      right: 10,
                      height: _kLandscapeTopBarHeight,
                      child: Row(
                        children: [
                          Flexible(
                            child: _infoPill(context,
                                margin: EdgeInsets.zero, compact: true),
                          ),
                          const SizedBox(width: 8),
                          _chromeIconButton(
                            icon: Icons.tune,
                            tooltip: '监看辅助(网格/斑马纹/直方图/水平仪…)',
                            selected: _assistPanelOpen,
                            onTap: () => setState(
                                () => _assistPanelOpen = !_assistPanelOpen),
                          ),
                          const SizedBox(width: 6),
                          _chromeIconButton(
                            icon: Icons.visibility_off,
                            tooltip: '纯净监看(隐藏全部控制,只留画面)',
                            onTap: () => setState(() {
                              _chromeHidden = true;
                              // 隐 chrome 时同步收起辅助浮层(不留一个
                              // 看不见却开着的面板态)。
                              _assistPanelOpen = false;
                            }),
                          ),
                        ],
                      ),
                    ),
                    // 左:参数读出竖列(读出条的竖向版)。
                    Positioned(
                      top: _kLandscapeTopInset + 8,
                      bottom: 8,
                      left: 10,
                      width: _kParamRailWidth,
                      child: _paramRail(context),
                    ),
                    // 右:动作竖列(取景/对焦/录制/MF/快门)。
                    Positioned(
                      top: _kLandscapeTopInset + 8,
                      bottom: 8,
                      right: 10,
                      width: 72,
                      child: _landscapeActionRail(context),
                    ),
                    // 辅助浮层:锚在 tune 钮下方、让位右动作栏。
                    if (_assistPanelOpen)
                      Positioned(
                        top: _kLandscapeTopInset + 8,
                        right: 90,
                        width: _kLandscapeAssistPanelWidth,
                        child: _assistPanel(context),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 纯净监看恢复钮:chrome 全隐后唯一入口(监看叠层/横幅仍在)。
        if (_chromeHidden)
          Positioned(
            top: 8,
            right: 10,
            child: _chromeIconButton(
              icon: Icons.visibility,
              tooltip: '显示控制界面',
              onTap: () => setState(() => _chromeHidden = false),
            ),
          ),
      ],
    );
  }

  // ── 方向锁定(应用内横竖屏切换)────────────────────────────────

  /// 方向按钮循环:跟随系统 → 锁横屏 → 锁竖屏 → 跟随系统。
  void _cycleOrientationLock() {
    const order = [
      _OrientationLock.auto,
      _OrientationLock.landscape,
      _OrientationLock.portrait,
    ];
    setState(() {
      _orientationLock =
          order[(order.indexOf(_orientationLock) + 1) % order.length];
    });
    _applyOrientationLock(_orientationLock);
  }

  /// 把方向锁定下发给系统(空列表 = 恢复默认全方向)。OHOS fork 若未
  /// 实现该 method 会 MissingPluginException —— 方向按钮不能因平台
  /// 差异炸页,静默兜住。
  void _applyOrientationLock(_OrientationLock lock) {
    final orientations = switch (lock) {
      _OrientationLock.auto => const <DeviceOrientation>[],
      _OrientationLock.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      _OrientationLock.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
    };
    unawaited(SystemChrome.setPreferredOrientations(orientations)
        .catchError((Object _) {}));
  }

  /// 方向切换钮(信息胶囊行尾,竖横屏同位一处实现):三态图标即态
  /// (锁定态金色),Tooltip 说明下一态。
  Widget _orientationButton() {
    final (icon, tip, locked) = switch (_orientationLock) {
      _OrientationLock.auto => (
          Icons.screen_rotation,
          '方向:跟随系统(点按锁定横屏)',
          false
        ),
      _OrientationLock.landscape => (
          Icons.stay_current_landscape,
          '方向:已锁横屏(点按锁定竖屏)',
          true
        ),
      _OrientationLock.portrait => (
          Icons.stay_current_portrait,
          '方向:已锁竖屏(点按恢复跟随系统)',
          true
        ),
    };
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: _cycleOrientationLock,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        child: SizedBox(
          width: 34,
          height: 30,
          child: Icon(icon,
              size: 18,
              color: locked ? _LiveDesign.accent : _LiveDesign.muted),
        ),
      ),
    );
  }

  /// 玻璃圆角图标钮(横屏 chrome 专用):暗底 + 描边 + Tooltip;
  /// [selected] 金 accent 高亮(辅助面板开等),[dimmed] 随可用性置灰。
  Widget _chromeIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    double size = 36,
    bool selected = false,
    bool dimmed = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: selected ? _LiveDesign.accentDim : _LiveDesign.glass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected
                  ? _LiveDesign.accent.withValues(alpha: 0.5)
                  : _LiveDesign.hairline,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Icon(icon,
                size: size * 0.5,
                color: dimmed
                    ? _LiveDesign.faint
                    : selected
                        ? _LiveDesign.accent
                        : _LiveDesign.text),
          ),
        ),
      ),
    );
  }

  // ── 信息胶囊:链路 + 设备名 + 接管徽标 + 方向钮 ──────────────────

  /// [compact]:横屏顶栏态 —— 不占满宽(收缩包内容,顶栏中部透出
  /// 画面),徽标前用小间距代替 Spacer 撑开。
  Widget _infoPill(BuildContext context,
      {EdgeInsetsGeometry? margin, bool compact = false}) {
    final linked = controller.linkUp;
    final name = controller.connection?.deviceName;
    return Container(
      width: compact ? null : double.infinity,
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
          compact ? const SizedBox(width: 12) : const Spacer(),
          if (controller.takeoverActive) ...[
            Icon(Icons.lock, size: 13, color: _LiveDesign.accent),
            const SizedBox(width: 4),
            const Text('APP 接管中',
                style:
                    TextStyle(fontSize: 12, color: _LiveDesign.accent)),
            const SizedBox(width: 6),
          ],
          _orientationButton(),
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

  /// 取景区:帧 + 监看叠层 + 底边横幅。[topInset]/[bottomInset]/
  /// [leftInset] 供横屏侧栏布局把贴边元素(即拍即览卡/直方图/横幅)
  /// 让位给顶栏/底浮层/左参数栏。
  Widget _feedArea(BuildContext context,
      {double topInset = 0, double bottomInset = 0, double leftInset = 0}) {
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
                  margin: EdgeInsets.fromLTRB(
                      10 + leftInset, 10 + topInset, 10, 10),
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
                    bottomInset: bottomInset),
              )
            else if (controller.error != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: _banner(controller.error!, _LiveDesign.bad,
                    bottomInset: bottomInset),
              ),
            if (controller.notice != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: _banner(controller.notice!, _LiveDesign.good,
                    bottomInset: bottomInset),
              ),
          ],
        ),
      );
    });
  }

  /// 点按 → 触控对焦:屏幕坐标经 contain 矩阵归一化到取景帧坐标系。
  /// 横屏辅助浮层开着时,点画面顺带收起浮层(画面本身即「外点」——
  /// 不用 TapRegion:它在外点 down 时关面板,锚按钮的 tap 在 up 时
  /// 又重开,两者打架)。
  void _handleTapFocus(TapUpDetails d, Rect? imageRect) {
    if (_assistPanelOpen) setState(() => _assistPanelOpen = false);
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
  /// 按住 = 连拍括持链发,抬起终止;普通档点按 = 单张)。[size] 默认
  /// 竖屏动作行 72,横屏右栏 64。
  Widget _shutterButton(BuildContext context, {double size = 72}) {
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
                      color: Colors.white.withValues(alpha: 0.92), width: 4),
                ),
              ),
              Container(
                width: size - 18,
                height: size - 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: controller.capturing
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white,
                ),
                child: Center(
                  child: controller.selfTimerCountdown != null
                      ? Text('${controller.selfTimerCountdown}',
                          style: TextStyle(
                              fontSize: size >= 72 ? 24 : 20,
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

  /// 横屏右动作栏:竖排 取景/对焦/录制 + MF 步进对 + 快门沉底,
  /// spaceBetween 分布。图标 + Tooltip(横屏屏面窄,不带下标签);
  /// 录制中钮下补时长小字(事件驱动刷新,同信息胶囊)。
  Widget _landscapeActionRail(BuildContext context) {
    final usable = controller.linkUp && controller.liveViewActive;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _chromeIconButton(
          icon: controller.liveViewActive
              ? Icons.videocam
              : Icons.videocam_off_outlined,
          tooltip: controller.liveViewActive ? '取景中(点按关闭)' : '取景',
          dimmed: !controller.liveViewActive,
          size: 44,
          onTap: controller.toggleLiveView,
        ),
        _chromeIconButton(
          icon: Icons.center_focus_strong,
          tooltip: controller.focusing ? '对焦中' : '对焦(驱动一次自动对焦)',
          dimmed: !usable,
          size: 44,
          onTap: usable && !controller.focusing ? controller.afDriveNow : null,
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chromeIconButton(
              icon: controller.recording ? Icons.stop : Icons.fiber_manual_record,
              tooltip: controller.recording ? '停录' : '录制',
              dimmed: !usable,
              size: 44,
              onTap: usable && !controller.capturing
                  ? controller.toggleRecord
                  : null,
            ),
            if (controller.recording)
              Text(_recDurationLabel(),
                  style: const TextStyle(
                      fontSize: 10,
                      color: _LiveDesign.bad,
                      fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
        _mfNearFarButtons(context),
        _shutterButton(context, size: 64),
      ],
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
  /// (MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/METER/PROFILE),其余随后
  /// (目录余量按目录序追加 —— AF 区域/主体检测/色调等曾因此不渲染,
  /// 2026-10-07 用户反馈「AF 区域/拍摄对象不能改」根因)。
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

  /// 读出条/参数栏的参数序:固定序(对齐 OpenZCine
  /// photographyCaptureValues:MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/
  /// METER/PROFILE,见 _stripOrder)+ 目录余量按目录序追加(新参数
  /// 默认上栏)。
  List<ShootingParam> _orderedParams() => [
        for (final code in _stripOrder)
          if (shootingParamByCode[code] != null) shootingParamByCode[code]!,
        for (final p in kShootingParams)
          if (!_stripOrder.contains(p.code)) p,
      ];

  /// 读出条 tile(竖屏底部横滚 / 横屏左参数栏竖列共用)的取值打包;
  /// [dense] 为左栏紧凑态(值 13px + 省略号)。
  _CaptureTile _captureTileOf(ShootingParam p, {bool dense = false}) =>
      _CaptureTile(
        param: p,
        displayValue:
            controller.displayParamValue(p.code, controller.paramProps[p.code]?.value),
        auto: controller.paramAutoControlled(p.code),
        writable: controller.propWritable(p.code),
        active: _activeParam == p.code,
        writing: controller.writing,
        locked: controller.lockedProps.contains(p.code),
        dense: dense,
        onTap: () => _editParam(context, p),
      );

  Widget _captureStrip(BuildContext context, {EdgeInsetsGeometry? margin}) {
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
                  for (final p in _orderedParams()) _captureTileOf(p),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 横屏左参数栏:读出条的竖向滚动版(dense tile:值 13px + 省略号),
  /// 上下边缘渐隐同横条(改轴向)。
  Widget _paramRail(BuildContext context) {
    return Container(
      width: _kParamRailWidth,
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: [0, 0.05, 0.95, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemExtent: 52,
          children: [
            for (final p in _orderedParams()) _captureTileOf(p, dense: true),
          ],
        ),
      ),
    );
  }

  // ── 辅助条:监看开关 + 对焦后拍 + APP 接管 ──────────────────────

  /// 辅助开关组(竖屏底部整条 / 横屏浮层面板共用):监看开关 Wrap +
  /// 对焦后拍/自拍/APP 接管芯片。
  Widget _assistToggles(BuildContext context) {
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
                      color:
                          current ? _LiveDesign.accent : _LiveDesign.muted),
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

    return Wrap(
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
    );
  }

  Widget _assistStrip(BuildContext context, {EdgeInsetsGeometry? margin}) {
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: _assistToggles(context),
    );
  }

  /// 横屏辅助浮层(非模态):监看开关 + 芯片组,锚在顶栏 tune 钮下方、
  /// 让位右动作栏。点取景画面即收起(见 _handleTapFocus),点浮层外
  /// 的其他控制件不收 —— 浮层不遮它们,互不打扰。
  Widget _assistPanel(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _LiveDesign.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _LiveDesign.hairline),
      ),
      child: _assistToggles(context),
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
                              // 槽位真名(0x90CC)优先:优化校准自定义/云组
                              // 静态表只有「自定义 N」「云 N」占位。
                              title: Text(
                                  controller.displayParamValue(p.code, v),
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
                          Text(controller.displayParamValue(p.code, current),
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
                            label: controller.displayParamValue(p.code, current),
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
    required this.displayValue,
    required this.auto,
    required this.writable,
    required this.active,
    required this.writing,
    required this.locked,
    required this.onTap,
    this.dense = false,
  });

  final ShootingParam param;

  /// 值文本(经控制器路由:优化校准槽位真名 0x90CC 优先)。
  final String displayValue;
  final bool auto;
  final bool writable;
  final bool active;
  final bool writing;
  final bool locked;
  final VoidCallback onTap;

  /// 横屏左参数栏竖列的紧凑态:值 13px + 省略号(栏宽 ~96)。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final value = displayValue;
    return InkWell(
      onTap: writable && !writing ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: writable ? 1 : 0.38,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10, vertical: 4),
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
                overflow:
                    dense ? TextOverflow.ellipsis : TextOverflow.clip,
                style: TextStyle(
                  fontSize: dense ? 13 : 15,
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

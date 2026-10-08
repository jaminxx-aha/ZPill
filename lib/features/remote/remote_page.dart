/// 拍摄页(底部导航 tab):Live View 监看 + 相机控制。
///
/// **界面语言源自 OpenZCine**(MonitorShell / MonitorCaptureStrip /
/// CaptureSettingButton / PhotographyShutterButton / LiveDesign,MIT):
/// 监看底色 + 金色 accent、玻璃胶囊条、等宽数字读出 tile(小标签 +
/// 大号等宽值)、白圈白芯快门钮、横向读出条边缘渐隐 + 金色箭头提示。
/// 外围 chrome 随应用主题(LiveDesign.of,2026-10-08「改成跟随主题」:
/// 深色 = 暖黑现状,浅色 = v8 白底统一黄);叠在取景画面上的内容层
/// (横幅/即拍即览/监看叠层/AF 框)恒定暗面不随主题。
/// 功能层为本仓 [RemoteController](拨盘级接管/曝光变量模式门/值回读
/// 路由/连拍按住,见其头注)—— 本页只做视图,交互全部走控制器。
/// 视图件已拆至同目录:取景区/横幅/信息胶囊/动作行/读出条/辅助条/
/// 参数面板各成文件,本文件只剩页面 State 与横竖屏组装。
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
/// 与监看叠层。方向按钮(恒显转屏图标,点按横↔竖直切,初始态跟随
/// 系统)经 SystemChrome 强制,系统转屏锁开着也能切,不依赖系统自动
/// 横竖屏设置。
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
import '../../platform/motion_host.dart';
import '../../platform/services.dart';
import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_action_row.dart';
import 'remote_assist_strip.dart';
import 'remote_capture_strip.dart';
import 'remote_controller.dart';
import 'remote_feed_area.dart';
import 'remote_info_pill.dart';
import 'remote_param_sheet.dart';
import 'shooting_param_catalog.dart';

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

  /// 监看辅助开关(页面级视图偏好,不入持久化设置)。
  MonitorToggles _toggles = const MonitorToggles();

  /// 读出条中当前打开面板的参数(金高亮 tile)。
  int? _activeParam;

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
    // 方向锁**不**随页复位:锁是会话级(挂 RemoteController);且复位
    // 要发空表 —— iOS 收 All mask 会按手机物理姿态重选方向、被转屏锁
    // 弹回(2026-10-08 真机日志定案:竖→横→竖双旋闪屏)。
    controller.setViewerVisible(false);
    super.dispose();
  }

  /// 斑马纹/直方图/伪色/峰值共享同一份帧分析:任一开启即启用分析器。
  void _syncAnalyzerEnabled() {
    final want =
        _toggles.zebra || _toggles.histogram || _toggles.falseColor || _toggles.peaking;
    if (controller.analyzer.enabled.value != want) {
      controller.analyzer.enabled.value = want;
    }
  }

  /// 辅助开关组落定(监看开关 + 帧分析器启停同步)。
  void _updateToggles(MonitorToggles toggles) {
    setState(() => _toggles = toggles);
    _syncAnalyzerEnabled();
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
      backgroundColor: LiveDesign.of(context).background,
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
          RemoteInfoPill(
              controller: controller,
              onToggleOrientation: _cycleOrientationLock),
          Expanded(
            child: RemoteFeedArea(
              controller: controller,
              toggles: _toggles,
              phoneAttitudes: () => _phoneAttitudes,
              onTapFocus: _handleTapFocus,
            ),
          ),
          CaptureRow(controller: controller),
          CaptureStrip(
              controller: controller,
              activeParam: _activeParam,
              onEditParam: _editParam),
          RemoteAssistStrip(
              controller: controller,
              toggles: _toggles,
              onTogglesChanged: _updateToggles,
              onTakeoverRequest: _confirmTakeover),
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
          builder: (context, _) => RemoteFeedArea(
            controller: controller,
            toggles: _toggles,
            phoneAttitudes: () => _phoneAttitudes,
            onTapFocus: _handleTapFocus,
            topInset: kLandscapeTopInset,
            leftInset: kLandscapeLeftInset,
          ),
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
                      height: kLandscapeTopBarHeight,
                      child: Row(
                        children: [
                          Flexible(
                            child: RemoteInfoPill(
                              controller: controller,
                              onToggleOrientation: _cycleOrientationLock,
                              margin: EdgeInsets.zero,
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChromeIconButton(
                            icon: Icons.tune,
                            tooltip: '监看辅助(网格/斑马纹/直方图/水平仪…)',
                            selected: _assistPanelOpen,
                            onTap: () => setState(
                                () => _assistPanelOpen = !_assistPanelOpen),
                          ),
                          const SizedBox(width: 6),
                          ChromeIconButton(
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
                      top: kLandscapeTopInset + 8,
                      bottom: 8,
                      left: 10,
                      width: kParamRailWidth,
                      child: ParamRail(
                          controller: controller,
                          activeParam: _activeParam,
                          onEditParam: _editParam),
                    ),
                    // 右:动作竖列(取景/对焦/录制/MF/快门)。
                    Positioned(
                      top: kLandscapeTopInset + 8,
                      bottom: 8,
                      right: 10,
                      width: 72,
                      child: LandscapeActionRail(controller: controller),
                    ),
                    // 辅助浮层:锚在 tune 钮下方、让位右动作栏。
                    if (_assistPanelOpen)
                      Positioned(
                        top: kLandscapeTopInset + 8,
                        right: 90,
                        width: kLandscapeAssistPanelWidth,
                        child: RemoteAssistPanel(
                            controller: controller,
                            toggles: _toggles,
                            onTogglesChanged: _updateToggles,
                            onTakeoverRequest: _confirmTakeover),
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
            child: ChromeIconButton(
              icon: Icons.visibility,
              tooltip: '显示控制界面',
              onTap: () => setState(() => _chromeHidden = false),
            ),
          ),
      ],
    );
  }

  // ── 方向锁定(应用内横竖屏切换)────────────────────────────────

  /// 方向按钮点按 = 切到另一半:横锁↔竖锁直切;auto 态(仅初始)按当前
  /// 屏向取反,首击必翻转、所见即所得。**永不发空表** —— 空表在 iOS 是
  /// All mask,requestGeometryUpdate 会按手机物理姿态重选方向、再被弹回
  /// (2026-10-08 真机日志定案:竖→横→竖双旋闪屏 + 白点一击),故按钮
  /// 不设「回跟随系统」路径(2026-10-08 用户明示取消长按)。
  void _cycleOrientationLock() {
    final current = controller.orientationLock.value;
    final screenLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final next = switch (current) {
      OrientationLock.landscape => OrientationLock.portrait,
      OrientationLock.portrait => OrientationLock.landscape,
      OrientationLock.auto => screenLandscape
          ? OrientationLock.portrait
          : OrientationLock.landscape,
    };
    controller.orientationLock.value = next;
    _applyOrientationLock(next);
  }

  /// 把方向锁定下发给系统(空列表 = 恢复默认全方向,现无发送方,switch
  /// 穷举保留)。竖屏锁只发 portraitUp:Info.plist 本就未声明 UpsideDown,
  /// 双值只留给系统自选余地。OHOS fork 若未实现该 method 会
  /// MissingPluginException —— 方向按钮不能因平台差异炸页,静默兜住。
  void _applyOrientationLock(OrientationLock lock) {
    final orientations = switch (lock) {
      OrientationLock.auto => const <DeviceOrientation>[],
      OrientationLock.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      OrientationLock.portrait => const [DeviceOrientation.portraitUp],
    };
    unawaited(
        SystemChrome.setPreferredOrientations(orientations).catchError((Object _) {}));
  }

  // ── 触控对焦 ───────────────────────────────────────────────────

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

  // ── 参数面板入口与接管确认 ─────────────────────────────────────

  /// 参数编辑入口(读出条 tile / 左参数栏 tile):打开即弹面板;拨盘
  /// 拥有参数的接管确认**在面板头**(双层跳合一,见 showParamEditSheet)。
  /// 面板期 tile 金框([_activeParam])。
  Future<void> _editParam(BuildContext context, ShootingParam p) async {
    setState(() => _activeParam = p.code);
    try {
      await showParamEditSheet(context, controller, p);
    } finally {
      if (mounted) setState(() => _activeParam = null);
    }
  }

  /// 专用「APP 接管」芯片的确认对话框路径(不进参数面板)。
  Future<bool> _confirmTakeover(BuildContext context) =>
      confirmTakeover(context, controller);
}

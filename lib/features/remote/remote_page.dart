/// 拍摄页(相机页「进入拍摄」push 的全屏路由):Live View 监看 + 相机
/// 控制。
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
/// 布局(竖屏,2026-10-08 参考手机原生相机重排):
/// - 取景画面占大头:信息胶囊(链路点 + 设备名 + 接管徽标 + 监看
///   辅助 tune 钮 + 方向钮)浮在画面顶部,监看开关/「对焦后拍」/
///   「自拍」/「APP 接管」收进 tune 钮的非模态浮层;
/// - 错误/提示横幅贴画面底边(OpenZCine「坐在画面下沿」的口径);
/// - 底部三行平铺在页面底色上:参数读出行(小标签 + 数值内联横滚,
///   自动变量标「(自动)」置灰,顺序对齐 OpenZCine
///   photographyCaptureValues:MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/
///   WB/METER/PROFILE,其余随后)→ 紧凑动作行(取景/对焦/录制/
///   MF 步进)→ 快门行(相册缩略图 | 大圆环快门 | 纯净监看)。
///
/// 横屏**侧栏监看 + 居右快门柱**(2026-10-08 随竖屏手机相机式重排定稿,
/// 用户点名「拍照按钮在右侧中间」):取景画面全幅铺底,顶栏一条(信息
/// 胶囊 + tune 钮),参数读出竖列贴左;**快门柱纵向居右** —— 相册
/// 缩略图 / 大圆环快门 / 纯净监看竖排,锚在右缘纵向中点(手机相机
/// 横屏的快门位);动作行贴底(取景/对焦/录制/MF,同竖屏一行平铺)。
/// 贴底叠层(横幅/直方图)经 bottomInset 让位动作行。辅助开关收进
/// 顶栏 tune 按钮的非模态浮层;纯净监看隐去全部控制浮层,只留画面与
/// 监看叠层。方向按钮(恒显转屏图标,点按横↔竖直切,初始态跟随
/// 系统)经 SystemChrome 强制,系统转屏锁开着也能切,不依赖系统自动
/// 横竖屏设置。
///
/// 水平仪数据源:相机帧头虚拟水平仪(LiveViewHeader.level,机身侧水平
/// 仪,OpenZCine 同源)优先,手机姿态流只作相机未报时的兜底。
///
/// 挂载模式(2026-10-08 从底栏 tab 改制):相机页已连接视图「进入拍摄」
/// 全屏 push,返回(pop/系统返回手势)即回相机页 —— 底栏全程不占监看
/// 画面。离页即挂起帧轮询(取景生命周期跟连接走 —— 0x9201 已随连接沿
/// 发出、相机保持取景,这里只停 USB 帧流量,不发 0x9202);每次进入
/// 都是新建页面,initState 恢复轮询并对表刷一次参数(原 tab 模式的
/// 「回台对表」沿移到此)。取景的显式开关仍在动作行;连接即取景由
/// HomeShell 在 connected 沿驱动(RemoteController.autoLiveViewOnConnect)。
///
/// 离页两收口(2026-10-08 真机反馈):①横锁还竖 —— 方向钮是监看页
/// 专属控件而 SystemChrome 全局生效,离页把外壳还竖(portraitUp 具体
/// 方向,空表 All mask 会闪屏永不发),锁态复位 portrait;②断连即
/// 退页 —— 链路没了监看页无从看,pop 回相机页(重连入口在彼)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../data/settings_store.dart';
import '../../platform/motion_host.dart';
import '../../platform/services.dart';
import '../browser/photo_grid_page.dart';
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
  const RemotePage({
    super.key,
    this.controller,
    this.active = true,
    this.settingsListenable,
  });

  final RemoteController? controller;

  /// 本页是否可见(IndexedStack 常驻直挂场景/单测用;push 进入恒 true,
  /// 离页即整页回收)。false 时挂起帧轮询(相机侧取景保持 —— 生命周期
  /// 跟连接走,只停 USB 流量)。
  final bool active;

  /// 取景设置监听(画面自动旋转/变宽还原;测试注入;null = AppServices
  /// 单例的 SettingsController)。
  final ValueListenable<AppSettings>? settingsListenable;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final RemoteController controller;

  /// 取景设置(画面自动旋转/变宽还原;下传取景区)。
  late final ValueListenable<AppSettings> _settings =
      widget.settingsListenable ?? AppServices.instance.settingsController;

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

  /// 上拍链路态:断连沿(linkUp true→false)触发自动退页。控制器冷启
  /// 乐观门闩 true 起步,直挂未连接场景与真连接在此同形,只在沿上分。
  bool _wasLinkUp = true;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
    controller.setViewerVisible(widget.active);
    _wasLinkUp = controller.linkUp;
    controller.addListener(_onControllerChanged);
    // 进页对表刷一次参数(路由模式每次进入都是新建页面,原 tab 模式
    // 「回台对表」沿不存在;机身侧拨盘/菜单改动的事件不一定送达,同
    // didUpdateWidget 的兜底口径)。门 = 取景在跑:连接即取景使真连接
    // 必然如此,而 linkUp 是冷启乐观门闩(恒真)不能作凭;直挂/未连接
    // 场景引擎 idle,零请求。
    if (widget.active && controller.liveViewActive) {
      unawaited(controller.refreshParams());
    }
  }

  @override
  void didUpdateWidget(RemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 可见性沿(常驻直挂场景,如单测):挂起/恢复帧轮询(相机侧取景
    // 保持,不发 0x9202)。push 路由每次进入都是新建页面,不走此沿。
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
    controller.removeListener(_onControllerChanged);
    // 离页只挂起轮询(取景生命周期跟连接走,不因拆页发 0x9202)。
    // 方向收口走 PopScope(pop 起点即发,不等 dispose);此处不动锁。
    controller.setViewerVisible(false);
    super.dispose();
  }

  /// 断连即退页(2026-10-08 真机反馈):链路没了监看页无从看,自动
  /// pop 回相机页 —— 重连入口在彼,相机页也随断连切回连接方式视图。
  /// 参数面板/确认框若开着一并收掉(popUntil 到壳);直挂首页场景
  /// (单测)isFirst 即自身,no-op。方向收口在 pop 前先发(幂等,
  /// PopScope 亦会走一遍)。
  void _onControllerChanged() {
    final up = controller.linkUp;
    final dropped = _wasLinkUp && !up;
    _wasLinkUp = up;
    if (!dropped || !mounted) return;
    _exitOrientationReset();
    Navigator.of(context).popUntil((r) => r.isFirst);
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
    return PopScope(
      canPop: true,
      // 离页方向收口(返回钮/系统返回手势/断连退页都经此):pop 起点
      // 即发,不等 dispose —— 转场与转屏并发,相机页落地即竖。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _exitOrientationReset();
      },
      child: Scaffold(
        backgroundColor: LiveDesign.of(context).background,
        body: SafeArea(child: body),
      ),
    );
  }

  /// 离页方向收口(幂等):横锁期间离开监看页,把外壳还竖 —— 方向钮
  /// 是监看页专属控件而 SystemChrome 全局生效,不还的话相机页/设置页
  /// 跟着横(2026-10-08 真机反馈)。锁态一并复位 portrait:每次进页
  /// 从竖起步、点按直切横竖(无白点一击)。发的是具体方向 portraitUp,
  /// **不是空表 All mask**(空表 iOS 按物理姿态闪转,2026-10-08 定案
  /// 永不发);portrait/auto 锁离页无需动作(本就全局竖)。
  void _exitOrientationReset() {
    if (controller.orientationLock.value != OrientationLock.landscape) {
      return;
    }
    controller.orientationLock.value = OrientationLock.portrait;
    unawaited(
      SystemChrome.setPreferredOrientations(
              const [DeviceOrientation.portraitUp])
          .catchError((Object _) {}),
    );
  }

  /// 竖屏手机相机式排版(2026-10-08 参考手机原生相机重排):取景画面
  /// 占大头,信息胶囊浮在画面顶部(辅助开关收进胶囊 tune 钮的非模态
  /// 浮层);底部三行平铺在页面底色上 —— 参数读出行(内联小标签 +
  /// 数值)→ 紧凑动作行 → 快门行(相册缩略图 | 大圆环快门 | 纯净
  /// 监看)。纯净监看隐去顶部浮层与底部三行(眼睛钮恢复),监看叠层/
  /// 横幅保留。
  ///
  /// 监听拆两层(同横屏):feed 区 merge(controller+frame+status)
  /// 逐帧刷;chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,胶囊/读出行/按钮不必逐帧重建。
  Widget _portraitBody(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // feed 区不能裸放:帧到达只写 ValueNotifier 不
              // notifyListeners,没有这层 merge 监听,首帧永远停在
              // 「等待首帧」。
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
                  topInset: kPortraitTopInset,
                  settingsListenable: _settings,
                  hideChrome: _chromeHidden,
                ),
              ),
              // 顶部浮层:信息胶囊(链路/张数/REC/接管 + tune/方向钮)
              // + 辅助浮层;经 IgnorePointer + AnimatedOpacity 支持纯净
              // 监看淡出。key 供测试定位(全树按类型找不到「chrome
              // 这一层」,同横屏)。
              Positioned.fill(
                child: IgnorePointer(
                  key: const ValueKey('portrait-chrome-top'),
                  ignoring: _chromeHidden,
                  child: AnimatedOpacity(
                    opacity: _chromeHidden ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => Stack(
                        children: [
                          Positioned(
                            top: 8,
                            left: 12,
                            right: 12,
                            child: RemoteInfoPill(
                              controller: controller,
                              onToggleOrientation: _cycleOrientationLock,
                              onToggleAssist: () => setState(() =>
                                  _assistPanelOpen = !_assistPanelOpen),
                              assistSelected: _assistPanelOpen,
                              margin: EdgeInsets.zero,
                            ),
                          ),
                          // 辅助浮层:锚在胶囊下方、右对齐。
                          if (_assistPanelOpen)
                            Positioned(
                              top: kPortraitTopInset + 4,
                              right: 12,
                              width: kAssistPanelWidth,
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
                  right: 12,
                  child: ChromeIconButton(
                    icon: Icons.visibility,
                    tooltip: '显示控制界面',
                    onTap: () => setState(() => _chromeHidden = false),
                  ),
                ),
            ],
          ),
        ),
        // 底部三行:参数读出 → 紧凑动作 → 快门行;同受纯净监看淡出
        // 支配(高度保留不跳版,画面区不重排)。
        IgnorePointer(
          key: const ValueKey('portrait-chrome-bottom'),
          ignoring: _chromeHidden,
          child: AnimatedOpacity(
            opacity: _chromeHidden ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CaptureReadoutLine(
                      controller: controller,
                      activeParam: _activeParam,
                      onEditParam: _editParam),
                  CaptureActionBar(controller: controller),
                  CaptureShutterRow(
                    controller: controller,
                    onOpenAlbum: _openAlbum,
                    onHideChrome: _hideChrome,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 相册缩略图钮(快门行左)→ 相机相册(手机相机语言 —— 拍完即看;
  /// 同相机页「相册」入口)。相册页期间本页在路由栈下保持挂载,帧
  /// 轮询照旧(PtpSession 串行锁排队,不与缩略图请求抢总线)。
  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGridPage(
          controller: AppServices.instance.browserController,
          folderHandle: CameraAlbum.allPhotosHandle,
          fallbackName: '相机相册',
        ),
      ),
    );
  }

  /// 纯净监看(竖横屏共用,悬底快门行右钮):隐去全部控制浮层,同步
  /// 收起辅助浮层(不留一个看不见却开着的面板态)。
  void _hideChrome() {
    setState(() {
      _chromeHidden = true;
      _assistPanelOpen = false;
    });
  }

  /// 横屏监看(2026-10-08 用户定案「拍照按钮在右侧中间」):全幅取景
  /// 打底,顶栏一条(信息胶囊 + tune 钮)、左参数栏;**快门柱纵向居右**
  /// (相册缩略图 / 大圆环快门 / 纯净监看 —— 竖屏快门行旋转 90° 的
  /// 同组三件,锚右缘中点);动作行贴底(取景/对焦/录制/MF,同竖屏
  /// 一行)。辅助开关收进顶栏 tune 按钮的非模态浮层。chrome 整体
  /// (顶栏 + 参数栏 + 快门柱 + 动作行 + 浮层)经 IgnorePointer +
  /// AnimatedOpacity 支持纯净监看淡出。
  ///
  /// 监听拆两层:feed 区照旧 merge(controller+frame+status)逐帧刷;
  /// chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,参数栏/快门柱/动作行不必逐帧重建。
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
            bottomInset: kLandscapeBottomInset,
            settingsListenable: _settings,
            hideChrome: _chromeHidden,
            // 拉焦轮让位右缘快门柱:上移到顶栏下方。
            dialAlignment: Alignment.topRight,
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
                    // 顶栏:信息胶囊收缩包内容(中部透出画面)+ tune 钮
                    // 撑到右端(辅助浮层入口;纯净监看移至悬底快门行)。
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
                          const Spacer(),
                          ChromeIconButton(
                            icon: Icons.tune,
                            tooltip: '监看辅助(网格/斑马纹/直方图/水平仪…)',
                            selected: _assistPanelOpen,
                            onTap: () => setState(
                                () => _assistPanelOpen = !_assistPanelOpen),
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
                    // 快门柱纵向居右(2026-10-08 用户定案「拍照按钮在
                    // 右侧中间」):缩略图/快门/纯净监看竖排,锚右缘
                    // 纵向中点(顶栏下沿与底部动作行之间取中)。
                    Positioned(
                      top: kLandscapeTopInset + 8,
                      bottom: kLandscapeBottomInset,
                      right: 10,
                      width: 78,
                      child: Center(
                        child: CaptureShutterColumn(
                          controller: controller,
                          onOpenAlbum: _openAlbum,
                          onHideChrome: _hideChrome,
                        ),
                      ),
                    ),
                    // 动作行贴底(同竖屏一行:取景/对焦/录制/MF 平铺;
                    // 贴底叠层已让位 bottomInset)。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: CaptureActionBar(controller: controller),
                      ),
                    ),
                    // 辅助浮层:锚在 tune 钮下方、让位右缘快门柱。
                    if (_assistPanelOpen)
                      Positioned(
                        top: kLandscapeTopInset + 8,
                        right: 98,
                        width: kAssistPanelWidth,
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
  /// 不设「回跟随系统」路径(2026-10-08 用户明示取消长按)。横锁离页由
  /// [_exitOrientationReset] 还竖复位(锁态回 portrait,不发空表)。
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

  /// 点按 → 触控对焦:取景区已把屏幕点逆映射为**归一化图像坐标**
  /// (缩放/旋转/变宽一次收口,见 FeedTransform.screenToNorm;null = 无
  /// 画面)。横屏辅助浮层开着时,点画面顺带收起浮层(画面本身即「外
  /// 点」—— 不用 TapRegion:它在外点 down 时关面板,锚按钮的 tap 在
  /// up 时又重开,两者打架)。
  void _handleTapFocus(TapUpDetails d, Offset? norm) {
    if (_assistPanelOpen) setState(() => _assistPanelOpen = false);
    if (norm == null) return;
    unawaited(controller.touchFocus(norm.dx, norm.dy));
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

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
/// 视图件已拆至同目录:取景区/横幅/信息胶囊/控制行/读出条/模式条/
/// 对焦浮层/设置浮层/参数面板各成文件,本文件只剩页面 State 与横竖
/// 屏组装。
///
/// 布局(竖屏,2026-10-10 iPhone 相机式重排,用户六条需求:取景默认
/// 开 / 拍照录像并一钮 / 对焦居中 / 设置右侧收参数与监看 / 隐藏显示
/// 同位 / 旋转到底):
/// - 取景画面占大头:信息胶囊(链路点 + 设备名 + 接管徽标 + REC +
///   纯净监看隐藏钮)浮在画面顶部;隐藏后恢复钮在**同一处**(右上
///   角,与胶囊行尾隐藏钮同位 —— 旧版隐藏在快门行右/恢复在顶部两处
///   不一,用户点名);
/// - **取景默认打开**:进页/回页沿未跑则自动起景(取景开关钮撤除;
///   失败态占位里「重试取景」兜底);
/// - 底部三行平铺:参数读出行(点 chip 仍可直接改,现状保留)→ 模式
///   条「照片|视频」(录制中锁,保证停录入口不被模式切换甩开)→
///   控制行(相册缩略图 | 对焦 | 大圆环快门 | 设置 | 方向旋转;快门
///   在视频模式红芯、整段点按起/停录像 —— 拍照/录像合一);
/// - 对焦/设置为**非模态玻璃浮层**(单开互斥,点画面即收):对焦浮层
///   = AF / MF 步进 / 拉焦轮;设置浮层 = 拍摄参数(全目录,点 tile
///   走读出条同款编辑底单)+ 监看开关(网格/斑马纹/直方图/水平仪/
///   伪色/峰值)+ 辅助芯片(对焦后拍/自拍/APP 接管;吸收原 tune 辅
///   助浮层)。
///
/// 横屏**侧栏监看 + 居右快门柱**(2026-10-08 用户定案「拍照按钮在右
/// 侧中间」;2026-10-10 动作行撤除后快门柱四件化):取景画面全幅铺
/// 底,顶栏一条(信息胶囊 + 纯净监看钮),参数读出竖列贴左;快门柱
/// 纵向居右 —— 相册缩略图 / 对焦 / 大圆环快门(64)/ 设置竖排(高
/// 度账 54+8+54+8+64+8+54=250,390pt 屏右列区 262 可容;320pt SE 级
/// 窄屏溢出为存量问题),锚在右缘纵向中点;贴底条 = 模式条(居中)+
/// 方向旋转(右端);对焦/设置浮层让位快门柱(right: 98)。贴底叠层
/// (横幅/直方图)经 bottomInset 让位。纯净监看隐去全部控制浮层,只
/// 留画面与监看叠层,恢复钮与顶栏隐藏钮同位。方向按钮(恒显转屏图
/// 标,点按横↔竖直切,初始态跟随系统)经 SystemChrome 强制,系统
/// 转屏锁开着也能切,不依赖系统自动横竖屏设置。
///
/// 水平仪数据源:相机帧头虚拟水平仪(LiveViewHeader.level,机身侧水平
/// 仪,OpenZCine 同源)优先,手机姿态流只作相机未报时的兜底。
///
/// 挂载模式(2026-10-08 从底栏 tab 改制):相机页已连接视图「进入拍摄」
/// 全屏 push,返回(pop/系统返回手势)即回相机页 —— 底栏全程不占监看
/// 画面。离页即挂起帧轮询(取景生命周期跟连接走 —— 0x9201 已随连接沿
/// 发出、相机保持取景,这里只停 USB 帧流量,不发 0x9202);每次进入
/// 都是新建页面,initState 恢复轮询、自动起景并对表刷一次参数(原
/// tab 模式的「回台对表」沿移到此)。连接即取景由 HomeShell 在
/// connected 沿驱动(RemoteController.autoLiveViewOnConnect),进页
/// 自动起景是对「用户显式关过/引擎失败后重进」的兜底,幂等。
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
import 'remote_capture_strip.dart';
import 'remote_controller.dart';
import 'remote_feed_area.dart';
import 'remote_focus_panel.dart';
import 'remote_info_pill.dart';
import 'remote_mode_strip.dart';
import 'remote_param_sheet.dart';
import 'remote_settings_panel.dart';
import 'shooting_param_catalog.dart';

/// 当前展开的非模态浮层(对焦/设置,单开互斥;点取景画面或再点锚
/// 钮即收,纯净监看一并收)。
enum _OpenPanel { none, focus, settings }

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

  /// 拍摄模式(照片/视频):页面级 UI 态,横竖屏重建不丢(控制器无
  /// 模式概念,Zf 实体拨杆决定)。
  CaptureMode _mode = CaptureMode.photo;

  /// 当前展开的非模态浮层(对焦/设置,单开互斥)。
  _OpenPanel _openPanel = _OpenPanel.none;

  /// 纯净监看:隐去全部控制浮层(横幅/监看叠层/触控对焦保留)。
  bool _chromeHidden = false;

  /// 手机姿态流(缓存单实例:MovtionHost 的 getter 每次返回**新**流,
  /// 取景期页面每帧重建会让 StreamBuilder 反复拆装 EventChannel)。
  /// 相机帧头带虚拟水平仪时优先用它,本流只作兜底。
  late final Stream<MotionOrientation> _phoneAttitudes =
      PlatformServices.motion.attitudes;

  /// 上拍链路态:断连沿(linkUp true→false)触发自动退页。控制器冷启
  /// 乐观门闩 true 起步,直挂未连接场景与真连接在此同形,只在沿上分。
  bool _wasLinkUp = true;

  /// 上拍自动重连态:connected→reconnecting **不弹页**(取景区保留
  /// 冻结帧 + 横幅「正在自动重连」);reconnecting→failed(预算耗尽/
  /// 风暴暂停)才弹,回根页拿重试入口。
  bool _wasRecovering = false;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
    controller.setViewerVisible(widget.active);
    _wasLinkUp = controller.linkUp;
    _wasRecovering = controller.reconnecting;
    controller.addListener(_onControllerChanged);
    // 取景默认打开(2026-10-10 用户需求,取景开关钮撤除):未跑则自动
    // 起景 —— 幂等(HomeShell 连接沿的 autoLiveViewOnConnect 同款),
    // 引擎 failed 态进页也由此重试。直挂/未连接场景 linkUp 是冷启乐观
    // 门闩(恒真)照样发,失败落占位「重试取景」,与真连接同形。
    if (widget.active && !controller.liveViewActive) {
      unawaited(controller.autoLiveViewOnConnect());
    }
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
    // 回台沿:先自动起景(0x9201 + 首帧入队)再对表刷参 —— 串成一条
    // 链而非两个并发 unawaited(引擎帧请求会穿插进刷参链,FIFO 脚本序
    // 无法预置;顺序化后请求序恒 [0x9201, 首帧, 参数…])。
    if (widget.active && !oldWidget.active) {
      unawaited(() async {
        if (!controller.liveViewActive) {
          await controller.autoLiveViewOnConnect();
        }
        if (controller.linkUp) {
          await controller.refreshParams();
        }
      }());
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
  /// **自动重连例外**(2026-10-10):reconnecting 期不弹 —— 画面保留
  /// 断开前的冻结帧(非实时),重连成功就地恢复;弹页只发生在重连
  /// 放弃(转 failed)的沿上。参数面板/确认框若开着一并收掉(popUntil
  /// 到壳);直挂首页场景(单测)isFirst 即自身,no-op。方向收口在
  /// pop 前先发(幂等,PopScope 亦会走一遍)。
  void _onControllerChanged() {
    final up = controller.linkUp;
    final recovering = controller.reconnecting;
    final dropped = (_wasLinkUp || _wasRecovering) && !up && !recovering;
    _wasLinkUp = up;
    _wasRecovering = recovering;
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

  /// 开关组落定(监看开关 + 帧分析器启停同步)。
  void _updateToggles(MonitorToggles toggles) {
    setState(() => _toggles = toggles);
    _syncAnalyzerEnabled();
  }

  /// 浮层开/关(对焦/设置互斥单开:开一个收另一个;再点同钮即收)。
  void _togglePanel(_OpenPanel p) {
    setState(() => _openPanel = _openPanel == p ? _OpenPanel.none : p);
  }

  /// 模式切换(模式条在录制中已禁用,这里再守一道 —— 模式条不可达
  /// 路径(测试直调/竞态)不至于把停录入口甩在视频模式外)。
  void _setMode(CaptureMode m) {
    if (controller.recording || m == _mode) return;
    setState(() => _mode = m);
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
    // 全幅铺底占大块屏幕,控制件(信息胶囊/读出条/快门柱/浮层)以
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

  /// 竖屏 iPhone 相机式排版(2026-10-10 重排):取景画面占大头,信息
  /// 胶囊(含纯净监看隐藏钮)浮在画面顶部;底部三行平铺 —— 参数读出
  /// 行 → 模式条(照片|视频,录制中锁)→ 控制行(相册 | 对焦 | 快门
  /// | 设置 | 旋转)。对焦/设置为非模态浮层,底锚居中浮在底栏上方。
  /// 纯净监看隐去顶部浮层与底部三行(恢复钮在右上角同位),监看叠
  /// 层/横幅保留。
  ///
  /// 监听拆两层(同横屏):feed 区 merge(controller+frame+status)
  /// 逐帧刷;chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,胶囊/读出行/按钮不必逐帧重建。
  Widget _portraitBody(BuildContext context) {
    final panelMaxHeight = MediaQuery.sizeOf(context).height * 0.55;
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
              // 顶部浮层:信息胶囊(链路/张数/REC/接管 + 隐藏钮)+ 对焦/
              // 设置浮层(底锚居中,浮在底栏上方);经 IgnorePointer +
              // AnimatedOpacity 支持纯净监看淡出。key 供测试定位(全树
              // 按类型找不到「chrome 这一层」,同横屏)。
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
                              onHideChrome: _hideChrome,
                              margin: EdgeInsets.zero,
                            ),
                          ),
                          if (_openPanel == _OpenPanel.settings)
                            Positioned(
                              bottom: 8,
                              left: 12,
                              right: 12,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      maxWidth: kCapturePanelWidth + 60),
                                  child: CaptureSettingsPanel(
                                    controller: controller,
                                    toggles: _toggles,
                                    activeParam: _activeParam,
                                    onEditParam: _editParam,
                                    onTogglesChanged: _updateToggles,
                                    onTakeoverRequest: _confirmTakeover,
                                    maxHeight: panelMaxHeight,
                                  ),
                                ),
                              ),
                            ),
                          if (_openPanel == _OpenPanel.focus)
                            Positioned(
                              bottom: 8,
                              left: 12,
                              right: 12,
                              child: Center(
                                child: CaptureFocusPanel(
                                  controller: controller,
                                  toggles: _toggles,
                                  onTogglesChanged: _updateToggles,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 纯净监看恢复钮:chrome 全隐后唯一入口(监看叠层/横幅仍在),
              // 与胶囊行尾隐藏钮同位(右上角)。
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
        // 底部三行:参数读出 → 模式条 → 控制行;同受纯净监看淡出
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
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 2),
                    child: Center(
                      child: CaptureModeStrip(
                        mode: _mode,
                        enabled: !controller.recording,
                        onModeChanged: _setMode,
                      ),
                    ),
                  ),
                  CaptureControlRow(
                    controller: controller,
                    mode: _mode,
                    onOpenAlbum: _openAlbum,
                    onOpenFocus: () => _togglePanel(_OpenPanel.focus),
                    onOpenSettings: () => _togglePanel(_OpenPanel.settings),
                    onToggleOrientation: _cycleOrientationLock,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 相册缩略图钮(控制行左)→ 相机相册(手机相机语言 —— 拍完即看;
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

  /// 纯净监看(竖横屏共用):隐去全部控制浮层,同步收起对焦/设置
  /// 浮层(不留一个看不见却开着的面板态)。恢复钮在右上角同位。
  void _hideChrome() {
    setState(() {
      _chromeHidden = true;
      _openPanel = _OpenPanel.none;
    });
  }

  /// 横屏监看(2026-10-08 用户定案「拍照按钮在右侧中间」):全幅取景
  /// 打底,顶栏一条(信息胶囊 + 纯净监看钮)、左参数栏;**快门柱纵向
  /// 居右**(相册缩略图 / 对焦 / 大圆环快门 64 / 设置,锚右缘中点);
  /// 贴底条 = 模式条(居中)+ 方向旋转(右端)。对焦/设置浮层让位
  /// 快门柱(right: 98 = 10 边距 + 78 柱宽 + 10 间隙)。chrome 整体
  /// (顶栏 + 参数栏 + 快门柱 + 贴底条 + 浮层)经 IgnorePointer +
  /// AnimatedOpacity 支持纯净监看淡出。
  ///
  /// 监听拆两层:feed 区照旧 merge(controller+frame+status)逐帧刷;
  /// chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,参数栏/快门柱/贴底条不必逐帧重建。
  Widget _landscapeBody(BuildContext context) {
    final panelMaxHeight = MediaQuery.sizeOf(context).height -
        kLandscapeTopInset -
        8 -
        kLandscapeBottomInset -
        8;
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
                    // 顶栏:信息胶囊收缩包内容(中部透出画面)+ 纯净
                    // 监看钮撑到右端(隐藏后恢复钮在同位)。
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
                              margin: EdgeInsets.zero,
                              compact: true,
                            ),
                          ),
                          const Spacer(),
                          ChromeIconButton(
                            icon: Icons.visibility_off,
                            tooltip: '纯净监看(隐藏全部控制,只留画面)',
                            onTap: _hideChrome,
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
                    // 快门柱纵向居右(2026-10-10 四件化):缩略图/对焦/
                    // 快门(64)/设置竖排,锚右缘纵向中点(顶栏下沿与
                    // 贴底条之间取中)。
                    Positioned(
                      top: kLandscapeTopInset + 8,
                      bottom: kLandscapeBottomInset,
                      right: 10,
                      width: 78,
                      child: Center(
                        child: CaptureShutterColumn(
                          controller: controller,
                          mode: _mode,
                          onOpenAlbum: _openAlbum,
                          onOpenFocus: () => _togglePanel(_OpenPanel.focus),
                          onOpenSettings: () =>
                              _togglePanel(_OpenPanel.settings),
                        ),
                      ),
                    ),
                    // 贴底条:模式条居中 + 方向旋转右端(贴底叠层已让位
                    // bottomInset)。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Padding(
                        padding: const EdgeInsets.only(
                            left: 10, right: 10, bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Center(
                                child: CaptureModeStrip(
                                  mode: _mode,
                                  enabled: !controller.recording,
                                  onModeChanged: _setMode,
                                ),
                              ),
                            ),
                            // 方向钮不包 Tooltip(长按抬起须等同点按,
                            // 见 CaptureCircleButton 类注)
                            CaptureCircleButton(
                              icon: Icons.screen_rotation,
                              onTap: _cycleOrientationLock,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 对焦/设置浮层:让位右缘快门柱。
                    if (_openPanel == _OpenPanel.settings)
                      Positioned(
                        top: kLandscapeTopInset + 8,
                        right: 98,
                        width: kCapturePanelWidth,
                        child: CaptureSettingsPanel(
                          controller: controller,
                          toggles: _toggles,
                          activeParam: _activeParam,
                          onEditParam: _editParam,
                          onTogglesChanged: _updateToggles,
                          onTakeoverRequest: _confirmTakeover,
                          maxHeight: panelMaxHeight,
                        ),
                      ),
                    if (_openPanel == _OpenPanel.focus)
                      Positioned(
                        top: kLandscapeTopInset + 8,
                        right: 98,
                        child: CaptureFocusPanel(
                          controller: controller,
                          toggles: _toggles,
                          onTogglesChanged: _updateToggles,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 纯净监看恢复钮:chrome 全隐后唯一入口(监看叠层/横幅仍在),
        // 与顶栏右端隐藏钮同位(右上角)。
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
  /// 画面)。对焦/设置浮层开着时,点画面顺带收起浮层(画面本身即
  /// 「外点」—— 不用 TapRegion:它在外点 down 时关面板,锚按钮的 tap
  /// 在 up 时又重开,两者打架)。
  void _handleTapFocus(TapUpDetails d, Offset? norm) {
    if (_openPanel != _OpenPanel.none) {
      setState(() => _openPanel = _OpenPanel.none);
    }
    if (norm == null) return;
    unawaited(controller.touchFocus(norm.dx, norm.dy));
  }

  // ── 参数面板入口与接管确认 ─────────────────────────────────────

  /// 参数编辑入口(读出条 tile / 左参数栏 tile / 设置浮层 tile):打开
  /// 即弹面板;拨盘拥有参数的接管确认**在面板头**(双层跳合一,见
  /// showParamEditSheet)。面板期 tile 金框([_activeParam])。
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

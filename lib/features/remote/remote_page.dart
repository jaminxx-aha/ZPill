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
/// 设置浮层/参数面板各成文件,本文件只剩页面 State 与横竖屏组装。
///
/// 布局(竖屏,2026-10-10 iPhone 相机式重排,用户六条需求:取景默认
/// 开 / 拍照录像并一钮 / 对焦居中 / 设置右侧收参数与监看 / 隐藏显示
/// 同位 / 旋转到底):
/// - 取景画面**完整显示**(2026-10-30 用户定案:[FeedFit.contain],
///   整帧可见,留背景带),不再满幅裁切;底部两行
///   按钮改浮层压画面下沿,「按钮整体往下移」):信息胶囊(链路点 +
///   设备名 + REC + APP 接管钮)浮在画面顶部。纯净监看(2026-10-17
///   用户定案改制):点页面**空白处**(信箱带/按钮间空档/取景盒外
///   让位带)隐去全部控制浮层,**再点任意处恢复** —— 胶囊隐藏钮与
///   恢复钮同日撤除,行尾位由 APP 接管钮接替(设置浮层接管芯片一并
///   撤除,配置项不再出现接管);
/// - **取景默认打开**(十二轮起可持久关:设置浮层「取景」钮,关 =
///   进页/回台/连接沿都不自动起景):进页/回页沿未跑则自动起景(失败
///   态占位里「重试取景」兜底);
/// - 底部两行**浮层压画面下沿**(2026-10-12 用户需求,参数读出行
///   删除 —— 参数入口 = 设置浮层全目录 tile):控制行(对焦 | 大圆环
///   快门 | 设置)→ 底行(相册缩略图 | 模式条「照片|视频」| 方向旋转,
///   水平一行;快门在视频模式红芯、整段点按起/停录像 —— 拍照/录像
///   合一;对焦钮点按即驱动一次 AF,2026-10-12 用户定案;模式条录制
///   中锁,保证停录入口不被模式切换甩开);行内空白自吃(不落到画面
///   手势触发对焦);
/// - 设置为**非模态玻璃浮层**(点画面即收):拍摄参数(全目录,点
///   tile 走读出条同款编辑底单)+ 对焦控制(MF 步进/拉焦轮,自对焦
///   浮层迁入)+ 监看开关(取景/网格/斑马纹/直方图/水平仪/伪色/峰值,
///   十二轮起全部持久化 —— 关掉重进保持)+ 辅助芯片(对焦后拍/自拍/
///   APP 接管;吸收原 tune 辅助浮层)。
///
/// 拍摄页仅竖屏(2026-10-30 去掉横屏模式):无方向钮、无横屏取景台,
/// 全局方向契约钉竖屏。
///
/// 水平仪数据源:相机帧头虚拟水平仪(LiveViewHeader.level,机身侧水平
/// 仪,OpenZCine 同源)。无帧(取景未开/失败)不显示任何水平仪 —— 手机
/// 姿态回落已撤(2026-10-16 用户定案:手机水平线误导,宁缺勿错)。
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
/// 离页收口(2026-10-08 真机反馈):断连即退页 —— 链路没了监看页
/// 无从看,pop 回相机页(重连入口在彼)。拍摄页现仅竖屏(2026-10-30
/// 去掉横屏模式),无方向锁复位。
library;

import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/browser/album.dart';
import '../../core/remote/peaking_engines.dart';
import '../../data/settings_store.dart';
import '../../design/app_haptics.dart';
import '../../l10n/l10n.dart';
import '../../platform/services.dart';
import '../../platform/volume_keys.dart';
import '../browser/photo_grid_page.dart';
import '../common/widgets/confirm_dialog.dart';
import '../settings/settings_page.dart' show SettingsController;
import 'feed_transform.dart';
import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_capture_keys.dart';
import 'remote_controller.dart';
import 'remote_exposure_strip.dart';
import 'remote_feed_area.dart';
import 'rec_labels.dart' show recDurationLabel;
import 'remote_mode_sheet.dart';
import 'remote_param_sheet.dart';
import 'remote_settings_panel.dart';
import 'shooting_param_catalog.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({
    super.key,
    this.controller,
    this.active = true,
    this.settingsListenable,
    this.volumeKeys,
  });

  final RemoteController? controller;

  /// 本页是否可见(IndexedStack 常驻直挂场景/单测用;push 进入恒 true,
  /// 离页即整页回收)。false 时挂起帧轮询(相机侧取景保持 —— 生命周期
  /// 跟连接走,只停 USB 流量)。
  final bool active;

  /// 取景设置监听(画面自动旋转/变宽还原;测试注入;null = AppServices
  /// 单例的 SettingsController)。
  final ValueListenable<AppSettings>? settingsListenable;

  /// 音量键快门宿主(测试注入;null = Android/iOS 用 MethodChannel
  /// 单例,其余平台不接线 —— ohos 未做原生拦截)。
  final VolumeKeyHost? volumeKeys;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final RemoteController controller;

  /// 取景设置(画面自动旋转/变宽还原;下传取景区)。
  late final ValueListenable<AppSettings> _settings =
      widget.settingsListenable ?? AppServices.instance.settingsController;

  /// 监看辅助开关(十二轮起持久化:进页从 [_settings] 桥接恢复,改动
  /// 经 [_persistSettings] 写回;单测注入裸 ValueNotifier 时只在内存里)。
  MonitorToggles _toggles = const MonitorToggles();

  /// 音量键快门设置镜像(面板芯片选中态;外部改动沿差分 setState,
  /// 自己写回的回声同值零动作 —— 同 [_toggles] 款)。
  bool _volumeKeyShutter = false;

  /// 读出条中当前打开面板的参数(金高亮 tile)。
  int? _activeParam;

  /// 拍摄模式本地态:**回落档**(相机 0xD1A6 读不到时的纯 UI 选择,
  /// 改造前行为);相机真状态在控制器([RemoteController.cameraMode]),
  /// 生效模式统一走 [_effMode]。
  CaptureMode _mode = CaptureMode.photo;

  /// 拍摄设置浮层是否展开(再点设置钮或点取景画面即收;2026-10-12
  /// 对焦浮层退场 —— 对焦钮瘦身为一键 AF,MF 步进/拉焦轮迁入设置
  /// 浮层,只剩此一个非模态浮层)。
  bool _settingsOpen = false;

  /// 拍摄设置浮层当前页签:0 参数 / 1 对焦 / 2 监看 / 3 辅助。
  int _settingsTab = 0;

  final _settingsSectionKeys = List<GlobalKey>.generate(4, (_) => GlobalKey());

  /// 纯净监看:隐去全部控制浮层(横幅/监看叠层/触控对焦保留)。
  bool _chromeHidden = false;

  /// 上拍链路态:断连沿(linkUp true→false)触发自动退页。控制器冷启
  /// 乐观门闩 true 起步,直挂未连接场景与真连接在此同形,只在沿上分。
  bool _wasLinkUp = true;

  /// 上拍自动重连态:connected→reconnecting **不弹页**(取景区保留
  /// 冻结帧 + 横幅「正在自动重连」);reconnecting→failed(预算耗尽/
  /// 风暴暂停)才弹,回根页拿重试入口。
  bool _wasRecovering = false;

  /// 断链强制退页:绕过「录制/间隔中退出确认」(链路已没了,任务状态
  /// 由控制器 `_invalidate` 清)。设置后下一帧 PopScope 放行。
  bool _forceExit = false;

  /// 退出确认框在途:防连点/连按返回叠框。
  bool _leaveDialogOpen = false;

  /// BLE GPS 注入芯片就绪态(未配对禁点;页面只读,起停全在
  /// AppServices 注入驱动)。
  bool _bleReady = false;
  StreamSubscription<BleSessionState>? _bleStateSub;

  /// 音量键快门宿主:注入优先(单测);无注入时按平台分派(Android
  /// 拦 onKeyUp / iOS 观察系统音量,见 volume_keys.dart;其余平台
  /// 原生侧无实现,接线也无事发生,索性不接)。
  late final VolumeKeyHost? _volumeKeys =
      widget.volumeKeys ?? MethodChannelVolumeKeys.platformHost;
  StreamSubscription<VolumeKey>? _volumeKeySub;
  bool _volumeShutterWired = false;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
    controller.setViewerVisible(widget.active);
    _wasLinkUp = controller.linkUp;
    _wasRecovering = controller.reconnecting;
    controller.addListener(_onControllerChanged);
    // 监看开关/取景开关持久化(十二轮):进页恢复 + 外部改动(设置页/
    // 其他会话)跟随;取景总闸同步给控制器(注入裸 ValueNotifier 的
    // 单测没有 AppServices 装配线,这里兜一道;生产路径同值幂等)。
    _toggles = monitorTogglesFromSettings(_settings.value);
    _volumeKeyShutter = _settings.value.volumeKeyShutter;
    _syncAnalyzerEnabled();
    controller.autoLiveViewEnabled = _settings.value.liveViewOn;
    _settings.addListener(_onSettingsChanged);
    // 音量键快门(Android/iOS):开关开即让原生拦音量键并订阅,离页/关
    // 开关沿还系统(见 _syncVolumeKeyShutter)。
    _syncVolumeKeyShutter();
    // BLE GPS 注入芯片门禁 = 已配对(身份在),**不是**瞬时就绪 ——
    // 相机进 USB 会话/待机会主动掉 BLE,门禁若挂 ready,用户永远点不
    // 了芯片、驱动也起不来(死锁,2026-10-13 真机实证)。就绪与否只
    // 影响注入是否在跑,掉线时点亮芯片 = 启动驱动自动重连。
    _bleReady = AppServices.instance.bleSession.identity != null;
    _bleStateSub = AppServices.instance.bleSession.states.listen((s) {
      if (!mounted) return;
      setState(
          () => _bleReady = AppServices.instance.bleSession.identity != null);
    });
    // 取景默认打开(2026-10-10 用户需求,取景开关钮撤除):未跑则自动
    // 起景 —— 幂等(HomeShell 连接沿的 autoLiveViewOnConnect 同款),
    // 引擎 failed 态进页也由此重试。直挂/未连接场景 linkUp 是冷启乐观
    // 门闩(恒真)照样发,失败落占位「重试取景」,与真连接同形。
    // 十二轮:设置里持久关过取景 → 控制器闸门挡住(上面刚同步)。
    if (widget.active && !controller.liveViewActive) {
      unawaited(controller.autoLiveViewOnConnect());
    }
    // 进页对表:先读拍摄模式再刷参数(2026-10-11 真机反馈:视频档进页
    // 模式条慢几秒才跟过去 —— 模式读单请求先行,不等整条刷参链;路由
    // 模式每次进入都是新建页面,原 tab 模式「回台对表」沿不存在;机身
    // 侧拨盘/菜单改动的事件不一定送达,同 didUpdateWidget 的兜底口径)。
    // 门 = 取景在跑:连接即取景使真连接必然如此,而 linkUp 是冷启乐观
    // 门闩(恒真)不能作凭;直挂/未连接场景引擎 idle,零请求。
    // 张数对表住 refreshParams 链首(2026-10-16):进页第二笔即对上,
    // 不再挂整条链尾等几秒。
    if (widget.active && controller.liveViewActive) {
      unawaited(() async {
        await controller.refreshCameraMode(triggerRefresh: false);
        // joinInFlight:连接沿刷参全链常还在跑,并入不另起一条(两条
        // 全链在 Wi-Fi 上把取景帧压成幻灯片,2026-10-16 真机反馈)。
        await controller.refreshParams(joinInFlight: true);
      }());
    }
    if (widget.active) {
      // 取景/间隔拍摄页默认常看屏:不锁屏,方便等长曝光与间隔节奏。
      unawaited(PlatformServices.screenAwake.setAwake(true));
    }
  }

  @override
  void didUpdateWidget(RemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 可见性沿(常驻直挂场景,如单测):挂起/恢复帧轮询(相机侧取景
    // 保持,不发 0x9202)。push 路由每次进入都是新建页面,不走此沿。
    if (widget.active != oldWidget.active) {
      controller.setViewerVisible(widget.active);
      unawaited(PlatformServices.screenAwake.setAwake(widget.active));
    }
    // 回台沿:先自动起景(0x9201 + 首帧入队)再对表(模式先行、参数
    // 随后)—— 串成一条链而非并发 unawaited(引擎帧请求会穿插进刷参
    // 链,FIFO 脚本序无法预置;顺序化后请求序恒 [0x9201, 首帧, 模式,
    // 参数…])。
    if (widget.active && !oldWidget.active) {
      unawaited(() async {
        if (!controller.liveViewActive) {
          await controller.autoLiveViewOnConnect();
        }
        if (controller.linkUp) {
          await controller.refreshCameraMode(triggerRefresh: false);
          // joinInFlight:连接沿刷参全链常还在跑,并入不另起一条(同
          // initState 沿口径,2026-10-16 真机反馈)。
          await controller.refreshParams(joinInFlight: true);
        }
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_onControllerChanged);
    _settings.removeListener(_onSettingsChanged);
    _bleStateSub?.cancel();
    // 音量键还系统:退订 + 原生不再拦(幂等;开关本就关时零请求)。
    _volumeKeySub?.cancel();
    _volumeKeySub = null;
    if (_volumeShutterWired) {
      _volumeShutterWired = false;
      unawaited(_volumeKeys?.setEnabled(false));
    }
    // 离页只挂起轮询(取景生命周期跟连接走,不因拆页发 0x9202)。
    // 方向收口走 PopScope(pop 起点即发,不等 dispose);此处不动锁。
    // 按住快门离场(返回/被系统拆页):指针取消沿不保证送达,主动收门
    // —— B 门不能停在开曝光、连拍不能跑满上限。
    if (controller.shutterHoldActive) {
      unawaited(controller.captureReleased());
    }
    unawaited(PlatformServices.screenAwake.setAwake(false));
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
    // 断链退页:录制/间隔状态已由控制器 _invalidate 清掉,强制放行
    // PopScope,下一帧再 pop(让 canPop 重建生效)。
    setState(() => _forceExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  /// 斑马纹/直方图/伪色/峰值/示波器族共享同一份帧分析:任一开启即启用
  /// 分析器;峰值引擎(「峰值算法」档)与灵敏度档(经典引擎梯度阈值 +
  /// 双尺度比值阈值/噪声门槛)随同同步,改档下一帧分析起生效。
  void _syncAnalyzerEnabled() {
    final want = _toggles.zebra ||
        _toggles.histogram ||
        _toggles.falseColor ||
        _toggles.peaking ||
        _toggles.scope != ScopeKind.off;
    if (controller.analyzer.enabled.value != want) {
      controller.analyzer.enabled.value = want;
    }
    controller.analyzer.peakingEngine = peakingEngineOf(_toggles.peakingEngine);
    controller.analyzer.peakingThreshold =
        monitorPeakingThresholdOf(_toggles.peakingLevel);
    final dual = peakingDualScaleParamsOf(_toggles.peakingLevel);
    controller.analyzer.peakingRatioThreshold = dual.ratioThreshold;
    controller.analyzer.peakingNoiseGate = dual.noiseGate;
  }

  /// 开关组落定(监看开关 + 帧分析器启停同步 + 持久化写回)。
  void _updateToggles(MonitorToggles toggles) {
    setState(() => _toggles = toggles);
    _syncAnalyzerEnabled();
    _persistSettings(applyMonitorToggles(_settings.value, toggles));
  }

  /// 设置外部改动沿(十二轮持久化):监看开关组差分跟随(同值零动作,
  /// 自己写回触发的回声在此吸收);取景总闸同步控制器;音量键快门
  /// 接线沿跟随(开关开/关)。
  void _onSettingsChanged() {
    if (!mounted) return;
    controller.autoLiveViewEnabled = _settings.value.liveViewOn;
    _syncLiveViewQualityFromSettings();
    _syncVolumeKeyShutter();
    final toggles = monitorTogglesFromSettings(_settings.value);
    if (toggles != _toggles) {
      setState(() => _toggles = toggles);
      _syncAnalyzerEnabled();
    }
    if (_settings.value.volumeKeyShutter != _volumeKeyShutter) {
      setState(() => _volumeKeyShutter = _settings.value.volumeKeyShutter);
    }
  }

  /// 取景画质档跟随持久化设置(外部改动沿;自己写回的回声在差分上零
  /// 动作)。控制器侧改动即时写相机,这里只对齐字段。进页**不**同步
  /// (2026-10-13):装配沿 AppServices 已把控制器字段对表设置值且监听
  /// 沿持续跟随,进页时必然同值;而直挂/单测的控制器字段保持默认
  /// null,连接链不凭空多两笔画质写(0x1015)搅乱脚本对表沿。
  void _syncLiveViewQualityFromSettings() {
    final s = _settings.value;
    if (controller.liveViewImageSize != s.liveViewImageSize ||
        controller.liveViewImageCompression != s.liveViewImageCompression) {
      controller.setLiveViewQuality(
          imageSize: s.liveViewImageSize,
          compression: s.liveViewImageCompression);
    }
  }

  /// 拍摄页侧设置写回:注入 SettingsController 走 apply(落盘,失败仅
  /// 吞 —— 会话内仍生效);单测注入裸 ValueNotifier 只改内存值。
  void _persistSettings(AppSettings next) {
    final src = _settings;
    if (src is SettingsController) {
      unawaited(src.apply(next));
    } else if (src is ValueNotifier<AppSettings>) {
      src.value = next;
    }
  }

  /// 取景开关落定(浮层「取景」钮,十二轮「取景器关闭的开关」):持久
  /// 位与控制器总闸同拍更新,再按需起/停景 —— 关 = 引擎停(0x9202,
  /// 相机侧退及时取景),开 = 未跑则起(走 toggleLiveView 而非自动起景
  /// 单飞槽:显式操作不受闸门,起景失败落「重试取景」占位)。录制中
  /// 禁点(浮层侧已禁,这里再守一道 —— 停录走快门,取景门不能被拆)。
  Future<void> _setLiveView(bool start) async {
    if (controller.recording) return;
    controller.autoLiveViewEnabled = start;
    _persistSettings(_settings.value.copyWith(liveViewOn: start));
    if (start != controller.liveViewActive) {
      await controller.toggleLiveView();
    }
  }

  /// 取景画质档落定(2026-10-12 官方 §6.5.11.4-5):控制器即时写相机
  /// (链路在)+ 持久化(下次连接沿起景前自动补写)。
  void _updateLiveViewQuality(int? imageSize, int? compression) {
    controller.setLiveViewQuality(
        imageSize: imageSize, compression: compression);
    _persistSettings(_settings.value.copyWith(
      liveViewImageSize: imageSize,
      liveViewImageCompression: compression,
    ));
  }

  /// SDRAM 直拍落定(0x90CB 一体拍 + 0xC101 回传入图库):控制器即时
  /// 生效 + 持久化(连接沿由 AppServices 同步,这里同值幂等)。
  void _updateSdramCapture(bool value) {
    controller.sdramCapture = value;
    _persistSettings(_settings.value.copyWith(sdramCapture: value));
  }

  /// BLE GPS 注入落定:只写设置;会话起停/重连由 AppServices 注入驱动
  /// 收口(BLE 独立于 PTP 链接;芯片未就绪 = 未配对,浮层侧已禁点)。
  void _updateBleGpsInject(bool value) {
    _persistSettings(_settings.value.copyWith(bleGpsInject: value));
  }

  /// 音量键快门落定(浮层芯片,Android/iOS 行):只写设置;原生开关
  /// (setEnabled 推/撤 + 订阅)由 [_syncVolumeKeyShutter] 在设置改动沿
  /// 收口 —— 同一沿,先落库后接线,回声同值零动作。
  void _updateVolumeKeyShutter(bool value) {
    _persistSettings(_settings.value.copyWith(volumeKeyShutter: value));
  }

  /// 音量键快门接线沿(进页/设置改动/离页):宿主在(Android/iOS)且开关
  /// 开 → 原生拦音量键 + 订阅事件流;关/离页 → 退订 + 还系统。命中走
  /// [RemoteController.capture] —— 与屏上快门钮同一守卫同一错误横幅
  /// (capturing 防重入、未连接如实落「未连接相机」),不绕过错误处理。
  /// 相机会话就绪与否不在门内:取景/连接守卫在 capture() 自身,断连
  /// 沿页面本就自动退页(dispose 兜底还系统)。
  void _syncVolumeKeyShutter() {
    final host = _volumeKeys;
    if (host == null) return;
    final want = _settings.value.volumeKeyShutter;
    if (want == _volumeShutterWired) return;
    _volumeShutterWired = want;
    if (want) {
      _volumeKeySub = host.keys.listen((_) {
        if (!mounted) return;
        unawaited(controller.capture());
      });
      unawaited(host.setEnabled(true));
    } else {
      unawaited(_volumeKeySub?.cancel());
      _volumeKeySub = null;
      unawaited(host.setEnabled(false));
    }
  }

  /// 设置浮层开/关(再点同钮即收)。
  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  /// 页签是「滚到段」而不是隐藏段:设计稿的浮层虽然四个页签,但内容
  /// 全量在同一个滚动区(参数/对焦/监看/辅助),页签只做锚点跳转。
  void _selectSettingsTab(int i) {
    setState(() => _settingsTab = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _settingsSectionKeys[i].currentContext;
      if (ctx == null) return;
      unawaited(Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
        alignment: 0.02,
      ));
    });
  }

  /// 点空白处收设置浮层(2026-10-12 用户需求):收起动作由满铺
  /// GestureDetector 垫层承担 —— 竖屏一处(画面全幅铺底后底区两行
  /// 也是浮层,整页满铺垫层连底区按钮间空白一起收);垫层**贪吃这一拍** —— 只收浮层,不触发取景画面
  /// 上的触控对焦。
  void _dismissSettings() {
    if (_settingsOpen) setState(() => _settingsOpen = false);
  }

  /// 模式切换(模式条在录制中已禁用,这里再守一道 —— 模式条不可达
  /// 路径(测试直调/竞态)不至于把停录入口甩在视频模式外)。
  void _setMode(CaptureMode m) {
    if (controller.recording || m == _mode) return;
    setState(() => _mode = m);
  }

  /// 生效模式:相机真状态优先([RemoteController.cameraMode],0xD1A6
  /// 镜像,拨杆翻转经事件实时跟随);读不到(null)回落本地 [_mode]
  /// —— 与改造前行为一致(纯 UI 态)。
  CaptureMode get _effMode => controller.cameraMode ?? _mode;

  /// 模式条点按:点段即切换意图(**不弹选择列表**,2026-10-12 用户定案
  /// —— 「照片/视频」两段不是从列表里挑,点哪段切哪档):
  /// - 相机模式不在表(旧机身/方言)→ 本地切换(改造前行为);
  /// - 模式写被拒过 → 直进 switchMode 弹拒答提示;
  /// - 未接管 → 弹「启用 APP 接管控制?」接管门(同点 ISO 未接管时
  ///   的接管区,remote_mode_sheet),启用成功自动走切换链;
  /// - 已接管 → 直切,零面板。
  Future<void> _onStripMode(CaptureMode m) async {
    if (m == _effMode) return;
    unawaited(AppHaptics.selection()); // 模式切换确认沿(原模式条触感)
    if (controller.cameraMode == null) {
      _setMode(m);
      return;
    }
    if (controller.modeWriteRejected) {
      unawaited(controller.switchMode(m));
      return;
    }
    if (!controller.takeoverActive) {
      unawaited(showModeTakeoverSheet(context, controller, target: m));
      return;
    }
    unawaited(controller.switchMode(m));
  }

  /// 模式条各段可切性(灰显口径):模式写被拒过 → 全灰(此机身远程
  /// 切换不可用,提示已给过);其余两方向都可远程切(2026-10-11 Zf
  /// 实证:覆写两向都被接受,拍照门跟软件态)—— 录像门跟物理拨杆
  /// 硬互锁,照片档覆写视频后开录被拒,拨杆提示在开录时弹出不预判。
  Set<CaptureMode> get _switchableTo =>
      controller.cameraMode != null && controller.modeWriteRejected
          ? const <CaptureMode>{}
          : const {CaptureMode.photo, CaptureMode.video};

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台/回前台:挂起/恢复帧轮询(相机侧取景保持 —— 取景生命周期
    // 跟连接走;后台不保活的是 iOS/ohos 的传输面,不再给相机发 0x9202)。
    if (state == AppLifecycleState.paused) {
      // 退后台先收口屏上快门(B 门/连拍按住态):系统可能直接掐掉
      // 指针事件,只停轮询会留下开曝光或跑满上限。
      if (controller.shutterHoldActive) {
        unawaited(controller.captureReleased());
      }
      unawaited(PlatformServices.screenAwake.setAwake(false));
      controller.setViewerVisible(false);
    }
    if (state == AppLifecycleState.resumed) {
      if (widget.active) {
        controller.setViewerVisible(true);
        unawaited(PlatformServices.screenAwake.setAwake(true));
      }
      // 回前台:对表兜底(模式先行 + 参数;后台期间机身侧改动的事件
      // 不一定送达,同切回 tab)。
      if (controller.linkUp) {
        unawaited(() async {
          await controller.refreshCameraMode(triggerRefresh: false);
          await controller.refreshParams();
        }());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 拍摄页只保留竖屏(2026-10-30 用户定案去掉横屏模式):全局方向
    // 契约本就是钉竖屏,旋转钮与横屏监看布局一并移除。
    final body = _portraitBody(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final busy = controller.recording || controller.intervalActive;
        return PopScope(
          // 录像/间隔拍摄在跑时拦下返回:不弹确认就退页,相机会继续
          // 录/拍,页外又没有停录入入口 —— 用户会误以为已经停了。
          canPop: _forceExit || !busy,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_confirmLeaveBusy());
          },
          child: Scaffold(
            backgroundColor: LiveDesign.of(context).background,
            // 破安全区(2026-10-12 六轮用户定案,参照 iOS 相机底部按钮
            // 距屏底的距离):页面用**物理屏坐标**铺满,底区贴物理屏缘
            // 20([kScreenEdgePadding])。顶部 notch(竖屏胶囊/恢复钮/取景
            // 盒 topInset)经 MediaQuery.padding 手动补偿;九轮:竖屏左右
            // 边距亦统一 20 (四缘一致)。
            body: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: body,
            ),
          ),
        );
      },
    );
  }

  /// 退出前的任务刹车:录像/间隔拍摄仍在跑 → 弹确认。确认后先停,
  /// 停录失败(相机拒/链路问题)就留在页面看错误横幅,不把相机留在
  /// 录制态。
  Future<void> _confirmLeaveBusy() async {
    if (_leaveDialogOpen) return;
    if (!controller.recording && !controller.intervalActive) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    _leaveDialogOpen = true;
    try {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t('remote.leaveBusyTitle'),
        content: context.t('remote.leaveBusyBody'),
        confirmLabel: context.t('remote.leaveBusyConfirm'),
      );
      if (!confirmed || !mounted) return;
      if (controller.recording) {
        await controller.toggleRecord();
        if (controller.recording) return; // 停录失败:留在页内看错误
      }
      controller.stopInterval();
      if (!mounted) return;
      setState(() => _forceExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } finally {
      _leaveDialogOpen = false;
    }
  }

  /// 竖屏 iPhone 相机式排版(2026-10-10 重排;九轮:四缘统一 20):
  /// 取景画面完整铺在页面内([FeedFit.contain] —— 整帧可见,留背景带),
  /// 信息胶囊(含 APP 接管钮)浮在画面顶部(顶距
  /// 补 notch,六轮破安全区后手动补偿;左右 20);底部两行浮层压画面
  /// 下沿、距**物理屏缘 20**([kScreenEdgePadding] 破手势条安全区,
  /// 参照 iOS 相机底部按钮距离;左右同为 20 —— 九轮用户「左右两侧按钮
  /// 离边的距离和离下方的距离保持一致」)
  /// —— 控制行(对焦 | 快门 | 设置)→ 底行(相册 | 模式条 |
  /// 旋转,参数读出行已删,参数入口 = 设置浮层);行内空白自吃
  /// (opaque 吸收层垫在按钮下,不落到画面手势;浮层关时纯吸收 ——
  /// 底区是控件区不是页面空白,锁住的钮落下的点按不能收 chrome)。
  /// 设置为非模态浮层,
  /// 底锚浮在底区两行上方。纯净监看隐去顶部浮层与底部两行(点取景
  /// 画面空白隐藏/再点任意处恢复),监看叠层/横幅保留。
  ///
  /// 监听拆两层:feed 区 merge(controller+frame+status)
  /// 逐帧刷;chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,胶囊/读出行/按钮不必逐帧重建。
  Widget _portraitBody(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final w = size.width;
    final shutter = w <= 320
        ? 72.0
        : w <= 360
            ? 80.0
            : w < 430
                ? 88.0
                : 94.0;
    final side = w <= 320 ? 44.0 : 48.0;
    final designBottom = w <= 320
        ? 16.0
        : w <= 360
            ? 20.0
            : 46.0;
    // 破安全区取物理屏缘,但不能压进手势条:320/360 档设计值(16/20)
    // 小于 Android 手势条插入(常见 24) —— 以系统底插 +8 为下限,
    // 393/430 档(46)本就在 34+8 之上,布局零变化。
    final bottomSafe =
        designBottom > pad.bottom + 8 ? designBottom : pad.bottom + 8;
    final sideX = w <= 320
        ? 16.0
        : w <= 360
            ? 20.0
            : w < 430
                ? 32.0
                : 48.0;
    final exposureH = w <= 320
        ? 44.0
        : w <= 360
            ? 46.0
            : w < 430
                ? 52.0
                : 50.0;
    const gap = 12.0;
    final exposureBottom = bottomSafe + shutter + gap;
    final panelTop = pad.top + 62;
    final panelMax = size.height * 0.55;
    // 取景底边到曝光条顶 = 曝光条底到快门顶(gap):画面底对齐到
    // 曝光条上沿再让一个 gap。
    final feedBottom = exposureBottom + exposureH + gap;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            controller.engine.status,
          ]),
          builder: (context, _) => RemoteFeedArea(
            controller: controller,
            toggles: _toggles,
            onTapFocus: _handleFeedTap,
            topInset: pad.top + 56,
            bottomInset: feedBottom,
            // 竖屏也按 contain 完整显示整帧(上下/左右留背景带),
            // 不再满幅裁剪两侧。
            fit: FeedFit.contain,
            settingsListenable: _settings,
            hideChrome: _chromeHidden,
          ),
        ),
        if (pad.top > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: pad.top,
            child: GestureDetector(
              key: const ValueKey('capture-status-band'),
              behavior: HitTestBehavior.opaque,
              onTap: _chromeHidden ? _showChrome : _hideChrome,
              child: ColoredBox(color: LiveDesign.of(context).background),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            key: const ValueKey('portrait-chrome'),
            ignoring: _chromeHidden,
            child: AnimatedOpacity(
              opacity: _chromeHidden ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Stack(
                  children: [
                    if (_settingsOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _dismissSettings,
                        ),
                      ),
                    if (_settingsOpen)
                      Positioned(
                        top: panelTop,
                        left: 8,
                        right: 8,
                        child: CaptureSettingsPanel(
                          controller: controller,
                          toggles: _toggles,
                          activeParam: _activeParam,
                          onEditParam: _editParam,
                          onTogglesChanged: _updateToggles,
                          onLiveViewToggle: _setLiveView,
                          onLiveViewQualityChanged: _updateLiveViewQuality,
                          onSdramCaptureChanged: _updateSdramCapture,
                          onBleGpsInjectChanged: _updateBleGpsInject,
                          onVolumeKeyShutterChanged: _updateVolumeKeyShutter,
                          bleGpsInject: _settings.value.bleGpsInject,
                          bleReady: _bleReady,
                          volumeKeyShutter: _volumeKeyShutter,
                          volumeKeyShutterAvailable: _volumeKeys != null,
                          liveViewImageSize: _settings.value.liveViewImageSize,
                          liveViewImageCompression:
                              _settings.value.liveViewImageCompression,
                          maxHeight: panelMax,
                          mode: _effMode,
                          onModeChanged: _onStripMode,
                          modeEnabled: !controller.recording &&
                              !controller.switchingMode,
                          switchableTo: _switchableTo,
                          tab: _settingsTab,
                          onTabChanged: _selectSettingsTab,
                          sectionKeys: _settingsSectionKeys,
                          onDismiss: _dismissSettings,
                        ),
                      ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: exposureBottom,
                      height: exposureH,
                      child: CaptureExposureStrip(
                        controller: controller,
                        height: exposureH,
                        activeCode: _activeParam,
                        onTapParam: _editParam,
                      ),
                    ),
                    if (controller.recording)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: feedBottom,
                        child: Center(child: _recChip(context)),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: bottomSafe,
                      child: CapturePortraitKeys(
                        controller: controller,
                        mode: _effMode,
                        sideSize: side,
                        shutterSize: shutter,
                        horizontalPadding: sideX,
                        onAlbum: _openAlbum,
                        onTakeoverRequest: _confirmTakeover,
                        onSettings: _toggleSettings,
                      ),
                    ),
                  ],
                ),
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
          fallbackName: context.t('conn.cameraAlbum'),
        ),
      ),
    );
  }

  /// 纯净监看:隐去全部控制浮层,同步收起设置浮层
  /// (不留一个看不见却开着的面板态)。恢复 = 再点任意空白
  /// ([_showChrome];2026-10-17 用户定案「再点击出现」,恢复钮同日
  /// 撤除)。
  void _hideChrome() {
    setState(() {
      _chromeHidden = true;
      _settingsOpen = false;
    });
  }

  /// 纯净监看恢复:任意点按(画面内/外)回 chrome —— 入口见
  /// [_handleFeedTap] 与取景盒外让位带垫层。
  void _showChrome() {
    setState(() => _chromeHidden = false);
  }

  Widget _recChip(BuildContext context) {
    final live = LiveDesign.of(context);
    return Container(
      key: const ValueKey('remote-rec-chip'),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: live.bad,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 7, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            '${context.t('remote.recPrefix')} '
            '${recDurationLabel(controller.recordingSeconds)}',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
  // ── 取景点按(触控对焦 + 纯净监看切换)────────────────────────

  /// 取景画面点按三分流(2026-10-17 纯净监看改制):
  /// - chrome 隐藏中:**任意点按恢复**([_showChrome],「再点击出现」;
  ///   隐藏态不触控对焦,先回 chrome 再对焦);
  /// - norm = null(无画面/点在画面外信箱空白):**点空白隐藏**
  ///   ([_hideChrome],2026-10-16 定案的「框外点按不挪对焦框」沿此
  ///   收口为显式动作);设置浮层开着时点不到这里(满铺垫层先吃,
  ///   见 _dismissSettings);
  /// - norm 非空:触控对焦 —— 取景区已把屏幕点逆映射为**归一化图像
  ///   坐标**(缩放/旋转/变宽一次收口,见 FeedTransform.screenToNorm)。
  void _handleFeedTap(TapUpDetails d, Offset? norm) {
    if (_chromeHidden) {
      _showChrome();
      return;
    }
    if (norm == null) {
      _hideChrome();
      return;
    }
    unawaited(controller.touchFocus(norm.dx, norm.dy));
  }

  // ── 参数面板入口与接管确认 ─────────────────────────────────────

  /// 参数编辑入口(设置浮层参数 tile):打开
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

  /// 信息胶囊「APP 接管」钮的确认对话框路径(不进参数面板;原设置
  /// 浮层专用芯片 2026-10-17 撤除,钮移胶囊行尾)。
  Future<bool> _confirmTakeover(BuildContext context) =>
      confirmTakeover(context, controller);
}

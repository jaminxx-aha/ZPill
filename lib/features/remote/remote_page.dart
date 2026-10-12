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
/// - 取景画面**全幅铺底恒满宽**(2026-10-12 用户定案:竖拍画面两侧
///   不留黑边 —— [FeedFit.widthFill],比屏更高的内容上下裁;底部两行
///   按钮改浮层压画面下沿,「按钮整体往下移」):信息胶囊(链路点 +
///   设备名 + 接管徽标 + REC + 纯净监看隐藏钮)浮在画面顶部;隐藏后
///   恢复钮在**同一处**(右上角,与胶囊行尾隐藏钮同位 —— 旧版隐藏在
///   快门行右/恢复在顶部两处不一,用户点名);
/// - **取景默认打开**:进页/回页沿未跑则自动起景(取景开关钮撤除;
///   失败态占位里「重试取景」兜底);
/// - 底部两行**浮层压画面下沿**(2026-10-12 用户需求,参数读出行
///   删除 —— 参数入口 = 设置浮层全目录 tile):控制行(对焦 | 大圆环
///   快门 | 设置)→ 底行(相册缩略图 | 模式条「照片|视频」| 方向旋转,
///   水平一行;快门在视频模式红芯、整段点按起/停录像 —— 拍照/录像
///   合一;对焦钮点按即驱动一次 AF,2026-10-12 用户定案;模式条录制
///   中锁,保证停录入口不被模式切换甩开);行内空白自吃(不落到画面
///   手势触发对焦);
/// - 设置为**非模态玻璃浮层**(点画面即收):拍摄参数(全目录,点
///   tile 走读出条同款编辑底单)+ 对焦控制(MF 步进/拉焦轮,自对焦
///   浮层迁入)+ 监看开关(网格/斑马纹/直方图/水平仪/伪色/峰值)+
///   辅助芯片(对焦后拍/自拍/APP 接管;吸收原 tune 辅助浮层)。
///
/// 横屏**满高画面 + 移出画面的右缘快门柱**(2026-10-08 用户定案
/// 「拍照按钮在右侧中间」;2026-10-12 三轮修正:取景盒右缩 94 让柱
/// **移出拍摄框**、[FeedFit.heightFill] **恒满高上下无黑边** ——
/// 16:9 视频满高零黑边、3:2 照片满高余侧边):顶栏一条(信息胶囊
/// 收缩包**整体居中**,纯净监看隐藏钮入胶囊行尾 —— 2026-10-12 用户
/// 定案);快门柱**距物理屏右缘 20**(六轮破安全区,与竖屏底距同距;
/// 灵动岛在侧缘中点,岛侧快门右段入岛)全高居中,自上而下
/// **旋转 / 设置 / 大圆环快门(64)/ 对焦 / 相册**(2026-10-12 用户
/// 定案柱序,方向钮自贴底条迁入柱顶);贴底条 = 模式条独占(居中于
/// 画面子盒);设置浮层让位快门柱(right: 94);拉焦轮 bottomRight
/// (右上角留给录制读出)。纯净监看隐去全部控制浮层,只留画面与监看
/// 叠层,恢复钮在右上角。方向按钮(恒显转屏图标,点按横↔竖直切,
/// 初始态跟随系统)经 SystemChrome 强制,系统转屏锁开着也能切,不
/// 依赖系统自动横竖屏设置。
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
import 'feed_transform.dart';
import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_action_row.dart';
import 'remote_controller.dart';
import 'remote_feed_area.dart';
import 'remote_info_pill.dart';
import 'remote_mode_sheet.dart';
import 'remote_mode_strip.dart';
import 'remote_param_sheet.dart';
import 'remote_settings_panel.dart';
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

  /// 拍摄模式本地态:**回落档**(相机 0xD1A6 读不到时的纯 UI 选择,
  /// 改造前行为);相机真状态在控制器([RemoteController.cameraMode]),
  /// 生效模式统一走 [_effMode]。
  CaptureMode _mode = CaptureMode.photo;

  /// 拍摄设置浮层是否展开(再点设置钮或点取景画面即收;2026-10-12
  /// 对焦浮层退场 —— 对焦钮瘦身为一键 AF,MF 步进/拉焦轮迁入设置
  /// 浮层,只剩此一个非模态浮层)。
  bool _settingsOpen = false;

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
    // 进页对表:先读拍摄模式再刷参数(2026-10-11 真机反馈:视频档进页
    // 模式条慢几秒才跟过去 —— 模式读单请求先行,不等整条刷参链;路由
    // 模式每次进入都是新建页面,原 tab 模式「回台对表」沿不存在;机身
    // 侧拨盘/菜单改动的事件不一定送达,同 didUpdateWidget 的兜底口径)。
    // 门 = 取景在跑:连接即取景使真连接必然如此,而 linkUp 是冷启乐观
    // 门闩(恒真)不能作凭;直挂/未连接场景引擎 idle,零请求。
    if (widget.active && controller.liveViewActive) {
      unawaited(() async {
        await controller.refreshCameraMode();
        await controller.refreshParams();
      }());
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
          await controller.refreshCameraMode();
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

  /// 设置浮层开/关(再点同钮即收)。
  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  /// 点空白处收设置浮层(2026-10-12 用户需求):收起动作由满铺
  /// GestureDetector 垫层承担 —— 竖屏一处(画面全幅铺底后底区两行
  /// 也是浮层,整页满铺垫层连底区按钮间空白一起收)、横屏一处
  /// (chrome 栈内);垫层**贪吃这一拍** —— 只收浮层,不触发取景画面
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
      controller.setViewerVisible(false);
    }
    if (state == AppLifecycleState.resumed) {
      if (widget.active) controller.setViewerVisible(true);
      // 回前台:对表兜底(模式先行 + 参数;后台期间机身侧改动的事件
      // 不一定送达,同切回 tab)。
      if (controller.linkUp) {
        unawaited(() async {
          await controller.refreshCameraMode();
          await controller.refreshParams();
        }());
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
        // 破安全区(2026-10-12 六轮用户定案,参照 iOS 相机底部按钮距屏底
        // 的距离):页面用**物理屏坐标**铺满,底区/横屏柱贴到物理屏缘
        // 20([kScreenEdgePadding])。顶部 notch(竖屏胶囊/恢复钮/取景
        // 盒 topInset)经 MediaQuery.padding 手动补偿;横屏上下安全
        // 插入本为 0 无需补偿。灵动岛在横屏侧缘中点 —— 岛侧快门右段
        // 会藏进岛里,是本定案的已知代价。
        body: body,
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

  /// 竖屏 iPhone 相机式排版(2026-10-10 重排;2026-10-12 三轮:画面
  /// 全幅铺底恒满宽,底部两行改浮层压画面下沿):取景画面占整页
  /// ([FeedFit.widthFill] —— 竖拍内容两侧不留黑边,比屏更高裁上下),
  /// 信息胶囊(含纯净监看隐藏钮)浮在画面顶部(顶距补 notch,六轮
  /// 破安全区后手动补偿);底部两行浮层压画面下沿、距**物理屏缘 20**
  /// ([kScreenEdgePadding] 破手势条安全区,参照 iOS 相机底部按钮距离)
  /// —— 控制行(对焦 | 快门 | 设置)→ 底行(相册 | 模式条 |
  /// 旋转,参数读出行已删,参数入口 = 设置浮层);行内空白自吃
  /// (opaque 吸收层垫在按钮下,不落到画面手势)。设置为非模态浮层,
  /// 底锚浮在底区两行上方。纯净监看隐去顶部浮层与底部两行(恢复钮
  /// 在右上角同位),监看叠层/横幅保留。
  ///
  /// 监听拆两层(同横屏):feed 区 merge(controller+frame+status)
  /// 逐帧刷;chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,胶囊/读出行/按钮不必逐帧重建。
  Widget _portraitBody(BuildContext context) {
    // 破安全区(六轮):页面物理坐标,顶部 notch 手动补偿(左右在竖屏
    // 恒 0 不必补);底部压进手势条区距物理屏缘 20。
    final pad = MediaQuery.paddingOf(context);
    final panelMaxHeight = MediaQuery.sizeOf(context).height * 0.55;
    return Stack(
      fit: StackFit.expand,
      children: [
        // feed 区不能裸放:帧到达只写 ValueNotifier 不
        // notifyListeners,没有这层 merge 监听,首帧永远停在
        // 「等待首帧」。全幅铺底(不与底区两行分高):底区两行是
        // 浮层,画面延伸到其下(2026-10-12「按钮整体往下移」)。
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
            topInset: pad.top + kPortraitTopInset,
            // 贴底叠层(横幅/直方图)让位底区两行浮层(含物理屏缘 20)。
            bottomInset: kScreenEdgePadding + kPortraitBottomChromeHeight,
            fit: FeedFit.widthFill,
            settingsListenable: _settings,
            hideChrome: _chromeHidden,
          ),
        ),
        // 顶部浮层:信息胶囊(链路/张数/REC/接管 + 隐藏钮)+ 设置浮层
        // (底锚居中,浮在底栏上方);经 IgnorePointer + AnimatedOpacity
        // 支持纯净监看淡出。key 供测试定位(全树按类型找不到「chrome
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
                    // 点空白处收设置浮层(2026-10-12 用户需求):满铺
                    // 手势层垫在全部 chrome 下、取景画面上 —— 画面全幅
                    // 铺底后底区两行也在其上,点空白(含按钮间空档)即
                    // 收且**贪吃这一拍**(不触发触控对焦);按钮在其上
                    // 照常。
                    if (_settingsOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _dismissSettings,
                        ),
                      ),
                    Positioned(
                      top: pad.top + 8,
                      left: 12,
                      right: 12,
                      child: RemoteInfoPill(
                        controller: controller,
                        onHideChrome: _hideChrome,
                        margin: EdgeInsets.zero,
                      ),
                    ),
                    if (_settingsOpen)
                      Positioned(
                        bottom: kScreenEdgePadding +
                            kPortraitBottomChromeHeight +
                            8,
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
                  ],
                ),
              ),
            ),
          ),
        ),
        // 底部两行浮层(2026-10-12 三轮:自「画面下方挤出」改压画面
        // 下沿 —— 画面全幅铺底,按钮整体下移):控制行(对焦 | 快门 |
        // 设置)→ 底行(相册 | 模式条 | 旋转);同受纯净监看淡出支配。
        // 行内空白自吃:opaque 吸收层**垫在按钮之下**(Stack 兄弟而非
        // 父级包装 —— 父级手势会进竞技场拖慢快门 onTapDown 的按下即拍
        // /连拍语义,2026-10-12 定案),拍到空白不落到画面手势(不把
        // 对焦点钳到画面底缘)。底锚 = 物理屏缘 20(六轮破安全区,参照
        // iOS 相机底部按钮距离)。
        Positioned(
          left: 0,
          right: 0,
          bottom: kScreenEdgePadding,
          child: IgnorePointer(
            key: const ValueKey('portrait-chrome-bottom'),
            ignoring: _chromeHidden,
            child: AnimatedOpacity(
              opacity: _chromeHidden ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // 空白吸收:浮层关 = 无回调纯吸收(点到空白不落到
                        // 画面手势,不把对焦点钳到画面底缘);浮层开 =
                        // 这一拍转为收浮层(同点画面空白,2026-10-12
                        // 「底区空白也收」口径 —— 吸收层在其上,须自带
                        // 收起,不能指望其下的垫层)。
                        onTap: _settingsOpen ? _dismissSettings : null,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CaptureControlRow(
                          controller: controller,
                          mode: _effMode,
                          onOpenSettings: _toggleSettings,
                        ),
                        Padding(
                          // 六轮:左右边距回 12(用户「还是太远」,参照
                          // iOS 相机);底距已由层锚的物理屏缘 20 承担,
                          // 行内不再垫底。
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
                          child: Row(
                            children: [
                              AlbumThumbButton(
                                controller: controller,
                                onTap: _openAlbum,
                              ),
                              Expanded(
                                child: Center(
                                  child: CaptureModeStrip(
                                    mode: _effMode,
                                    enabled: !controller.recording &&
                                        !controller.switchingMode,
                                    onModeChanged: _onStripMode,
                                    switchableTo: _switchableTo,
                                  ),
                                ),
                              ),
                              // 方向钮不包 Tooltip(长按抬起须等同点按,见
                              // CaptureCircleButton 类注)
                              CaptureCircleButton(
                                icon: Icons.screen_rotation,
                                onTap: _cycleOrientationLock,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 纯净监看恢复钮:chrome 全隐后唯一入口(监看叠层/横幅仍在),
        // 与胶囊行尾隐藏钮同位(右上角,顶距补 notch)。
        if (_chromeHidden)
          Positioned(
            top: pad.top + 8,
            right: 12,
            child: ChromeIconButton(
              icon: Icons.visibility,
              tooltip: '显示控制界面',
              onTap: () => setState(() => _chromeHidden = false),
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

  /// 纯净监看(竖横屏共用):隐去全部控制浮层,同步收起设置浮层
  /// (不留一个看不见却开着的面板态)。恢复钮在右上角同位。
  void _hideChrome() {
    setState(() {
      _chromeHidden = true;
      _settingsOpen = false;
    });
  }

  /// 横屏监看(2026-10-12 三轮定案;六轮破安全区):取景盒**右缩 94
  /// 让位快门柱**(画面移出按钮、heightFill 恒满高 —— 上下永无黑边;
  /// 3:2 照片满高后左右黑边留在取景盒内);顶栏一条 = **信息胶囊整体
  /// 居中**(收缩包内容,纯净监看钮入胶囊行尾);快门柱**距物理屏右缘
  /// 20**(kScreenEdgePadding,与竖屏底距同距 —— 破侧边安全区;灵动岛
  /// 在侧缘中点,岛侧快门右段入岛)全高中置五件竖排(**旋转 / 设置 /
  /// 快门 64 / 对焦 / 相册** —— 方向钮自贴底条迁入柱顶,相册坠底);
  /// 贴底条 = 模式条独占(居中于取景盒)。设置浮层让位快门柱
  /// (right: 94)。chrome 整体(顶栏 + 快门柱 + 贴底条 + 浮层)经
  /// IgnorePointer + AnimatedOpacity 支持纯净监看淡出。
  ///
  /// 监听拆两层:feed 区照旧 merge(controller+frame+status)逐帧刷;
  /// chrome 层只听 controller —— 帧到达只写 ValueNotifier 不
  /// notifyListeners,快门柱/贴底条不必逐帧重建。
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
        // 没有这层 merge 监听,首屏永远停在「等待首帧」。取景盒右缩
        // 94 = 快门柱让位(六轮柱右距物理屏缘 20、柱带宽 84 + 10 间隙):
        // 视频 heightFill 恒满高,上下永无黑边;16:9 视频在 94 右缩盒内
        // 满高近似满格。盒已右缩,盒内贴右叠层(录制读出/拉焦轮)的
        // rightInset 归零 —— 屏幕位置与旧全宽盒 + rightInset 全同。
        Padding(
          padding: const EdgeInsets.only(right: 94),
          child: AnimatedBuilder(
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
              bottomInset: kLandscapeBottomInset,
              fit: FeedFit.heightFill,
              settingsListenable: _settings,
              hideChrome: _chromeHidden,
              // 拉焦轮挪 bottomRight —— 右上角留给录制读出,右缘中带
              // 让给快门柱(盒已右缩,rightInset 归零即屏幕原位)。
              dialAlignment: Alignment.bottomRight,
            ),
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
                    // 点空白处收设置浮层(同竖屏):满铺手势层垫在全部
                    // chrome 之下、取景画面之上 —— 点空白即收且贪吃这一
                    // 拍(不触发触控对焦);顶栏/快门柱/贴底条在其上,
                    // 点按照常。
                    if (_settingsOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _dismissSettings,
                        ),
                      ),
                    // 顶栏:信息胶囊**整体居中**(2026-10-12 用户定案
                    // 「这一个按钮居中」—— compact 收缩包内容才可被
                    // Center 居中);纯净监看钮入胶囊行尾(与竖屏同款
                    // 单入口,不再另摆顶栏右端)。
                    Positioned(
                      top: 8,
                      left: 10,
                      right: 10,
                      height: kLandscapeTopBarHeight,
                      child: Center(
                        child: RemoteInfoPill(
                          controller: controller,
                          margin: EdgeInsets.zero,
                          compact: true,
                          onHideChrome: _hideChrome,
                        ),
                      ),
                    ),
                    // 快门柱贴右缘全高中置(2026-10-12 用户定案柱序
                    // 自上而下:旋转 / 设置 / 快门 64 / 对焦 / 相册 ——
                    // 方向钮自贴底条迁入柱顶,相册坠底;高度账
                    // 54+8+54+8+64+8+54+8+54=312,402pt 级横屏可容,
                    // 柱在取景盒外的右缩带内 —— 不压画面)。六轮右移:
                    // 右距**物理屏缘 20**(破侧边安全区,与竖屏底距
                    // 同距,参照 iOS 相机;柱件 crossAxisAlignment.end
                    // 右缘齐平,快门最宽凸左 10)。灵动岛在侧缘中点,
                    // 岛侧方向快门右段藏进岛里 —— 已知代价,翻面即避。
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: kScreenEdgePadding,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: CaptureShutterColumn(
                          controller: controller,
                          mode: _effMode,
                          onOpenAlbum: _openAlbum,
                          onOpenSettings: _toggleSettings,
                          onRotate: _cycleOrientationLock,
                        ),
                      ),
                    ),
                    // 贴底条:模式条独占、居中于取景盒(旋转钮已迁快门
                    // 柱顶;right: 94 让位柱带,贴底叠层让位 bottomInset)。
                    Positioned(
                      left: 0,
                      right: 94,
                      bottom: 0,
                      child: Padding(
                        padding: const EdgeInsets.only(
                            left: 10, right: 10, bottom: 6),
                        child: Center(
                          child: CaptureModeStrip(
                            mode: _effMode,
                            enabled: !controller.recording &&
                                !controller.switchingMode,
                            onModeChanged: _onStripMode,
                            switchableTo: _switchableTo,
                          ),
                        ),
                      ),
                    ),
                    // 设置浮层:让位右缘快门柱(柱带宽 20+64=84 + 10 间隙)。
                    if (_settingsOpen)
                      Positioned(
                        top: kLandscapeTopInset + 8,
                        right: 94,
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
                  ],
                ),
              ),
            ),
          ),
        ),
        // 纯净监看恢复钮:chrome 全隐后唯一入口(监看叠层/横幅仍在),
        // 摆在顶栏胶囊同位(居中 —— 胶囊整体居中后恢复钮随行,同竖屏
        // 「恢复钮同位」口径)。
        if (_chromeHidden)
          Positioned(
            top: 8,
            left: 10,
            right: 10,
            height: kLandscapeTopBarHeight,
            child: Center(
              child: ChromeIconButton(
                icon: Icons.visibility,
                tooltip: '显示控制界面',
                onTap: () => setState(() => _chromeHidden = false),
              ),
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
  /// 画面)。设置浮层开着时收浮层由垫层手势承担(见 _dismissSettings)
  /// —— 这里的点按必然已越过垫层 = 浮层已收,径直对焦。
  void _handleTapFocus(TapUpDetails d, Offset? norm) {
    if (norm == null) return;
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

  /// 专用「APP 接管」芯片的确认对话框路径(不进参数面板)。
  Future<bool> _confirmTakeover(BuildContext context) =>
      confirmTakeover(context, controller);
}

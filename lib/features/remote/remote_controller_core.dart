part of 'remote_controller.dart';

mixin _RemoteCore on ChangeNotifier {
  // 门面 final 字段的抽象面(域内可见;facade 构造注入满足)。
  PtpSession get session;
  CameraConnection? get connection;
  LiveViewEngine get engine;
  TransferEngine? get transferEngine;
  FrameAnalyzer get analyzer;
  bool Function()? get isApMode;
  Future<void> Function(Duration) get _delay;
  Future<void> Function(Duration) get _aeDelay;
  bool Function() get _setPropEnabled;

  bool get apMode => isApMode?.call() ?? false;
  bool get takeoverActive => _takeoverActive;

  // ---- 跨域钩子(域内实现,linearization 解析)----
  Future<void> refreshParams({bool joinInFlight = false});
  Future<void> refreshCameraMode({bool triggerRefresh = true});
  Future<void> toggleLiveView();
  Future<void> autoLiveViewOnConnect();
  Future<void> _applyLiveViewQuality();
  Future<void> _showInstantReview(int? handle);
  Future<bool> enableTakeover();
  void _syncAePolling();
  void _schedulePropRefresh(int propCode);
  void _cancelSelfTimer();
  void _onIntervalChanged();
  Future<(bool, L10nMessage?)> _intervalShot();
  Future<void> _recoverLiveViewAfterFailedSwitch();

  bool capturing = false;

  /// 卡上录制中(0x920A/0x920B;事件 0xC10A/0xC108 与本状态双保险)。
  bool recording = false;

  /// 录制开始时刻(时长显示;null = 未在录)。
  DateTime? recordingSince;

  /// 剩余可拍张数(0xD1F1;null = 未读/拒答)。
  int? shotsRemaining;

  /// 视频剩余可录时长(帧头 @816 机身自报,毫秒;null/0 = 头没带或
  /// 本帧无效 —— 官方标录制态有效,录制态外是否恒 0 待真机核对)。
  /// 视频档胶囊以它替代张数(张数在该档被相机录像估算污染)。
  int? videoRemainingMs;

  /// 0x4006(0xD1F1)合并窗在途旗标:相机 1s 巡检逢变化即发,连拍
  /// 一串 —— 与参数事件同窗(150ms)合并成一次裸读。
  bool _shotsRefreshScheduled = false;

  /// 即拍即览清理计时(新照片到达即重置)。
  Timer? _reviewTimer;

  /// 本会话被相机拒绝过(0x200F)的参数 → 读出条锁标(OpenZCine
  /// lockedControls 口径;写成功或断连即清)。
  final lockedProps = <int>{};

  /// 相机当前拍摄模式(照片/视频);null = 未读到(旧机身无此属性/
  /// 连接沿读失败)—— 页面回落本地模式条。连接沿初读、0x4006 事件
  /// 跟随([_onEvent])、切换链定态([switchMode])三处更新。
  CaptureMode? _cameraMode;

  /// 拨杆真档(非覆写期 0xD1A6 读值的落点):与 [cameraMode] 同步更新;
  /// 覆写期读值被软件态遮蔽、真档不可见,不再跟随 —— 释放接管后的读回
  /// 对表([releaseTakeover])。不变式:[cameraMode] 非 null ⇒ 本值非 null。
  CaptureMode? _dialMode;

  /// 软件态可能在偏离拨杆真档(我们的 0xD1A6 覆写活着;覆写只在接管
  /// 持有期保值)。**一旦写过即置位**:拨杆真档从此被软件态遮蔽(读值
  /// 只见回声),连「切回 believed 拨杆档」也不清它 —— 拨杆可能已被拨
  /// 过,真相只能靠新鲜读([releaseTakeover] 的释放后读回 /
  /// [refreshCameraMode] 读到不同值)。覆写随接管释放/断链死亡:释放沿
  /// 读回对表、断链沿对齐拨杆真档([_invalidate])。录像门跟物理拨杆
  /// —— 照片档覆写视频后开录仍被拒,拨杆提示在开录时弹出(不预判拦截)。
  bool _modeOverridden = false;

  /// 本会话模式写已被相机拒(try-and-see 能力缓存:0x1016 对 0xD1A6
  /// 的可写性 PropDesc 报不出 —— Zf getSet=False 但接管下可写)。拒过
  /// 一次即两方向灰显,不再反复试探。
  bool _modeWriteRejected = false;

  /// 模式切换链在途(接管 → 写 0xD1A6 → 重启取景 → 刷参);期间模式
  /// 条锁、快门行为不变到链尾定态。
  bool _switchingMode = false;

  /// 自拍档位:0 = 关;> 0 = 秒数(倒计时后释放,期间可再点取消)。
  int selfTimerSeconds = 0;
  int? _selfTimerLeft;
  bool _selfTimerRunning = false;

  /// 拍摄参数写入中(编辑面板防连点)。
  bool writing = false;

  /// 拍摄参数状态(PropDesc 驱动),键 = [PtpDevicePropCode]。
  final paramProps = <int, PropState>{};

  /// 优化校准(0xD200)槽位真名(0x90CC 拉取):自定义(201-209)/云
  /// (301-309)组的注册名由用户在机身上起,静态表只有「自定义 N」「云 N」
  /// 占位 —— 键 = 槽位值。断连/重连重建。
  final picCtrlNames = <int, String>{};

  /// 名字已在本连接拉取过(一次性;机身下载新校准属罕见,重连即重取)。
  bool _picCtrlNamesFetched = false;

  /// 0x90CC 在本连接已失败(首异常即停,余下槽位不试)。
  bool _picCtrlNamesBroken = false;

  /// 静照自动 ISO(0xD0B5 读到的有效 ISO 是机身应用值);null = 未读/
  /// 拒答,不猜。与手动 ISO 值互不干扰(用户口径:开关只由面板的
  /// 「自动 ISO」控制,选手动值不联动开关)。
  bool? isoAuto;

  /// 接管是否生效(机身拨盘锁定,host 才能调拨盘拥有的参数)。
  bool _takeoverActive = false;

  /// 断链时还持有接管 → 重连后防御性解除(机身拨盘可能仍锁定)。
  bool _takeoverDangling = false;
  bool _linkUp = true;

  /// 断链自动重连中(连接层 reconnecting 态;connected/disconnected/
  /// failed 沿清)。_invalidate 不碰它 —— 由状态沿独占管理。
  bool _reconnecting = false;
  bool _disposed = false;

  /// 拍摄页是否可见(IndexedStack 常驻,页面离台/回台、应用退后台/回
  /// 前台都经 [setViewerVisible] 汇报)。不可见 = 挂起帧轮询与 AE 轮询
  /// (相机侧保持取景 —— 取景生命周期跟连接走);默认 true = 无页面
  /// 汇报时按可见处理(单测/无 HomeShell 场景)。
  bool _viewerVisible = true;
  StreamSubscription<PtpEvent>? _eventsSub;
  StreamSubscription<CameraLinkState>? _statesSub;
  Completer<void>? _captureDone;

  /// SDRAM 直拍旗标(面板芯片,AppSettings 持久化):开 = 快门改发
  /// 0x90CB(官方 §6.2.4.3 无参;探针实证),对象经 0xC101 事件回传后
  /// 由 [_collectSdramObject] 存入图库。
  bool sdramCapture = false;

  /// 在途直拍的句柄接力:0xC101 objectAddedInSdram 事件参数补全
  /// ([_onEvent])。句柄不跨会话、不进对象仓库持久缓存。
  Completer<int>? _sdramHandle;

  /// 等回传对象的窗口(0xC101 未到 = 快门已实发但对象未回,如实提示)。
  /// 实例字段:测试拨小即时收口。
  Duration sdramHandleTimeout = const Duration(seconds: 5);

  /// 等图库落地的窗口(TransferEngine 自带 3 次重试;超窗如实转为
  /// 「后台保存中」提示,传输页可见)。同上,测试可拨小。
  Duration sdramTransferTimeout = const Duration(seconds: 120);

  /// 本连接 0x90CB 已被 0x2005(操作不支持)拒过:模型个性跨连接稳定,
  /// 不再逐拍重试,直发常规快门(同 [_captureOpPref] 会话记忆语义)。
  /// 状态类拒绝(0x200F/0x2013)不记 —— 拨杆拨回、卡归位后直拍仍可用。
  bool _sdramCaptureDropped = false;

  /// 最近取景帧尺寸(SOF 嗅探):触控对焦坐标映射 + 页面画幅计算用。
  final frameSize = ValueNotifier<({int width, int height})?>(null);

  /// 触控对焦框位置;null = 无。
  AfBox? afBox;

  /// 对焦驱动进行中(对焦按钮 / 触控对焦共用,期间防重入)。
  bool focusing = false;
  bool _focusBeforeCapture = false;

  /// 本轮会话已验证可用的快门码(0x100E / 0x9207)。断连不清:相机
  /// 个性跨连接稳定,重连后直发省一次失败事务。
  int? _captureOpPref;

  /// 本轮会话已验证可用的 0x9207 首参 CaptureSort(直接释放路径)。
  int? _captureSortPref;

  /// 按住中(释放档为连续):期间随就绪链发,抬起 [captureReleased] 终止。
  bool _burstLatched = false;

  /// 屏上快门是否仍处于「按住」态(B 门曝光中/连拍括持中)。
  /// 页面退后台或离场时必须主动 [captureReleased] —— 指针取消沿不保证
  /// 送达,漏掉收口会把相机留在开曝光状态。
  bool get shutterHoldActive => _openShutterHeld || _burstLatched;

  /// 连拍括持已开(0x90C2 remote + burstNumber 65535)。
  bool _burstBracketHeld = false;
  int _burstRun = 0;
  int _burstFrames = 0;
  bool _openShutterHeld = false;

  /// 手动按住 B 门已曝光秒数(null = 未在手动曝光)。定时 B 门走
  /// [bulbExposureCountdown],两者互斥。
  int? _bulbOpenSeconds;
  int? get bulbOpenSeconds => _bulbOpenSeconds;

  /// 开拍(0x9207)在途:抬起若先于开拍落地,立即 0x920C 会扑空 ——
  /// 记 [_bulbClosePending],开拍任务落地后自行收门。
  bool _bulbOpening = false;
  bool _bulbClosePending = false;

  /// 上次收门预算耗尽(曝光可能仍开着):下一次按下转为收门重试。
  bool _bulbCloseFailed = false;

  /// 应用写过 Bulb/Time 哨兵前的快门值(收门链还原步;setParam 记录;
  /// 写前值本身是哨兵时保留更早记录 —— 还原目标永远是最后一个非哨兵值)。
  int? _bulbShutterRestore;
  int? _bulbExposureLeft;
  double _dialAccum = 0;
  int _dialGen = 0;
  bool _dialDriving = false;
  final _dialFailures = <DateTime>[];
  bool _dialSuspended = false;

  /// 滚轮刻度鼓净脉冲(乐观账本,towardNear 为正):滚轮路径派发即
  /// 入账(拒答重排队脉冲未弃单,不回冲);按钮路径按结果入账(拒答
  /// /步进过小 = 镜头未动,不入账)。只喂轮子刻度鼓(ValueListenable,
  /// 高频滚动不广播全页);断连与 [resetFocusDial] 归零。
  final dialNetPulses = ValueNotifier<int>(0);

  /// 当前拒答连跑起点(complete/endOfTravel/stepTooSmall 即清;暂停/
  /// 重置同清)。
  DateTime? _dialRefusalSince;

  /// MF 端点态(0xA00C/0xA00E 按请求方向归因学习,见 [MfTravelEnds]);
  /// 步进/滚轮两条 0x9204 路径共用。UI 读 [mfNearEnd]/[mfFarEnd]。
  final MfTravelEnds _mfEnds = MfTravelEnds();

  /// 追踪进行中(0x9424 启动成功 → 0x9425/断连收口;相机侧随取景
  /// 关闭自灭,本旗标只是 UI 态)。
  bool _tracking = false;

  /// 锁定态(乐观,读回对表):type 2 = AE+AWB。WB 非 auto 时机身
  /// 拒 AWB 锁(0x200F)—— 应答失败走 error,旗标不动。
  bool _aeLocked = false;

  /// 强关态(乐观,读回对表):应答 OK 只代表「请求已收到」;会话级
  /// 不持久化,断连沿清零(重连后内屏随会话新开未知)。
  bool _monitorOff = false;
  bool _aePolling = false;
  int _aeRun = 0;

  /// 连接沿「起景段」落定门(2026-10-16,侧链放行信号):[_onConnectedChain]
  /// 的接管→模式读→画质→0x9201(含自愈梯)段落走完即放行,链尾刷参
  /// 不计 —— 概览/双卡槽/清事件/对时/事件轮询等这门而非死等固定窗,
  /// 起景快侧链就早走(相机页信息卡不再白扛整段让路窗)。
  ///
  /// **预置下一沿的空门**:概览两控制器订阅序在本控制器之前(AppServices
  /// 装配序),connected 事件先到它们手里 —— 它们取到的必须是本沿的门
  /// (上一沿落定时预建的新门,尚未完成),完成于本沿起景段落定;构造期
  /// 即备好首沿门。complete 与换门之间无 await,同同步块原子,并发的
  /// 两条连接链各完成当时的现门,不会双完成。
  Completer<void> _startSettledGate = Completer<void>();

  /// 取景总开关(十二轮):闸 [autoLiveViewOnConnect] 的连接沿/进页/
  /// 回台自动起景;显式 [toggleLiveView] 不受闸。AppServices 装配后
  /// 同步自 settingsController.value.liveViewOn(含监听),拍摄页
  /// 浮层「取景」钮改动也同步到这里 —— 单测直挂控制器时默认 true
  /// 保持「取景默认打开」原行为。
  bool autoLiveViewEnabled = true;

  /// 取景画质档(2026-10-12 官方 §6.5.11.4-5):null = 跟随相机(不写
  /// —— 尊重机身菜单既有设置);非 null = 连接沿在起景前写入 + 改动
  /// 即时写(0xD1AC 尺寸 1=QVGA/2=VGA/3=XGA;0xD1BC 压缩 0=Basic 尺寸
  /// 优先…5=Fine 质量优先)。写失败静默(尽力而为,总闸关断/拒答不打扰)。
  int? liveViewImageSize;
  int? liveViewImageCompression;

  /// 在途的自动起景([autoLiveViewOnConnect] 单飞槽)。
  Future<void>? _autoStartInFlight;

  /// 拍摄参数刷新(目录 [kShootingParams] 全量):PropDesc 优先(自带
  /// 当前值 + 可写性 + 取值域),值回读按目录路由(厂商读码,见
  /// [_refreshProp]);PropDesc 不可用退回裸值 0x1015(值有、域未知)。
  /// 单属性失败置空不上抛,断连后迟到值不上屏。目录序逐个刷(不并发):
  /// PropDesc 拒答的退回路径会二次入队,并发时与脚本应答交错易错位。
  /// 视频档追加视频参数族 [kVideoShootingParams](照片档零流量 ——
  /// 拨杆照片档下这些属性枚举塌 1 值,刷了也是噪声)。
  ///
  /// **单飞合流**([joinInFlight]):进页/回台沿对表与连接沿刷参常同拍
  /// 到达 —— 连接沿整链(照片档 ~35 事务,视频档翻倍)还在跑,进页又
  /// 起一条,两条全链在 Wi-Fi 每事务一次往返下把取景帧压成幻灯片
  /// (2026-10-16 真机「进页卡很久、无实时取景」)。仅显式 [joinInFlight]
  /// 的调用方(进页/回台对表)并入在途全链;连接沿/模式翻转沿/拍摄沿
  /// 等语义要求**新鲜**全链的调用方默认 false 照旧直发。
  /// 在途的全量刷参([refreshParams] 单飞槽)。
  Future<void>? _paramSweepInFlight;

  /// 首轮刷参完成旗标:模式翻转沿的补刷只在首刷之后触发(连接沿的
  /// 模式初读不作数 —— 那次刷新由 _onConnectedChain 尾部统一做,
  /// 双刷会翻倍脚本序)。
  bool _paramsRefreshedOnce = false;
  final _pendingPropRefreshes = <int>{};
  bool _propRefreshScheduled = false;

  /// 间隔拍摄调度器(纯核心件,见 [Intervalometer] 头注):延迟/就绪
  /// 探测/单拍事务全注入 —— 单拍复用屏上快门链([_captureOnce]:码回落/
  /// CaptureSort 对焦后拍/落地等待/取景挂起),零第二套快门方言。
  /// 探针 = 0x90C8 DeviceReady(忙等语义在 session 层收敛)。
  late final Intervalometer _interval = Intervalometer(
    delay: _delay,
    probeReady: () => session.deviceReady(),
    // 单拍返回键+参记录;detail 是纯诊断透出(UI 不消费),落键即可。
    shoot: () async {
      final (ok, msg) = await _intervalShot();
      return (ok, msg?.key);
    },
  )..addListener(_onIntervalChanged);

  /// 即拍即览:最近一张的缩略图(0x100A,几秒后清;null = 无)。
  Uint8List? reviewThumb;

  // ---- 拍摄模式(0xD1A6 镜像:跟随 + 远程切换)----

  CaptureMode? get cameraMode => _cameraMode;

  /// 换档落位(唯一入口):翻转沿把张数/可录时长一并作废 —— 它们是
  /// 旧档口径(0xD1F1 在视频档被录像估算污染,切回照片沿会先闪旧值
  /// 再被链首新鲜读纠正),清空等新鲜读,胶囊宁缺不错。
  void _setCameraMode(CaptureMode? m) {
    if (m == _cameraMode) return;
    _cameraMode = m;
    shotsRemaining = null;
    videoRemainingMs = null;
    _syncActualIsoPoller(); // 视频档起 0xD0B5 实际值轮询(1s 轻读)
  }

  // ---- 实际工作 ISO(0xD0B5 裸读):视频档设定值(0xD1AA)与机身
  // auto 增益分叉时的第二读数;照片档 ISO 块读码本就是 0xD0B5,无此需。

  int? _actualIso;

  /// 机身实际工作 ISO(视频档随 [_kActualIsoPollInterval] 轻读):与
  /// 设定值分叉时上屏「{v}(实际 {a})」。照片档不轮询(值路同读码)。
  int? get actualIso => _actualIso;

  int _actualIsoRun = 0;
  bool _actualIsoLooping = false;

  /// 视频档起停 0xD0B5 轮询环(唯一入口 = [_setCameraMode])。环走
  /// [_delay](测试侧 _parkedDelay 停摆)而非 Timer —— 队列型假会话按
  /// opcode 全局排队,轮询事务会偷 refreshParams 的脚本位;且真定时器
  /// 在 flutter_test 的 pending-timer invariant 下活不过用例(invariant
  /// 先于 addTearDown 跑,dispose 撤不掉;2026-10-26 两轮红实证)。
  /// 断链空转自续,离开视频档才撤值。
  void _syncActualIsoPoller() {
    final want = _cameraMode == CaptureMode.video;
    if (want && !_actualIsoLooping) {
      _actualIsoLooping = true;
      unawaited(_actualIsoLoop(++_actualIsoRun));
    } else if (!want && _actualIsoLooping) {
      _actualIsoLooping = false;
      _actualIsoRun++; // 旧环到点自退
      _setActualIso(null);
    }
  }

  Future<void> _actualIsoLoop(int run) async {
    while (run == _actualIsoRun && !_disposed) {
      await _delay(_kActualIsoPollInterval);
      if (run != _actualIsoRun || _disposed) return;
      if (_cameraMode != CaptureMode.video) return; // 模式沿对账自退
      if (!_linkUp) continue; // 断链空转,重连自续
      await _pollActualIso();
    }
  }

  /// 0xD0B5 裸读:拒答/断链静默保旧值 —— 展示性第二读数,不参与写路。
  /// on Object 收口(transport 关闭抛 Error,会逃逸 on Exception)。
  Future<void> _pollActualIso() async {
    try {
      final v = await session
          .getDevicePropValue(PtpDevicePropCode.isoControlSensitivity);
      _setActualIso(v.value as int?);
    } on Object {
      // 保旧值
    }
  }

  void _setActualIso(int? v) {
    if (v == _actualIso) return;
    _actualIso = v;
    if (!_disposed) notifyListeners();
  }

  CaptureMode? get dialMode => _dialMode;

  bool get modeOverridden => _modeOverridden;

  bool get modeWriteRejected => _modeWriteRejected;

  bool get switchingMode => _switchingMode;

  L10nMessage? error;

  /// 「已拍摄」提示(ObjectAdded 事件驱动;下一次操作时清)。
  L10nMessage? notice;

  /// 三要素只读快照(派生自 [paramProps],chips 展示用)。
  Exposure? get exposure => paramProps.isEmpty
      ? null
      : Exposure(
          fNumber: paramProps[PtpDevicePropCode.fNumber]?.value,
          shutterRaw: paramProps[PtpDevicePropCode.exposureTime]?.value,
          iso: paramProps[PtpDevicePropCode.exposureIndex]?.value,
        );

  /// 取景是否在跑(引擎状态透传)。
  bool get liveViewActive => engine.status.value == LiveViewStatus.running;

  /// 链路是否在(断连/失败后闩上,页面据此显示连接指引)。
  bool get linkUp => _linkUp;

  /// 断链自动重连中(连接层恢复循环跑着):页面保留冻结帧不弹回,
  /// 横幅「正在自动重连」由消费端按此驱动。
  bool get reconnecting => _reconnecting;

  /// 取景流 BUSY 保持(机身忙:写卡/下载 flush 中,画面保持不重启;
  /// 看门狗产物,见 [LiveViewEngine.health])。
  bool get liveViewBusyHold => engine.health.value == LiveViewHealth.busy;

  /// 拍摄参数调节总开关(生产 = [PtpSession.kSetPropEnabled],真机实证已开)。
  bool get canAdjustParams => _setPropEnabled();

  /// 该属性当前是否可调:总门禁 + 目录 readOnly(机身件拥有)+ 模式门
  /// (曝光变量:机身在 M/S 之外拥有快门、M/A 之外拥有光圈 —— A/P 下
  /// 快门自动、S/P 下光圈自动,影控台同状态同样不可调,2026-10-06 真机
  /// 实证)+ 相机 getSet 上报。厂商写路由参数(writeCode != null)跳过
  /// getSet:标准码的 getSet 不代表厂商写码可写性(真机:0x500D/0x500F
  /// 报只读,0xD100/0xD0B4 照常可写)。
  void _onEngineStatus() {
    if (engine.status.value == LiveViewStatus.failed &&
        engine.lastError != null) {
      error = engine.lastError;
    }
    if (engine.status.value != LiveViewStatus.running) {
      afBox = null; // 对焦框只活在取景中
    }
    _syncAePolling();
    notifyListeners();
  }

  /// 看门狗健康度变化(busy/frozen 横幅的驱动沿):纯透传。
  void _onEngineHealth() => notifyListeners();

  /// 取景帧到达:SOF 嗅探帧尺寸(只走标记结构不解码,开销可忽略;
  /// 失败保留旧值)。尺寸变化沿落一行 AppLog(live 域,二十轮:比例
  /// 不一致取证 —— 流档位 3:2/16:9/旋转都从这里对账)。
  void _onFrame() {
    final f = engine.frame.value;
    if (f == null) return;
    final s = jpegSofSize(f);
    if (s != null && s != frameSize.value) {
      frameSize.value = s;
      AppLog.d(AppLog.live, '取景帧 ${s.width}×${s.height}(SOF)');
    }
  }

  /// 帧头到达:对齐录制态(头部 @828 是机身权威 —— app/机身侧启动的
  /// 录制都如实;0xC10A/0xC108 事件之外的每帧兜底)。头部无录制域
  /// (一代 512B 头/解析失败)时不动状态。
  void _onHeader() {
    final h = engine.header.value;
    if (h == null) return;
    // 0x9205 坐标系缓存(OpenZCine lastFocusCoordinateSpace 同款):头
    // 瞬时丢帧/解析失败时,触控对焦仍用相机最近自报的 whole-size,
    // 不掉级到帧像素(两空间差 ~9 倍,掉级即点哪儿都跑左上角)。
    if (h.coordinateWidth > 0 && h.coordinateHeight > 0) {
      _lastHeaderSpace = (width: h.coordinateWidth, height: h.coordinateHeight);
    }
    // 视频剩余可录(帧头 @816,机身权威):>0 才认有效,变化沿才
    // notify(每帧都到,倒计时秒级游走,不能逐帧 notify)。
    final remain = h.videoRemainingMs;
    final valid = remain != null && remain > 0 ? remain : null;
    if (valid != videoRemainingMs) {
      videoRemainingMs = valid;
      notifyListeners();
    }
    if (h.recording == recording) return;
    recording = h.recording;
    recordingSince = h.recording ? DateTime.now() : null;
    notifyListeners();
  }

  /// 最近一次帧头自报的 whole-size 坐标系(触控对焦坐标回退链第二级)。
  ({int width, int height})? _lastHeaderSpace;

  /// connected 沿串链:自动起景(0x9201 + 首帧入队)先行,再对表刷参
  /// —— 回台沿(41c6bba)同款序,请求序恒 [0x9201, 首帧, 参数…];两个
  /// 并发 unawaited 会让引擎帧请求穿插进刷参链。
  ///
  /// 起景驱动移到本控制器自己的 connected 沿,背景(2026-10-11 真机
  /// 修复):原先由 HomeShell 在 ConnectionController 的通知沿调用
  /// [autoLiveViewOnConnect],但 AppServices 装配序里 ConnectionController
  /// 先订阅 states 流(构造器先于本控制器),connected 事件派发时它先
  /// notifyListeners、HomeShell 的调用先到,而本控制器的 _linkUp 要在
  /// 自己的订阅(排在其后)里才置位 —— 首连靠 _linkUp 冷启乐观门闩
  /// (恒真起步)蒙混过关,重连沿 _invalidate 已把它压成 false,调用
  /// 全数早退:引擎停在 idle,画面冻结在断链前末帧、无「重试取景」、
  /// 录像被 liveViewActive 门拦住,唯退出拍摄页重进才恢复。由持有
  /// _linkUp 的本控制器自驱,顺序不再寄望装配序。
  Future<void> _onConnectedChain() async {
    // AP 直连主动接管(2026-10-15 用户定案,取代「失败后引导」两步流):
    // 点连接 = 接管同意 —— 连上先持 remote 模式(机身停「已连接到计算
    // 机」屏 + 拨盘锁定,连接页 AP 卡有提示),0x9201 取景门随之开,
    // 连接即取景一步到位。尽力而为:被拒不拦链,落取景失败占位的引导
    // 兜底;总闸关不接管(取景不开就不锁机身);重连沿同样重进(防御
    // 性解除先行,会话串行门保序 0→1)。
    if (apMode && autoLiveViewEnabled) {
      await enableTakeover();
    }
    // 模式读打头(2026-10-11 真机反馈:视频档进页要等整条刷参链跑完
    // 才跟到视频档,几秒观感延迟)—— 单请求先行,再起景、刷参。
    // triggerRefresh=false:链尾 refreshParams 统一刷,这里补刷即双刷。
    await refreshCameraMode(triggerRefresh: false);
    // 取景画质档(用户设过非「跟随相机」才写;起景前写 → 首帧即目标
    // 分辨率,0x9428 帧尺寸随 0xD1AC)。
    await _applyLiveViewQuality();
    await autoLiveViewOnConnect();
    // 起景段落定(0x9201 成败已分,含自愈梯):放行侧链(概览/双卡槽/
    // 清事件/对时/轮询),再进链尾刷参 —— 侧链此后与刷参链轮转,不再
    // 与起景段争锁;固定让路窗由此退役(2026-10-16)。
    _startSettledGate.complete();
    _startSettledGate = Completer<void>();
    await refreshParams();
  }

  /// 读 0xD1A6 刷 [cameraMode](连接沿初读、进页/回台沿对表、0x4006
  /// 事件跟随用)。读失败保持原状(null 仍 null → 页面回落;已知值
  /// 不因瞬态失败清掉)。**覆写回声护栏**:覆写期读值是软件态回声(与
  /// 拨杆真档不可分),与已知软件态相同即零动作 —— 拨杆真档的真相留给
  /// 释放接管后的读回([releaseTakeover]);读到不同值 = 覆写已被机身
  /// 顶掉/拨杆态盖过,按新真相全量对表。
  ///
  /// [triggerRefresh]:模式翻转沿是否补刷参数(视频参数族只视频档刷,
  /// 拨到视频档要拉整条链不然面板全「--」)。连接沿/进页沿的调用后都
  /// 紧跟显式 refreshParams,必须传 false 防双刷(双刷翻倍脚本序);
  /// 0x4006 事件路径用默认 true(那里没有后续刷参)。
  /// 剩余可拍张数(0xD1F1 裸读;拒答 null 不猜)。on Object 收口:
  /// 断链沿 transport 关闭抛的是 Error(StateError),会逃逸 on Exception
  /// (autoLiveViewOnConnect 同款「transport 已关」口径)。
  Future<void> _refreshShotsRemaining() async {
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.exposureRemaining);
      if (!_linkUp) return;
      shotsRemaining = v.value as int?;
      // 诊断开闸时沿张数刷新打语义时间线(真机行为与官方语义背离排查,
      // 2026-10-16;测试/常规运行恒关零开销)
      if (kPtpDiagnosticsOnConnect && shotsRemaining != null) {
        unawaited(PtpDiagnostics.shotsSemanticsProbe(session, shotsRemaining!));
      }
    } on Object {
      if (!_linkUp) return;
      shotsRemaining = null;
    }
  }

  /// 轻量张数刷新(单笔裸读 + 变化沿上屏):进页沿/0x4006 事件路径用,
  /// 不等整条刷参链(链尾同读是确认,首读是「进页即对」)。
  Future<void> refreshShotsRemaining() async {
    final prev = shotsRemaining;
    await _refreshShotsRemaining();
    if (_disposed || !_linkUp || shotsRemaining == prev) return;
    notifyListeners();
  }

  /// 0x4006(0xD1F1)事件 → 合并窗后轻量刷新(机身拍摄/改画质/换卡都
  /// 走这条官方推送通道;不合并连拍会一串裸读)。
  void _scheduleShotsRemainingRefresh() {
    if (_shotsRefreshScheduled) return;
    _shotsRefreshScheduled = true;
    Timer(_propRefreshDebounce, () {
      _shotsRefreshScheduled = false;
      unawaited(refreshShotsRemaining());
    });
  }

  /// 静照自动 ISO 状态(0xD054,u8 裸读;拒答 null 不猜)。
  void _onEvent(PtpEvent event) {
    if (!_linkUp) return; // 断连后迟到事件一律丢弃
    switch (event.code) {
      case PtpEventCode.captureComplete:
      case NikonEventCode.captureCompleteRecInSdram:
        final done = _captureDone;
        if (done != null && !done.isCompleted) {
          done.complete();
        }
      case PtpEventCode.objectAdded:
      case NikonEventCode.objectAddedInSdram:
        // SDRAM 直拍在途:0xC101 参数 = 回传对象句柄,交给直拍收尾链
        // ([_collectSdramObject]),不走进卡的即览/刷参分支。
        if (event.code == NikonEventCode.objectAddedInSdram) {
          final pending = _sdramHandle;
          if (pending != null &&
              !pending.isCompleted &&
              event.params.isNotEmpty) {
            pending.complete(event.params.first);
            return;
          }
          // 无在途链:照旧按卡对象提示(防御 —— 相机内存残留等)
        }
        notice = (key: 'remote.captured', args: null);
        notifyListeners();
        // 先缩略图(即拍即览要快)再全量刷参 —— 顺序确定,事务排队
        // 不会与参数刷新交错。
        unawaited(() async {
          await _showInstantReview(
              event.params.isNotEmpty ? event.params.first : null);
          await refreshParams();
        }());
      case PtpEventCode.devicePropChanged:
        // 机身侧拨盘/菜单改动(OpenZCine 口径):定向刷新被点名的参数,
        // 短窗合并(一次拨杆转动会连发一串)。
        if (event.params.isNotEmpty) {
          final code = event.params.first;
          if (code == PtpDevicePropCode.liveViewSelector && !_switchingMode) {
            // 拨杆翻转(或我们切换链之外的模式写入,如覆写被机身顶
            // 回):重读镜像跟随。切换链在途时跳过 —— 链尾已定态。
            unawaited(refreshCameraMode());
          }
          _schedulePropRefresh(code);
        }
      case NikonEventCode.movieRecordStarted:
        recording = true;
        recordingSince ??= DateTime.now();
        notifyListeners();
      case NikonEventCode.movieRecordComplete:
      case NikonEventCode.movieRecordInterrupted:
        recording = false;
        recordingSince = null;
        notifyListeners();
      default:
        break; // 0xC10C 等:见类注,不消费
    }
  }

  /// 即拍即览:新照片到达 → GetThumb 缩略图小卡,几秒后自动撤
  /// (OpenZCine InstantReview 的轻量版;handle 缺失时跳过 ——
  /// SD 卡写完前事件可能先到,拿不到就等下一张)。
  /// 断连/失败:停引擎、清状态;迟到的参数值/事件被门闩挡住。
  void _invalidate() {
    _linkUp = false;
    _burstLatched = false;
    _burstRun++;
    _burstBracketHeld = false;
    _openShutterHeld = false;
    // B 门会话态随链路消亡(收门重试/还原目标不跨连接:下次连接重读
    // 参数才是真相)。
    _bulbOpening = false;
    _bulbClosePending = false;
    _bulbCloseFailed = false;
    _bulbShutterRestore = null;
    _bulbExposureLeft = null;
    _bulbOpenSeconds = null;
    _cancelSelfTimer();
    // 间隔拍摄随链路消亡:调度等待即时取消(在途单拍事务被门闩挡在
    // 收尾,快门命运如实交给相机侧)。停止摘要 notice 被下方清空,
    // 「未连接」横幅独占告知。
    _interval.stop();
    _dialGen++;
    _dialAccum = 0;
    _dialDriving = false;
    _dialSuspended = false;
    _dialFailures.clear();
    dialNetPulses.value = 0; // 刻度鼓随链路消亡(重连后镜头位置未知)
    recording = false;
    recordingSince = null;
    reviewThumb = null;
    _reviewTimer?.cancel();
    lockedProps.clear();
    _tracking = false; // 追踪随会话消亡(0x9425 不必发)
    _aeLocked = false; // 会话级锁态,重连后未知(乐观态不留假亮)
    _monitorOff = false; // 同上:内屏强关态,重连后未知
    if (_takeoverActive) {
      // 链路已死无法发 0x90C2 [0]:记悬挂,重连后防御性解除。
      _takeoverDangling = true;
      _takeoverActive = false;
    }
    engine.remoteHeld = false;
    // 模式覆写随会话死亡(持有期保值):拨杆真档即真相,cameraMode 对
    // 齐它(不变式:非覆写 ⇒ cameraMode == dialMode);重连沿
    // _onConnectedChain 重读对表。
    if (_modeOverridden) {
      _setCameraMode(_dialMode);
      _modeOverridden = false;
    }
    _switchingMode = false;
    _syncAePolling(); // 引擎停转的通知可能在门闩之后才到,这里先收口
    unawaited(engine.stop());
    capturing = false;
    writing = false;
    error = null;
    notice = null;
    afBox = null;
    paramProps.clear();
    picCtrlNames.clear();
    _picCtrlNamesFetched = false;
    _picCtrlNamesBroken = false;
    _pendingPropRefreshes.clear();
    notifyListeners();
  }
}

/// 取景域:起停景、画质档、查看器可见性、起景段落定门。

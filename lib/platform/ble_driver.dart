  // ------------------------------------------------------------------
  // BLE 链路/注入双层驱动(2026-10-17 全自动重连定案):有身份+未挂起
  // → 链路层常跑(tick 保活 + 退避重连循环,无人值守);注入开关只翻
  // GPS 层(定位流+GEO),关开关不再拆链停循环。session 层零 Timer,
  // 前台驱动全收在这里。
  // ------------------------------------------------------------------

///
/// 2026-10-22 自 AppServices 抽出:装配器回归纯装配,重连时序可独立
/// 单测 —— 平台面(定位流/后台保活/数据目录)与 GPS 开关全部注入,
/// 本类不触 PlatformServices 单例。
library;

import 'dart:async';
import 'dart:io' show File, exit;

import '../core/ble/ble_camera_session.dart';
import '../core/ble/ble_keepalive.dart';
import '../core/ble/geo_payload.dart';
import '../core/log/app_log.dart';
import 'background_transfer.dart';
import 'instance_watch.dart';
import 'location_host.dart';

/// BLE 重连循环重臂谓词(纯函数,供单测):无命中且驱动在跑 →
/// reconnecting(连上又掉)或 idle+有身份(冷启扫空/闸门等唤醒)
/// 都续跑,循环不死;命中(ok)或驱动停/身份没了才收。
bool bleRetryRearm({
  required bool ok,
  required bool running,
  required BleSessionState state,
  required bool hasIdentity,
  bool paused = false,
}) =>
    !paused &&
    !ok &&
    running &&
    (state == BleSessionState.reconnecting ||
        (state == BleSessionState.idle && hasIdentity));


/// BLE 驱动:链路层(tick 保活 + 退避重连循环)与注入层(定位流 +
/// GEO)双层状态机;挂起/手动断开/面板扫描让位三类外部闸。
final class BleDriver {
  BleDriver({
    required BleCameraSession session,
    required bool Function() gpsInjectEnabled,
    required LocationStreamHost locationStream,
    required BackgroundTransferScheduler background,
    required Future<String> Function() dataDir,
    bool Function()? ptpGpsAvailable,
    Future<bool> Function(GeoFix fix)? ptpGpsWrite,
  })  : _session = session,
        _gpsInjectEnabled = gpsInjectEnabled,
        _locationStream = locationStream,
        _background = background,
        _dataDir = dataDir,
        _ptpGpsAvailable = ptpGpsAvailable,
        _ptpGpsWrite = ptpGpsWrite;

  final BleCameraSession _session;

  /// GPS 注入开关读数(设置页落库沿经监听 → [refresh] 重判)。
  final bool Function() _gpsInjectEnabled;
  final LocationStreamHost _locationStream;
  final BackgroundTransferScheduler _background;
  final Future<String> Function() _dataDir;

  /// Wi-Fi PTP 位置写入(0x9523)能力:非空 = 无线会话已连接。生产只在
  /// Wi-Fi(非 USB)链路注入 —— Zf USB data-out STALL,真机 2026-11-08。
  final bool Function()? _ptpGpsAvailable;

  /// 0x9523 写入器(载荷由装配层用 GeoPayload 构建);返回 false =
  /// 相机拒/链路异常,驱动回落 BLE 0x2007。
  final Future<bool> Function(GeoFix fix)? _ptpGpsWrite;

  /// PTP 注入节流:30s 或位移 ≥5m 才写(相机只保留最近位置,不必跟
  /// 3s 定位流);失败后 60s 内不再试 PTP,直接走 BLE。
  static const Duration _ptpGpsInterval = Duration(seconds: 30);
  static const double _ptpGpsDistanceM = 5.0;
  static const Duration _ptpGpsBackoff = Duration(seconds: 60);
  GeoFix? _ptpLastOkFix;
  DateTime? _ptpLastOkAt;
  DateTime? _ptpBackoffUntil;
  bool _ptpWriteInFlight = false;
  bool _ptpWasReady = false;

  /// 最近一个定位点:定位常先于 Wi-Fi 连接到达(连接后流静止不再发点),
  /// PTP 可用沿用它补写一次,免等用户移动。
  GeoFix? _lastFix;

  /// PTP-only 注入的独立 location 后台持有(防重复 ensure/stop)。
  bool _gpsHold = false;

  /// PTP 注入可用 = 链路谓词真且写入器已装配。
  bool get _ptpReady =>
      (_ptpGpsAvailable?.call() ?? false) && _ptpGpsWrite != null;

  Timer? _bleTick;
  Timer? _bleRetry;
  StreamSubscription<LocationSample>? _bleFixSub;
  StreamSubscription<BleSessionState>? _bleStateSub;

  /// 链路层在跑(wantLink:有身份+未挂起)。
  bool _bleRunning = false;

  /// 注入层在跑(wantInject:链路层之上再叠加 GPS 开关)。
  bool _bleInjecting = false;

  /// 平台定位流已起(BLE 断连不清 —— 定位流独立于链路;注入层收口才
  /// 复位)。tick 兜底自愈的判据,防每 5s 重复 startStream。
  bool _locationStreamUp = false;

  /// 实例心跳看门狗(2026-10-21):升级安装留僵尸(旧实例不终止)的
  /// App 内自愈 —— 新实例出现,旧实例 3-6s 内自我退出。随驱动启停
  /// (无线电战争只存在于跑驱动的实例;测试无 pending Timer)。
  InstanceWatch? _instanceWatch;
  bool _instanceWatchStarted = false;

  /// 看门狗武装(幂等,dataDir 通道缺失则缺席):随驱动启停,测试的
  /// 「无 pending Timer」断言不炸。
  Future<void> _ensureInstanceWatch() async {
    if (_instanceWatchStarted) return;
    _instanceWatchStarted = true;
    try {
      final dir = await _dataDir();
      if (dir.isEmpty) return;
      _instanceWatch = InstanceWatch(
        lockFile: File('$dir/instance.json'),
        onExit: (reason) {
          AppLog.e(AppLog.ble, 'instance watch: $reason');
          exit(0);
        },
      )..start();
    } on Exception {
      // 通道缺失(测试/异端):看门狗缺席,僵尸回潮可容忍
      _instanceWatchStarted = false;
    }
  }

  /// BLE 持有式后台保活同步(调用点:会话状态沿/设置沿/挂起沿,均
  /// 幂等):会话 ready → hold('ble', bluetoothInteraction);GPS 注入
  /// 层在跑(_bleInjecting)再并 location。模式须有真实业务背书 ——
  /// location 挂着但 GPS 不采样,系统可能按「未使用」吊销整个长时
  /// 任务(HarmoNiLink 实证口径)。
  void syncBackgroundHold() {
    // PTP-only 注入(BLE 未 ready / 无身份,但 Wi-Fi 会话在):用独立
    // 'gps' 持有 location 模式,防系统按「location 未使用」吊销。
    final ptpOnly = _bleInjecting &&
        _session.state != BleSessionState.ready &&
        _ptpReady;
    if (ptpOnly) {
      if (!_gpsHold) {
        _gpsHold = true;
        unawaited(_background.ensureRunning('gps', {BgMode.location}));
      }
    } else if (_gpsHold) {
      _gpsHold = false;
      unawaited(_background.stop('gps'));
    }
    if (_session.state != BleSessionState.ready) {
      unawaited(_background.stop('ble'));
      return;
    }
    final modes = <BgMode>{BgMode.bluetoothInteraction};
    if (_bleInjecting) {
      modes.add(BgMode.location);
    }
    unawaited(_background.ensureRunning('ble', modes));
  }

  /// 配对页手动流程期间挂起(驱动自动重连/ GEO tick 会与手动配对撞车:
  /// 扫描互踩 + 拆链沿 GEO 写 notFound 污染 lastError —— 真机实证)。
  bool _bleSuspended = false;

  /// 配对页进入时挂驱动、离页恢复(见 _bleSuspended)。只停驱动循环
  /// (tick/重试/定位流/订阅),不动已建立的 BLE 链路 —— 管理页进出
  /// 不应拆链(真机 2026-10-14:挂起沿 disconnect 把 ready 链路也拆了,
  /// 连接页「配对管理」一点蓝牙就断)。
  void suspend() {
    // 有身份不挂起(2026-10-21 用户定稿 SnapBridge 行为「配对后马上连
    // 接」:回链优先于一切面板流程)—— 旧规「面板打开即挂起」只该管
    // 首次配对(无身份):有身份时挂起 = 相机在广播等我们、驱动却被摁
    // 死,「已配对,未连接」僵持实证。ready 会话同理(扫描/配对已收
    // 口,无撞车面)。仅无身份(真首配,扫描/配对手动流程)才挂。
    if (_session.identity != null) {
      _bleSuspended = false;
      AppLog.e(AppLog.ble,
        'driver suspend skipped (identity present, state=${_session.state.name})'); // 运营必需
      return;
    }
    _bleSuspended = true;
    AppLog.e(AppLog.ble,
        'driver suspend (first-pairing flow, state=${_session.state.name})'); // 运营必需
    if (_bleRunning) {
      _bleRunning = false;
      _bleInjecting = false;
      _stopBleDriverLoop();
    }
    // 挂起期 GPS 不再采样:location 模式撤出(防系统按「location
    // 未使用」吊销整个长时任务)。
    syncBackgroundHold();
  }

  void resume() {
    _bleSuspended = false;
    _update();
  }

  /// 用户显式断开意图(蓝牙页「断开」沿置位):压制一切自动回链 ——
  /// 驱动冷启动/空闲沿续轮询/面板打开沿与回前台守候全哑,直到显式
  /// 「连接」/重新配对沿清除。仅内存态:冷启 App 即回归默认守候。
  bool _bleManualOff = false;
  bool get manualOff => _bleManualOff;
  set manualOff(bool v) {
    if (_bleManualOff == v) return;
    _bleManualOff = v;
    refresh(); // 翻面沿驱动跟随(置位收链路层,清除恢复守候)
  }
  set bleManualOff(bool v) {
    if (_bleManualOff == v) return;
    _bleManualOff = v;
    refresh(); // 翻面沿驱动跟随(置位收链路层,清除恢复守候)
  }

  /// 配对页配对成功/解除后刷新(设置监听之外的显式入口)。
  void refresh() => _update();

  /// 驱动循环在跑(面板重连循环让位判据;挂起沿 false)。
  bool get running => _bleRunning;

  void _update() {
    // 三层门(2026-10-17 全自动重连定案 + 2026-10-19 手动断开意图):
    // 链路层只认「已配对+未挂起+非用户显式断开」—— 重连循环与 TIME
    // 保活是链路义务,不随 GPS 开关走;注入层 = 链路层之上再叠加开关,
    // 只管定位流+GEO。
    final wantLink = !_bleSuspended &&
        _session.identity != null &&
        !_bleManualOff;
    // PTP(Wi-Fi)位置写入不依赖 BLE 身份/链路:只要设置开关开、无线
    // 会话在,注入层就跑;USB 由 ptpGpsAvailable 排除。
    final ptpReady = _ptpReady;
    final wantInject = _gpsInjectEnabled() && (wantLink || ptpReady);
    if (wantLink == _bleRunning &&
        wantInject == _bleInjecting &&
        ptpReady == _ptpWasReady) {
      return;
    }
    _ptpWasReady = ptpReady;
    // 门判定落盘(运营必需:冷启链/挂起链断点全靠它定位)。**只在真翻面
    // 时记一行**:设置滑杆拖动会逐 tick 走 _update,旧写法放在幂等短路
    // 之前且用 error 级,一次拖动 = 上百行日志 + 上百次 error 尾巴落盘。
    AppLog.i(AppLog.ble,
        'inj gate: wantLink=$wantLink wantInject=$wantInject running=$_bleRunning '
        'inj=$_bleInjecting susp=$_bleSuspended manualOff=$_bleManualOff '
        'id=${_session.identity != null} gps=${_gpsInjectEnabled()} '
        'state=${_session.state.name}');
    final wasRunning = _bleRunning;
    _bleRunning = wantLink;
    _bleInjecting = wantInject;
    // 翻面后再同步:hold 并集跟 _bleInjecting(挂起恢复沿链路仍是
    // ready、无状态沿可蹭,必须在此对齐)。
    syncBackgroundHold();
    if (!wantLink) {
      if (wasRunning) {
        _stopBleDriverLoop(keepInject: _bleInjecting);
        // 解除配对沿(身份没了)连链路一起收;挂起沿保留 —— 真机
        // 2026-10-14:挂起沿 disconnect 把 ready 链路也拆了,连接页
        // 「配对管理」一点蓝牙就断。
        if (_session.identity == null) {
          unawaited(_session.disconnect());
        }
      }
      if (_bleInjecting) _syncInjectLayer(); // PTP-only 注入层
      return;
    }
    if (!wasRunning) {
      _startBleInjection(); // 链路层首启(内含注入层对齐)
    } else {
      _syncInjectLayer(); // 仅注入层翻面(开关沿):链路循环不动
    }
  }

  void _startBleInjection() {
    AppLog.e(AppLog.ble, 'driver start (state=${_session.state.name})');
    _ensureInstanceWatch(); // 僵尸自愈看门狗随驱动武装(无线电战争面)
    _bleStateSub = _session.states.listen((s) {
      // 状态沿落盘(运营必需:重连链断点定位,频率=连接态变更)。
      AppLog.e(AppLog.ble, 'state → ${s.name}');
      if (s == BleSessionState.reconnecting) {
        _scheduleBleRetry();
      } else if (s == BleSessionState.ready) {
        // 就绪沿注入层复启(断连重连沿天然跟上;未授权/通道缺失时
        // 静默零坐标,TIME 心跳仍维持会话)。
        _syncInjectLayer();
      } else if (s == BleSessionState.idle) {
        // 空闲沿(握手放弃/超时):有身份就续轮询 —— 全自动重连的
        // 冷恢复锚点,循环不再一轮即死。
        _bleRetry?.cancel();
        _scheduleBleRetry();
      }
    });
    // 拍频 5s = 到点判定分辨率(首写门 2.5s/GEO 失败回补重闸 2.5s →
    // 实际首写 ≤7.5s);TIME 写本身由会话按 45s/90s 档位门控,拍频加密
    // 不抬 BLE 流量。
    _bleTick = Timer.periodic(const Duration(seconds: 5), (_) async {
      // 自愈兜底(2026-10-21 实证):ready 沿的 _syncInjectLayer 偶发不
      // 达(边沿丢失机制未定案),定位流从没起过 → 注入层零写入。tick
      // 每拍核查「注入在跑+ready+流没起」即补起,不再赌单次边沿。
      if (_bleInjecting &&
          !_locationStreamUp &&
          _session.state == BleSessionState.ready) {
        await _startLocationStream();
      }
      await _session.tick();
    });
    // 冷启恢复档:idle/reconnecting 且盘载身份在 → 直接进重试循环(免
    // 重走菜单配对;挂起恢复沿链路保留,可停在 reconnecting,同样续跑)。
    if (_session.state == BleSessionState.idle ||
        _session.state == BleSessionState.reconnecting) {
      _scheduleBleRetry();
    }
    _syncInjectLayer();
  }

  /// 面板配对扫描期标志:面板扫描占无线电(iOS 扫描单槽),驱动重连
  /// 循环在此期间让位 —— 否则驱动的 8s scanForDeviceId 空扫反复顶掉
  /// 面板的 scanForPairing,发现事件断流、5s 过期剪行(2026-10-21 实
  /// 证:面板能发现设备但过一会就消失)。收口沿归还并续跑重连循环。
  bool _panelScanActive = false;

  /// 面板扫描起/止(ble_pair_panel._startScan 调用):true = 驱动重连
  /// 让位;false = 归还,链路在跑且会话在 idle/reconnecting 则续跑循环。
  void setPanelScanActive(bool active) {
    if (_panelScanActive == active) return;
    _panelScanActive = active;
    if (!active &&
        _bleRunning &&
        (_session.state == BleSessionState.idle ||
            _session.state == BleSessionState.reconnecting)) {
      _scheduleBleRetry();
    }
  }

  void _scheduleBleRetry() {
    _bleRetry?.cancel();
    if (!_bleRunning) return;
    if (_panelScanActive) return; // 面板扫描占台:驱动让位(收口沿归还)
    if (_session.autoReconnectPaused) return; // 深睡暂停:只有手动连接能解除
    _bleRetry = Timer(_session.nextRetryDelay, () async {
      if (!_bleRunning) return;
      if (_panelScanActive) return; // 在途尝试结束后不再续棒(面板扫描期)
      if (_session.autoReconnectPaused) return; // 暂停沿(定时器在途)
      // 无参调用 = 深睡闸门开:扫到待机广播即停止自动重连(会话置
      // autoReconnectPaused 并回 idle),只有手动连接才尝试唤醒。
      var ok = await _session.retryReconnect();
      if (bleRetryRearm(
          ok: ok,
          running: _bleRunning,
          state: _session.state,
          hasIdentity: _session.identity != null,
          paused: _session.autoReconnectPaused)) {
        _scheduleBleRetry();
      }
    });
  }

  /// 注入层对齐(幂等,翻面沿与 ready 沿均可直调):开关开 → 挂定位流
  /// 订阅 + 链路可用时起平台流;关 → 订阅与平台流一起收。链路层不沾。
  void _syncInjectLayer() {
    _session.geoEnabled = _bleInjecting; // 开关投影:关断即停保鲜重发
    if (_bleInjecting) {
      _bleFixSub ??= _locationStream.stream().listen(
            _onLocation,
            onError: (Object e) => _session.lastError = (
              key: 'ble.locationStreamFail',
              args: {'e': e.toString()},
            ),
          );
      if (_session.state == BleSessionState.ready || _ptpReady) {
        unawaited(_startLocationStream());
      }
      _flushCachedPtpFix();
    } else if (_bleFixSub != null) {
      _teardownInjectLayer();
    }
  }

  /// PTP 可用沿补写最近定位点(定位常早于 Wi-Fi 连接;流按 3m 位移
  /// 触发,静止时不会再发,不补写就要等用户移动)。
  void _flushCachedPtpFix() {
    final fix = _lastFix;
    if (fix == null || !_ptpReady) return;
    final now = DateTime.now().toUtc();
    if (_ptpBackoffActive(now) || !_ptpGpsDue(fix, now)) return;
    unawaited(_writePtpGps(fix));
  }

  /// 定位到达:Wi-Fi PTP 在(且未退避)优先 0x9523,按 30s/5m 节流;
  /// 否则走既有 BLE 0x2007(会话 ready 才落,未 ready 由会话缓存/丢弃)。
  void _onLocation(LocationSample sample) {
    final fix = GeoFix(
      latitude: sample.latitude,
      longitude: sample.longitude,
      altitude: sample.altitude,
      // iOS 无卫星数 API。真机 2026-10-13:填 0 相机按「无定位」
      // 处理 —— EXIF 只落 GPS 空壳(仅 VersionID)不写坐标,故
      // 填常规可视卫星数(坐标本身是真实的,卫星数仅为修饰)。
      satellites: 8,
      utcTime: DateTime.now().toUtc(),
    );
    _lastFix = fix;
    final now = DateTime.now().toUtc();
    if (_ptpReady && !_ptpBackoffActive(now)) {
      if (_ptpGpsDue(fix, now)) unawaited(_writePtpGps(fix));
      return; // PTP 已持有位置:不再写 BLE(同点位重复写无收益)
    }
    _session.onFix(fix);
  }

  bool _ptpBackoffActive(DateTime now) {
    final until = _ptpBackoffUntil;
    return until != null && now.isBefore(until);
  }

  bool _ptpGpsDue(GeoFix fix, DateTime now) {
    final last = _ptpLastOkFix;
    final at = _ptpLastOkAt;
    if (last == null || at == null) return true;
    if (now.difference(at) >= _ptpGpsInterval) return true;
    return BleKeepalive.distanceM(last, fix) >= _ptpGpsDistanceM;
  }

  /// 写一次 0x9523。失败(相机拒/USB 等)退避 60s 并立即回落 BLE;
  /// 在途去重:一次 PTP 事务期间新定位点直接丢弃(下一拍再取)。
  Future<void> _writePtpGps(GeoFix fix) async {
    final write = _ptpGpsWrite;
    if (write == null || _ptpWriteInFlight) return;
    _ptpWriteInFlight = true;
    try {
      final ok = await write(fix);
      if (ok) {
        _ptpLastOkFix = fix;
        _ptpLastOkAt = DateTime.now().toUtc();
        _ptpBackoffUntil = null;
        AppLog.i(AppLog.ble, 'GEO→0x9523 已写入');
      } else {
        _ptpBackoffUntil = DateTime.now().toUtc().add(_ptpGpsBackoff);
        AppLog.w(AppLog.ble, 'GEO→0x9523 被拒,60s 内回落 BLE');
        _session.onFix(fix);
      }
    } on Exception catch (e) {
      _ptpBackoffUntil = DateTime.now().toUtc().add(_ptpGpsBackoff);
      AppLog.w(AppLog.ble, 'GEO→0x9523 失败($e),60s 内回落 BLE');
      _session.onFix(fix);
    } finally {
      _ptpWriteInFlight = false;
    }
  }

  /// 停驱动循环(tick/重试/订阅/注入层),保留 BLE 链路本身。恢复时
  /// [_startBleInjection] 按当前会话态续上(ready → 注入层;idle/
  /// reconnecting → 重试循环)。[keepInject] = true 时保留定位流订阅
  /// (PTP-only 注入在 BLE 链路关闭后继续)。
  void _stopBleDriverLoop({bool keepInject = false}) {
    _bleRetry?.cancel();
    _bleRetry = null;
    _bleTick?.cancel();
    _bleTick = null;
    _instanceWatch?.stop(); // 看门狗随驱动停(无无线电即无战争面)
    unawaited(_bleStateSub?.cancel());
    _bleStateSub = null;
    if (!keepInject) _teardownInjectLayer();
  }

  /// 注入层收口:定位流订阅 + 平台流停。
  void _teardownInjectLayer() {
    _locationStreamUp = false;
    _lastFix = null;
    unawaited(_bleFixSub?.cancel());
    _bleFixSub = null;
    unawaited(() async {
      try {
        await _locationStream.stopStream();
      } on Exception {
        // 通道未实现(异端):流本就没起,无妨
      }
    }());
  }

  Future<void> _startLocationStream() async {
    try {
      await _locationStream.startStream();
      _locationStreamUp = true;
      AppLog.i(AppLog.ble, 'GPS location stream started');
    } on Exception catch (e) {
      // 定位源不可用(未授权/通道缺失):会话 TIME 心跳照常,零坐标注入
      AppLog.w(AppLog.ble, 'GPS location stream start failed: $e');
    }
  }
}
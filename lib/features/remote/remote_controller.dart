/// 遥控拍摄控制器:Live View 开关、快门释放、拍摄参数展示与调节。
///
/// 快门码选择:优先取相机 op 表 —— 在册 0x9207(落卡拍)直用
/// (OpenZCine 全系口径);表拿不到/不在册退标准 0x100E。运行期被拒
/// (0x2002/0x2005/0x2006/0x200F/0x2013)自动换另一码重发;0x9207 的
/// CaptureSort 首参被 0x201D 拒时按候选序换形(2026-10-06 真机:
/// [0,0] 在应用模式/接管态被拒),成功码/形缓存后续直发。
///
/// **APP 接管控制**(0x90C2 remote 模式,影控台同款):快门等参数受
/// 机身物理拨盘控制,启用接管(机身拨盘锁定)应用才能调整。进入路径
/// 二:①用户在拍摄页确认后 [enableTakeover];②USB 连接流兜底
/// (enableAppControl 的 0x90C2(1) 兜底,OpenZCine 同款 —— Zf 由此
/// 退出上传优先模式)在 connected 沿静默对齐。解除/断连由
/// [releaseTakeover] 与重连防御性收口(见 [_takeoverDangling])。
///
/// **连接即取景**(OpenZCine 口径:连接成功直接驱动进监看,相机侧由
/// 此进及时取景):本控制器在 connected 沿串链驱动([_onConnectedChain],
/// 2026-10-11 从 HomeShell 移入 —— 装配序使 HomeShell 的调用先于
/// _linkUp 置位,重连沿取景无人重启)。
/// 取景生命周期跟连接走 —— 0x9202 只在用户显式关取景或断连时发;
/// 拍摄页不可见只挂起帧轮询([setViewerVisible]),相机保持取景。
/// 应用侧**不因连接切 tab**(用户明示)。
///
/// 事件驱动:CaptureComplete(0x400D / 尼康 0xC102)提前收口拍照等待;
/// ObjectAdded(0x4002 / 0xC101)→「已拍摄」提示 + 参数刷新(**不下载**,
/// 纯遥控 —— 速传联动是 TODO T1 的独立功能);DevicePropChanged
/// (0x4006,机身拨盘/菜单改动)→ 定向刷新该参数(合并去抖)。真机
/// 核对:若事件在链路上不达,尼康走 GetEventEx 0x941C 轮询(OpenZCine/
/// libgphoto2 口径,另见 TODO)。
/// 0xC10C LiveViewStateChanged 不参与取景启停(语义未实证)。
///
/// 拍摄参数目录驱动([kShootingParams]):PropDesc(0x1014)自描述
/// (可写性/枚举域/范围域),裸值 0x1015 只作 PropDesc 不可用时的回退。
/// **值回读路由**(2026-10-06 真机「改了不同步」根因):厂商写路由的
/// 参数标准码不跟写 —— ISO 值读 0xD0B5(有效 ISO)、快门读写全走
/// 0xD100(打包分数,面板值即写值);标准码只供取值域/可写性参考。
/// 写路径(0x1016)三重门禁:[PtpSession.kSetPropEnabled] 总开关
/// (2026-10-05 生产已开,真机实证;保留作紧急关断)+ 相机 getSet
/// 上报(厂商写路由参数跳过 —— 标准码的 getSet 不代表厂商码可写性)
/// + 值域(枚举/范围外的值由相机 clamp,回读为准)。
///
/// 对焦域(候选码,待真机核对):点取景画面 → 0x9205 移动对焦区域 +
/// 0x90C1 驱动(对焦按钮单独驱动);「对焦后拍」开关把快门 0x9207
/// 首参换成 CaptureSort 0xFFFFFFFE(先 AF 后释放,OpenZCine 候选)。
/// 曝光读数轮换轮询:取景运行期间每 2s 刷三要素(机身重算曝光不发
/// 0x4006,OpenZCine 实测口径)。
///
/// 模式抄 BrowserController:构造器注入 + 断连门闩(_linkUp)+ _invalidate。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/object_entry.dart';
import '../../core/browser/object_repository.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/log/app_log.dart';
import '../../core/ptp/device_prop.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/frame_analyzer.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/intervalometer.dart';
import '../../core/remote/mf_travel_ends.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../debug/ptp_diagnostics.dart';
import '../../l10n/message.dart';
import 'bulb_close_policy.dart';
import 'shooting_param_catalog.dart';

/// 曝光三要素(只读快照;null = 该属性读取失败/未读)。
final class Exposure {
  const Exposure({this.fNumber, this.shutterRaw, this.iso});

  /// 光圈值 ×100(u16;280 = f/2.8,ISO 15740 定点)。
  final int? fNumber;

  /// 快门 0xD100 打包分数(num<<16|den;哨兵 0xFFFFFFFF=Bulb /
  /// 0xFFFFFFFE=X 同步 / 0xFFFFFFFD=Time;展示经目录 format)。
  final int? shutterRaw;

  /// ISO(u32;0xD0B5 有效 ISO,Auto ISO 时 = 机身当前应用值)。
  final int? iso;
}

/// 单个拍摄属性的 UI 状态:PropDesc(可写性/取值域)+ 当前值。
final class PropState {
  const PropState({this.desc, this.value});

  /// 0x1014 全描述;null = PropDesc 不可用(裸值回读,取值域未知)。
  final PtpDevicePropDesc? desc;

  /// 当前值(拍摄域属性全为整型;null = 读取失败)。
  final int? value;
}

/// 触控对焦框:归一化坐标(0..1,取景图像坐标系;页面按 BoxFit.contain
/// 映射回屏幕)。[focused] 由 0x90C1 应答推得:null = 对焦中/未知,
/// true = 合焦,false = 未合焦(0xA002)—— 框色跟机身屏对齐只有红绿
/// 两色(2026-10-12 用户定案:合焦绿、其余红);纯位置仍由点按替换、
/// 停取景/断连清除。
final class AfBox {
  const AfBox({required this.nx, required this.ny, this.focused});
  final double nx;
  final double ny;
  final bool? focused;
}

/// 应用内方向锁(拍摄页方向按钮):auto 跟随系统(仅初始态);landscape/
/// portrait 经 SystemChrome.setPreferredOrientations 强制(系统转屏锁
/// 开着也能切)。挂在常驻控制器上:页面重建不丢;但**离页即还竖**
/// (RemotePage._exitOrientationReset:横锁是监看页专属,SystemChrome
/// 却全局生效;锁态复位 portrait,再进从竖起步 —— 2026-10-08 真机
/// 反馈改制)。**点按只在横/竖锁间直切,不设回 auto 路径**(长按已按
/// 用户要求取消,2026-10-08)—— 空表在 iOS 是 All mask,会让系统按
/// 手机物理姿态重选方向(旋转锁开着时闪一圈,2026-10-08 真机日志
/// 定案),不能放进点按循环。
enum OrientationLock { auto, landscape, portrait }

/// 拍摄模式 = 相机真状态(0xD1A6 镜像:0=照片 / 1=视频)。跟随与切换
/// 都在控制器([cameraMode] / [switchMode]):拨杆翻转经 0x4006 事件
/// 实时跟随;接管持有下**两方向都可远程覆写**(2026-10-11 Zf 实证:
/// 写 0xD1A6 被接受、拍照门跟软件态),唯独录像门跟物理拨杆硬互锁
/// (照片档覆写视频后开录仍 0xA004)—— 录像按钮的拨杆提示在开录被拒
/// 时弹出。读不到 0xD1A6 的机身 [cameraMode] 为 null —— 页面回落本地
/// 模式条(纯 UI 行为选择,现状)。
enum CaptureMode { photo, video }

final class RemoteController extends ChangeNotifier {
  RemoteController({
    required this.session,
    this.connection,
    this.transferEngine,
    LiveViewEngine? engine,
    Future<void> Function(Duration)? delay,
    Future<void> Function(Duration)? aeDelay,
    bool Function()? setPropGate,
    this.isApMode,
  })  : engine = engine ?? LiveViewEngine(session: session),
        _delay = delay ?? Future<void>.delayed,
        _aeDelay = aeDelay ?? delay ?? Future<void>.delayed,
        _setPropEnabled = setPropGate ?? _sessionSetPropGate {
    this.engine.status.addListener(_onEngineStatus);
    this.engine.health.addListener(_onEngineHealth);
    this.engine.frame.addListener(_onFrame);
    this.engine.header.addListener(_onHeader);
    _statesSub = connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _reconnecting = false;
        final wasUp = _linkUp;
        _linkUp = true;
        if (!wasUp) {
          // 新连接(状态未离开的重复 connected 沿不重置):优化校准真名
          // 缓存与旗标重建;模式写拒缓存随会话死亡 —— 新会话再试一次。
          picCtrlNames.clear();
          _picCtrlNamesFetched = false;
          _picCtrlNamesBroken = false;
          _modeWriteRejected = false;
        }
        if (session.remoteModeActive) {
          // 连接流的开闩括号(0x90C2(1)→(0),enableAppControl)正常
          // 已退 remote:接管从 OFF 起步,机身回自己的取景屏。落到本
          // 分支 = 括号的退步被拒、remote 仍持有(拨盘锁定)—— 静默
          // 对齐接管态,芯片如实显示;可随时解除。门不会因此丢(单向
          // 闩,2026-10-07 v9 定案:退 remote 不关已开的 0x9201 门)。
          _takeoverDangling = false;
          _takeoverActive = true;
          this.engine.remoteHeld = true; // 取景自愈梯不得再碰 0x90C2(会杀会话写入)
        } else if (_takeoverDangling) {
          // 上次断链时还持有 remote 模式:防御性解除(机身拨盘可能仍
          // 锁定,OpenZCine 同款「photo 模式重入先复位」口径)。
          _takeoverDangling = false;
          unawaited(_endRemoteModeQuietly());
        }
        unawaited(_onConnectedChain());
      } else if (s == CameraLinkState.reconnecting) {
        // 断链自动恢复期:按断连收口门闩(停引擎/清态,迟到的参数值/
        // 事件被挡),但**不弹页** —— 页面保留冻结帧等重连成功;横幅由
        // reconnecting getter 驱动。
        _reconnecting = true;
        _invalidate();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _reconnecting = false;
        _invalidate();
      }
    });
    _eventsSub = session.events.listen(_onEvent);
    // 监看辅助:帧分析挂引擎帧通知(禁用时零开销,开关由页面拨)。
    analyzer.attach(this.engine.frame);
  }

  static bool _sessionSetPropGate() => PtpSession.kSetPropEnabled;

  final PtpSession session;
  final CameraConnection? connection;

  /// 当前连接是否 AP 方式(装配沿接 ConnectionController.method;取景
  /// 失败引导的门槛 —— AP 人设取景门随接管开,STA 门天然开不出此引导,
  /// USB 另有因;测试注入可空 = 非 AP)。
  final bool Function()? isApMode;

  /// 便捷判定(装配缺失按非 AP)。
  bool get apMode => isApMode?.call() ?? false;
  final LiveViewEngine engine;

  /// 图库导入通道(SDRAM 直拍收尾用):生产装配 [TransferEngineImpl],
  /// null = 未接(直拍对象停在「已取回句柄」提示)。接口类型 —— 测试
  /// 注假实现。
  final TransferEngine? transferEngine;

  /// 监看辅助帧分析(直方图/斑马纹)。
  final FrameAnalyzer analyzer = FrameAnalyzer();
  final Future<void> Function(Duration) _delay;

  /// AE 轮询节拍(测试注入独立门控,与 [_delay] 分离 —— 共享门控时
  /// AE 拍与忙退避会互抢放行次序);默认与 [_delay] 同源。
  final Future<void> Function(Duration) _aeDelay;

  /// 写门禁:生产恒取 [PtpSession.kSetPropEnabled](真机实证已开,
  /// 紧急关断时这里同步收口);测试注入覆写以覆盖写路径。
  final bool Function() _setPropEnabled;

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

  /// 即拍即览:最近一张的缩略图(0x100A,几秒后清;null = 无)。
  Uint8List? reviewThumb;

  /// 即拍即览清理计时(新照片到达即重置)。
  Timer? _reviewTimer;

  /// 本会话被相机拒绝过(0x200F)的参数 → 读出条锁标(OpenZCine
  /// lockedControls 口径;写成功或断连即清)。
  final lockedProps = <int>{};

  // ---- 拍摄模式(0xD1A6 镜像:跟随 + 远程切换)----

  /// 相机当前拍摄模式(照片/视频);null = 未读到(旧机身无此属性/
  /// 连接沿读失败)—— 页面回落本地模式条。连接沿初读、0x4006 事件
  /// 跟随([_onEvent])、切换链定态([switchMode])三处更新。
  CaptureMode? _cameraMode;
  CaptureMode? get cameraMode => _cameraMode;

  /// 换档落位(唯一入口):翻转沿把张数/可录时长一并作废 —— 它们是
  /// 旧档口径(0xD1F1 在视频档被录像估算污染,切回照片沿会先闪旧值
  /// 再被链首新鲜读纠正),清空等新鲜读,胶囊宁缺不错。
  void _setCameraMode(CaptureMode? m) {
    if (m == _cameraMode) return;
    _cameraMode = m;
    shotsRemaining = null;
    videoRemainingMs = null;
  }

  /// 拨杆真档(非覆写期 0xD1A6 读值的落点):与 [cameraMode] 同步更新;
  /// 覆写期读值被软件态遮蔽、真档不可见,不再跟随 —— 释放接管后的读回
  /// 对表([releaseTakeover])。不变式:[cameraMode] 非 null ⇒ 本值非 null。
  CaptureMode? _dialMode;
  CaptureMode? get dialMode => _dialMode;

  /// 软件态可能在偏离拨杆真档(我们的 0xD1A6 覆写活着;覆写只在接管
  /// 持有期保值)。**一旦写过即置位**:拨杆真档从此被软件态遮蔽(读值
  /// 只见回声),连「切回 believed 拨杆档」也不清它 —— 拨杆可能已被拨
  /// 过,真相只能靠新鲜读([releaseTakeover] 的释放后读回 /
  /// [refreshCameraMode] 读到不同值)。覆写随接管释放/断链死亡:释放沿
  /// 读回对表、断链沿对齐拨杆真档([_invalidate])。录像门跟物理拨杆
  /// —— 照片档覆写视频后开录仍被拒,拨杆提示在开录时弹出(不预判拦截)。
  bool _modeOverridden = false;
  bool get modeOverridden => _modeOverridden;

  /// 本会话模式写已被相机拒(try-and-see 能力缓存:0x1016 对 0xD1A6
  /// 的可写性 PropDesc 报不出 —— Zf getSet=False 但接管下可写)。拒过
  /// 一次即两方向灰显,不再反复试探。
  bool _modeWriteRejected = false;
  bool get modeWriteRejected => _modeWriteRejected;

  /// 模式切换链在途(接管 → 写 0xD1A6 → 重启取景 → 刷参);期间模式
  /// 条锁、快门行为不变到链尾定态。
  bool _switchingMode = false;
  bool get switchingMode => _switchingMode;

  // ---- 自拍定时 ----

  /// 自拍档位:0 = 关;> 0 = 秒数(倒计时后释放,期间可再点取消)。
  int selfTimerSeconds = 0;

  /// 自拍倒计时剩余秒(null = 未在倒计时)。
  int? get selfTimerCountdown => _selfTimerLeft;
  int? _selfTimerLeft;
  bool _selfTimerRunning = false;
  static const _selfTimerTick = Duration(seconds: 1);

  /// 选自拍档位(0/2/5/10s;正在倒计时时切换即取消当前倒计时)。
  void setSelfTimer(int seconds) {
    if (seconds == selfTimerSeconds && !_selfTimerRunning) return;
    _cancelSelfTimer();
    selfTimerSeconds = seconds;
    notifyListeners();
  }

  void _cancelSelfTimer() {
    _selfTimerRunning = false;
    _selfTimerLeft = null;
  }

  /// 快门按下带自拍:倒计时(可取消)到点释放;档位 0 = 直接拍
  /// ([fire] 是异步动作,统一 await —— 按下的 Future 才真正盖住整段)。
  Future<void> _runSelfTimerThen(Future<void> Function() fire) async {
    if (selfTimerSeconds <= 0) {
      await fire();
      return;
    }
    if (_selfTimerRunning) return;
    _selfTimerRunning = true;
    _selfTimerLeft = selfTimerSeconds;
    notifyListeners();
    for (;;) {
      await _delay(_selfTimerTick);
      if (!_selfTimerRunning) return; // 被取消(切档/再点/断连)
      final left = _selfTimerLeft = _selfTimerLeft! - 1;
      if (left > 0) {
        notifyListeners();
        continue;
      }
      _selfTimerRunning = false;
      _selfTimerLeft = null;
      notifyListeners();
      await fire();
      return;
    }
  }

  /// 拍摄参数写入中(编辑面板防连点)。
  bool writing = false;

  // ---- 间隔拍摄(延时摄影)----

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

  IntervalometerStatus get intervalStatus => _interval.status;
  bool get intervalActive => _interval.active;
  int get intervalTaken => _interval.taken;
  int get intervalAttempted => _interval.attempted;
  int get intervalFailed => _interval.failed;
  int? get intervalShotCount => _interval.config?.shotCount;

  /// 调度器原句(测试拨小就绪预算/失败阈值用)。
  Intervalometer get intervalometer => _interval;

  /// 本轮收口 Future(测试 await 用)。
  Future<void> get intervalDone => _interval.done;

  /// 启动间隔拍摄。入口互锁(全部 notice 指路不炸):B 门/Time 曝光中
  /// (按住或定时)、录像中、SDRAM 直拍开(逐拍回传图库与紧间隔冲突)、
  /// 自拍倒计时中、单拍/连拍在途。间隔/张数域钳制见 [IntervalConfig]。
  void startInterval({required int intervalSeconds, int? shotCount}) {
    if (_interval.active) return;
    if (!_linkUp) {
      notice = (key: 'remote.ivNotConnected', args: null);
    } else if (_shutterIsOpenShutter ||
        _openShutterHeld ||
        _bulbExposureLeft != null) {
      notice = (key: 'remote.ivBulbOpen', args: null);
    } else if (recording) {
      notice = (key: 'remote.ivRecordingBusy', args: null);
    } else if (sdramCapture) {
      notice = (key: 'remote.ivSdramBusy', args: null);
    } else if (selfTimerCountdown != null) {
      notice = (key: 'remote.ivSelfTimerBusy', args: null);
    } else if (capturing) {
      notice = (key: 'remote.ivCapturingBusy', args: null);
    } else {
      _interval.start(IntervalConfig(
        interval: Duration(seconds: intervalSeconds),
        shotCount: shotCount,
      ));
      return; // start 已通知(_onIntervalChanged 转发)
    }
    notifyListeners();
  }

  void pauseInterval() => _interval.pause();
  void resumeInterval() => _interval.resume();
  void stopInterval() => _interval.stop();

  /// 间隔拍摄单拍执行器:UI 静默(错误只记账,跳拍策略;进度由状态行
  /// 透出),链路/B 门守卫复用 capture 口径。capturing 逐拍置位 —— 屏
  /// 上快门芯随拍闪忙,与手动单拍观感一致。
  Future<(bool, L10nMessage?)> _intervalShot() async {
    if (!_linkUp) return (false, (key: 'remote.notConnected', args: null));
    if (_shutterIsOpenShutter) {
      return (false, (key: 'remote.ivSkipBulb', args: null));
    }
    capturing = true;
    notifyListeners();
    try {
      return await _captureOnce();
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  /// 调度器状态/记账变化 → 转发刷新;一轮收口时把摘要上 notice
  /// (completed/autoStopped/stopped 三态文案)。断链沿的 stop 先于
  /// _invalidate 清 notice,不残留「已停止」横幅。
  void _onIntervalChanged() {
    if (_disposed) return;
    final iv = _interval;
    if (iv.status == IntervalometerStatus.stopped &&
        iv.stopReason != null) {
      switch (iv.stopReason!) {
        case IntervalStopReason.completed:
          notice = iv.failed == 0
              ? (key: 'remote.ivDoneAll', args: {'n': iv.taken})
              : (key: 'remote.ivDone',
                  args: {'n': iv.taken, 'f': iv.failed});
        case IntervalStopReason.autoStopped:
          notice = (
            key: 'remote.ivAutoStop',
            args: {'f': iv.consecutiveFailures, 'n': iv.taken},
          );
        case IntervalStopReason.stopped:
          notice = iv.failed == 0
              ? (key: 'remote.ivStoppedAll', args: {'n': iv.taken})
              : (key: 'remote.ivStopped',
                  args: {'n': iv.taken, 'f': iv.failed});
      }
    }
    notifyListeners();
  }

  L10nMessage? error;

  /// 「已拍摄」提示(ObjectAdded 事件驱动;下一次操作时清)。
  L10nMessage? notice;

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
  bool propWritable(int propCode) {
    if (!_setPropEnabled()) return false;
    final param = shootingParamByCode[propCode];
    if (param == null || param.readOnly) return false;
    if (_autoControlled(propCode)) return false;
    // 厂商写路由 / 取值域直供 / 拨盘拥有参数:标准码的 getSet 与 desc
    // 都不作数(真机:0x500F/0x500D 报只读但 0xD0B4/0xD100 可写;
    // 0x500E 拨盘拥有报只读 —— 接管(0x90C2 锁转盘)后可写;厂商码
    // PropDesc 拒答时 desc 为空但 pickValues 面板照常可用)。
    if (param.writeCode != null ||
        param.pickValues != null ||
        param.dialOwned) {
      return true;
    }
    return paramProps[propCode]?.desc?.getSet ?? false;
  }

  // ---- 曝光变量模式门(OpenZCine stillAllows* 同款)----

  /// 静照自动 ISO(0xD0B5 读到的有效 ISO 是机身应用值);null = 未读/
  /// 拒答,不猜。与手动 ISO 值互不干扰(用户口径:开关只由面板的
  /// 「自动 ISO」控制,选手动值不联动开关)。
  bool? isoAuto;

  /// 模式值(U 档 0x805x 段):U 档按内部程序跑,不猜锁交给相机应答。
  static bool _isUserMode(int mode) =>
      mode >= 0x8050 && mode <= 0x8053;

  /// 模式门判定:模式未读(null)或 U 档 → 不锁;否则看 [allowed]。
  bool _modeAllows(Set<int> allowed) {
    final mode = paramProps[PtpDevicePropCode.exposureProgramMode]?.value;
    if (mode == null || _isUserMode(mode)) return true;
    return allowed.contains(mode);
  }

  /// 快门可调:M/S(其余模式机身拥有,A 下快门是自动曝光变量)。
  bool get shutterAdjustable =>
      _modeAllows({1, 4}); // M / S

  /// 光圈可调:M/A。
  bool get apertureAdjustable => _modeAllows({1, 3});

  /// 手动 ISO 可调:P/S/A/M(场景档拥有感光度,OpenZCine 同款门)。
  bool get isoManualAllowed => _modeAllows({1, 2, 3, 4});

  /// 该参数当前是否被写入门拦下(芯片置灰):模式门锁定的快门/光圈
  /// + 场景档锁定的 ISO(自动 ISO 开着**不拦** —— 开关与手动值互不
  /// 干扰,见 [isoAuto];显示标注照打,由「自动 ISO」开关显式控制)。
  bool _autoControlled(int propCode) {
    switch (propCode) {
      case PtpDevicePropCode.exposureTime:
        return !shutterAdjustable;
      case PtpDevicePropCode.fNumber:
        return !apertureAdjustable;
      case PtpDevicePropCode.exposureIndex:
        return !isoManualAllowed;
      default:
        return false;
    }
  }

  /// 该参数当前是否由相机自动控制(页面芯片「(自动)」标注):模式门
  /// 锁定 + 自动 ISO 开启(此时显示的是 0xD0B5 工作值)。
  bool paramAutoControlled(int propCode) {
    if (propCode == PtpDevicePropCode.exposureIndex && isoAuto == true) {
      return true;
    }
    return _autoControlled(propCode);
  }

  /// 控制器无 BuildContext:error/notice 类动态串按既定决策维持中文
  /// 回落;内嵌的参数名/模式名从 zh 词表取渲染形态,避免键名上屏
  /// (2026-10-16:label 键化后 `${p.label}` 直插会显示 ns.key)。
  /// 当前模式展示键(错误提示 {m} 参数用;未读为 null)。渲染端
  /// arg-t 落地,键查不到直通(枚举表外裸值)。
  String? get _modeLabel {
    final mode = paramProps[PtpDevicePropCode.exposureProgramMode]?.value;
    if (mode == null) return null;
    return shootingParamByCode[PtpDevicePropCode.exposureProgramMode]
        ?.display(mode);
  }

  /// 自动 ISO 开关(0xD054,u8):开 = ISO 面板「自动」项;关后手动值
  /// 生效。开关后 ISO 值随即回读(0xD0B5 工作值跟随)。
  Future<void> setIsoAuto(bool enabled) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    writing = true;
    error = null;
    notifyListeners();
    try {
      await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.stillIsoAutoControl,
          dataType: PtpDataType.uint8,
          value: enabled ? 1 : 0));
      isoAuto = enabled;
      await _refreshProp(PtpDevicePropCode.exposureIndex);
    } on Exception catch (e) {
      if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.accessDenied) {
        error = (
          key: 'remote.autoIsoFailDial',
          args: {'e': e.toString()},
        );
      } else {
        error = (key: 'remote.autoIsoFail', args: {'e': e.toString()});
      }
    } finally {
      writing = false;
      if (_linkUp) notifyListeners();
    }
  }

  // ---- APP 接管控制(0x90C2 remote 模式)----

  /// 接管是否生效(机身拨盘锁定,host 才能调拨盘拥有的参数)。
  bool _takeoverActive = false;
  bool get takeoverActive => _takeoverActive;

  /// 断链时还持有接管 → 重连后防御性解除(机身拨盘可能仍锁定)。
  bool _takeoverDangling = false;

  /// 启用 APP 接管控制(0x90C2 [1] = remote 模式,影控台同款):机身
  /// 拨盘锁定、屏幕可能熄灭;host 写入的会话值仅在持有期保值。
  /// 失败置 [error] 返回 false(0xA003 等,拨盘在释放/AF 中时会被拒)。
  Future<bool> enableTakeover() async {
    if (_takeoverActive) return true;
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return false;
    }
    try {
      await session.changeCameraMode(1);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.takeoverFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
      );
      notifyListeners();
      return false;
    } on Exception catch (e) {
      error = (key: 'remote.takeoverFail', args: {'e': e.toString()});
      notifyListeners();
      return false;
    }
    _takeoverActive = true;
    engine.remoteHeld = true; // 取景自愈梯不得再碰 0x90C2(会杀会话写入)
    error = null;
    notifyListeners();
    return true;
  }

  /// 解除接管(0x90C2 [0];尽力而为,链路将断时的拒绝不影响本地状态)。
  /// 模式覆写随解除死亡:软件态回拨杆真档 —— 拨杆在覆写期可能被拨过
  /// (读值被软件态遮蔽,我们看不见),不能凭旧态猜,释放后读回对表。
  Future<void> releaseTakeover() async {
    if (!_takeoverActive) return;
    final wasOverridden = _modeOverridden;
    _takeoverActive = false;
    _modeOverridden = false;
    engine.remoteHeld = false;
    notifyListeners();
    await _endRemoteModeQuietly();
    if (wasOverridden) await refreshCameraMode();
  }

  Future<void> _endRemoteModeQuietly() async {
    try {
      await session.changeCameraMode(0);
    } on Exception {
      // 尽力而为
    }
  }

  /// 无线取景失败占位的引导动作(2026-10-15 AP 三轮真机定案):开启
  /// 接管(0x90C2(1) 持有)后自动重试取景 —— AP 人设的取景门随接管
  /// 开(连接括号的 0x90C2(0) 退闩即关,未持有态 0x9201 回 OK 假成);
  /// 持有态起景为真。接管态机身停「已连接到计算机」屏 + 拨盘锁定,
  /// 解除即还(影控台同款);USB 不走此路(连接流已开闩,失败另有因)。
  /// 重试仍失败落既有占位(取景开启失败带梯),不吞错。
  /// 同日深夜起降为**兜底**:AP 连接沿已主动接管([_onConnectedChain]),
  /// 落到本引导 = 连接沿开闩被拒/总闸关,用户手动补一拍。
  Future<void> enableTakeoverAndRetryLiveView() async {
    if (!await enableTakeover()) return;
    await toggleLiveView();
  }

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

  // ---- SDRAM 直拍(0x90CB AF+SDRAM 一体拍,对象不入卡)----

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

  /// 方向锁(会话级):图标与循环读这里,页面只发切换与系统下发。
  final orientationLock = ValueNotifier<OrientationLock>(OrientationLock.auto);

  /// 触控对焦框位置;null = 无。
  AfBox? afBox;

  /// 对焦驱动进行中(对焦按钮 / 触控对焦共用,期间防重入)。
  bool focusing = false;

  bool _focusBeforeCapture = false;

  /// 对焦后拍:快门 0x9207 首参 CaptureSort —— true = 0xFFFFFFFE(先
  /// 驱动 AF 再释放,半按-全按;OpenZCine 默认形态),false = 0xFFFFFFFF
  /// (直接释放不动焦点,保留触控对焦/手动焦;OpenZCine preserveFocus
  /// 形态)。0x0000 旧实证形只作 0x201D 回退(见 [_captureSortCandidates])。
  bool get focusBeforeCapture => _focusBeforeCapture;
  set focusBeforeCapture(bool v) {
    if (_focusBeforeCapture == v) return;
    _focusBeforeCapture = v;
    notifyListeners();
  }

  /// 本轮会话已验证可用的快门码(0x100E / 0x9207)。断连不清:相机
  /// 个性跨连接稳定,重连后直发省一次失败事务。
  int? _captureOpPref;

  /// 本轮会话已验证可用的 0x9207 首参 CaptureSort(直接释放路径)。
  int? _captureSortPref;

  /// 0x9207 首参 CaptureSort 候选序:0xFFFFFFFF 直接释放(OpenZCine
  /// preserveFocus 形态)→ 0x00000000 旧实证形(2026-10-05 Zf 真机过,
  /// 2026-10-06 应用模式/接管态被 0x201D 拒)→ 0xFFFFFFFE 先 AF 后
  /// 释放(OpenZCine 默认形态,兜底)。0x201D(InvalidParameter)按序
  /// 换形重试,成功形缓存。
  static const _captureSortCandidates = <int>[0xFFFFFFFF, 0x00000000, 0xFFFFFFFE];

  /// 快门码回退信号集:相机明说「此码不对/不允许」的响应码 → 换另一
  /// 码重发。忙(0x2019)/会话/链路/参数域(0x201D,由 CaptureSort
  /// 换形处理)类错误不在其列。2026-10-06 真机补 0x2013 与 0x200F。
  static const _captureFallbackFrom = {
    PtpResponseCode.generalError,
    PtpResponseCode.operationNotSupported,
    PtpResponseCode.parameterNotSupported,
    PtpResponseCode.storeNotAvailable,
    PtpResponseCode.accessDenied,
  };

  /// 快门码选择:SDRAM 直拍开 = 0x90CB AF+SDRAM 一体(不入卡,收尾见
  /// [_collectSdramObject]);被拒(码级)自动回落常规码入卡 —— 照片不因
  /// 直拍拒而丢。返回 = (是否真发了 0x90CB, 回落提示):false 时拍照收尾
  /// 走常规卡拍流程,提示由 capture() 落收口后(防被 ObjectAdded 的
  /// 「已拍摄」冲掉)。否则首选码按相机 op 表(在册 0x9207 直用,
  /// OpenZCine 全系口径 —— Zf 在册;表拿不到退标准 0x100E)。0x9207 的
  /// CaptureSort 首参按 [_captureSortCandidates] 序换形(0x201D);被拒
  /// (码级)自动换另一码,成功后缓存。0x2013(存储不可用)转友好提示。
  Future<(bool, L10nMessage?)> _fireShutter() async {
    L10nMessage? fallbackNotice;
    if (sdramCapture && !_sdramCaptureDropped) {
      if (_shutterIsOpenShutter) {
        // B 门/Time 哨兵:直拍族(0x90C0/0x90CB)规格明文不支持长曝档
        //(0xA008 Shutter_Speed_Bulb / 0xA204 Shutter_Speed_Time,官方
        // §6.2.4.2/.3;2026-10-17 真机实证)—— 本地跳过零流量,直接走
        // 0x9207 按住/定时 B 门路,照片照旧入卡,如实提示。
        fallbackNotice = (key: 'remote.sdramBulbFallback', args: null);
      } else {
        try {
          await session.afAndCaptureRecInSdram();
          return (true, null);
        } on PtpResponseException catch (e) {
          if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
          // 0x90CB 码级被拒:记回落提示后**贯穿**到常规拍摄链(照片必须
          // 实拍入卡,这里只换机制)。模型级拒绝(0x2005)记本会话不再
          // 重试;状态类(0x200F/0x2013)逐拍回试 —— 拨杆拨回、卡归位后
          // 直拍仍可用。
          final dropped =
              e.responseCode == PtpResponseCode.operationNotSupported;
          if (dropped) _sdramCaptureDropped = true;
          final code = '0x${e.responseCode.toRadixString(16).toUpperCase()}';
          fallbackNotice = (
            key: 'remote.sdramRejected',
            args: {
              'c': code,
              'tail': dropped ? 'remote.sdramNoRetry' : '',
            },
          );
        }
      }
    }
    final pref = _captureOpPref;
    if (pref == PtpOperationCode.initiateCapture) {
      await session.initiateCapture();
      return (false, null);
    }
    final info = session.cachedDeviceInfo;
    final mediaFirst = pref == NikonOperationCode.initiateCaptureRecInMedia ||
        info == null ||
        info.supportsOperation(NikonOperationCode.initiateCaptureRecInMedia);
    if (mediaFirst) {
      try {
        await _fireMedia();
        return (false, fallbackNotice);
      } on PtpResponseException catch (e) {
        if (pref != null || !_captureFallbackFrom.contains(e.responseCode)) {
          rethrow; // 已缓存码/参数域类错误:换码解决不了
        }
        // 首选 0x9207 被拒(码级):标准码一试
        await session.initiateCapture();
        _captureOpPref = PtpOperationCode.initiateCapture;
        return (false, fallbackNotice);
      }
    }
    try {
      await session.initiateCapture();
      _captureOpPref = PtpOperationCode.initiateCapture;
    } on PtpResponseException catch (e) {
      if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
      await _fireMedia();
    }
    return (false, fallbackNotice);
  }

  /// 0x9207 落卡拍:CaptureSort 按候选序换形(0x201D 参数域拒时),
  /// 成功形缓存。对焦后拍开 = 固定 0xFFFFFFFE(显式意图,不缓存覆盖);
  /// 关 = 缓存形/0xFFFFFFFF 起。
  Future<void> _fireMedia() async {
    _captureOpPref = NikonOperationCode.initiateCaptureRecInMedia;
    final preferred =
        _focusBeforeCapture ? 0xFFFFFFFE : (_captureSortPref ?? 0xFFFFFFFF);
    final forms = <int>[
      preferred,
      ..._captureSortCandidates.where((f) => f != preferred),
    ];
    Object? lastError;
    for (final sort in forms) {
      try {
        await session.initiateCaptureRecInMedia(captureSort: sort);
        if (!_focusBeforeCapture) {
          _captureSortPref = sort; // 直接释放路径:记住成功形
        }
        return;
      } on PtpResponseException catch (e) {
        if (e.responseCode != PtpResponseCode.invalidParameter) rethrow;
        lastError = e; // 换下一形
      }
    }
    throw lastError!; // 全部形态皆被拒:抛最后一个(上层转提示)
  }

  // ---- 连拍按住(OpenZCine shutterPressLatchedBurst 同款)----

  /// 按住中(释放档为连续):期间随就绪链发,抬起 [captureReleased] 终止。
  bool _burstLatched = false;

  /// 连拍括持已开(0x90C2 remote + burstNumber 65535)。
  bool _burstBracketHeld = false;
  int _burstRun = 0;
  int _burstFrames = 0;

  /// 链发上限(OpenZCine chainedBurstFrames < 30 同款,防失控)。
  static const int _burstFrameCap = 30;

  /// 释放档当前值是否连续(高速连拍/低速连拍/C15-C120)。
  static const _continuousDriveValues = {
    2, // 高速连拍
    0x8010, // 低速连拍
    0x810F, // C15
    0x811E, // C30
    0x813C, // C60
    0x8178, // C120
  };

  bool get _driveContinuous => _continuousDriveValues
      .contains(paramProps[PtpDevicePropCode.stillCaptureMode]?.value);

  /// 0xD100 开门哨兵(Bulb 0xFFFFFFFF / Time 0xFFFFFFFD;X 同步
  /// 0xFFFFFFFE 非按住曝光态不列)。与 [_shutterIsOpenShutter] 同源。
  static bool _isOpenShutterSentinel(int v) =>
      v == 0xFFFFFFFF || v == 0xFFFFFFFD;

  /// 快门当前值是否 Bulb/Time(0xD100 哨兵):**按住 = 开曝光,抬起
  /// 结束**(0x920C;OpenZCine pendingStillTerminate 同款语义)。
  bool get _shutterIsOpenShutter {
    final v = paramProps[PtpDevicePropCode.exposureTime]?.value;
    return v != null && _isOpenShutterSentinel(v);
  }

  /// 快门按钮**按下**(页面 onTapDown):
  /// - Bulb/Time:开曝光(按住中),[captureReleased] 抬起结束;自拍
  ///   档 > 0 时组合成**定时 B 门**(倒计时到点开门 → 同时长曝光倒计时
  ///   → 到点自动收门,见 [_openShutterPress]);
  /// - 连续释放档:连拍括持(0x90C2 remote + burstNumber 65535 —— 不
  ///   括持每次释放都会弹回单张,OpenZCine 同款)后释放,按住期间随
  ///   DeviceReady 就绪链发(上限 30 帧),抬起终止;
  /// - 普通档:自拍倒计时(档位 > 0)后一次 [capture]。
  Future<void> capturePressed() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      // 间隔拍摄运行中:屏上快门(含 B 门按住/连拍按住)全部让位,
      // 本地拒绝零流量 —— 停止间隔拍摄后再手动拍。
      notice = (key: 'remote.ivShutterYield', args: null);
      notifyListeners();
      return;
    }
    if (_bulbCloseFailed) {
      // 上次 B 门收门预算耗尽(曝光可能仍开着):这次按下不另开曝光,
      // 直接再试收门链 —— 「再点一次快门收门」的恢复路径。
      error = null;
      notice = null;
      notifyListeners();
      await _closeBulbExposure();
      return;
    }
    if (_shutterIsOpenShutter) {
      if (selfTimerSeconds > 0) {
        await _runSelfTimerThen(() => _openShutterPress(timed: true));
      } else {
        await _openShutterPress();
      }
      return;
    }
    if (!_driveContinuous) {
      await _runSelfTimerThen(capture); // 自拍档 > 0 时倒计时
      return;
    }
    if (capturing || _burstLatched) return;
    _burstLatched = true;
    _burstFrames = 0;
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      // 括持(尽力而为:失败不阻断 —— 释放档本身在机身上,可能仍连拍)
      try {
        await session.changeCameraMode(1);
        await session.setDevicePropValue(PtpDevicePropValue(
            code: PtpDevicePropCode.burstNumber,
            dataType: PtpDataType.uint16,
            value: 65535));
        _burstBracketHeld = true;
      } on Exception {
        // 括持失败:按单发链继续
      }
      final run = ++_burstRun;
      while (_burstLatched &&
          run == _burstRun &&
          _burstFrames < _burstFrameCap) {
        await _fireShutter();
        _burstFrames++;
        var ready = false;
        for (var i = 0;
            i < _capturePolls && _burstLatched && run == _burstRun && !ready;
            i++) {
          await _delay(_capturePollInterval);
          if (!_burstLatched || run != _burstRun) break;
          try {
            ready = await session.deviceReady();
          } on Exception {
            break; // DeviceReady 非忙错误:不再链发
          }
        }
        if (!ready) break; // 就绪超时:停链(用户可再按)
      }
    } on Exception catch (e) {
      error = (key: 'remote.errShutterFail', args: {'e': e.toString()});
    } finally {
      await _endBurstBracket();
      _burstLatched = false;
      _burstRun++;
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
  }

  // ---- B 门 / Time:按住开曝光 ----

  bool _openShutterHeld = false;

  /// 开拍(0x9207)在途:抬起若先于开拍落地,立即 0x920C 会扑空 ——
  /// 记 [_bulbClosePending],开拍任务落地后自行收门。
  bool _bulbOpening = false;
  bool _bulbClosePending = false;

  /// 上次收门预算耗尽(曝光可能仍开着):下一次按下转为收门重试。
  bool _bulbCloseFailed = false;

  /// 应用写过 Bulb/Time 哨兵前的快门值(收门链还原步;setParam 记录;
  /// 写前值本身是哨兵时保留更早记录 —— 还原目标永远是最后一个非哨兵值)。
  int? _bulbShutterRestore;

  /// 定时 B 门曝光剩余秒(null = 未在定时曝光)。
  int? get bulbExposureCountdown => _bulbExposureLeft;
  int? _bulbExposureLeft;

  /// Bulb/Time 按下:开曝光(0x9207 直发,不等待落地 —— 曝光持续到
  /// 抬起/定时到点)。[timed] = 定时 B 门(自拍定时 × B 门组合,
  /// 2026-10-15):开拍后同时长曝光倒计时,到点自动收门 —— 快拍一下
  /// = 延时 N 秒 + 定时 N 秒曝光,全程免按住;曝光中再点抬起 = 立即
  /// 手动收门。时长暂用自拍档位值(2/5/10s),更长档待后续。取景挂起
  /// 防事务挤占。
  Future<void> _openShutterPress({bool timed = false}) async {
    if (capturing || _openShutterHeld) return;
    _openShutterHeld = true;
    _bulbOpening = true;
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      final (_, sdramFallback) = await _fireShutter();
      if (sdramFallback != null) {
        // 直拍-B 门互斥改道等机制提示:曝光开始前如实带出(capture()
        // 路径的回落提示在收口带出,按住路径这里等效提前)。
        notice = sdramFallback;
        notifyListeners();
      }
      _bulbOpening = false;
      if (_bulbClosePending) {
        // 抬起先于开拍落地(极速点按):落地即收门,曝光开了就关。
        _bulbClosePending = false;
        await _closeBulbExposure();
        return;
      }
      if (timed) {
        _bulbExposureLeft = selfTimerSeconds;
        notifyListeners();
        while (_openShutterHeld && (_bulbExposureLeft ?? 0) > 0) {
          await _delay(_selfTimerTick);
          if (!_openShutterHeld) break; // 抬起已收门
          _bulbExposureLeft = _bulbExposureLeft! - 1;
          notifyListeners();
        }
        if (_openShutterHeld) {
          // 定时到点自动收门(检查-置位同步执行,与 captureReleased
          // 互斥,不会双收门)。
          _openShutterHeld = false;
          _bulbExposureLeft = null;
          notifyListeners();
          await _closeBulbExposure(autoClose: true);
        }
      } else {
        // 按住中:等抬起(不轮询 settle —— 曝光开着,DeviceReady 恒忙)
        while (_openShutterHeld) {
          await _delay(const Duration(seconds: 1));
        }
      }
    } on Exception catch (e) {
      error = (key: 'remote.errShutterFail', args: {'e': e.toString()});
    } finally {
      // 开拍失败也解锁:原实现失败路径漏置 false,后续按下被静默吞
      //(2026-10-15 收门鲁棒性收口)。
      _openShutterHeld = false;
      _bulbOpening = false;
      _bulbClosePending = false;
      _bulbExposureLeft = null;
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
  }

  /// 快门按钮**抬起**:B 门结束曝光(收门链 [_closeBulbExposure]:
  /// 恢复原快门值 → 0x920C → 忙等码有界重试,2026-10-15)/ 终止进行
  /// 中的连拍(0x920C,已拍帧保留;运行已自行结束时相机会拒绝,容忍)。
  /// 普通档点按无副作用。
  Future<void> captureReleased() async {
    if (_openShutterHeld) {
      _openShutterHeld = false; // 等待环/倒计时环收口
      _bulbExposureLeft = null;
      notifyListeners();
      if (_bulbOpening) {
        // 开拍(0x9207)尚未落地:立刻 0x920C 会扑空 —— 记收门请求,
        // 开拍任务落地后立即收门。
        _bulbClosePending = true;
      } else {
        await _closeBulbExposure();
      }
      return;
    }
    if (!_burstLatched) return;
    _burstLatched = false;
    _burstRun++; // 打断链发循环
    await _terminateCaptureWithRetry(); // 忙等码有界重试;终态容忍(原口径)
  }

  /// B 门收门链(结构借 N-link BulbPolicy 步序,不采纳其与本仓已证
  /// 事实冲突的步骤,详见 [BulbClosePolicy] 头注):
  /// ① 恢复原快门值([_bulbShutterRestore] 有记录且当前仍是哨兵):
  ///    曝光中写被拒不阻断②,关门后相机闲态补试一次;
  /// ② 0x920C TerminateCapture(已证收门路径,官方 §2.8.4 步 6);
  /// ③ 忙等码(0x2019/0xA200/0xA201)按 [BulbClosePolicy] 短退避有界
  ///    重试,预算耗尽如实上报([autoClose] = 定时到点自动收门,文案
  ///    区分);失败后下一次按下转为收门重试([_bulbCloseFailed])。
  Future<void> _closeBulbExposure({bool autoClose = false}) async {
    if (!_linkUp) return;
    final restore = _bulbShutterRestore;
    if (restore != null && _shutterIsOpenShutter) {
      if (await _tryRestoreShutter(restore)) _bulbShutterRestore = null;
    }
    final closed = await _terminateCaptureWithRetry();
    _bulbCloseFailed = !closed;
    if (!closed) {
      error = autoClose
          ? (key: 'remote.errTimedBulbBusy', args: null)
          : (key: 'remote.errBulbCloseBusy', args: null);
      notifyListeners();
      return;
    }
    if (_bulbShutterRestore != null && _shutterIsOpenShutter) {
      // ① 中途失败(曝光中写被拒)的补试:曝光已终止,相机闲态写最稳。
      if (await _tryRestoreShutter(_bulbShutterRestore!)) {
        _bulbShutterRestore = null;
      } else {
        notice = (key: 'remote.errShutterRestore', args: null);
        notifyListeners();
      }
    }
  }

  /// 恢复快门值(0xD100 写,路由同 setParam):成功后乐观对表(该写
  /// 路径已证「面板值即写值」;0x4006 事件再校),失败返回 false 由
  /// 调用方决定补试。
  Future<bool> _tryRestoreShutter(int value) async {
    try {
      final param = shootingParamByCode[PtpDevicePropCode.exposureTime]!;
      await session.setDevicePropValue(PtpDevicePropValue(
          code: param.writeCode ?? PtpDevicePropCode.exposureTime,
          dataType: param.writeType ?? PtpDataType.uint32,
          value: value));
      paramProps[PtpDevicePropCode.exposureTime] = PropState(
          desc: paramProps[PtpDevicePropCode.exposureTime]?.desc,
          value: value);
      notifyListeners();
      return true;
    } on Exception {
      return false; // 曝光中写被拒(0x200F 等)等形态:不阻断收门
    }
  }

  /// 0x920C 终止(B 门收门/连拍终止共用):忙等码(0x2019/0xA200/
  /// 0xA201)按 [BulbClosePolicy] 有界退避重试;非忙码 = 运行已自行
  /// 结束的预期形态,容忍收口;链路级异常命令命运未知,交给断连路径。
  /// 返回是否真正终止成功(预算耗尽 = false)。
  Future<bool> _terminateCaptureWithRetry() async {
    final policy = BulbClosePolicy();
    for (;;) {
      try {
        await session.terminateCapture();
        return true;
      } on PtpResponseException catch (e) {
        if (!BulbClosePolicy.isBusyCode(e.responseCode)) return true;
        final d = policy.nextBusyDelay();
        if (d == null) return false; // 预算耗尽:如实上报由调用方
        await _delay(d);
      } on Exception {
        return true; // 链路级:命令命运未知,断连路径接管
      }
    }
  }

  Future<void> _endBurstBracket() async {
    if (!_burstBracketHeld) return;
    _burstBracketHeld = false;
    if (_takeoverActive) return; // 用户接管还持有:remote 模式保持
    try {
      await session.changeCameraMode(0);
    } on Exception {
      // 解除尽力而为
    }
  }

  // ---- 录制(0x920A/0x920B)+ MF 步进(0x9204)----

  /// 录制开关:取景开启为前置(机身口径)。录制中拍照会被机身拒,
  /// 先提示。事件 0xC10A/0xC108 到达时对齐状态(双保险)。间隔拍摄
  /// 运行中禁开录(对「录像中禁启间隔」的对称互锁 —— 录像会让每拍
  /// 静照落空,先停轮再录)。
  Future<void> toggleRecord() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errRecordNeedsViewfinder', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      notice = (key: 'remote.ivRecYield', args: null);
      notifyListeners();
      return;
    }
    if (capturing) return;
    error = null;
    notifyListeners();
    try {
      if (recording) {
        await session.endMovieRec();
        recording = false;
        recordingSince = null;
      } else {
        await session.startMovieRec();
        recording = true;
        recordingSince = DateTime.now();
      }
    } on PtpResponseException catch (e) {
      if (e.responseCode == NikonResponseCode.invalidStatus) {
        // 0xA004:机身不在可录制的状态 —— Zf 的机顶「照片/视频」切换
        // 拨杆在照片档时 0x920A 即被拒(OpenZCine 同码口径 invalidStatus)。
        error = (key: 'remote.errLeverVideo', args: null);
      } else {
        error = (
          key: 'remote.errRecFail',
          args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
        );
      }
    } on Exception catch (e) {
      error = (key: 'remote.errRecFail', args: {'e': e.toString()});
    }
    notifyListeners();
  }

  /// MF 步进(0x9204):向近/远驱动一步([pulses] 脉冲,默认 300)。
  /// 取景挂起防事务挤占;结果转提示(行程尽头/步进过小是结果非错误,
  /// OpenZCine 口径),并按方向归因进端点态([MfTravelEnds],步进/滚轮
  /// 两路共用 —— 提示行与轮压暗跟读)。
  Future<void> mfDriveStep({required bool towardNear, int pulses = 300}) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (focusing) return;
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程拉焦同样失效
    error = null;
    notifyListeners();
    engine.pause();
    try {
      _noteMfDrive(towardNear); // 反向请求即解锁(nico 语义)
      final outcome =
          await session.mfDrive(towardNear: towardNear, pulses: pulses);
      _applyMfOutcome(towardNear: towardNear, outcome: outcome);
      if (outcome == MfDriveOutcome.complete ||
          outcome == MfDriveOutcome.endOfTravel) {
        // 刻度鼓按实际驱动入账;步进过小(0xA00E 镜头未动)与拒答不入。
        dialNetPulses.value += towardNear ? pulses : -pulses;
      }
      switch (outcome) {
        case MfDriveOutcome.complete:
          break;
        case MfDriveOutcome.endOfTravel:
          notice = towardNear
              ? (key: 'remote.focusNearEnd', args: null)
              : (key: 'remote.focusFarEnd', args: null);
        case MfDriveOutcome.stepTooSmall:
          notice = (key: 'remote.stepTooSmall', args: null);
        case MfDriveOutcome.refused:
          error = (key: 'remote.errMfUnavailable', args: null);
      }
    } finally {
      if (_viewerVisible) engine.resume();
      if (_linkUp) notifyListeners();
    }
  }

  /// 对焦滚轮拖动增量(竖直像素,正 = 向近 / 负 = 向远):攒够一步
  /// [_dialStepPx] 发一次 0x9204([_dialStepPulses] 脉冲/步,不足一步的
  /// 余量保留)。单在途:驱动进行中再拖,像素攒着,完成后续发 —— 命令
  /// 通道上永远最多一个滚轮事务。**不挂起取景**(跟焦要在画面上看
  /// 焦点变化,与 [mfDriveStep] 的单发路径不同)。AF 驱动(点按对焦/
  /// 对焦按钮)抢占:代数自增,在途脉冲发完后不再续发。
  ///
  /// 端点锁(0xA00C 方向归因,见 [MfTravelEnds]):目标方向端点已到
  /// → 该增量静默丢弃(不发 0x9204,省流量防错;余量保留 —— 反向
  /// 增量照常攒步)。拖动方向反转后首步请求即解锁([_noteMfDrive]),
  /// 轮身压暗随 [_mfEnds] 翻转。
  ///
  /// 拒答(0x9204 refused)不弃单:脉冲原量归还,退避
  /// [_dialRetryBackoff] 静默续发(瞬时拒答 = AF 收敛/STM 镜头初始化/
  /// 激活瞬时忙,OpenZCine 重排队口径);同一拒答连跑超
  /// [_dialRefusalGrace] 墙钟才暂停出提示。
  void focusDialDrag(double dy) {
    if (dy == 0 || !_linkUp || capturing) return;
    if (focusModeIsMf) {
      // 机身 MF:拖动无效。静默丢弃(拖动事件高频,不刷横幅)+ 清
      // 余量,防锁定解除瞬间陈旧增量爆发成一次误驱动。
      _dialAccum = 0;
      return;
    }
    if ((dy > 0 && _mfEnds.nearEnd) || (dy < 0 && _mfEnds.farEnd)) {
      // 端点锁:该方向没有更多行程,静默丢增量(反向余量保留)。
      return;
    }
    _dialAccum += dy;
    _dialPump();
  }

  /// 滚轮重新启用(开关从关到开时页面调;清失败预算、拒答连跑戳与余量)。
  void resetFocusDial() {
    _dialFailures.clear();
    _dialSuspended = false;
    _dialRefusalSince = null;
    _dialAccum = 0;
    dialNetPulses.value = 0;
  }

  /// 步进标定:24px 拖动 = 300 脉冲。**真机定案(2026-10-17 Zf + 24-120
  /// ƒ4 S)**:300 是唯一实证可见量(MF 步进按钮单发),60 脉冲/步弱到
  /// 看不见(拉焦轮「拉了没动」主因);等比标定天然带速度曲线 —— 慢拖
  /// 24px/s ≈ 300 脉冲/s,快甩十倍 ≈ 3000/s(OpenZCine 2 脉冲/dp 量级
  /// 偏弱,其「pulse feel per lens」本就标 verify-on-HW)。换算随机身
  /// /镜头,手感出入再调。
  static const double _dialStepPx = 24.0;
  static const int _dialStepPulses = 300;

  /// 失败墙钟预算:8s 窗口内 3 次失败 → 暂停滚轮(提示),窗口滑出
  /// 后再拖自动恢复。失败多为链路/状态类,无脑重试只会堵命令通道。
  static const _dialFailureWindow = Duration(seconds: 8);
  static const int _dialFailureLimit = 3;

  /// 拒答重试(0x9204 refused):瞬时拒答(AF 收敛/STM 镜头初始化/激活
  /// 瞬时忙)是常态,退避 [_dialRetryBackoff] 静默续发;同一拒答连跑超
  /// [_dialRefusalGrace] 墙钟(镜头拨杆 MF / 持续忙)才暂停出提示
  /// (OpenZCine wall-clock 预算同款口径)。
  static const _dialRetryBackoff = Duration(milliseconds: 150);
  static const _dialRefusalGrace = Duration(seconds: 4);

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

  /// 近端已到(0xA00C 向近归因;反向驱动/驱动成功/AF 移焦即清)。
  bool get mfNearEnd => _mfEnds.nearEnd;

  /// 远端已到(0xA00C 向远归因;反向驱动/驱动成功/AF 移焦即清)。
  bool get mfFarEnd => _mfEnds.farEnd;

  /// 一次 0x9204 派出:反向端点旗作废 + 端点态变化才广播(轮压暗/
  /// 提示行跟随;高频拖动下不额外刷监听)。
  void _noteMfDrive(bool towardNear) {
    final before = _mfEnds.anyEnd;
    _mfEnds.noteDrive(towardNear);
    if (_mfEnds.anyEnd != before) notifyListeners();
  }

  /// 一次 0x9204 结果归因落账(端点态变化才广播,同 [_noteMfDrive])。
  /// 行程尽头落锁时滚轮余量一并清零 —— 步进路径落锁时滚轮可能正攒
  /// 着同向余量,不清会在解锁后陈旧爆发成一次误驱动。
  void _applyMfOutcome(
      {required bool towardNear, required MfDriveOutcome outcome}) {
    final before = _mfEnds.anyEnd;
    _mfEnds.apply(towardNear: towardNear, outcome: outcome);
    if (outcome == MfDriveOutcome.endOfTravel) _dialAccum = 0;
    if (_mfEnds.anyEnd != before) notifyListeners();
  }

  void _dialPump() {
    if (_dialDriving) return;
    if (!_linkUp || !liveViewActive) {
      _dialAccum = 0; // 无链路/无取景:余量无意义,清掉防陈旧爆发
      return;
    }
    // 暂停中先看窗口:失败都滑出窗即自动恢复。
    if (_dialSuspended) {
      _pruneDialFailures();
      if (_dialFailures.length >= _dialFailureLimit) return;
      _dialSuspended = false;
    }
    final steps = _dialAccum ~/ _dialStepPx; // 截断除法:正负对称攒步
    if (steps == 0) return;
    final sentPx = steps * _dialStepPx;
    _dialAccum -= sentPx;
    final gen = _dialGen;
    final towardNear = steps > 0;
    final pulses = steps.abs() * _dialStepPulses;
    _noteMfDrive(towardNear); // 反向请求即解锁(nico 语义,镜头正离开该端)
    // 刻度鼓派发即入账(乐观,跟手):拒答重排队脉冲未弃单,不回冲。
    dialNetPulses.value += towardNear ? pulses : -pulses;
    _dialDriving = true;
    unawaited(() async {
      var requeued = false;
      try {
        final outcome =
            await session.mfDrive(towardNear: towardNear, pulses: pulses);
        _applyMfOutcome(towardNear: towardNear, outcome: outcome);
        switch (outcome) {
          case MfDriveOutcome.complete:
          case MfDriveOutcome.stepTooSmall:
            _dialRefusalSince = null;
            break; // 过小是结果:不提示(拖快些即可),不挡续发
          case MfDriveOutcome.endOfTravel:
            _dialRefusalSince = null;
            notice = towardNear
                ? (key: 'remote.focusNearEnd', args: null)
                : (key: 'remote.focusFarEnd', args: null);
            notifyListeners();
          case MfDriveOutcome.refused:
            // 瞬时拒答是常态:脉冲重排队(原量归还)退避静默续发,
            // 不横幅不清账(OpenZCine 同款);连跑超宽限才暂停出提示,
            // 并入失败预算同走 8s 窗恢复门。
            _dialAccum += sentPx;
            requeued = true;
            _dialRefusalSince ??= DateTime.now();
            if (DateTime.now()
                    .difference(_dialRefusalSince!) >=
                _dialRefusalGrace) {
              requeued = false;
              _dialSuspended = true;
              _dialAccum = 0;
              _dialRefusalSince = null;
              _dialFailures.add(DateTime.now());
              notice = (key: 'remote.focusDialPaused', args: null);
              notifyListeners();
            }
        }
      } on Exception catch (e) {
        if (!_linkUp) return; // 断连收口已清状态,迟到异常不计数
        if (e is PtpResponseException &&
            e.responseCode == PtpResponseCode.deviceBusy) {
          // 机身忙(别的驱动在途):不算失败,余量丢弃不堆积
          _dialAccum = 0;
          return;
        }
        _dialFailures.add(DateTime.now());
        _pruneDialFailures();
        if (_dialFailures.length >= _dialFailureLimit) {
          _dialSuspended = true;
          _dialAccum = 0;
          notice = (key: 'remote.focusDialPaused', args: null);
          notifyListeners();
        }
      } finally {
        _dialDriving = false;
        // 在途期间又拖了(或没被抢占):续发攒下的余量;拒答重排队走
        // 退避续发(瞬时忙/AF 收敛给机身喘息窗),代数守卫防 AF 抢占
        // 后陈旧续发。
        if (!_dialSuspended && gen == _dialGen && _linkUp) {
          if (requeued) {
            unawaited(_delay(_dialRetryBackoff).then((_) {
              if (gen == _dialGen && !_dialSuspended && _linkUp) _dialPump();
            }));
          } else {
            _dialPump();
          }
        }
      }
    }());
  }

  void _pruneDialFailures() {
    final cutoff = DateTime.now().subtract(_dialFailureWindow);
    _dialFailures.removeWhere((t) => t.isBefore(cutoff));
  }

  /// AF 驱动(同点再点对焦/对焦按钮)抢占在途滚轮:代数自增即止续发,
  /// 余量清零(AF 改变了焦点位置,攒的像素是陈旧意图);端点态同样
  /// 作废(AF 移焦后镜头不再顶在已记端点,nico clearMfLimits 同款)。
  /// 挪框(0x9205)**不**走这里 —— 不动镜,端点/余量照旧有效。
  void _preemptFocusDial() {
    _dialGen++;
    _dialAccum = 0;
    _mfEnds.clear();
  }

  /// 录制时长(秒;未录制为 null)。
  int? get recordingSeconds => recordingSince == null
      ? null
      : DateTime.now().difference(recordingSince!).inSeconds;

  /// DeviceReady 轮询兜底:300ms × 10(CaptureComplete 事件先到则提前)。
  static const _capturePollInterval = Duration(milliseconds: 300);
  static const int _capturePolls = 10;

  void _onEngineStatus() {
    if (engine.status.value == LiveViewStatus.failed && engine.lastError != null) {
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

  // ---- 对焦域:触控对焦 + 对焦驱动(候选码,待真机核对)----

  /// 机身对焦模式(0xD061)是否为 MF:是 → 远程对焦控制全部失效
  /// (机身 MF 下 AF 马达脱开,0x90C1/0x9205/0x9204 均无效,只有镜头
  /// 对焦环能动焦 —— libgphoto2/nico 实证口径,**3=MF(固定)/4=MF(选择)
  /// 两态同拦**:值 3 在 Zf 取值域外、其余 Z 机身可能回,按全方言集
  /// 判定)。值未知(desc 拒答/未读到)**不锁**:宁可按钮可按被机身拒,
  /// 也不把可用控制锁死。机身拨杆改动经 0x4006 事件定向刷新,门控实时
  /// 跟随。
  bool get focusModeIsMf => kStillFocusModeMfValues
      .contains(paramProps[PtpDevicePropCode.stillFocusMode]?.value);

  /// MF 门闩的提示文案(触控对焦/AF 钮/MF 步进共用)。
  static const _focusModeMfHint = (key: 'remote.errMfMode', args: null);

  /// MF 门闩:锁定时设提示并返回 true,调用方即拦下本次操作。
  bool _rejectIfFocusModeMf() {
    if (!focusModeIsMf) return false;
    notice = _focusModeMfHint;
    notifyListeners();
    return true;
  }

  /// 对焦链忙(0x2019)重试(0x9205 挪框 / 0x90C1 驱动共用):瞬时忙是
  /// 常态 —— 在途 0x9204 滚轮驱动物理拉镜可达 2s+、AF 收敛、机身自忙,
  /// 对焦操作即撞忙窗(2026-10-17 真机:旧预算 3 次×200ms 耗不尽忙窗 →
  /// 假失败「对焦区域移动失败」)。按拉焦轮同款口径退避静默重试,宽限
  /// 墙钟(与 [_dialRefusalGrace] 同 4s)内不报错,超宽限才如实报。
  static const _afBusyBackoff = Duration(milliseconds: 150);
  static const _afBusyGrace = Duration(seconds: 4);

  /// 「同点再点」判定半径(画面归一化,约半指节):指头点按有精度,
  /// 落点在上次框位容差内即视为同一处 —— 不重发 0x9205,直接驱动 AF。
  static const _afBoxTapRadius = 0.05;

  /// 触控对焦两手势(2026-10-17 用户定案:挪框不自动对焦 —— 省一趟
  /// 马达,对焦单独控):
  /// - 点按空白处 → 0x9205 移动对焦区域,框上屏红(未合焦);**不跟发
  ///   AF、不抢占滚轮**(0x9205 只挪框不动镜,端点态/攒余量仍有效)。
  /// - 点在上次框位([_afBoxTapRadius] 容差内)→ 不重发 0x9205,直接
  ///   0x90C1 驱动 AF 并抢占滚轮(点两下 = 移动 + 对焦;同点重发挪框
  ///   是纯冗余)。
  /// 坐标系:归一化 0..1 → **whole-size**(帧头 @16/18,如 6048×3400;
  /// OpenZCine 重置对焦用 coordinateWidth/2 实证 —— 0x9205 参数不在
  /// JPEG 像素空间)。头不可用回退链:当前头 → 最近头(OpenZCine 同款
  /// 缓存)→ SOF 帧尺寸(末级候选,比例同但缩尺不同,待真机核对)。
  /// 对焦框上屏直到下次点按/停取景;帧头 AF 框(真实尺寸)另行叠加。
  Future<void> touchFocus(double nx, double ny) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive || focusing) return; // 无取景/对焦中:静默忽略
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    final h = engine.header.value;
    final size = h != null && h.coordinateWidth > 0 && h.coordinateHeight > 0
        ? (width: h.coordinateWidth, height: h.coordinateHeight)
        : _lastHeaderSpace ?? frameSize.value;
    if (size == null) {
      error = (key: 'remote.errNoFrameFocus', args: null);
      notifyListeners();
      return;
    }
    error = null;
    final box = afBox;
    final sameSpot = box != null &&
        (nx - box.nx).abs() < _afBoxTapRadius &&
        (ny - box.ny).abs() < _afBoxTapRadius;
    if (sameSpot) {
      _preemptFocusDial(); // AF 抢占在途滚轮驱动(焦点位置将改变)
      notifyListeners();
      await _driveAf();
      return;
    }
    final x = (nx * size.width).round().clamp(0, size.width);
    final y = (ny * size.height).round().clamp(0, size.height);
    // 框先上屏(未定红):忙窗重试可达秒级,无框点按形同「没反应」;
    // 失败留在点按处红框 + 报错(同 _driveAf 失败语义)。
    afBox = AfBox(nx: nx, ny: ny);
    notifyListeners();
    final busyDeadline = DateTime.now().add(_afBusyGrace);
    for (;;) {
      try {
        await session.changeAfArea(x, y);
        break;
      } on PtpResponseException catch (e) {
        if (e.responseCode != PtpResponseCode.deviceBusy ||
            DateTime.now().isAfter(busyDeadline)) {
          error = (
            key: 'remote.errAfAreaFail',
            args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
          );
          notifyListeners();
          return;
        }
        await _delay(_afBusyBackoff);
      } on Exception catch (e) {
        if (!_linkUp) return; // 断连收口已清状态,迟到异常不横幅
        error = (key: 'remote.errAfAreaFail', args: {'e': e.toString()});
        notifyListeners();
        return;
      }
    }
  }

  /// 对焦按钮:独立驱动一次自动对焦(取景开启是前置条件 ——
  /// 0xA00B notLiveView 为未开取景的应答形态)。对焦中再点 = 如实
  /// 提示**不发包**(2026-10-17 真机定案):Zf 对 0x90C1 扣住应答直至
  /// AF 结束(0xA002 未合焦即从该应答带回,§6.2.5.1 的「开始即回 OK +
  /// 0x90C8 轮完成」两段流在 Zf 上不存在),AF 期间线路被在途事务
  /// 占死(PIMA 时序:应答未读走,下一发命令上不了线),排队 0x9206
  /// 只能到 AF 后空放一枪 —— 打断是假动作,撤包零流量。
  Future<void> afDriveNow() async {
    if (focusing) {
      notice = (key: 'remote.focusInProgress', args: null);
      notifyListeners();
      return;
    }
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    _preemptFocusDial(); // AF 抢占在途滚轮驱动(同点再点同此)
    error = null;
    notifyListeners();
    await _driveAf();
  }

  /// 驱动自动对焦(0x90C1):挂起取景轮询防事务挤占串行锁;厂商响应码
  /// (0xA002 未合焦 / 0xA004 状态不允许等)转友好提示。应答同时驱动
  /// [AfBox.focused](两色制:合焦绿 / 其余红,见类注;既有框在起步时
  /// 先回未定红 = 对焦中),对焦钮与触控对焦两条路都经此。
  Future<void> _driveAf() async {
    focusing = true;
    final box = afBox;
    if (box != null) {
      afBox = AfBox(nx: box.nx, ny: box.ny); // 回未定红 = 对焦中
    }
    notifyListeners();
    engine.pause();
    bool? focused;
    try {
      final busyDeadline = DateTime.now().add(_afBusyGrace);
      for (;;) {
        try {
          await session.afDrive();
          focused = true;
          break;
        } on PtpResponseException catch (e) {
          // 0x90C1 同吃忙窗:滚轮驱动/挪框在途时「同点再点对焦」第二拍
          // 必撞 0x2019 —— 宽限内静默续发(同 touchFocus 挪框口径)。
          if (e.responseCode != PtpResponseCode.deviceBusy ||
              DateTime.now().isAfter(busyDeadline)) {
            rethrow;
          }
          await _delay(_afBusyBackoff);
        }
      }
    } on PtpResponseException catch (e) {
      focused = e.responseCode == NikonResponseCode.outOfFocus ? false : null;
      error = (
        key: 'remote.errAfFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
      );
    } on Exception catch (e) {
      focused = null; // 链路/超时类失败:合焦与否未知,不冒充结论
      error = (key: 'remote.errAfFail', args: {'e': e.toString()});
    } finally {
      final b = afBox;
      if (b != null && focused != null) {
        afBox = AfBox(nx: b.nx, ny: b.ny, focused: focused);
      }
      if (_viewerVisible) engine.resume();
      focusing = false;
      if (_linkUp) notifyListeners();
    }
  }

  /// 尼康厂商响应码 → 友好提示(候选语义,OpenZCine 口径);null =
  /// 无表项,调用方用原始异常。返回键由渲染端 arg-t 落地。
  static L10nMessage? _nikonHint(int code) {
    switch (code) {
      case NikonResponseCode.hardwareError:
        return (key: 'remote.hintHardwareError', args: null);
      case NikonResponseCode.outOfFocus:
        return (key: 'remote.hintOutOfFocus', args: null);
      case NikonResponseCode.changeCameraModeFailed:
        return (key: 'remote.hintModeSwitchFailed', args: null);
      case NikonResponseCode.cameraModeNotAdjustFnumber:
        return (key: 'remote.hintApertureLocked', args: null);
      case NikonResponseCode.invalidStatus:
        return (key: 'remote.hintInvalidStatus', args: null);
      case NikonResponseCode.notLiveView:
        return (key: 'remote.hintNotLiveView', args: null);
      case NikonResponseCode.movieFrameReleaseBusy:
        return (key: 'remote.hintRecStillBusy', args: null);
      default:
        return null;
    }
  }

  // ---- 主体追踪(0x9424/0x9425,官方 §6.2.6)----

  /// 追踪进行中(0x9424 启动成功 → 0x9425/断连收口;相机侧随取景
  /// 关闭自灭,本旗标只是 UI 态)。
  bool _tracking = false;
  bool get tracking => _tracking;

  /// 主体追踪门控(官方 §6.2.6.7):AF 区域(0xD05D)须「自动」
  /// (0x8011)且取景开启。Zf FORM 七值无 3D 追踪档,单值判定;
  /// 值未知(拒答/未读到)不锁 —— 宁可按了被机身拒(focusModeIsMf
  /// 同口径)。
  bool get afAreaCanTrack =>
      paramProps[PtpDevicePropCode.stillFocusMeteringMode]?.value == 0x8011;

  /// 开启主体追踪:坐标 = 最近触控对焦点(无则 whole-size 中心),
  /// 坐标系同 0x9205(帧头 whole-size)。
  Future<void> startTracking() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (_rejectIfFocusModeMf()) return;
    if (!afAreaCanTrack) {
      notice = (key: 'remote.errTrackingNeedsAuto', args: null);
      notifyListeners();
      return;
    }
    final box = afBox;
    final h = engine.header.value;
    final size = h != null && h.coordinateWidth > 0 && h.coordinateHeight > 0
        ? (width: h.coordinateWidth, height: h.coordinateHeight)
        : _lastHeaderSpace ?? frameSize.value;
    if (size == null) {
      error = (key: 'remote.errNoFrameTrack', args: null);
      notifyListeners();
      return;
    }
    final nx = box?.nx ?? 0.5;
    final ny = box?.ny ?? 0.5;
    error = null;
    notifyListeners();
    try {
      await session.startTracking(
        (nx * size.width).round().clamp(0, size.width),
        (ny * size.height).round().clamp(0, size.height),
      );
      _tracking = true;
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errTrackingFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
      );
    } on Exception catch (e) {
      error = (key: 'remote.errTrackingFail', args: {'e': e.toString()});
    }
    if (_linkUp) notifyListeners();
  }

  /// 停止主体追踪(0x9425 无参)。收尾失败不上 error(追踪随会话/
  /// 取景消亡,旗标照落)。
  Future<void> endTracking() async {
    if (!_tracking) return;
    _tracking = false;
    notifyListeners();
    try {
      await session.endTracking();
    } on Exception {
      // 状态已落,链路级失败由断链路径收口
    }
  }

  // ---- AE/AWB 锁(0x9426,官方 §6.2.4.5)----

  /// 锁定态(乐观,读回对表):type 2 = AE+AWB。WB 非 auto 时机身
  /// 拒 AWB 锁(0x200F)—— 应答失败走 error,旗标不动。
  bool _aeLocked = false;
  bool get aeLocked => _aeLocked;

  /// 切换 AE/AWB 锁:应答 OK 先落乐观态,随即尽力读 AELockStatus
  /// (0xD105)对表 —— 读失败保持乐观态(不亮假态);断连沿清零
  /// (会话级状态,重连后未知)。
  Future<void> toggleAELock() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    final target = !_aeLocked;
    try {
      await session.changeAELock(lock: target, type: 2);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errAeLockFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
      );
      notifyListeners();
      return;
    } on Exception catch (e) {
      error = (key: 'remote.errAeLockFail', args: {'e': e.toString()});
      notifyListeners();
      return;
    }
    _aeLocked = target;
    notifyListeners();
    try {
      final v = await session.getDevicePropValue(PtpDevicePropCode.aeLockStatus);
      final actual = v.value == 1;
      if (actual != _aeLocked && !_disposed) {
        _aeLocked = actual;
        notifyListeners();
      }
    } on Exception {
      // 读回失败:保持乐观态
    }
  }

  // ---- 相机内屏强关(0x9422,官方 §6.2.2.17,B 组:线上未验)----

  /// 强关态(乐观,读回对表):应答 OK 只代表「请求已收到」;会话级
  /// 不持久化,断连沿清零(重连后内屏随会话新开未知)。
  bool _monitorOff = false;
  bool get monitorOff => _monitorOff;

  /// 切换机背内屏强关:OK 先落乐观态,随即尽力读 MonitorOffStatus
  /// (0xD1BA)对表 —— 读失败保持乐观态;失败不动旗标。副作用未知
  /// (可能断取景流)由看门狗既有兜底,UI 标实验性。
  Future<void> toggleMonitorOff() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    final target = !_monitorOff;
    try {
      await session.changeMonitorOff(off: target);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errMonitorOffFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
      );
      notifyListeners();
      return;
    } on Exception catch (e) {
      error = (key: 'remote.errMonitorOffFail', args: {'e': e.toString()});
      notifyListeners();
      return;
    }
    _monitorOff = target;
    notifyListeners();
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.monitorOffStatus);
      final actual = v.value == 1;
      if (actual != _monitorOff && !_disposed) {
        _monitorOff = actual;
        notifyListeners();
      }
    } on Exception {
      // 读回失败:保持乐观态
    }
  }

  // ---- 曝光读数轮换轮询 ----

  /// A/P/S + 自动 ISO 下机身持续重算快门/光圈/ISO,而多数机身不发
  /// DevicePropChanged(0x4006)—— 必须主动轮询(OpenZCine
  /// CameraAutoExposureReadouts 实测口径;它轮厂商码 0xD0B5/0xD100/
  /// 0x5007,值回读路由后我们同款)。只在取景运行期间跑,拍照/写参数
  /// 时跳过(事务在会话串行锁上自然交错,不与取帧抢锁)。
  static const _aePollInterval = Duration(seconds: 2);
  static const _aePollProps = <int>[
    PtpDevicePropCode.fNumber,
    PtpDevicePropCode.exposureTime,
    PtpDevicePropCode.exposureIndex,
  ];
  bool _aePolling = false;
  int _aeRun = 0;

  void _syncAePolling() {
    // 页面不可见不轮询(取景引擎同款挂起;相机侧取景保持)。
    final shouldRun = _linkUp &&
        _viewerVisible &&
        engine.status.value == LiveViewStatus.running;
    if (shouldRun && !_aePolling) {
      _aePolling = true;
      unawaited(_aePollLoop(++_aeRun));
    } else if (!shouldRun && _aePolling) {
      _aePolling = false;
      _aeRun++;
    }
  }

  Future<void> _aePollLoop(int run) async {
    while (_aePolling && run == _aeRun) {
      await _aeDelay(_aePollInterval);
      if (!_aePolling || run != _aeRun || !_linkUp) return;
      if (capturing || writing) continue;
      for (final code in _aePollProps) {
        await _refreshProp(code);
      }
      if (_linkUp) notifyListeners();
    }
  }

  /// 取景开关:引擎启停(帧轮询/AE 轮询/对焦框状态都随引擎状态联动)。
  Future<void> toggleLiveView() async {
    error = null;
    notice = null;
    if (liveViewActive) {
      await engine.stop();
    } else {
      await engine.start();
    }
    notifyListeners();
  }

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

  /// 侧链放行门(见 [_startSettledGate])。消费方自带超时兜底 —— 门永不
  /// 落定也不押死侧链(理论不至:连接沿必经落定点)。
  Future<void> get connectedStartSettled => _startSettledGate.future;

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
  Future<void> refreshCameraMode({bool triggerRefresh = true}) async {
    if (!_linkUp) return;
    try {
      final v = await session
          .getDevicePropValue(PtpDevicePropCode.liveViewSelector);
      final value = v.value;
      if (value is! int || (value != 0 && value != 1)) return; // 表外方言:宁缺不错
      final m = value == 1 ? CaptureMode.video : CaptureMode.photo;
      if (_modeOverridden && m == _cameraMode) return;
      final changed = m != _cameraMode;
      _setCameraMode(m);
      _dialMode = m;
      _modeOverridden = false;
      if (changed && !_disposed) {
        notifyListeners();
        // 模式翻转沿补刷参数(2026-10-12 视频参数族:拨到视频档要拉
        // 整条视频参数链,不然面板全「--」)。连接沿初读不触发(首刷
        // 由 _onConnectedChain 尾部统一做);切换链在途不触发(链尾
        // refreshParams 已定态)。
        if (_paramsRefreshedOnce && !_switchingMode && triggerRefresh) {
          unawaited(refreshParams());
        }
      }
    } on Object {
      // 旧机身无此属性/瞬态拒绝/链路已死(transport StateError):模式
      // 未知,页面走本地模式条
    }
  }

  /// 远程切换拍摄模式(模式条点按):接管持有下写 0xD1A6 + 重启取景。
  /// **两方向可切**(2026-10-11 Zf 实证:写被接受、拍照门跟软件态);
  /// 录像门跟物理拨杆 —— 照片档覆写视频后开录被拒,拨杆提示在开录时
  /// 弹出不预判。写被拒记 [modeWriteRejected](会话级,UI 灰显两方向)。
  /// 取景重启后必刷参(模式族属性连片变)。
  Future<bool> switchMode(CaptureMode target) async {
    if (_switchingMode || recording || capturing || focusing) return false;
    final current = _cameraMode;
    if (current == null || target == current) return false;
    if (_modeWriteRejected) {
      error = (key: 'remote.errModeSwitchRefused', args: null);
      notifyListeners();
      return false;
    }
    if (!_setPropEnabled()) {
      error = (key: 'remote.errWriteDisabledMode', args: null);
      notifyListeners();
      return false;
    }
    _switchingMode = true;
    error = null;
    notifyListeners();
    try {
      if (!takeoverActive && !await enableTakeover()) return false;
      // 探针实证序:0x90C2(1) → 0x9202 → 写 0xD1A6 → 0x9201(取景
      // 关着写,起景原生以新档起)。
      await engine.stop();
      try {
        await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.liveViewSelector,
          dataType: PtpDataType.uint8,
          value: target == CaptureMode.photo ? 0 : 1,
        ));
      } on PtpResponseException catch (e) {
        _modeWriteRejected = true;
        error = (
          key: 'remote.errModeSwitchFail',
          args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
        );
        unawaited(_recoverLiveViewAfterFailedSwitch());
        notifyListeners();
        return false;
      }
      _setCameraMode(target);
      // 写过即覆写期:拨杆真档被软件态遮蔽(哪怕切回 believed 拨杆档
      // —— 拨杆可能已被拨过,真相只在释放后的读回里)。
      _modeOverridden = true;
      notifyListeners();
      // 起景:接管已置 engine.remoteHeld,自愈梯自动转忙重试(模式
      // 写后的 0xA004 是瞬态,2026-10-11 实证)。
      await engine.start();
      if (!_viewerVisible) engine.pause();
      await refreshParams();
      return true;
    } finally {
      _switchingMode = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 切换链写失败后的取景回滚(停景已发生,尽力起回;接管保持不动
  /// —— 用户侧芯片仍如实显示)。
  Future<void> _recoverLiveViewAfterFailedSwitch() async {
    try {
      await engine.start();
      if (!_viewerVisible) engine.pause();
    } on Object {
      // 回滚失败:引擎自落 failed →「重试取景」兜底
    }
  }

  /// 连接即取景(OpenZCine 口径:连接成功直接驱动进监看,相机侧由此
  /// 进及时取景 —— 退出上传优先的收尾一步)。由本控制器的 connected
  /// 沿串链驱动([_onConnectedChain]),进页/回台沿(RemotePage)同款
  /// 幂等调用。拍摄页不在前台也无妨:0x9201 照发(相机进取景),帧轮询
  /// 挂起等页面可见([setViewerVisible])。闸门 [autoLiveViewEnabled]
  /// (十二轮持久化的取景总开关,AppServices 同步自设置):关 = 连接/
  /// 进页/回台沿都不自动起景;用户在浮层里显式开([toggleLiveView])
  /// 不经此闸,照常生效。
  ///
  /// 单飞:连接沿/进页沿/回台沿可能同拍到达(连接成功恰逢进页),
  /// 共享在途 Future —— 否则两个 start() 都过 status==running 门
  /// (running 要等 0x9201 应答才置),双发 0x9201、双起轮询循环。
  Future<void> autoLiveViewOnConnect() {
    final inFlight = _autoStartInFlight;
    if (inFlight != null) return inFlight;
    final completer = Completer<void>();
    _autoStartInFlight = completer.future;
    () async {
      try {
        if (!autoLiveViewEnabled) return;
        if (!_linkUp) return;
        if (engine.status.value == LiveViewStatus.running) return;
        await engine.start();
        if (!_viewerVisible) engine.pause();
      } on Object {
        // 引擎自身的失败已落在 status=failed/lastError(「重试取景」
        // 兜底);此处异常属意外(如 transport 已关),单飞共享面不上抛。
      } finally {
        _autoStartInFlight = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

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

  /// 取景画质落定(设置浮层「监看」段):更新本地值;取景在跑即写相机
  /// (会话已开),否则留给连接沿(_onConnectedChain 起景前补写 ——
  /// 冷启乐观门闩期 _linkUp 恒真,不能拿它当会话已开的凭据)。
  void setLiveViewQuality({int? imageSize, int? compression}) {
    liveViewImageSize = imageSize;
    liveViewImageCompression = compression;
    if (_linkUp && liveViewActive) unawaited(_applyLiveViewQuality());
    notifyListeners();
  }

  /// 把当前画质档写入相机(0x1016,u8 显式;起景前后均合法 —— 尺寸
  /// 档决定 0x9428 帧分辨率)。尽力而为:拒答/断链/会话未开静默
  /// (`on Object` —— 未开会话的 StateError 是 Error 不是 Exception,
  /// 逃出去会炸 initState/连接链)。
  Future<void> _applyLiveViewQuality() async {
    for (final entry in <(int, int?)>[
      (PtpDevicePropCode.liveViewImageSize, liveViewImageSize),
      (PtpDevicePropCode.liveViewImageCompression, liveViewImageCompression),
    ]) {
      final code = entry.$1;
      final value = entry.$2;
      if (value == null) continue;
      try {
        await session.setDevicePropValue(PtpDevicePropValue(
            code: code, dataType: PtpDataType.uint8, value: value));
      } on Object {
        if (!_linkUp) return;
      }
    }
  }

  /// 在途的自动起景([autoLiveViewOnConnect] 单飞槽)。
  Future<void>? _autoStartInFlight;

  /// 拍摄页可见性汇报(离台/回台、退后台/回前台):不可见挂起帧轮询
  /// 与 AE 轮询(相机侧保持取景,不发 0x9202),可见恢复。拍照/对焦
  /// 操作前后的挂起不受影响(操作内 resume 会查本状态,页面不可见
  /// 不提前恢复轮询)。
  void setViewerVisible(bool visible) {
    if (_viewerVisible == visible) return;
    _viewerVisible = visible;
    if (visible) {
      engine.resume();
    } else {
      engine.pause();
    }
    _syncAePolling();
  }

  /// 快门释放:op 表选码(在册 0x9207 直用,见 [_fireShutter]),被拒
  /// 自动换码重试(成功码缓存,后续直发)。SDRAM 直拍被拒(码级)自动
  /// 回落常规入卡拍并如实提示,照片不丢。
  ///
  /// 取景开着时挂起轮询,避免取帧事务挤占串行锁;完成信号 = 事件优先、
  /// DeviceReady 轮询兜底。0x2019 忙(半按对焦未就绪等)按失败提示。
  Future<void> capture() async {
    if (capturing) return;
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      // 间隔拍摄运行中:屏上快门/音量键快门全部让位(快门由调度器按
      // 间隔驱动),如实提示 —— 用户要手动拍先停间隔轮。
      notice = (key: 'remote.ivShutterYield', args: null);
      notifyListeners();
      return;
    }
    if (_shutterIsOpenShutter) {
      // B 门/Time 经不起「点按即走」:曝光开了没人收门(音量键快门等
      // capture() 直呼路径)—— 本地拒绝零流量并指路;按住曝光走屏上
      // 快门钮([capturePressed]),或开自拍定时组合成定时 B 门。
      notice = (key: 'remote.errBulbShutter', args: null);
      notifyListeners();
      return;
    }
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final (ok, message) = await _captureOnce();
      if (!ok) {
        error = message;
      } else if (message != null) {
        notice = message; // SDRAM 回落提示落收口后(「已拍摄」先到)
      }
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  /// 单张拍摄核心链(屏上快门 [capture] 与间隔拍摄单拍共用):挂起取景
  /// → 发码(含码回落/CaptureSort 换形/SDRAM 一体拍)→ 等落地
  /// (CaptureComplete 事件优先,DeviceReady 兜底)→ SDRAM 回传收尾。
  /// 只管相机事务,不碰 UI 状态(capturing/error/notice 由调用方按场景
  /// 收口)—— 间隔拍摄单拍失败只记账(跳拍策略),不走屏上错误横幅。
  /// 返回 (是否成功, 文案):失败文案 = 错误消息;成功文案 = SDRAM 回落
  /// 提示(仅回落发生时非 null)。
  Future<(bool, L10nMessage?)> _captureOnce() async {
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      (bool, L10nMessage?) firedResult;
      try {
        firedResult = await _fireShutter();
      } on PtpResponseException catch (e) {
        return (false, await _captureErrorMessage(e));
      } on Exception catch (e) {
        return (false, (key: 'remote.errShutterFail', args: {'e': e.toString()}));
      }
      _captureDone = Completer<void>();
      final (sdramFired, sdramFallback) = firedResult;
      if (sdramFired) _sdramHandle = Completer<int>();
      await _awaitCaptureSettled();
      if (sdramFired && _linkUp) {
        await _collectSdramObject();
      }
      return (true, sdramFallback);
    } finally {
      _captureDone = null;
      _sdramHandle = null;
      if (wasLive && _viewerVisible) engine.resume();
    }
  }

  /// 快门释放被相机拒(码级)的用户提示(原 capture 内联映射抽出,语义
  /// 不变;尽力读 WarningStatus 0xD102 —— Bit0 序列错误 → 自愈指引)。
  Future<L10nMessage> _captureErrorMessage(PtpResponseException e) async {
    if (e.responseCode == PtpResponseCode.storeNotAvailable) {
      // 0x2013:标准义 = 存储不可用(无卡/卡错误);2026-10-11 真机
      // 另证:机身拨杆在视频档时远程拍照除 0x200F 外也会报此码
      //(存储卡在位,具体子态待核)—— 双因都指,别把用户支去翻卡槽。
      return (key: 'remote.errShutterStorage', args: null);
    }
    if (e.responseCode == PtpResponseCode.invalidParameter) {
      return (key: 'remote.errShutterParam', args: null);
    }
    if (e.responseCode == NikonResponseCode.movieFrameReleaseBusy) {
      // 0xA202:录像中的静照释放进行中(官方 §6.3.2.17)—— 录像
      // 期间拍静照连拍两下会撞上,等一拍再试。
      return (key: 'remote.errShutterDuringRec', args: null);
    }
    if (e.responseCode == PtpResponseCode.accessDenied) {
      // 0x200F:相机锁定拍照控制 —— Zf 机顶「照片/视频」切换拨杆在
      // 视频档时 0x9207 即被拒(2026-10-11 真机定案;对称于录像侧
      // 0xA004 的拨杆提示)。
      return (key: 'remote.errLeverPhoto', args: null);
    }
    // 码随文浮出:有提示语时附 〔0x????〕(同连接梯诊断风格);
    // 无提示语时异常文本自带码,不再重复。seq 参数 = WarningStatus
    // Bit0 序列错误自愈指引(键,渲染端 arg-t 落地;正常为空串)。
    final hint = _nikonHint(e.responseCode);
    var msg = hint == null
        ? (key: 'remote.errShutterFail',
            args: {'e': e.toString(), 'seq': ''})
        : (
            key: 'remote.errShutterFailCode',
            args: {
              'h': hint.key,
              'c': '0x${e.responseCode.toRadixString(16).toUpperCase()}',
              'seq': '',
            },
          );
    // 尽力读 WarningStatus(0xD102,官方 §6.5.6.24):Bit0 序列错误
    // → 自愈指引(官方 §11.7.5:下一次释放自清,非重启级故障)。
    try {
      final w =
          await session.getDevicePropValue(PtpDevicePropCode.warningStatus);
      final raw = w.value;
      if (raw is int && (raw & 0x1) != 0) {
        msg = (
          key: msg.key,
          args: {...msg.args, 'seq': 'remote.warnSeqRecover'},
        );
      }
    } on Exception {
      // 读不到就只报原错误
    }
    return msg;
  }

  /// 等拍照落地:CaptureComplete 事件先到即收口,否则 DeviceReady 兜底。
  /// DeviceReady 报非忙错误码(op 不支持等)时放弃兜底 —— 命令已被接受,
  /// 等事件即可。
  Future<void> _awaitCaptureSettled() async {
    final done = _captureDone!.future;
    for (var i = 0; i < _capturePolls; i++) {
      bool ready;
      try {
        ready = await Future.any([
          done.then((_) => true),
          _delay(_capturePollInterval).then((_) => session.deviceReady()),
        ]);
      } on Exception {
        return; // DeviceReady 非忙错误:命令已接受,不再兜底
      }
      if (ready) return;
    }
  }

  /// SDRAM 直拍收尾:取回相机内存对象并入图库(0x90CB → 0xC101 句柄 →
  /// GetObjectInfo → TransferEngine 图库目的地,水印/XMP/后台保活全链
  /// 共用)。句柄一律取 0xC101 事件参数(不硬编码,不跨会话);5s 无
  /// 事件如实提示不上 error(快门已实发)。
  Future<void> _collectSdramObject() async {
    // 压掉 2s 轮询延迟:手动拉一轮厂商事件队列(0xC101 经 _onEvent 补
    // 全 [_sdramHandle]);拉取失败不致命,异步通道/轮询器还有机会。
    try {
      session.emitPolledEvents(await session.getEventEx());
    } on Exception {
      // 下面的 5s 窗兜底
    }
    int? handle;
    try {
      handle = await _sdramHandle?.future.timeout(sdramHandleTimeout);
    } on TimeoutException {
      handle = null;
    }
    if (!_linkUp) return;
    if (handle == null || handle == 0) {
      notice = (key: 'remote.errNoSdramObject', args: null);
      notifyListeners();
      return;
    }
    final engine = transferEngine;
    try {
      final info = await session.getObjectInfo(handle);
      if (!_linkUp) return;
      final entry = ObjectRepository.toEntry(info);
      if (engine == null) {
        notice = (key: 'remote.sdramNoGallery', args: null);
        notifyListeners();
        return;
      }
      final state = await _awaitGalleryTerminal(engine, entry);
      if (!_linkUp) return;
      switch (state) {
        case TransferState.completed:
          notice = (key: 'remote.sdramSaved', args: null);
        case TransferState.failed:
          notice = (key: 'remote.sdramSaveFailed', args: null);
        default:
          notice = (key: 'remote.sdramSaving', args: null);
      }
      notifyListeners();
    } on Exception catch (e) {
      if (!_linkUp) return;
      notice = (key: 'remote.errSaveFail', args: {'e': e.toString()});
      notifyListeners();
    }
  }

  /// 入队图库目的地并等到终态(或超窗)。订阅先于入队(广播流不补发,
  /// 错过终态帧会白等);返回最后观测到的状态,null = 超窗未终态。
  Future<TransferState?> _awaitGalleryTerminal(
    TransferEngine engine,
    ObjectEntry entry,
  ) async {
    TransferState? finalState;
    final terminal = Completer<void>();
    final sub = engine.tasks.listen((ts) {
      for (final t in ts) {
        if (t.handle == entry.handle && t.isTerminal) finalState = t.state;
      }
      if (finalState != null && !terminal.isCompleted) terminal.complete();
    });
    try {
      await engine.enqueue([entry], destination: TransferDestination.gallery);
      await terminal.future.timeout(sdramTransferTimeout, onTimeout: () {});
      return finalState;
    } finally {
      await sub.cancel();
    }
  }

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

  Future<void> refreshParams({bool joinInFlight = false}) {
    final inFlight = _paramSweepInFlight;
    if (joinInFlight && inFlight != null) return inFlight;
    final completer = Completer<void>();
    _paramSweepInFlight = completer.future;
    () async {
      try {
        await _refreshParamsSweep();
        completer.complete();
      } catch (error, stackTrace) {
        // 与直呼同形:错误经返回的 Future 交给各调用方(全链自身逐项
        // 兜底,走到这里只有意外形态)。
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_paramSweepInFlight, completer.future)) {
          _paramSweepInFlight = null;
        }
      }
    }();
    return completer.future;
  }

  Future<void> _refreshParamsSweep() async {
    // 张数读打头(2026-10-16):进页/拍摄沿的整条链 30+ 笔事务要跑几秒,
    // 排尾的话胶囊挂旧值几秒才对上;单笔裸读放链首,第二笔即对上。
    await _refreshShotsRemaining();
    for (final param in kShootingParams) {
      await _refreshProp(param.code);
    }
    if (_cameraMode == CaptureMode.video) {
      for (final param in kVideoShootingParams) {
        await _refreshProp(param.code);
      }
    }
    await _refreshIsoAuto();
    await _maybeFetchPicCtrlNames();
    _paramsRefreshedOnce = true;
    if (!_linkUp) return;
    notifyListeners();
  }

  /// 首轮刷参完成旗标:模式翻转沿的补刷只在首刷之后触发(连接沿的
  /// 模式初读不作数 —— 那次刷新由 _onConnectedChain 尾部统一做,
  /// 双刷会翻倍脚本序)。
  bool _paramsRefreshedOnce = false;

  /// 优化校准槽位真名拉取(0x90CC,每连接一次):对 FORM 枚举里静态表
  /// 未收录的槽位(自定义 201-209/云 301-309/表外新值)逐个读注册名;
  /// 内置(1-11)/创意(101-120)静态表已有真名,跳过。首异常即停
  /// (0x90CC 不通整组不试,机身名字显示回落静态占位)。digiCamControl
  /// InitPictControl 同款枚举循环;Zf 待真机核对。
  Future<void> _maybeFetchPicCtrlNames() async {
    if (_picCtrlNamesFetched || _picCtrlNamesBroken || !_linkUp) return;
    _picCtrlNamesFetched = true;
    final param = shootingParamByCode[PtpDevicePropCode.activePicCtrlItem];
    final staticLabels = param?.enumLabels ?? const <int, String>{};
    final values = paramProps[PtpDevicePropCode.activePicCtrlItem]?.desc
            ?.enumValues
            ?.whereType<int>() ??
        const <int>[];
    var fetched = false;
    for (final slot in values) {
      if (staticLabels.containsKey(slot)) continue;
      String? name;
      try {
        name = await session.getPictureControlName(slot);
      } on Exception {
        if (!_linkUp) return;
        _picCtrlNamesBroken = true;
        break;
      }
      if (!_linkUp) return;
      if (name != null) {
        picCtrlNames[slot] = name;
        fetched = true;
      }
    }
    if (fetched && _linkUp) notifyListeners();
  }

  /// 参数值展示(页面统一入口):优化校准槽位真名优先(0x90CC 缓存),
  /// 其余走目录静态表;返回键/动态串由渲染端 t(key, args) 落地。
  /// null 值 = 「--」;创意校准段位(101-120/201-209/301-309,目录
  /// display 无参通道)在此键化成 {n} 参。
  L10nMessage displayParamValue(int code, int? value) {
    if (code == PtpDevicePropCode.activePicCtrlItem && value != null) {
      final name = picCtrlNames[value];
      if (name != null) return (key: name, args: null);
      if (value >= 101 && value <= 120) {
        return (key: 'param.picCtrlCreative', args: {'n': value - 100});
      }
      if (value >= 201 && value <= 209) {
        return (key: 'param.picCtrlCustom', args: {'n': value - 200});
      }
      if (value >= 301 && value <= 309) {
        return (key: 'param.picCtrlCloud', args: {'n': value - 300});
      }
    }
    return (
      key: shootingParamByCode[code]?.display(value) ?? '--',
      args: null,
    );
  }

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
  Future<void> _refreshIsoAuto() async {
    try {
      final v = await session
          .getDevicePropValue(PtpDevicePropCode.stillIsoAutoControl);
      if (!_linkUp) return;
      isoAuto = (v.value as int?) != 0;
    } on Exception {
      if (!_linkUp) return;
      isoAuto = null;
    }
  }

  Future<void> _refreshProp(int propCode) async {
    final param = shootingParamByCode[propCode];
    // 取值域来源:目录 pickValues 直供(快门 —— 0x500D 枚举单位存疑
    // 弃用)的参数不读标准码 PropDesc;其余读之(枚举/范围/可写性)。
    PtpDevicePropDesc? desc;
    if (param?.pickValues == null) {
      try {
        desc = await session.getDevicePropDesc(propCode);
        if (!_linkUp) return;
      } on Exception {
        // PropDesc 不给(方言/截断/不支持):值走裸读
      }
    }
    // 值回读路由:厂商写路由的参数标准码不跟写(真机「改了不同步」
    // 根因)—— 值读走目录 readCode(ISO 0xD0B5 有效 ISO / 快门 0xD100
    // 打包分数,OpenZCine 轮询同款);无路由且 PropDesc 在册时直接用
    // desc.currentValue。
    final readCode = param?.readCode ?? propCode;
    if (readCode != propCode || desc == null) {
      try {
        final v = await session.getDevicePropValue(readCode);
        if (!_linkUp) return;
        paramProps[propCode] = PropState(
            desc: desc, value: v.value as int? ?? desc?.currentValue as int?);
        return;
      } on Exception {
        if (!_linkUp) return;
        paramProps[propCode] =
            PropState(desc: desc, value: desc?.currentValue as int?);
        return;
      }
    }
    paramProps[propCode] =
        PropState(desc: desc, value: desc.currentValue as int?);
  }

  /// 拍摄参数调节(0x1016,数据入相)。
  ///
  /// 门禁:总开关、目录 readOnly(模式转盘)、**模式门**(曝光变量:
  /// A/P 下快门自动、S/P 下光圈自动 —— 本地拒绝零流量,不再撞 0x200F
  /// 报「启用接管」的误导)、相机 getSet(厂商路由跳过)、链路在。
  /// 写成功后按读码路由回读。拨盘拥有参数写被拒时,提示按接管状态分
  /// (接管已开 → 指向模式;未开 → 提示接管)。
  Future<void> setParam(int propCode, int value) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!_setPropEnabled()) {
      error = (key: 'remote.errWriteKilled', args: null);
      notifyListeners();
      return;
    }
    final param = shootingParamByCode[propCode];
    if (param?.readOnly ?? false) {
      error = (key: 'remote.errDialOwned', args: null);
      notifyListeners();
      return;
    }
    if (_autoControlled(propCode)) {
      final mode = _modeLabel ?? 'param.currentMode';
      switch (propCode) {
        case PtpDevicePropCode.exposureTime:
          error = (key: 'remote.errAutoShutter', args: {'m': mode});
        case PtpDevicePropCode.fNumber:
          error = (key: 'remote.errAutoAperture', args: {'m': mode});
        case PtpDevicePropCode.exposureIndex:
          error = (key: 'remote.errAutoIso', args: {'m': mode});
        default:
          error = (key: 'remote.errAutoControlled', args: null);
      }
      notifyListeners();
      return;
    }
    final desc = paramProps[propCode]?.desc;
    if (param?.writeCode == null &&
        param?.dialOwned != true &&
        desc != null &&
        !desc.getSet) {
      error = (key: 'remote.errReadOnly', args: null);
      notifyListeners();
      return;
    }
    // 写路径路由(目录 [ShootingParam.writeCode]):Z 系 ISO/快门的标准
    // 码只读,写走厂商码;值域仍取读码的相机自报枚举,换算失败不发
    // (宁失败不错值)。快门面板值已是 0xD100 打包分数,直写。
    var writeValue = value;
    final convert = param?.writeConvert;
    if (convert != null) {
      final packed = convert(value);
      if (packed == null) {
        error = (key: 'remote.errNotEncodable', args: null);
        notifyListeners();
        return;
      }
      writeValue = packed;
    }
    final writeCode = param?.writeCode ?? propCode;
    final dataType = param?.writeType ??
        desc?.dataType ??
        kStandardPropDataType[propCode] ??
        PtpDataType.uint16;
    writing = true;
    error = null;
    notice = null; // 新写动作清旧提示(上一写的横幅已属过去时)
    notifyListeners();
    // B 门/Time 哨兵写入:记写前值作收门还原目标(_closeBulbExposure
    // 步①,2026-10-15;官方 §2.8.4 收门序无还原步 —— N-link 模型的
    // 应用侧收口:相机不应被留在 Bulb 档)。
    final prevShutter = paramProps[propCode]?.value;
    final wroteOpenShutter = propCode == PtpDevicePropCode.exposureTime &&
        _isOpenShutterSentinel(writeValue);
    try {
      // 色温只在 WB=色温档(0x8012)生效:写入前自动切档(真机
      // 「改了没效果」根因 —— 机身语义,K 值跟随 WB 模式)。
      if (propCode == PtpDevicePropCode.wbColorTemp &&
          paramProps[PtpDevicePropCode.whiteBalance]?.value != 0x8012) {
        await session.setDevicePropValue(PtpDevicePropValue(
            code: PtpDevicePropCode.whiteBalance,
            dataType: PtpDataType.uint16,
            value: 0x8012));
      }
      await session.setDevicePropValue(PtpDevicePropValue(
          code: writeCode, dataType: dataType, value: writeValue));
      lockedProps.remove(propCode); // 写通:解除该参数的锁标
      if (wroteOpenShutter &&
          prevShutter != null &&
          !_isOpenShutterSentinel(prevShutter)) {
        // 写前值本身是哨兵(Bulb→Time)时保留更早记录。
        _bulbShutterRestore = prevShutter;
      }
      await _refreshProp(propCode);
      // 视频参数写后复读守卫(2026-10-13 USB 探针定案:Zf 视频曝光
      // 写 = 五态全试「0x2001 收下但弹回拨盘值」—— 协议成功 ≠ 生效,
      // 复读不一致就明说,不让用户以为改上了)。照片参数不设此守卫:
      // 回读差异有合法形态(如 Auto ISO 下 0xD0B5 回工作值)。
      if (param?.videoOnly == true) {
        final readBack = paramProps[propCode]?.value;
        if (readBack != null && readBack != value && !_disposed) {
          notice = (
            key: 'remote.errPropBounce',
            args: {
              'label': param!.label,
              'v': displayParamValue(propCode, readBack),
            },
          );
        }
      }
      // AF 区域切到宽C1/C2:饱和轴触屏移框不动属相机行为,切换沿
      // 浮一条提示(文案与 AF 面板常驻行同源)。
      if (propCode == PtpDevicePropCode.stillFocusMeteringMode) {
        final hint = afAreaAxisHint(value);
        if (hint != null) notice = hint;
      }
    } on Exception catch (e) {
      if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.accessDenied) {
        // 控制锁(OpenZCine lockedControls 口径):相机拒绝这个参数
        // 的遥控 → 读出条打锁标,直到写通或断连。
        lockedProps.add(propCode);
      }
      if (e is PtpResponseException && param?.dialOwned == true) {
        error = (
          key: 'remote.errPropWriteDial',
          args: {
            'e': _nikonHint(e.responseCode)?.key ?? e.toString(),
            'tail': _takeoverActive
                ? 'remote.errPropWriteDialTakeover'
                : 'remote.errPropWriteDialLatch',
          },
        );
      } else if (e is PtpResponseException) {
        error = (
          key: 'remote.errPropWrite',
          args: {
            'e': _nikonHint(e.responseCode)?.key ?? e.toString(),
            'tail': e.responseCode == PtpResponseCode.accessDenied
                ? 'remote.errPropWriteLatch'
                : '',
          },
        );
      } else {
        error = (
          key: 'remote.errPropWrite',
          args: {'e': e.toString(), 'tail': ''},
        );
      }
    } finally {
      writing = false;
      if (_linkUp) notifyListeners();
    }
  }

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
          if (code == PtpDevicePropCode.liveViewSelector &&
              !_switchingMode) {
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
  Future<void> _showInstantReview(int? handle) async {
    if (handle == null || handle == 0) return;
    try {
      final thumb = await session.getThumb(handle);
      if (!_linkUp) return;
      reviewThumb = thumb;
      notifyListeners();
      _reviewTimer?.cancel();
      _reviewTimer = Timer(const Duration(seconds: 4), () {
        reviewThumb = null;
        if (!_disposed) notifyListeners();
      });
    } on Exception {
      // 缩略图拿不到:即拍即览静默跳过
    }
  }

  /// 0x4006 定向刷新的合并窗:拨杆转动连发的通知攒一波一次刷。
  static const _propRefreshDebounce = Duration(milliseconds: 150);
  final _pendingPropRefreshes = <int>{};
  bool _propRefreshScheduled = false;

  void _schedulePropRefresh(int propCode) {
    if (propCode == PtpDevicePropCode.exposureRemaining) {
      // 0xD1F1 不在参数目录(上面哨兵会丢),专路轻量刷张数
      _scheduleShotsRemainingRefresh();
      return;
    }
    if (!shootingParamByCode.containsKey(propCode)) return;
    _pendingPropRefreshes.add(propCode);
    if (_propRefreshScheduled) return;
    _propRefreshScheduled = true;
    unawaited(Future<void>.delayed(_propRefreshDebounce).then((_) async {
      _propRefreshScheduled = false;
      final codes = _pendingPropRefreshes.toList();
      _pendingPropRefreshes.clear();
      if (_disposed || !_linkUp) return;
      for (final code in codes) {
        await _refreshProp(code);
      }
      if (!_disposed && _linkUp) notifyListeners();
    }));
  }

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

  @override
  void dispose() {
    _disposed = true;
    _interval.stop();
    _interval.removeListener(_onIntervalChanged);
    _interval.dispose();
    _aePolling = false;
    _aeRun++;
    _reviewTimer?.cancel();
    _eventsSub?.cancel();
    _statesSub?.cancel();
    engine.status.removeListener(_onEngineStatus);
    engine.health.removeListener(_onEngineHealth);
    engine.frame.removeListener(_onFrame);
    engine.header.removeListener(_onHeader);
    frameSize.dispose();
    orientationLock.dispose();
    analyzer.dispose();
    dialNetPulses.dispose();
    super.dispose();
  }
}

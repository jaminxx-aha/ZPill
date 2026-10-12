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

import '../../core/camera/camera_connection.dart';
import '../../core/ptp/device_prop.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/frame_analyzer.dart';
import '../../core/remote/live_view_engine.dart';
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
    LiveViewEngine? engine,
    Future<void> Function(Duration)? delay,
    Future<void> Function(Duration)? aeDelay,
    bool Function()? setPropGate,
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
  final LiveViewEngine engine;

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

  String? error;

  /// 「已拍摄」提示(ObjectAdded 事件驱动;下一次操作时清)。
  String? notice;

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

  /// 当前模式的中文名(错误提示用;未读为 null)。
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
      error = '未连接相机';
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
        error = '自动 ISO 设置失败:该开关受机身控制,请先启用「APP 接管」'
            '后重试($e)';
      } else {
        error = '自动 ISO 设置失败:$e';
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
      error = '未连接相机';
      notifyListeners();
      return false;
    }
    try {
      await session.changeCameraMode(1);
    } on PtpResponseException catch (e) {
      error = '启用 APP 接管失败:${_nikonHint(e.responseCode) ?? e}';
      notifyListeners();
      return false;
    } on Exception catch (e) {
      error = '启用 APP 接管失败:$e';
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

  /// 快门码选择:首选码按相机 op 表(在册 0x9207 直用,OpenZCine 全系
  /// 口径 —— Zf 在册;表拿不到退标准 0x100E)。0x9207 的 CaptureSort
  /// 首参按 [_captureSortCandidates] 序换形(0x201D);被拒(码级)
  /// 自动换另一码,成功后缓存。0x2013(存储不可用)转友好提示。
  Future<void> _fireShutter() async {
    final pref = _captureOpPref;
    if (pref == PtpOperationCode.initiateCapture) {
      await session.initiateCapture();
      return;
    }
    final info = session.cachedDeviceInfo;
    final mediaFirst = pref == NikonOperationCode.initiateCaptureRecInMedia ||
        info == null ||
        info.supportsOperation(NikonOperationCode.initiateCaptureRecInMedia);
    if (mediaFirst) {
      try {
        await _fireMedia();
        return;
      } on PtpResponseException catch (e) {
        if (pref != null || !_captureFallbackFrom.contains(e.responseCode)) {
          rethrow; // 已缓存码/参数域类错误:换码解决不了
        }
        // 首选 0x9207 被拒(码级):标准码一试
        await session.initiateCapture();
        _captureOpPref = PtpOperationCode.initiateCapture;
        return;
      }
    }
    try {
      await session.initiateCapture();
      _captureOpPref = PtpOperationCode.initiateCapture;
    } on PtpResponseException catch (e) {
      if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
      await _fireMedia();
    }
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

  /// 快门当前值是否 Bulb/Time(0xD100 哨兵):**按住 = 开曝光,抬起
  /// 结束**(0x920C;OpenZCine pendingStillTerminate 同款语义)。
  bool get _shutterIsOpenShutter =>
      paramProps[PtpDevicePropCode.exposureTime]?.value == 0xFFFFFFFF ||
      paramProps[PtpDevicePropCode.exposureTime]?.value == 0xFFFFFFFD;

  /// 快门按钮**按下**(页面 onTapDown):
  /// - Bulb/Time:开曝光(按住中),[captureReleased] 抬起结束;
  /// - 连续释放档:连拍括持(0x90C2 remote + burstNumber 65535 —— 不
  ///   括持每次释放都会弹回单张,OpenZCine 同款)后释放,按住期间随
  ///   DeviceReady 就绪链发(上限 30 帧),抬起终止;
  /// - 普通档:自拍倒计时(档位 > 0)后一次 [capture]。
  Future<void> capturePressed() async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (_shutterIsOpenShutter) {
      await _openShutterPress();
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
      error = '快门释放失败:$e';
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

  /// Bulb/Time 按下:开曝光(0x9207 直发,不等待落地 —— 曝光持续到
  /// 抬起)。取景挂起防事务挤占。
  Future<void> _openShutterPress() async {
    if (capturing || _openShutterHeld) return;
    _openShutterHeld = true;
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      await _fireShutter();
      // 按住中:等抬起(不轮询 settle —— 曝光开着,DeviceReady 恒忙)
      while (_openShutterHeld) {
        await _delay(const Duration(seconds: 1));
      }
    } on Exception catch (e) {
      error = '快门释放失败:$e';
    } finally {
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
  }

  /// 快门按钮**抬起**:B 门结束曝光 / 终止进行中的连拍(0x920C,已拍
  /// 帧保留;运行已自行结束时相机会拒绝,容忍)。普通档点按无副作用。
  Future<void> captureReleased() async {
    if (_openShutterHeld) {
      _openShutterHeld = false; // _openShutterPress 的等待环收口
      try {
        await session.terminateCapture();
      } on Exception {
        // 曝光已自行结束:预期内
      }
      return;
    }
    if (!_burstLatched) return;
    _burstLatched = false;
    _burstRun++; // 打断链发循环
    try {
      await session.terminateCapture();
    } on Exception {
      // 运行已自行结束:预期内(OpenZCine 同款容忍)
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
  /// 先提示。事件 0xC10A/0xC108 到达时对齐状态(双保险)。
  Future<void> toggleRecord() async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = '请先开启取景再录制';
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
        error = '相机当前状态不允许录制 —— 请把机顶「照片/视频」切换拨杆'
            '拨到视频档后重试(取景保持开启)';
      } else {
        error = '录制控制失败:${_nikonHint(e.responseCode) ?? e}';
      }
    } on Exception catch (e) {
      error = '录制控制失败:$e';
    }
    notifyListeners();
  }

  /// MF 步进(0x9204):向近/远驱动一步([pulses] 脉冲,默认 300)。
  /// 取景挂起防事务挤占;结果转提示(行程尽头/步进过小是结果非错误,
  /// OpenZCine 口径)。
  Future<void> mfDriveStep({required bool towardNear, int pulses = 300}) async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = '请先开启取景';
      notifyListeners();
      return;
    }
    if (focusing) return;
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程拉焦同样失效
    error = null;
    notifyListeners();
    engine.pause();
    try {
      final outcome =
          await session.mfDrive(towardNear: towardNear, pulses: pulses);
      switch (outcome) {
        case MfDriveOutcome.complete:
          break;
        case MfDriveOutcome.endOfTravel:
          notice = '对焦行程尽头';
        case MfDriveOutcome.stepTooSmall:
          notice = '步进量过小,镜头未动';
        case MfDriveOutcome.refused:
          error = '手动对焦不可用(机械对焦环或机身忙)';
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
  void focusDialDrag(double dy) {
    if (dy == 0 || !_linkUp || capturing) return;
    if (focusModeIsMf) {
      // 机身 MF:拖动无效。静默丢弃(拖动事件高频,不刷横幅)+ 清
      // 余量,防锁定解除瞬间陈旧增量爆发成一次误驱动。
      _dialAccum = 0;
      return;
    }
    _dialAccum += dy;
    _dialPump();
  }

  /// 滚轮重新启用(开关从关到开时页面调;清失败预算与余量)。
  void resetFocusDial() {
    _dialFailures.clear();
    _dialSuspended = false;
    _dialAccum = 0;
  }

  /// 步进标定:24px 拖动 = 60 脉冲(OpenZCine FocusDial 同款量级;
  /// 0x9204 脉冲与镜头 focus-by-wire 行程换算随机身,真机再调)。
  static const double _dialStepPx = 24.0;
  static const int _dialStepPulses = 60;

  /// 失败墙钟预算:8s 窗口内 3 次失败 → 暂停滚轮(提示),窗口滑出
  /// 后再拖自动恢复。失败多为链路/状态类,无脑重试只会堵命令通道。
  static const _dialFailureWindow = Duration(seconds: 8);
  static const int _dialFailureLimit = 3;

  double _dialAccum = 0;
  int _dialGen = 0;
  bool _dialDriving = false;
  final _dialFailures = <DateTime>[];
  bool _dialSuspended = false;

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
    _dialAccum -= steps * _dialStepPx;
    final gen = _dialGen;
    _dialDriving = true;
    unawaited(() async {
      try {
        final outcome = await session.mfDrive(
            towardNear: steps > 0, pulses: steps.abs() * _dialStepPulses);
        switch (outcome) {
          case MfDriveOutcome.complete:
          case MfDriveOutcome.stepTooSmall:
            break; // 过小是结果:不提示(拖快些即可),不挡续发
          case MfDriveOutcome.endOfTravel:
            notice = '对焦行程尽头';
            _dialAccum = 0; // 该方向没有更多行程:余量丢弃
            notifyListeners();
          case MfDriveOutcome.refused:
            notice = '手动对焦不可用(机械对焦环或机身忙)';
            _dialAccum = 0;
            notifyListeners();
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
          notice = '对焦滚轮已暂停(连续失败),稍后自动恢复';
          notifyListeners();
        }
      } finally {
        _dialDriving = false;
        // 在途期间又拖了(或没被抢占):续发攒下的余量。
        if (!_dialSuspended && gen == _dialGen && _linkUp) {
          _dialPump();
        }
      }
    }());
  }

  void _pruneDialFailures() {
    final cutoff = DateTime.now().subtract(_dialFailureWindow);
    _dialFailures.removeWhere((t) => t.isBefore(cutoff));
  }

  /// AF 驱动(点按对焦/对焦按钮)抢占在途滚轮:代数自增即止续发,
  /// 余量清零(AF 改变了焦点位置,攒的像素是陈旧意图)。
  void _preemptFocusDial() {
    _dialGen++;
    _dialAccum = 0;
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
  /// 失败保留旧值)。
  void _onFrame() {
    final f = engine.frame.value;
    if (f == null) return;
    final s = jpegSofSize(f);
    if (s != null && s != frameSize.value) frameSize.value = s;
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
  static const _focusModeMfHint = '机身对焦模式为 MF —— 远程对焦不可用,'
      '请切回 AF-S/AF-C(「对焦模式」芯片可直接切换)';

  /// MF 门闩:锁定时设提示并返回 true,调用方即拦下本次操作。
  bool _rejectIfFocusModeMf() {
    if (!focusModeIsMf) return false;
    notice = _focusModeMfHint;
    notifyListeners();
    return true;
  }

  /// 0x9205 忙重试(OpenZCine 同款策略:对焦区域移动遇 0x2019 短退避重试)。
  static const _afBusyRetries = 3;
  static const _afBusyRetryDelay = Duration(milliseconds: 200);

  /// 触控对焦:点按取景画面 [nx]/[ny](归一化 0..1,取景图像坐标系)→
  /// **whole-size 坐标系**(帧头 @16/18,如 6048×3400;OpenZCine 重置对焦
  /// 用 coordinateWidth/2 为中心点实证 —— 0x9205 参数不在 JPEG 像素空间)
  /// → 0x9205 ChangeAfArea 移动对焦区域,随即驱动一次 AF(点按即合焦的
  /// 常规预期)。头不可用回退链:当前头 → 最近头(OpenZCine 同款缓存)→
  /// SOF 帧尺寸(末级候选,比例同但缩尺不同,待真机核对)。
  /// 对焦框上屏直到下次点按/停取景;帧头 AF 框(真实尺寸)另行叠加。
  Future<void> touchFocus(double nx, double ny) async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!liveViewActive || focusing) return; // 无取景/对焦中:静默忽略
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    _preemptFocusDial(); // AF 抢占在途滚轮驱动(焦点位置将改变)
    final h = engine.header.value;
    final size = h != null && h.coordinateWidth > 0 && h.coordinateHeight > 0
        ? (width: h.coordinateWidth, height: h.coordinateHeight)
        : _lastHeaderSpace ?? frameSize.value;
    if (size == null) {
      error = '暂无取景帧,无法定位对焦点';
      notifyListeners();
      return;
    }
    final x = (nx * size.width).round().clamp(0, size.width);
    final y = (ny * size.height).round().clamp(0, size.height);
    error = null;
    notifyListeners();
    for (var attempt = 0;; attempt++) {
      try {
        await session.changeAfArea(x, y);
        break;
      } on PtpResponseException catch (e) {
        if (e.responseCode != PtpResponseCode.deviceBusy ||
            attempt >= _afBusyRetries) {
          error = '对焦区域移动失败:${_nikonHint(e.responseCode) ?? e}';
          notifyListeners();
          return;
        }
        await _delay(_afBusyRetryDelay);
      }
    }
    if (!_linkUp) return;
    afBox = AfBox(nx: nx, ny: ny);
    notifyListeners();
    await _driveAf();
  }

  /// 对焦按钮:独立驱动一次自动对焦(取景开启是前置条件 ——
  /// 0xA00B notLiveView 为未开取景的应答形态)。
  Future<void> afDriveNow() async {
    if (focusing) return;
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = '请先开启取景';
      notifyListeners();
      return;
    }
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    _preemptFocusDial(); // 同 touchFocus:AF 抢占在途滚轮驱动
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
      await session.afDrive();
      focused = true;
    } on PtpResponseException catch (e) {
      focused = e.responseCode == NikonResponseCode.outOfFocus ? false : null;
      error = '对焦失败:${_nikonHint(e.responseCode) ?? e}';
    } on Exception catch (e) {
      focused = null; // 链路/超时类失败:合焦与否未知,不冒充结论
      error = '对焦失败:$e';
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

  /// 尼康厂商响应码 → 中文提示(候选语义,OpenZCine 口径);
  /// null = 无表项,调用方用原始异常。
  static String? _nikonHint(int code) {
    switch (code) {
      case NikonResponseCode.hardwareError:
        return '相机硬件错误';
      case NikonResponseCode.outOfFocus:
        return '未合焦';
      case NikonResponseCode.changeCameraModeFailed:
        return '相机模式切换失败(释放/对焦/清洁中会被拒,稍后再试)';
      case NikonResponseCode.cameraModeNotAdjustFnumber:
        return '当前相机模式不能遥控调整光圈(受光圈环/拨盘控制)';
      case NikonResponseCode.invalidStatus:
        return '当前相机状态不允许该操作';
      case NikonResponseCode.notLiveView:
        return '未开启取景';
      default:
        return null;
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
    // 模式读打头(2026-10-11 真机反馈:视频档进页要等整条刷参链跑完
    // 才跟到视频档,几秒观感延迟)—— 单请求先行,再起景、刷参。
    await refreshCameraMode();
    await autoLiveViewOnConnect();
    await refreshParams();
  }

  /// 读 0xD1A6 刷 [cameraMode](连接沿初读、进页/回台沿对表、0x4006
  /// 事件跟随用)。读失败保持原状(null 仍 null → 页面本地回落;已知值
  /// 不因瞬态失败清掉)。**覆写回声护栏**:覆写期读值是软件态回声(与
  /// 拨杆真档不可分),与已知软件态相同即零动作 —— 拨杆真档的真相留给
  /// 释放接管后的读回([releaseTakeover]);读到不同值 = 覆写已被机身
  /// 顶掉/拨杆态盖过,按新真相全量对表。
  Future<void> refreshCameraMode() async {
    if (!_linkUp) return;
    try {
      final v = await session
          .getDevicePropValue(PtpDevicePropCode.liveViewSelector);
      final value = v.value;
      if (value is! int || (value != 0 && value != 1)) return; // 表外方言:宁缺不错
      final m = value == 1 ? CaptureMode.video : CaptureMode.photo;
      if (_modeOverridden && m == _cameraMode) return;
      final changed = m != _cameraMode;
      _cameraMode = m;
      _dialMode = m;
      _modeOverridden = false;
      if (changed && !_disposed) notifyListeners();
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
      error = '相机拒绝了远程切换拍摄模式 —— 请直接用机顶拨杆切换';
      notifyListeners();
      return false;
    }
    if (!_setPropEnabled()) {
      error = '参数写入已关断,无法切换拍摄模式';
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
        error = '切换拍摄模式失败:${_nikonHint(e.responseCode) ?? e}';
        unawaited(_recoverLiveViewAfterFailedSwitch());
        notifyListeners();
        return false;
      }
      _cameraMode = target;
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
  /// 自动换码重试(成功码缓存,后续直发)。
  ///
  /// 取景开着时挂起轮询,避免取帧事务挤占串行锁;完成信号 = 事件优先、
  /// DeviceReady 轮询兜底。0x2019 忙(半按对焦未就绪等)按失败提示。
  Future<void> capture() async {
    if (capturing) return;
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      try {
        await _fireShutter();
      } on PtpResponseException catch (e) {
        if (e.responseCode == PtpResponseCode.storeNotAvailable) {
          // 0x2013:标准义 = 存储不可用(无卡/卡错误);2026-10-11 真机
          // 另证:机身拨杆在视频档时远程拍照除 0x200F 外也会报此码
          //(存储卡在位,具体子态待核)—— 双因都指,别把用户支去翻卡槽。
          error = '快门释放失败:相机存储不可用 —— 请检查存储卡与插槽;'
              '若卡在位,可能是机身拨杆在视频档拒绝了远程拍照,'
              '请拨回照片档重试(视频档请用拍摄页的录制钮拍视频)';
        } else if (e.responseCode == PtpResponseCode.invalidParameter) {
          error = '快门释放失败:相机不接受快门参数(0x201D,已试全部'
              '已知形态)—— 请反馈当时的「APP 接管」与「对焦后拍」状态';
        } else if (e.responseCode == PtpResponseCode.accessDenied) {
          // 0x200F:相机锁定拍照控制 —— Zf 机顶「照片/视频」切换拨杆在
          // 视频档时 0x9207 即被拒(2026-10-11 真机定案;对称于录像侧
          // 0xA004 的拨杆提示)。
          error = '相机当前状态不允许拍照 —— 请把机顶「照片/视频」切换'
              '拨杆拨回照片档后重试(视频档请用拍摄页的录制钮拍视频)';
        } else {
          // 码随文浮出:有提示语时附 〔0x????〕(同连接梯诊断风格);
          // 无提示语时异常文本自带码,不再重复。
          final hint = _nikonHint(e.responseCode);
          error = hint == null
              ? '快门释放失败:$e'
              : '快门释放失败:$hint'
                  '〔0x${e.responseCode.toRadixString(16).toUpperCase()}〕';
        }
        return;
      } on Exception catch (e) {
        error = '快门释放失败:$e';
        return;
      }
      _captureDone = Completer<void>();
      await _awaitCaptureSettled();
    } finally {
      _captureDone = null;
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
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

  /// 拍摄参数刷新(目录 [kShootingParams] 全量):PropDesc 优先(自带
  /// 当前值 + 可写性 + 取值域),值回读按目录路由(厂商读码,见
  /// [_refreshProp]);PropDesc 不可用退回裸值 0x1015(值有、域未知)。
  /// 单属性失败置空不上抛,断连后迟到值不上屏。目录序逐个刷(不并发):
  /// PropDesc 拒答的退回路径会二次入队,并发时与脚本应答交错易错位。
  Future<void> refreshParams() async {
    for (final param in kShootingParams) {
      await _refreshProp(param.code);
    }
    await _refreshIsoAuto();
    await _refreshShotsRemaining();
    await _maybeFetchPicCtrlNames();
    if (!_linkUp) return;
    notifyListeners();
  }

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
  /// 其余走目录静态表。null 值 = 「--」。
  String displayParamValue(int code, int? value) {
    if (code == PtpDevicePropCode.activePicCtrlItem && value != null) {
      final name = picCtrlNames[value];
      if (name != null) return name;
    }
    return shootingParamByCode[code]?.display(value) ?? '--';
  }

  /// 剩余可拍张数(0xD1F1 裸读;拒答 null 不猜)。
  Future<void> _refreshShotsRemaining() async {
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.exposureRemaining);
      if (!_linkUp) return;
      shotsRemaining = v.value as int?;
    } on Exception {
      if (!_linkUp) return;
      shotsRemaining = null;
    }
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
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!_setPropEnabled()) {
      error = '参数写入已被总闸关断(kSetPropEnabled=false,紧急关断)';
      notifyListeners();
      return;
    }
    final param = shootingParamByCode[propCode];
    if (param?.readOnly ?? false) {
      error = '该参数由机身转盘控制,不支持遥控修改';
      notifyListeners();
      return;
    }
    if (_autoControlled(propCode)) {
      final mode = _modeLabel ?? '当前模式';
      switch (propCode) {
        case PtpDevicePropCode.exposureTime:
          error = '$mode 下快门由相机自动控制,不可手调 —— 可调 EV 或切到 S/M 档';
        case PtpDevicePropCode.fNumber:
          error = '$mode 下光圈由相机自动控制,不可手调 —— 可调 EV 或切到 A/M 档';
        case PtpDevicePropCode.exposureIndex:
          error = '$mode 下 ISO 由相机自动控制,不可手调';
        default:
          error = '该参数当前由相机自动控制,不可手调';
      }
      notifyListeners();
      return;
    }
    final desc = paramProps[propCode]?.desc;
    if (param?.writeCode == null &&
        param?.dialOwned != true &&
        desc != null &&
        !desc.getSet) {
      error = '相机上报该属性为只读';
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
        error = '该值无法换算为机身写码(0x100),未发送';
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
    notifyListeners();
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
      await _refreshProp(propCode);
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
        error = '参数写入失败:${_nikonHint(e.responseCode) ?? e}'
            '(${_takeoverActive ? '接管已开启仍被拒 —— 该模式下此参数由相机自动控制,请检查模式转盘' : '该参数受机身物理拨盘控制,请先启用「APP 接管」'})';
      } else if (e is PtpResponseException) {
        error = '参数写入失败:${_nikonHint(e.responseCode) ?? e}';
      } else {
        error = '参数写入失败:$e';
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
        notice = '已拍摄';
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
    _cancelSelfTimer();
    _dialGen++;
    _dialAccum = 0;
    _dialDriving = false;
    _dialSuspended = false;
    _dialFailures.clear();
    recording = false;
    recordingSince = null;
    reviewThumb = null;
    _reviewTimer?.cancel();
    lockedProps.clear();
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
      _cameraMode = _dialMode;
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
    super.dispose();
  }
}

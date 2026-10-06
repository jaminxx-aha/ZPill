/// 遥控拍摄控制器:Live View 开关、快门释放、拍摄参数展示与调节。
///
/// 快门码选择:优先取相机 op 表 —— 在册 0x9207(落卡拍)直用
/// (OpenZCine 全系口径);表拿不到/不在册退标准 0x100E。运行期被拒
/// (0x2002/0x2005/0x2006/0x200F/0x2013)自动换另一码重发;0x9207 的
/// CaptureSort 首参被 0x201D 拒时按候选序换形(2026-10-06 真机:
/// [0,0] 在应用模式/接管态被拒),成功码/形缓存后续直发。
///
/// **APP 接管控制**(0x90C2 remote 模式,影控台同款):快门等参数受
/// 机身物理拨盘控制,启用接管(机身拨盘锁定)应用才能调整;用户在
/// 拍摄页确认后 [enableTakeover],解除/断连由 [releaseTakeover] 与
/// 重连防御性收口(见 [_takeoverDangling])。
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
/// 映射回屏幕)。相机侧合焦与否无事件可依 —— 纯位置指示,下次点按
/// 替换、停取景/断连清除。
final class AfBox {
  const AfBox({required this.nx, required this.ny});
  final double nx;
  final double ny;
}

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
    this.engine.frame.addListener(_onFrame);
    _statesSub = connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        if (_takeoverDangling) {
          // 上次断链时还持有 remote 模式:防御性解除(机身拨盘可能仍
          // 锁定,OpenZCine 同款「photo 模式重入先复位」口径)。
          _takeoverDangling = false;
          unawaited(_endRemoteModeQuietly());
        }
        unawaited(refreshParams());
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
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

  /// 拍摄参数写入中(编辑面板防连点)。
  bool writing = false;

  String? error;

  /// 「已拍摄」提示(ObjectAdded 事件驱动;下一次操作时清)。
  String? notice;

  /// 拍摄参数状态(PropDesc 驱动),键 = [PtpDevicePropCode]。
  final paramProps = <int, PropState>{};

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

  /// 拍摄参数调节总开关(生产 = [PtpSession.kSetPropEnabled],真机实证已开)。
  bool get canAdjustParams => _setPropEnabled();

  /// 该属性当前是否可调:总门禁 + 目录 readOnly(机身件拥有)+ 相机
  /// getSet 上报三过。厂商写路由参数(writeCode != null)跳过 getSet:
  /// 标准码的 getSet 不代表厂商写码可写性(2026-10-06 真机:0x500D/
  /// 0x500F 报只读,0xD100/0xD0B4 照常可写)。
  bool propWritable(int propCode) {
    if (!_setPropEnabled()) return false;
    final param = shootingParamByCode[propCode];
    if (param == null || param.readOnly) return false;
    if (param.writeCode != null) return true;
    return paramProps[propCode]?.desc?.getSet ?? false;
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
    error = null;
    notifyListeners();
    return true;
  }

  /// 解除接管(0x90C2 [0];尽力而为,链路将断时的拒绝不影响本地状态)。
  Future<void> releaseTakeover() async {
    if (!_takeoverActive) return;
    _takeoverActive = false;
    notifyListeners();
    await _endRemoteModeQuietly();
  }

  Future<void> _endRemoteModeQuietly() async {
    try {
      await session.changeCameraMode(0);
    } on Exception {
      // 尽力而为
    }
  }

  bool _linkUp = true;
  bool _disposed = false;
  StreamSubscription<PtpEvent>? _eventsSub;
  StreamSubscription<CameraLinkState>? _statesSub;
  Completer<void>? _captureDone;

  /// 最近取景帧尺寸(SOF 嗅探):触控对焦坐标映射 + 页面画幅计算用。
  final frameSize = ValueNotifier<({int width, int height})?>(null);

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

  /// 取景帧到达:SOF 嗅探帧尺寸(只走标记结构不解码,开销可忽略;
  /// 失败保留旧值)。
  void _onFrame() {
    final f = engine.frame.value;
    if (f == null) return;
    final s = jpegSofSize(f);
    if (s != null && s != frameSize.value) frameSize.value = s;
  }

  // ---- 对焦域:触控对焦 + 对焦驱动(候选码,待真机核对)----

  /// 0x9205 忙重试(OpenZCine 同款策略:对焦区域移动遇 0x2019 短退避重试)。
  static const _afBusyRetries = 3;
  static const _afBusyRetryDelay = Duration(milliseconds: 200);

  /// 触控对焦:点按取景画面 [nx]/[ny](归一化 0..1,取景图像坐标系)→
  /// 帧像素坐标 → 0x9205 ChangeAfArea 移动对焦区域,随即驱动一次 AF
  /// (点按即合焦的常规预期;若机身移点即自动对焦,后随的 0x90C1 应当
  /// 立即返回,真机核对)。对焦框上屏直到下次点按/停取景。
  Future<void> touchFocus(double nx, double ny) async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!liveViewActive || focusing) return; // 无取景/对焦中:静默忽略
    final size = frameSize.value;
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
    error = null;
    notifyListeners();
    await _driveAf();
  }

  /// 驱动自动对焦(0x90C1):挂起取景轮询防事务挤占串行锁;厂商响应码
  /// (0xA002 未合焦 / 0xA004 状态不允许等)转友好提示。
  Future<void> _driveAf() async {
    focusing = true;
    notifyListeners();
    engine.pause();
    try {
      await session.afDrive();
    } on PtpResponseException catch (e) {
      error = '对焦失败:${_nikonHint(e.responseCode) ?? e}';
    } on Exception catch (e) {
      error = '对焦失败:$e';
    } finally {
      engine.resume();
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
    final shouldRun = _linkUp && engine.status.value == LiveViewStatus.running;
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
          error = '快门释放失败:相机存储不可用(请检查存储卡与插槽)';
        } else if (e.responseCode == PtpResponseCode.invalidParameter) {
          error = '快门释放失败:相机不接受快门参数(0x201D,已试全部'
              '已知形态)—— 请反馈当时的「APP 接管」与「对焦后拍」状态';
        } else {
          error = '快门释放失败:${_nikonHint(e.responseCode) ?? e}';
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
      if (wasLive) engine.resume();
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
    if (!_linkUp) return;
    notifyListeners();
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
  /// 三重门禁:总开关([canAdjustParams],生产已开/紧急关断收口)、
  /// 目录 readOnly(模式转盘)/相机 getSet(厂商路由跳过)、链路在。
  /// 写成功后按读码路由回读 —— 相机对域外值可能 clamp,屏显一律以
  /// 回读为准。拨盘拥有参数([ShootingParam.dialOwned])的写被拒时
  /// 提示启用 APP 接管(0x90C2 remote 模式)。
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
    final desc = paramProps[propCode]?.desc;
    if (param?.writeCode == null && desc != null && !desc.getSet) {
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
      await session.setDevicePropValue(PtpDevicePropValue(
          code: writeCode, dataType: dataType, value: writeValue));
      await _refreshProp(propCode);
    } on Exception catch (e) {
      if (e is PtpResponseException && param?.dialOwned == true) {
        error = '参数写入失败:${_nikonHint(e.responseCode) ?? e}'
            '(该参数受机身物理拨盘控制,请先启用「APP 接管」)';
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
        unawaited(refreshParams());
      case PtpEventCode.devicePropChanged:
        // 机身侧拨盘/菜单改动(OpenZCine 口径):定向刷新被点名的参数,
        // 短窗合并(一次拨杆转动会连发一串)。
        if (event.params.isNotEmpty) {
          _schedulePropRefresh(event.params.first);
        }
      default:
        break; // 0xC10C 等:见类注,不消费
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
    if (_takeoverActive) {
      // 链路已死无法发 0x90C2 [0]:记悬挂,重连后防御性解除。
      _takeoverDangling = true;
      _takeoverActive = false;
    }
    _syncAePolling(); // 引擎停转的通知可能在门闩之后才到,这里先收口
    unawaited(engine.stop());
    capturing = false;
    writing = false;
    error = null;
    notice = null;
    afBox = null;
    paramProps.clear();
    _pendingPropRefreshes.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _aePolling = false;
    _aeRun++;
    _eventsSub?.cancel();
    _statesSub?.cancel();
    engine.status.removeListener(_onEngineStatus);
    engine.frame.removeListener(_onFrame);
    frameSize.dispose();
    analyzer.dispose();
    super.dispose();
  }
}

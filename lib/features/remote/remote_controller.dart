/// 遥控拍摄控制器:Live View 开关、快门释放、拍摄参数展示与调节。
///
/// 快门码回退链:0x100E 标准优先,被「此码不对」类响应(0x2002/
/// 0x2005/0x2006)拒绝 → 换尼康 0x9207 落卡拍,成功码缓存后续直发
/// (2026-10-05 Zf 真机实证 0x100E → 0x2002,见 [_fireShutter])。
///
/// 事件驱动:CaptureComplete(0x400D / 尼康 0xC102)提前收口拍照等待;
/// ObjectAdded(0x4002 / 0xC101)→「已拍摄」提示 + 参数刷新(**不下载**,
/// 纯遥控 —— 速传联动是 TODO T1 的独立功能)。0xC10C
/// LiveViewStateChanged 不参与取景启停(语义未实证,引擎纯轮询自治,
/// 待真机核对后再决定是否消费)。
///
/// 拍摄参数目录驱动([kShootingParams]):PropDesc(0x1014)自描述
/// (可写性/枚举域/范围域),裸值 0x1015 只作 PropDesc 不可用时的回退。
/// 写路径(0x1016)三重门禁:[PtpSession.kSetPropEnabled] 总开关
/// (真机核对前恒关)+ 相机 getSet 上报 + 值域(枚举/范围外的值由
/// 相机 clamp,回读为准)。
///
/// 对焦域(候选码,待真机核对):点取景画面 → 0x9205 移动对焦区域 +
/// 0x90C1 驱动对焦(对焦按钮单独驱动);「对焦后拍」开关把快门 0x9207
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
  const Exposure({this.fNumber, this.shutterUs, this.iso});

  /// 光圈值 ×100(u16;280 = f/2.8,ISO 15740 定点)。
  final int? fNumber;

  /// 快门时长(µs,u32;10000 = 1/100s)。
  final int? shutterUs;

  /// ISO(u16)。
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

  /// 写门禁:生产恒取 [PtpSession.kSetPropEnabled];测试注入覆写以
  /// 覆盖写路径(总开关本身是编译期常量,测试不可翻转)。
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
          shutterUs: paramProps[PtpDevicePropCode.exposureTime]?.value,
          iso: paramProps[PtpDevicePropCode.exposureIndex]?.value,
        );

  /// 取景是否在跑(引擎状态透传)。
  bool get liveViewActive => engine.status.value == LiveViewStatus.running;

  /// 链路是否在(断连/失败后闩上,页面据此显示连接指引)。
  bool get linkUp => _linkUp;

  /// 拍摄参数调节总开关(生产 = [PtpSession.kSetPropEnabled],恒关待真机核对)。
  bool get canAdjustParams => _setPropEnabled();

  /// 该属性当前是否可调:总门禁 + 相机 getSet 上报双过。
  bool propWritable(int propCode) {
    if (!_setPropEnabled()) return false;
    return paramProps[propCode]?.desc?.getSet ?? false;
  }

  bool _linkUp = true;
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
  /// 驱动 AF 再释放,半按-全按;OpenZCine 候选语义,待真机核对),
  /// false = 0x0000(Zf 真机已实证姿势,默认)。
  bool get focusBeforeCapture => _focusBeforeCapture;
  set focusBeforeCapture(bool v) {
    if (_focusBeforeCapture == v) return;
    _focusBeforeCapture = v;
    notifyListeners();
  }

  /// 本轮会话已验证可用的快门码(0x100E / 0x9207)。断连不清:相机
  /// 个性跨连接稳定,重连后直发省一次失败事务。
  int? _captureOpPref;

  /// 快门码回退信号集:相机明说「此码不对」的响应码 → 换尼康码重发。
  /// 忙(0x2019)/会话/链路类错误不在其列 —— 换码解决不了,原样上抛。
  static const _captureFallbackFrom = {
    PtpResponseCode.generalError,
    PtpResponseCode.operationNotSupported,
    PtpResponseCode.parameterNotSupported,
  };

  /// 快门码回退链:标准 0x100E 优先;被拒(2026-10-05 Zf 真机实证
  /// 0x100E → 0x2002 GeneralError)→ 尼康 0x9207 落卡拍;成功后缓存。
  Future<void> _fireShutter() async {
    final pref = _captureOpPref;
    if (pref == NikonOperationCode.initiateCaptureRecInMedia) {
      await session.initiateCaptureRecInMedia(
          focusBeforeCapture: _focusBeforeCapture);
      return;
    }
    if (pref == PtpOperationCode.initiateCapture) {
      await session.initiateCapture();
      return;
    }
    try {
      await session.initiateCapture();
      _captureOpPref = PtpOperationCode.initiateCapture;
    } on PtpResponseException catch (e) {
      if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
      await session.initiateCaptureRecInMedia(
          focusBeforeCapture: _focusBeforeCapture);
      _captureOpPref = NikonOperationCode.initiateCaptureRecInMedia;
    }
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
        return '相机模式切换失败';
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
  /// 0x5007,我们用标准三码)。只在取景运行期间跑,拍照/写参数时跳过
  /// (事务在会话串行锁上自然交错,不与取帧抢锁)。
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

  /// 快门释放:0x100E 标准码优先,被拒自动回退尼康 0x9207 落卡拍
  /// (成功码缓存,后续直发 —— 见 [_fireShutter])。
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
  /// 当前值 + 可写性 + 取值域),PropDesc 不可用退回裸值 0x1015(值有、
  /// 域未知)。单属性失败置空不上抛,断连后迟到值不上屏。目录序逐个
  /// 刷(不并发):PropDesc 拒答的退回路径会二次入队,并发时与脚本
  /// 应答交错易错位。
  Future<void> refreshParams() async {
    for (final param in kShootingParams) {
      await _refreshProp(param.code);
    }
    if (!_linkUp) return;
    notifyListeners();
  }

  Future<void> _refreshProp(int propCode) async {
    try {
      final desc = await session.getDevicePropDesc(propCode);
      if (!_linkUp) return;
      paramProps[propCode] =
          PropState(desc: desc, value: desc.currentValue as int?);
      return;
    } on Exception {
      // PropDesc 不给(方言/截断/不支持):退回裸值
    }
    try {
      final v = await session.getDevicePropValue(propCode);
      if (!_linkUp) return;
      paramProps[propCode] = PropState(value: v.value as int?);
    } on Exception {
      if (!_linkUp) return;
      paramProps[propCode] = const PropState();
    }
  }

  /// 拍摄参数调节(0x1016,数据入相)。
  ///
  /// 三重门禁:总开关([canAdjustParams],真机核对前恒关)、相机
  /// getSet 上报、链路在。写成功后回读当键 —— 相机对域外值可能 clamp,
  /// 屏显一律以回读为准。
  Future<void> setParam(int propCode, int value) async {
    if (!_linkUp) {
      error = '未连接相机';
      notifyListeners();
      return;
    }
    if (!_setPropEnabled()) {
      error = '参数调节未启用:待真机核对可写域后开放';
      notifyListeners();
      return;
    }
    final desc = paramProps[propCode]?.desc;
    if (desc != null && !desc.getSet) {
      error = '相机上报该属性为只读';
      notifyListeners();
      return;
    }
    final dataType = desc?.dataType ??
        kStandardPropDataType[propCode] ??
        PtpDataType.uint16;
    writing = true;
    error = null;
    notifyListeners();
    try {
      await session.setDevicePropValue(
          PtpDevicePropValue(code: propCode, dataType: dataType, value: value));
      await _refreshProp(propCode);
    } on Exception catch (e) {
      error = '参数写入失败:$e';
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
      default:
        break; // 0xC10C 等:见类注,不消费
    }
  }

  /// 断连/失败:停引擎、清状态;迟到的参数值/事件被门闩挡住。
  void _invalidate() {
    _linkUp = false;
    _syncAePolling(); // 引擎停转的通知可能在门闩之后才到,这里先收口
    unawaited(engine.stop());
    capturing = false;
    writing = false;
    error = null;
    notice = null;
    afBox = null;
    paramProps.clear();
    notifyListeners();
  }

  @override
  void dispose() {
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

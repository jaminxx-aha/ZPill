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
/// 模式抄 BrowserController:构造器注入 + 断连门闩(_linkUp)+ _invalidate。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/camera/camera_connection.dart';
import '../../core/ptp/device_prop.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';
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

final class RemoteController extends ChangeNotifier {
  RemoteController({
    required this.session,
    this.connection,
    LiveViewEngine? engine,
    Future<void> Function(Duration)? delay,
    bool Function()? setPropGate,
  })  : engine = engine ?? LiveViewEngine(session: session),
        _delay = delay ?? Future<void>.delayed,
        _setPropEnabled = setPropGate ?? _sessionSetPropGate {
    this.engine.status.addListener(_onEngineStatus);
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
      await session.initiateCaptureRecInMedia();
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
      await session.initiateCaptureRecInMedia();
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
    notifyListeners();
  }

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
    unawaited(engine.stop());
    capturing = false;
    writing = false;
    error = null;
    notice = null;
    paramProps.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _statesSub?.cancel();
    engine.status.removeListener(_onEngineStatus);
    analyzer.dispose();
    super.dispose();
  }
}

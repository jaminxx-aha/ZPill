/// 遥控拍摄控制器:Live View 开关、快门释放、曝光只读展示。
///
/// 事件驱动:CaptureComplete(0x400D / 尼康 0xC102)提前收口拍照等待;
/// ObjectAdded(0x4002 / 0xC101)→「已拍摄」提示 + 曝光刷新(**不下载**,
/// 纯遥控 —— 速传联动是 TODO T1 的独立功能)。0xC10C
/// LiveViewStateChanged 不参与取景启停(语义未实证,引擎纯轮询自治,
/// 待真机核对后再决定是否消费)。
///
/// 模式抄 BrowserController:构造器注入 + 断连门闩(_linkUp)+ _invalidate。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/camera/camera_connection.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';
import '../../core/remote/live_view_engine.dart';

/// 曝光三要素(只读;null = 该属性读取失败/未读)。
final class Exposure {
  const Exposure({this.fNumber, this.shutterUs, this.iso});

  /// 光圈值 ×10(u16;28 = f/2.8)。
  final int? fNumber;

  /// 快门时长(µs,u32;10000 = 1/100s)。
  final int? shutterUs;

  /// ISO(u16)。
  final int? iso;
}

final class RemoteController extends ChangeNotifier {
  RemoteController({
    required this.session,
    this.connection,
    LiveViewEngine? engine,
    Future<void> Function(Duration)? delay,
  })  : engine = engine ?? LiveViewEngine(session: session),
        _delay = delay ?? Future<void>.delayed {
    this.engine.status.addListener(_onEngineStatus);
    connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        unawaited(refreshExposure());
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _invalidate();
      }
    });
    _eventsSub = session.events.listen(_onEvent);
  }

  final PtpSession session;
  final CameraConnection? connection;
  final LiveViewEngine engine;
  final Future<void> Function(Duration) _delay;

  bool capturing = false;
  String? error;

  /// 「已拍摄」提示(ObjectAdded 事件驱动;下一次操作时清)。
  String? notice;

  Exposure? exposure;

  /// 取景是否在跑(引擎状态透传)。
  bool get liveViewActive => engine.status.value == LiveViewStatus.running;

  /// 链路是否在(断连/失败后闩上,页面据此显示连接指引)。
  bool get linkUp => _linkUp;

  bool _linkUp = true;
  StreamSubscription<PtpEvent>? _eventsSub;
  Completer<void>? _captureDone;

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

  /// 快门释放(InitiateCapture 0x100E,落卡)。
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
        await session.initiateCapture();
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

  /// 曝光只读刷新(0x5007 / 0x500D / 0x500F;单属性失败置 null 不上抛)。
  Future<void> refreshExposure() async {
    int? f;
    int? s;
    int? iso;
    try {
      f = (await session.getDevicePropValue(PtpDevicePropCode.fNumber)).value as int?;
    } on Exception {
      // 属性失败:置 null,不上抛
    }
    try {
      s = (await session.getDevicePropValue(PtpDevicePropCode.exposureTime)).value as int?;
    } on Exception {
      // 同上
    }
    try {
      iso = (await session.getDevicePropValue(PtpDevicePropCode.exposureIndex)).value as int?;
    } on Exception {
      // 同上
    }
    if (!_linkUp) return; // 断连后迟到值不上屏
    exposure = Exposure(fNumber: f, shutterUs: s, iso: iso);
    notifyListeners();
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
        unawaited(refreshExposure());
      default:
        break; // 0xC10C 等:见类注,不消费
    }
  }

  /// 断连/失败:停引擎、清状态;迟到的曝光值/事件被门闩挡住。
  void _invalidate() {
    _linkUp = false;
    unawaited(engine.stop());
    capturing = false;
    error = null;
    notice = null;
    exposure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    engine.status.removeListener(_onEngineStatus);
    super.dispose();
  }
}

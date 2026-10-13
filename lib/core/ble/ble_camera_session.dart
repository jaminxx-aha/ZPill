/// BLE 相机会话(M3):四步配对握手 / 身份复用重连 / TIME 心跳 /
/// GEO 注入。
///
/// 纯协议层,零 Timer —— 心跳与重试全部外部驱动(前台注入驱动页
/// Timer.periodic;iOS 后台由原生 BLE/定位事件唤醒)调 [tick] 与
/// [retryReconnect]:
/// - 状态机:idle → pairing → ready;ready 断连 → reconnecting,
///   退避 1/2/4/8/16/30/60s 封顶,驱动按 [nextRetryDelay] 定时重试;
///   pairing 期断连回 idle(握手作废)。
/// - 重连复用身份:createStage1 带已存 device/nonce,相机据以识别
///   旧会话(TODO「二」既定)。
/// - 写闸:重连后 2.5s 内不写(相机唤醒窗拒收 2900099 同类);GEO
///   写失败同样入闸缓存,到期由 tick 重发。
/// - keep-alive:30s 无发送重发最后定位(nsg 保鲜节奏)。
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../platform/ble_scanner.dart';

import 'gatt_uuids.dart';
import 'geo_payload.dart';
import 'pairing_engine.dart';
import 'pairing_message.dart';
import 'time_payload.dart';

/// 会话状态:idle(未连)/pairing(握手中)/ready(可注入)/
/// reconnecting(断连退避中)。
enum BleSessionState { idle, pairing, ready, reconnecting }

/// 配对身份(持久化由上层身份存储做,本层只暴露)。
class BleIdentity {
  const BleIdentity({
    required this.peripheralUuid,
    required this.deviceId,
    required this.nonce,
    required this.serial,
    required this.name,
  });

  /// 系统 BLE 设备标识(iOS peripheral.identifier / Android MAC)。
  final String peripheralUuid;
  final int deviceId;
  final int nonce;

  /// 相机 BLE 侧序列号(stage4 帧,独立于 USB 序列)。
  final String serial;
  final String name;
}

/// 握手失败(配对/重连共用)。
class BlePairingException implements Exception {
  BlePairingException(this.message);
  final String message;
  @override
  String toString() => 'BlePairingException: $message';
}

final class BleCameraSession {
  BleCameraSession({
    required BleHost host,
    this.controllerName = 'NikonPill',
    this.handshakeTimeout = const Duration(seconds: 15),
    DateTime Function()? now,
  })  : _host = host,
        _now = now ?? DateTime.now {
    _sub = host.events.listen(_onEvent);
  }

  /// 写 0x2002 的控制器名(32B ASCII 零填充;相机「已配对设备」显示)。
  final String controllerName;

  /// 握手/连接总闸(15s):连上非相机(扫描全量列表误点)或相机已退出
  /// 配对菜单时,stage1 无应答 —— 没有超时 pair() 会永久挂在 pairing。
  final Duration handshakeTimeout;

  /// 诊断跟踪(配对页 hex 日志用;每帧 device/nonce 落一行,可随时
  /// 换绑/清空)。
  void Function(String line)? onTrace;

  static const double _minSendDistanceM = 3.0;
  static const Duration _minSendInterval = Duration(seconds: 20);
  static const Duration _keepAlive = Duration(seconds: 30);
  static const Duration _writeGate = Duration(milliseconds: 2500);
  static const List<int> _backoffSeconds = [1, 2, 4, 8, 16, 30, 60];

  final BleHost _host;
  final DateTime Function() _now;
  final NikonPairingEngine _engine = NikonPairingEngine();
  late final StreamSubscription<BleEvent> _sub;

  BleSessionState _state = BleSessionState.idle;
  BleSessionState get state => _state;
  final _stateCtrl = StreamController<BleSessionState>.broadcast();
  Stream<BleSessionState> get states => _stateCtrl.stream;

  /// 配对/重连成功后填充;重连以其 deviceId 扫描匹配。
  BleIdentity? identity;
  String? lastError;

  Completer<void>? _handshake;
  PairingMessage? _stage1;
  bool _stage3Sent = false;
  bool _nameWritten = false;
  String? _connectedUuid;
  bool _resuming = false;
  String? _serial;
  int _backoffStep = 0;
  DateTime? _gateWritesUntil;

  GeoFix? _lastFix;
  GeoFix? _pendingFix;
  GeoFix? _lastSent;
  DateTime? _lastSentAt;

  /// 最近一次收到的定位(含未满足节流的;UI 可显示)。
  GeoFix? get lastFix => _lastFix;

  /// 注入诊断计数(配对页状态行):GEO/TIME 实发成功帧数与最后 GEO
  /// 时刻 —— 0 帧 = 链路/授权没跑起来,N 帧 = 载荷已到相机。
  int geoWriteCount = 0;
  int timeWriteCount = 0;
  DateTime? lastGeoAt;

  /// 下次重连建议退避(驱动按此定时调 [retryReconnect])。
  Duration get nextRetryDelay =>
      Duration(seconds: _backoffSeconds[min(_backoffStep, _backoffSeconds.length - 1)]);

  /// 配对扫描(相机须先进「连接至智能设备」配对菜单,广播窗 ~30s)。
  Future<List<BleDevice>> scanForPairing(
          {Duration timeout = const Duration(seconds: 30)}) =>
      _host.scan(timeout: timeout);

  /// 与已发现设备完整配对:连接 → 4 步握手 → 写控制器名。
  /// 成功填 [identity] 并转 ready;失败抛 [BlePairingException] 回 idle。
  Future<void> pair(BleDevice device) async {
    if (_state != BleSessionState.idle) {
      throw StateError('会话非 idle(state=$_state)');
    }
    _resuming = false;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    try {
      await _host.connectPaired(device.uuid).timeout(handshakeTimeout);
      await done.future.timeout(handshakeTimeout);
    } on TimeoutException {
      _abandonHandshake(done);
      throw BlePairingException(
          '握手超时(${handshakeTimeout.inSeconds}s 无相机应答)—— 相机须停在'
          '「连接至智能设备」配对页(广播窗约 30s)再点扫描连接');
    } on Exception {
      _setState(BleSessionState.idle);
      _handshake = null;
      rethrow;
    }
  }

  /// 断连重连一次尝试:按已存身份 deviceId 扫广播,命中即连接并以
  /// 已存 device/nonce 复用握手。无命中只推进退避(返回 false)。
  /// reconnecting = 断连退避档;idle 且已有身份 = 冷启恢复档(盘载
  /// 身份直接进重试循环,免重走相机菜单配对)。
  Future<bool> retryReconnect() async {
    if (identity == null ||
        (_state != BleSessionState.reconnecting &&
            _state != BleSessionState.idle)) {
      return false;
    }
    final devices = await _host
        .scanForDeviceId(identity!.deviceId, timeout: const Duration(seconds: 8));
    final match = devices.isEmpty ? null : devices.first;
    if (match == null) {
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
    _resuming = true;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    try {
      await _host.connectPaired(match.uuid).timeout(handshakeTimeout);
      await done.future.timeout(handshakeTimeout);
      return true;
    } on TimeoutException {
      _abandonHandshake(done);
      // 重连超时:留在 reconnecting(退避推进),重试循环继续,不塌回
      // idle 停摆 —— 相机唤醒窗错过的场景下一轮再试。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception {
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
  }

  /// 超时弃局:迟到的握手完成挂空捕获(防 unhandled async error),清
  /// 握手态,拆链回 idle。
  void _abandonHandshake(Completer<void> done) {
    done.future.catchError((Object _) {});
    _handshake = null;
    _stage1 = null;
    _stage3Sent = false;
    unawaited(_host.disconnect());
    _setState(BleSessionState.idle);
  }

  /// 断开回 idle(身份保留;重连仍可复用)。
  Future<void> disconnect() async {
    try {
      await _host.disconnect();
    } on Exception {
      // 已断链时忽略。
    }
    _setState(BleSessionState.idle);
  }

  void dispose() {
    _sub.cancel();
    _stateCtrl.close();
  }

  // ------------------------------------------------------------------
  // 注入
  // ------------------------------------------------------------------

  /// 定位到达(定位流回调)。ready 且过写闸且节流通过(位移 ≥3m 或
  /// 距上次 ≥20s)即写 GEO。
  void onFix(GeoFix fix) {
    _lastFix = fix;
    if (_state != BleSessionState.ready) return;
    final t = _now();
    if (_gated(t)) return;
    final sent = _lastSent;
    final moved =
        sent == null || _distanceM(sent, fix) >= _minSendDistanceM;
    final stale = _lastSentAt == null ||
        t.difference(_lastSentAt!) >= _minSendInterval;
    if (moved || stale) {
      unawaited(_sendGeo(fix, t));
    }
  }

  /// 外部心跳驱动(幂等):写闸期直接返回;到期重发 GEO → TIME
  /// 心跳 → keep-alive(30s 无发送重发最后定位)。
  Future<void> tick() async {
    if (_state != BleSessionState.ready) return;
    final t = _now();
    if (_gated(t)) return;
    final pending = _pendingFix;
    if (pending != null) {
      _pendingFix = null;
      await _sendGeo(pending, t);
      if (_gated(_now())) return;
    }
    try {
      await _host.write(kNikonCharTime, TimePayload.build(t));
      timeWriteCount++;
    } on Exception catch (e) {
      lastError = 'TIME 写失败:$e';
    }
    final sent = _lastSent;
    if (sent != null &&
        _lastSentAt != null &&
        t.difference(_lastSentAt!) >= _keepAlive) {
      await _sendGeo(sent, t);
    }
  }

  Future<void> _sendGeo(GeoFix fix, DateTime t) async {
    _lastSent = fix;
    _lastSentAt = t;
    try {
      await _host.write(kNikonCharGeo, GeoPayload().build(fix));
      geoWriteCount++;
      lastGeoAt = t;
    } on Exception catch (e) {
      _pendingFix = fix;
      _gateWritesUntil = t.add(_writeGate);
      lastError = 'GEO 写失败:$e';
    }
  }

  bool _gated(DateTime t) =>
      _gateWritesUntil != null && t.isBefore(_gateWritesUntil!);

  /// 球面距离(米;haversine,注入节流精度足够)。
  static double _distanceM(GeoFix a, GeoFix b) {
    const r = 6371000.0;
    double rad(double d) => d * pi / 180;
    final dLat = rad(b.latitude - a.latitude);
    final dLon = rad(b.longitude - a.longitude);
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(rad(a.latitude)) *
            cos(rad(b.latitude)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return 2 * r * atan2(sqrt(h), sqrt(1 - h));
  }

  // ------------------------------------------------------------------
  // 事件推进(握手状态机)
  // ------------------------------------------------------------------

  Future<void> _onEvent(BleEvent event) async {
    switch (event) {
      case BleConnected(:final uuid):
        if (_state != BleSessionState.pairing) return;
        _connectedUuid = uuid;
        if (_resuming) {
          _gateWritesUntil = _now().add(_writeGate);
        }
        try {
          await _host.setNotify(kNikonCharPairing);
          await _host.setNotify(kNikonCharNot1);
          // NOT2(0x200A)留观察窗:方言核对期跟踪信号帧,不参与状态机。
          await _host.setNotify(kNikonCharNot2);
          // 会话控制面观察(SnapBridge 方言):帧落诊断日志,不参与状态机。
          await _host.setNotify(kNikonCharStatusForControl);
          await _host.setNotify(kNikonCharControlPoint);
          final stage1 = _engine.createStage1(
            savedDevice: _resuming ? identity!.deviceId : null,
            savedNonce: _resuming ? identity!.nonce : null,
          );
          _stage1 = stage1;
          _stage3Sent = false;
          _nameWritten = false;
          await _host.write(kNikonCharPairing, stage1.encode());
          _trace('stage1 → device=${stage1.device.toRadixString(16)} '
              'nonce=${stage1.nonce.toRadixString(16)}'
              '${_resuming ? '(复用)' : '(全新)'}');
        } on Exception catch (e) {
          lastError = '握手起始失败:$e';
          _failHandshake();
        }
      case BleNotified(:final uuid, :final data):
        if (uuid == kNikonCharPairing) {
          await _onPairingFrame(data);
        } else if (uuid == kNikonCharNot1) {
          await _onNot1(data);
        } else if (uuid == kNikonCharNot2) {
          _trace(
              'NOT2 ← ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        } else if (uuid == kNikonCharStatusForControl ||
            uuid == kNikonCharControlPoint) {
          _trace(
              '${uuid.substring(4, 8)} ← ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        }
      case BleDisconnected():
        if (_state == BleSessionState.pairing) {
          lastError = '握手期间断连';
          _failHandshake();
        } else if (_state == BleSessionState.ready) {
          _backoffStep = 0;
          _setState(BleSessionState.reconnecting);
        }
      case BleError(:final code, :final message):
        lastError = '$code:$message';
      case BleStateChanged() || BleDeviceFound():
        break;
    }
  }

  Future<void> _onPairingFrame(Uint8List data) async {
    final stage1 = _stage1;
    if (stage1 == null) return;
    if (_stage3Sent) {
      // stage4:字节 9-16 = 相机 BLE 侧序列号(NUL 截止)。
      if (data.length == PairingMessage.length) {
        _serial = _engine.extractSerial(PairingMessage.decode(data));
        _trace('stage4 → 序列号=$_serial');
        // 真机方言(2026-10-13 Zf):名字先行 —— 相机收下 0x2002 控制
        // 器名后才发 NOT1 确认;等 NOT1 再写名会双方互等到超时。
        await _writeName();
      }
      return;
    }
    if (data.length != PairingMessage.length) {
      lastError = 'PAIR 帧长度异常(${data.length})';
      _trace('PAIR 帧长度异常(${data.length})');
      return;
    }
    final msg = PairingMessage.decode(data);
    _trace('stage2 ← device=${msg.device.toRadixString(16)} '
        'nonce=${msg.nonce.toRadixString(16)}');
    final stage3 = _engine.verifyStage2AndBuildStage3(stage1, msg);
    if (stage3 == null) {
      lastError = 'stage2 无 salt 命中,握手失败';
      _trace('stage2 无 salt 命中(8 组 salt 全试未中)');
      _failHandshake();
      return;
    }
    _stage3Sent = true;
    try {
      await _host.write(kNikonCharPairing, stage3.encode());
      _trace('stage3 → device=${stage3.device.toRadixString(16)} '
          'nonce=${stage3.nonce.toRadixString(16)}');
    } on Exception catch (e) {
      lastError = 'stage3 写失败:$e';
      _failHandshake();
    }
  }

  /// NOT1 只作跟踪(真机 2026-10-13 实测:Zf 收下名字后并不回 NOT1,
  /// 闸门在名字写;此帧若到,配对多半已收口,纯信息)。
  Future<void> _onNot1(Uint8List data) async {
    _trace(
        'NOT1 ← ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
  }

  /// 写 0x2002 控制器名(32B ASCII 零填充)。真机方言(2026-10-13
  /// Zf):stage4 沿即发;名字落定即收口 —— NOT1 非闸门,实测不回。
  Future<void> _writeName() async {
    final stage1 = _stage1;
    if (stage1 == null) return;
    final name = controllerName.codeUnits;
    final payload = Uint8List(32);
    for (var i = 0; i < name.length && i < 32; i++) {
      payload[i] = name[i] & 0xFF;
    }
    try {
      await _host.write(kNikonCharName, payload);
      _nameWritten = true;
      _trace('0x2002 控制器名已写($controllerName)');
    } on Exception catch (e) {
      lastError = '控制器名写失败:$e';
      _failHandshake();
      return;
    }
    _completeIfReady();
  }

  /// 名字已写 → 收口(stage4 序列号 + 0x2002 名字落定 = 相机侧配对
  /// 实质完成;NOT1 非闸门 —— 真机 2026-10-13 实测 Zf 不主动回)。
  void _completeIfReady() {
    if (!_nameWritten) return;
    final stage1 = _stage1;
    if (stage1 == null) return;
    identity = BleIdentity(
      peripheralUuid: _connectedUuid ?? '',
      deviceId: stage1.device,
      nonce: stage1.nonce,
      serial: _serial ?? identity?.serial ?? '',
      name: controllerName,
    );
    _backoffStep = 0;
    _setState(BleSessionState.ready);
    _handshake?.complete();
    _handshake = null;
    _trace('配对成功 ✓ device=${stage1.device.toRadixString(16)}');
    // 收口沿即校时(SnapBridge 语义:配对事务末环;相机注册可能等
    // 这帧才落档 —— CLI 真机那次 TIME 显式写过,app 此前从没发过)。
    unawaited(() async {
      try {
        await _host.write(
            kNikonCharTime, TimePayload.build(_now().toUtc()));
        _trace('TIME → 收口沿校时已发');
      } on Exception catch (e) {
        _trace('TIME 收口沿校时失败:$e');
      }
    }());
  }

  void _failHandshake() {
    _stage1 = null;
    _stage3Sent = false;
    _handshake?.completeError(BlePairingException(lastError ?? '握手失败'));
    _handshake = null;
    _setState(BleSessionState.idle);
  }

  void _setState(BleSessionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(s);
    }
  }

  void _trace(String line) => onTrace?.call(line);
}

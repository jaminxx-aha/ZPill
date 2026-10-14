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
import 'wifi_credentials.dart';

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
  /// 可变:配对页实验用(SnapBridge 按平台写前缀名 —— Android 版实证
  /// `Android_<机型>_<4位随机>`;相机以名识别客户端类型,见 0x2008 注)。
  String controllerName;

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
  /// 首配注册等待(NOT1 01 00 = 相机侧注册完成信号;2026-10-13 定案:
  /// 注册在配对事务的 bond 落地后完成,NOT1 此前从不出现)。
  Completer<bool>? _registrationWait;
  /// 第二段静默窗(相机 DEEP_SLEEP_WAIT 周期:配对后半段相机进深睡,
  /// 醒来才发 SMP 安全请求;期间任何 GATT 流量都会被打断掐线 ——
  /// SnapBridge 同名 Progress 阶段实证)。0 = 不静默。
  Duration silentBondWait = Duration.zero;

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

  /// 直连重连(iOS 首配第二段):相机静默等待态无广播可扫,直接按
  /// 本会话已知 peripheralUuid 连(iOS retrievePeripherals 能找回本
  /// 会话已见外设)。连接沿相机可能发 SMP 安全请求 → iOS 弹配对码 →
  /// 确认后 bond 落、注册完成。握手超时放宽(60s):等用户确认弹窗。
  Future<bool> reconnectDirect() async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
    _resuming = true;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    try {
      await _host
          .connectPaired(identity!.peripheralUuid)
          .timeout(const Duration(seconds: 20));
      await done.future.timeout(const Duration(seconds: 60));
      return true;
    } on TimeoutException {
      _abandonHandshake(done);
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception catch (e) {
      lastError = '第二段连接失败:$e';
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
  }

  /// 扫描式二连(iOS 首配第二段,2026-10-14 订正):未注册相机每次广播
  /// 轮换 RPA(iOS identifier 随之变),直连旧 uuid = 打给已旋转的地址
  /// —— 必须像 SnapBridge BLE2ND 的 FIND_CAMERA_BLE 一样**重扫**,拿
  /// 新广播的新 uuid 连接;连上**立即**跑复用握手(device/nonce 在
  /// stage1 里走,与 BLE 地址无关),静默等待反而会被相机当死客户端
  /// 掐线。握手超时放宽(45s):等用户确认可能出现的系统配对码弹窗。
  Future<bool> reconnectScan({Duration scanTimeout = const Duration(seconds: 10)}) async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
    silentBondWait = Duration.zero;
    final devices = await _host.scan(timeout: scanTimeout);
    if (devices.isEmpty) {
      lastError = '二段扫描无相机广播';
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
    final target = devices.first;
    _resuming = true;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    try {
      await _host.connectPaired(target.uuid).timeout(const Duration(seconds: 20));
      await done.future.timeout(const Duration(seconds: 45));
      return true;
    } on TimeoutException {
      _abandonHandshake(done);
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception catch (e) {
      lastError = '二段连接失败:$e';
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
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

  /// 唤起相机 WiFi(0x2005 CONNECTION_ESTABLISHMENT 写 0x01;M7 独立
  /// 按钮 —— 相机热点开启后到系统 Wi-Fi 加入走 AP 传图)。仅 ready 态
  /// 可发;失败落 lastError 返回 false。
  Future<bool> wakeCameraWifi() => _writeEstablishment(0x01, '唤起 WiFi');

  /// 关闭相机 WiFi(0x2005 写 0x80,同款反义 op)。
  Future<bool> closeCameraWifi() => _writeEstablishment(0x80, '关闭 WiFi');

  /// 读 0x2004 相机 AP 凭据并解密(BLE→WiFi 二期)。特征面是会话激活
  /// 的(会话外读恒为零),须 ready 态;失败返回 null 原因落 lastError,
  /// blob 落 trace 供候选密钥增补。
  Future<WifiCredentials?> readWifiCredentials() async {
    if (_state != BleSessionState.ready) {
      lastError = 'BLE 未连接,无法读 AP 凭据';
      return null;
    }
    try {
      final blob = await _host.read(kNikonCharConfig);
      _trace('0x2004 ← ${blob == null ? 'null' : '${blob.length}B ${hex(blob)}'}');
      if (blob == null || blob.isEmpty) {
        lastError = '相机未下发 AP 凭据(0x2004 空)';
        return null;
      }
      if (blob.length < 97) {
        lastError = 'AP 凭据长度异常(${blob.length}B,应为 97B)';
        return null;
      }
      final creds = decodeWifiCredentials(blob);
      if (creds == null) {
        lastError = 'AP 凭据解密未中(候选密钥全试未命中,blob 已落诊断日志)';
      }
      return creds;
    } on Exception catch (e) {
      lastError = '读 AP 凭据失败:$e';
      return null;
    }
  }

  Future<bool> _writeEstablishment(int value, String label) async {
    if (_state != BleSessionState.ready) {
      lastError = 'BLE 未连接,无法$label';
      return false;
    }
    try {
      await _host.write(kNikonCharWifi, Uint8List.fromList([value]));
      _trace('$label → 0x2005=0x${value.toRadixString(16)}');
      return true;
    } on Exception catch (e) {
      lastError = '$label 失败:$e';
      return false;
    }
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
          // 第二段静默窗:深睡周期内零 GATT 流量(SnapBridge 的
          // DEEP_SLEEP_WAIT 同款);窗内相机发安全请求 → 系统配对码。
          if (_resuming && silentBondWait > Duration.zero) {
            _trace('第二段静默 ${silentBondWait.inSeconds}s'
                '(等相机唤醒/安全请求/配对码)…');
            await Future<void>.delayed(silentBondWait);
            silentBondWait = Duration.zero;
            _trace('静默窗结束 → 复用握手');
          }
          await _host.setNotify(kNikonCharPairing);
          await _host.setNotify(kNikonCharNot1);
          // NOT2(0x200A)留观察窗:方言核对期跟踪信号帧,不参与状态机。
          await _host.setNotify(kNikonCharNot2);
          // 读特征面(SnapBridge 配对期读 0x2004 同款;若相机挂「加密
          // 读」权限,读触发 iOS LE 配对弹窗 —— 首配注册通道,弹窗由
          // 系统处理,读失败照常继续不挡握手)。
          unawaited(() async {
            for (final uuid in const [
              kNikonCharConfig,
              kNikonCharServerName,
              kNikonCharFeature,
              kNikonCharPowerControl,
              kNikonCharSerialString,
              kNikonCharStatusForControl,
            ]) {
              try {
                final v = await _host.read(uuid);
                _trace(
                    'read ${uuid.substring(4, 8)} → ${v == null ? 'null' : '${v.length}B'}');
              } on Exception catch (e) {
                _trace('read ${uuid.substring(4, 8)} 失败:$e');
              }
            }
          }());
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

  /// 0x2008 LSS_CONTROL_POINT 跟踪(SnapBridge smali 定案:2B LE 位域
  /// `(Connection<<8)|(Location<<4)|Time`,相机经 notify 发布自己的请求
  /// 位,app 读后清位应答;`01 00` = TimeRequest ON「要时间」而非配对
  /// 成功标志)。此帧若到,顺带完结注册等待(注册后相机才会发请求位)。
  Future<void> _onNot1(Uint8List data) async {
    if (data.length == 2) {
      final time = data[0] & 0x0F;
      final loc = (data[0] >> 4) & 0x0F;
      final conn = data[1] & 0x0F;
      _trace('0x2008 ← ${hex(data)} '
          '(Time=$time Loc=$loc Conn=$conn)');
      if (time >= 1) {
        _registrationWait?.complete(true);
        _registrationWait = null;
      }
    } else {
      _trace('0x2008 ← ${hex(data)}');
    }
  }

  static String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  /// 挂在原连接上等注册完成信号(NOT1 01 00;相机在注册挂起态可能于
  /// 原连接上延迟发安全请求 → 用户确认 → bond → 注册 → NOT1)。
  /// 到窗未至返回 false(调用方转第二段直连)。
  Future<bool> waitRegistration({Duration window = const Duration(seconds: 45)}) async {
    if (_state != BleSessionState.ready) {
      return false;
    }
    final wait = _registrationWait = Completer<bool>();
    final got = await wait.future.timeout(window, onTimeout: () => false);
    _registrationWait = null;
    return got;
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

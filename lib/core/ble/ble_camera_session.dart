/// BLE 相机会话(M3):四步配对握手 / 身份复用重连 / TIME 保活 /
/// GEO 注入。
///
/// 纯协议层,周期驱动零 Timer —— 保活与重试全部外部驱动(前台注入
/// 驱动页 Timer.periodic;iOS 后台由原生 BLE/定位事件唤醒)调 [tick]
/// 与 [retryReconnect]:
/// - 状态机:idle → pairing → ready;ready 断连 → reconnecting,
///   退避 1/2/4/8/16/30/60s 封顶,驱动按 [nextRetryDelay] 定时重试;
///   pairing 期断连回 idle(握手作废)。
/// - 重连复用身份:createStage1 带已存 device/nonce,相机据以识别
///   旧会话(既定方案)。
/// - 首写门:Ready(首配/重连同套)后 [writeGate] 内不写 GEO/TIME
///   (相机 GPS 会话未醒拒收 0x2007,HarmoNiLink 实证;ohos 2900099
///   「醒着但会话未就绪」瞬态同类减灾,非替代重试);过闸首笔 TIME
///   (收口校时)由一次性延迟自发([_deferredFirstWrite]),不依赖驱动
///   tick —— 配对页挂起期驱动停摆。写失败走既有路径:GEO 入闸缓存
///   重发,TIME 下一拍到点重试。
/// - TIME 保活:前台 45s/后台 90s 档位([setForeground];相机 2min
///   无 BLE 流量掐链,写 0x2006 内容=当前时刻顺带持续校时)。
/// - GEO 注入:定位流事件驱动([onFix]),距上次成功注入 <3s 且位移
///   <1.1m 跳过(去重门见 [BleKeepalive]);30s 无成功注入重发最后
///   定位(nsg 保鲜节奏)。
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../../l10n/message.dart';
import '../../platform/ble_scanner.dart';

import '../log/app_log.dart';
import 'adv_payload.dart';
import 'ble_keepalive.dart';
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
    this.writeGate = const Duration(milliseconds: 2500),
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

  /// 写闸:Ready 后首笔 GEO/TIME 与 GEO 失败回补共用的静默窗(相机
  /// GPS 会话未醒拒收 0x2007 的减灾前置;2900099 瞬态同类)。
  final Duration writeGate;

  /// 诊断跟踪(配对页 hex 日志用;每帧 device/nonce 落一行,可随时
  /// 换绑/清空)。
  void Function(String line)? onTrace;

  /// GEO 保鲜间隔(nsg 节奏):持续无成功注入时重发最后定位。
  static const Duration _keepAlive = Duration(seconds: 30);
  static const List<int> _backoffSeconds = [1, 2, 4, 8, 16, 30, 60];

  final BleHost _host;
  final DateTime Function() _now;
  final NikonPairingEngine _engine = NikonPairingEngine();
  final BleKeepalive _keepalive = BleKeepalive();
  late final StreamSubscription<BleEvent> _sub;

  BleSessionState _state = BleSessionState.idle;
  BleSessionState get state => _state;
  final _stateCtrl = StreamController<BleSessionState>.broadcast();
  Stream<BleSessionState> get states => _stateCtrl.stream;
  final _errorCtrl = StreamController<L10nMessage?>.broadcast();

  /// 错误沿(实时):lastError 变化(含 ready 沿清空)即发,UI 订阅
  /// 即时上屏,不等无关重建。随 [_stateCtrl] 一并关闭。
  Stream<L10nMessage?> get errors => _errorCtrl.stream;

  /// 配对/重连成功后填充;重连以其 deviceId 扫描匹配。
  BleIdentity? identity;

  L10nMessage? _lastError;

  /// 最近一次失败原因;ready 沿自动清空(陈旧错误不上屏)。
  /// 消息为键+参([L10nMessage]),渲染端统一 t()/tm() 落地。
  L10nMessage? get lastError => _lastError;
  set lastError(L10nMessage? v) {
    if (v == _lastError) return;
    _lastError = v;
    if (!_errorCtrl.isClosed) _errorCtrl.add(v);
  }

  /// 最近一次 [retryReconnect] 是否被深睡闸门拦下(下轮尝试开跑即失效;
  /// 上层配对页日志据此区分「无命中」与「被闸」)。
  bool lastRetryGated = false;

  /// 最近一次命中设备的广播名([pair]/[retryReconnect] 命中沿更新;
  /// iOS 系统缓存 GAP 名基本恒有,Android 重连广播可能无名 = 空)——
  /// ready 沿旧档相机名回填(ConnectionController.healCameraName)消费,
  /// 旧版档案缺 cameraName 字段时免重配补名。
  String lastMatchName = '';

  Completer<void>? _handshake;
  PairingMessage? _stage1;
  bool _stage3Sent = false;
  bool _nameWritten = false;
  String? _connectedUuid;
  bool _resuming = false;
  String? _serial;

  /// 取消纪元(十三轮):[disconnect] 沿推进 —— 在途连接尝试
  /// (retryReconnect/reconnectDirect/reconnectScan)的迟到收口不再把
  /// 状态翻回 reconnecting。用户取消沿状态已回 idle,若无此闸,握手的
  /// 60s 超时会迟到触发把页面「复活」成连接中(且 manualOff 压着驱动,
  /// 谁也不会真的再连 —— 假在途卡死)。
  int _cancelEpoch = 0;
  int _backoffStep = 0;
  /// 深睡闸门连续跳过轮数(episode 限频日志用;非闸沿归零)。
  int _standbySkips = 0;
  DateTime? _gateWritesUntil;
  /// 首配注册等待(NOT1 01 00 = 相机侧注册完成信号;2026-10-13 定案:
  /// 注册在配对事务的 bond 落地后完成,NOT1 此前从不出现)。
  Completer<bool>? _registrationWait;
  /// 第二段静默窗(相机 DEEP_SLEEP_WAIT 周期:配对后半段相机进深睡,
  /// 醒来才发 SMP 安全请求;期间任何 GATT 流量都会被打断掐线 ——
  /// SnapBridge 同名 Progress 阶段实证)。0 = 不静默。
  Duration silentBondWait = Duration.zero;

  /// iOS 首配 bond 探针静默窗旗标([runIosBondProbe] 挂窗期间置位):
  /// onFix / _flushDueWrites / 手发件(0x2005 写、0x2004 读)共查,
  /// 窗内除探针自身写外零 GATT 流量。
  bool _bondProbeActive = false;

  /// 最近一次连接发现的全特征表(权限掩码;iOS properties 不标加密,
  /// 加密门只在访问沿现形,v9 面扫用)。
  Map<String, String>? _lastCharacteristics;
  /// NOT1 Time 位粘性记忆:注册完成信号可能早于挂等待(握手期读面
  /// 触发弹窗、用户秒确认即属此路径),先到先记;BleConnected 沿复位
  /// (防换相机串台)。
  bool _registrationDoneSeen = false;
  /// 握手期特征面读收口句柄(探针起步前等它落定,防读溢出静默窗)。
  Future<void>? _introReads;

  GeoFix? _pendingFix;
  /// 上次成功注入的定位与时刻(去重门/保鲜锚;失败沿不更新)。
  GeoFix? _lastOkFix;
  DateTime? _lastOkAt;
  /// 上次成功 TIME 写时刻(保活档位锚;Ready 沿清零 = 首笔校时待发)。
  DateTime? _lastTimeOkAt;

  /// 下次重连建议退避(驱动按此定时调 [retryReconnect])。
  Duration get nextRetryDelay =>
      Duration(seconds: _backoffSeconds[min(_backoffStep, _backoffSeconds.length - 1)]);

  /// 配对扫描(相机须先进「连接至智能设备」配对菜单,广播窗 ~30s)。
  Future<List<BleDevice>> scanForPairing(
          {Duration timeout = const Duration(seconds: 30)}) =>
      _host.scan(timeout: timeout);

  /// 停配对扫描(十四轮):显式重连(manualResume)沿停面板在途自动扫
  /// —— 扫描互踩扫描(BLE 无线电独占),重连的 scanForDeviceId 与自页
  /// 30s 扫描窗并行 = 全程无命中,「断开后怎么都连不上」主因之一。
  Future<void> stopScan() => _host.stopScan();

  /// 与已发现设备完整配对:连接 → 4 步握手 → 写控制器名。
  /// 成功填 [identity] 并转 ready;失败抛 [BlePairingException] 回 idle。
  Future<void> pair(BleDevice device) async {
    if (_state != BleSessionState.idle) {
      throw StateError('会话非 idle(state=$_state)');
    }
    lastMatchName = device.name;
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

  /// 配对码探针进行中(面板自动重连/注入驱动让路;真机 2026-10-19
  /// 实证:探针断链后面板重挂自动重连与注入驱动的重扫会掐死探针二段
  /// 的扫描 —— iOS 原生扫描单槽,新扫描起即收掉旧扫描)。
  bool get bondProbeActive => _bondProbeActive;

  /// 断连重连一次尝试:按已存身份 deviceId 扫广播,命中即连接并以
  /// 已存 device/nonce 复用握手。无命中只推进退避(返回 false)。
  /// reconnecting = 断连退避档;idle 且已有身份 = 冷启恢复档(盘载
  /// 身份直接进重试循环,免重走相机菜单配对)。
  ///
  /// [gateStandby] 深睡闸门(默认开):扫到广播待机位(bit0=1,Zf
  /// 0x1E/0x1F 真机实证)不连 —— 连接会打断深睡(Z6 III 固件 7.5s
  /// 监督超时掐链,Zf 深睡被动重连固有开销 ~12s),而被动扫描不惊动
  /// 相机;闸门期退避冻结在 2s,相机唤醒(半按快门,bit0=0)后下一
  /// 轮即快连。手动重连(显式用户意图)传 false 绕闸。
  Future<bool> retryReconnect({bool gateStandby = true}) async {
    if (_bondProbeActive) return false; // 探针期让路(防扫描互掐)
    if (identity == null ||
        (_state != BleSessionState.reconnecting &&
            _state != BleSessionState.idle)) {
      return false;
    }
    final epoch = _cancelEpoch; // 十三轮:取消沿迟到收口不推态。
    final devices = await _host
        .scanForDeviceId(identity!.deviceId, timeout: const Duration(seconds: 8));
    lastRetryGated = false;
    final match = devices.isEmpty ? null : devices.first;
    lastMatchName = match?.name ?? '';
    if (match == null) {
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
    if (gateStandby &&
        advertisedPowerState(match.mfgData) == NikonAdvPowerState.standby) {
      // 首闸落一行日志(episode 级限频,防待机数小时刷屏)。
      if (_standbySkips == 0) {
        AppLog.i(AppLog.ble, '深睡闸门:相机广播待机位,暂缓连接等唤醒');
      }
      _standbySkips++;
      lastRetryGated = true;
      _backoffStep = min(1, _backoffSeconds.length - 1);
      return false;
    }
    if (epoch != _cancelEpoch) {
      return false; // 已取消:预连接沿也不再推进 —— 否则取消落在扫描窗
      // 内时本尝试照旧入 pairing,僵尸态把后续尝试全挡在门外(十四轮)。
    }
    _standbySkips = 0;
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
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      // 重连超时:留在 reconnecting(退避推进),重试循环继续,不塌回
      // idle 停摆 —— 相机唤醒窗错过的场景下一轮再试。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception {
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
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
  /// v8b(2026-10-19 v8 真机订正)升为探针二段主路:leg-1 收口后
  /// 断链,相机**零广播** 2 分钟+ —— 静默等待态唯直连可及。
  Future<bool> reconnectDirect() async {
    if (_bondProbeActive) return false; // 探针期让路(核由探针自调)
    return _reconnectDirect();
  }

  Future<bool> _reconnectDirect() async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
    final epoch = _cancelEpoch; // 十三轮:取消沿迟到收口不推态。
    _resuming = true;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    var linked = false;
    try {
      await _host
          .connectPaired(identity!.peripheralUuid)
          .timeout(const Duration(seconds: 20));
      linked = true;
      await done.future.timeout(const Duration(seconds: 60));
      return true;
    } on TimeoutException {
      lastError = linked
          ? (key: 'ble.stage2HandshakeTimeout', args: null)
          : (key: 'ble.stage2DirectTimeout', args: null);
      _abandonHandshake(done);
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception catch (e) {
      lastError = (key: 'ble.stage2ConnectFail', args: {'e': e.toString()});
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
  }

  /// 扫描式二连(iOS 首配第二段):未注册相机每次广播轮换 RPA(iOS
  /// identifier 随之变),直连旧 uuid = 打给已旋转的地址 —— 必须像
  /// SnapBridge BLE2ND 的 FIND_CAMERA_BLE 一样**重扫**,拿新广播的新
  /// uuid 连接;连上**立即**跑复用握手(device/nonce 在 stage1 里走,
  /// 与 BLE 地址无关),静默等待反而会被相机当死客户端掐线。握手超时
  /// 放宽(45s):等用户确认可能出现的系统配对码弹窗。v8b(2026-10-19
  /// v8 真机订正)降为探针二段兜底:leg-1 收口后断链相机零广播 2
  /// 分钟+,主路改 [reconnectDirect],此路只在直连未成时兜底。
  Future<bool> reconnectScan(
      {Duration scanTimeout = const Duration(seconds: 10)}) async {
    if (_bondProbeActive) return false; // 探针期让路(核由探针自调)
    return _reconnectScan(scanTimeout: scanTimeout);
  }

  Future<bool> _reconnectScan(
      {Duration scanTimeout = const Duration(seconds: 10)}) async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
    silentBondWait = Duration.zero;
    final epoch = _cancelEpoch; // 十三轮:取消沿迟到收口不推态。
    final devices = await _host.scan(timeout: scanTimeout);
    if (devices.isEmpty) {
      lastError = (key: 'ble.stage2ScanNoBroadcast', args: null);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
    final target = devices.first;
    if (epoch != _cancelEpoch) {
      return false; // 已取消:预连接沿也不再推进(十四轮,同 retryReconnect)。
    }
    _resuming = true;
    _serial = null;
    _setState(BleSessionState.pairing);
    final done = _handshake = Completer<void>();
    var linked = false;
    try {
      await _host.connectPaired(target.uuid).timeout(const Duration(seconds: 20));
      linked = true;
      await done.future.timeout(const Duration(seconds: 45));
      return true;
    } on TimeoutException {
      lastError = linked
          ? (key: 'ble.stage2HandshakeTimeout', args: null)
          : (key: 'ble.stage2ConnectTimeout', args: null);
      _abandonHandshake(done);
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception catch (e) {
      lastError = (key: 'ble.stage2ConnectFail', args: {'e': e.toString()});
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
  }

  /// 断开回 idle(身份保留;重连仍可复用)。十三轮:在途握手一并弃局
  /// —— 立刻 completeError 让等待沿当场收口(迟到的 60s 超时不再复活
  /// 状态),纪元推进让各尝试的 catch 不再推 reconnecting。
  Future<void> disconnect() async {
    _cancelEpoch++;
    final pending = _handshake;
    if (pending != null) {
      _abandonHandshake(pending);
      if (!pending.isCompleted) {
        pending.completeError(BlePairingException('已取消'));
      }
    }
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
  Future<bool> wakeCameraWifi() => _writeEstablishment(0x01, 'ble.wakeWifi');

  /// 关闭相机 WiFi(0x2005 写 0x80,同款反义 op)。
  Future<bool> closeCameraWifi() => _writeEstablishment(0x80, 'ble.closeWifi');

  /// 读 0x2004 相机 AP 凭据并解密(BLE→WiFi 二期)。特征面是会话激活
  /// 的(会话外读恒为零),须 ready 态;失败返回 null 原因落 lastError,
  /// blob 落 trace 供候选密钥增补。
  Future<WifiCredentials?> readWifiCredentials() async {
    if (_state != BleSessionState.ready) {
      lastError = (key: 'ble.notConnectedReadCred', args: null);
      return null;
    }
    if (_bondProbeActive) {
      lastError = (key: 'ble.probeGateReadCred', args: null);
      return null;
    }
    try {
      final blob = await _host.read(kNikonCharConfig);
      if (blob == null) {
        _trace('0x2004 ← null');
      } else {
        // AppLog 分支脱敏(加密凭据 blob);onTrace 保持全 hex 供方言核对。
        _trace('0x2004 ← ${blob.length}B ${hex(blob)}',
            masked: '0x2004 ← ${blob.length}B '
                '${AppLog.hex(blob, sensitive: true)}');
      }
      if (blob == null || blob.isEmpty) {
        lastError = (key: 'ble.noCredBroadcast', args: null);
        return null;
      }
      if (blob.length < 97) {
        lastError = (
          key: 'ble.credLengthAbnormal',
          args: {'n': blob.length},
        );
        return null;
      }
      final creds = decodeWifiCredentials(blob);
      if (creds == null) {
        // 十七轮:解密未中**不上 lastError**(错误位)—— 唤醒流程下
        // 相机 Wi-Fi 已开,错误位让位「去系统连 Wi-Fi」红字提醒;细节
        // 落 AppLog(blob 已 trace,候选密钥增补用)。
        AppLog.w(AppLog.ble, 'AP 凭据解密未中(候选密钥全试未命中,blob 已落诊断日志)');
      }
      return creds;
    } on Exception catch (e) {
      lastError = (key: 'ble.readCredFail', args: {'e': e.toString()});
      return null;
    }
  }

  Future<bool> _writeEstablishment(int value, String label) async {
    if (_state != BleSessionState.ready) {
      lastError = (key: 'ble.notConnectedOp', args: {'label': label});
      return false;
    }
    if (_bondProbeActive) {
      lastError = (key: 'ble.probeGateOp', args: {'label': label});
      return false;
    }
    try {
      await _host.write(kNikonCharWifi, Uint8List.fromList([value]));
      _trace('$label → 0x2005=0x${value.toRadixString(16)}');
      return true;
    } on PlatformException catch (e) {
      // 上屏文案只取 message(裸 PlatformException dump 是四段噪音,
      // 用户要看的是「连接已断开」不是构造参数)。
      lastError = (
        key: 'ble.opFail',
        args: {'label': label, 'e': e.message ?? e.code},
      );
      return false;
    } on Exception catch (e) {
      lastError = (key: 'ble.opFail', args: {'label': label, 'e': e.toString()});
      return false;
    }
  }

  void dispose() {
    _sub.cancel();
    _stateCtrl.close();
    _errorCtrl.close();
  }

  // ------------------------------------------------------------------
  // 注入
  // ------------------------------------------------------------------

  /// 前台/后台档位(TIME 保活间隔 45s/90s,见 [BleKeepalive]):上层
  /// 生命周期观察注入(AppServices 挂 AppLifecycleListener);未注入恒
  /// 前台档。切档只改下一拍到点判定,不立即补写。
  void setForeground(bool foreground) => _keepalive.foreground = foreground;

  /// 注入层开关投影(驱动翻面沿同步,2026-10-21 实证补):关断后保鲜
  /// 重发与缓存回补全停 —— 否则关了开关,30s 重发仍拿缓存点刷时间,
  /// 相机位置数据一直在走。TIME 心跳是链路保活,不受此闸。
  bool geoEnabled = false;

  /// ready 沿一次定位更新待办(每次 ready 重置;首个过闸拍消费)。
  bool _readyOneShotPending = false;

  /// 握手起始连续被踢计数(成功 ready 清零;瞬时踢 2s 快试,持续踢换
  /// 引导文案,见 handshakeStartFail 处)。
  int _kickStreak = 0;

  /// 定位到达(定位流回调,事件驱动)。ready、注入开(geoEnabled)、
  /// 过写闸且过去重门(距上次成功注入 <3s 且位移 <1.1m 跳过,见
  /// [BleKeepalive])即写 GEO;写闸期缓存待回补(不弃点)。
  void onFix(GeoFix fix) {
    if (_state != BleSessionState.ready) return;
    if (!geoEnabled) return;
    final t = _now();
    if (_gated(t) || _bondProbeActive) {
      _pendingFix = fix;
      return;
    }
    if (_keepalive.geoPassesDedup(t, fix, _lastOkFix, _lastOkAt)) {
      // 缓存的旧点被本点取代(直发失败沿 _sendGeo 会回填缓存)。
      _pendingFix = null;
      unawaited(_sendGeo(fix, t));
    }
  }

  /// 外部心跳驱动(幂等):非 ready 态零动作(断链 ticker 停);写闸期
  /// 直接返回;过闸走 [_flushDueWrites](缓存定位回补 → TIME 保活到点
  /// → GEO 保鲜)。
  Future<void> tick() async {
    if (_state != BleSessionState.ready) return;
    final t = _now();
    if (_gated(t)) return;
    await _flushDueWrites(t);
  }

  /// 过闸写入体(tick 与首写自发沿 [_deferredFirstWrite] 共用)。探针
  /// 静默窗期整闸 —— 旗标查在顶部,ready 沿睡着、窗内醒来的 deferred
  /// 也拦得住;缓存点由探针收口沿 re-arm 回补。
  ///
  /// 十六轮单飞:tick(驱动周期)与首写自发沿并发进入会对同一特征
  /// (TIME/GEO)各发一笔 withResponse 写,后笔撞原生「同特征已有写在
  /// 途」busy(iOS 逐特征闸);写是周期性保活,丢一拍下一拍兜底,
  /// 单飞跳过不排队。
  bool _flushing = false;

  Future<void> _flushDueWrites(DateTime t) async {
    if (_bondProbeActive) return;
    if (_flushing) return;
    _flushing = true;
    try {
      final pending = _pendingFix;
      if (pending != null) {
        _pendingFix = null;
        if (geoEnabled) {
          await _sendGeo(pending, t);
          if (_gated(_now())) return; // GEO 失败重进闸:后续写等下一拍
        }
      }
      // ready 沿一次定位更新:pending 已带新点则它本身就是更新,缓存点
      // 补发只在这轮没有新点时才做(防双发)。
      if (_readyOneShotPending) {
        _readyOneShotPending = false;
        final cached = _lastOkFix;
        if (geoEnabled && pending == null && cached != null) {
          await _sendGeo(cached.withUtcTime(t.toUtc()), t);
        }
      }
      if (_keepalive.timeDue(t, _lastTimeOkAt)) {
        await _sendTime(t);
      }
      final lastOk = _lastOkFix;
      if (geoEnabled &&
          lastOk != null &&
          _lastOkAt != null &&
          t.difference(_lastOkAt!) >= _keepAlive) {
        // 保鲜重发:坐标用缓存点,时间刷到当前 —— fix 时间取定位回调
        // 沿,静止期 distanceFilter 3m 零回调,原样重发会把 EXIF GPS
        // 时间冻在最后一次移动时刻(2026-10-21 真机实证,同 nsg 重发
        // 保鲜口径)。
        await _sendGeo(lastOk.withUtcTime(t.toUtc()), t);
      }
    } finally {
      _flushing = false;
    }
  }

  /// 首写门开沿自发写(不依赖驱动 tick —— 配对页挂起期驱动停摆,收口
  /// 校时不能只靠 tick 补发):过闸体与 tick 共用;断链/拆链/仍在闸内
  /// 则弃(驱动下一拍兜底)。
  Future<void> _deferredFirstWrite() async {
    await Future<void>.delayed(writeGate);
    if (_state != BleSessionState.ready) return;
    final t = _now();
    if (_gated(t)) return;
    try {
      await _flushDueWrites(t);
    } on Exception catch (e) {
      lastError = (key: 'ble.firstWriteFail', args: {'e': e.toString()});
    }
  }

  Future<void> _sendGeo(GeoFix fix, DateTime t) async {
    try {
      await _host.write(kNikonCharGeo, GeoPayload().build(fix));
      _lastOkFix = fix;
      _lastOkAt = t;
    } on Exception catch (e) {
      _pendingFix = fix;
      _gateWritesUntil = t.add(writeGate);
      // 断链类写失败不上红字(2026-10-21 用户反馈):链路死亡沿自己会
      // 接手(断连 → 2s 快试重连 → ready 沿缓存回补),红字只留真实拒
      // 收(GPS 会话未醒等)。判定 = 平台错误码 disconnected。
      if (e is! PlatformException || e.code != 'disconnected') {
        lastError = (key: 'ble.geoWriteFail', args: {'e': e.toString()});
      }
    }
  }

  Future<void> _sendTime(DateTime t) async {
    try {
      await _host.write(kNikonCharTime, TimePayload.build(t));
      _lastTimeOkAt = t;
    } on Exception catch (e) {
      // 断链静默同 _sendGeo:重连 ready 沿 TIME 锚清零,首拍即补校时。
      if (e is! PlatformException || e.code != 'disconnected') {
        lastError = (key: 'ble.timeWriteFail', args: {'e': e.toString()});
      }
    }
  }

  bool _gated(DateTime t) =>
      _gateWritesUntil != null && t.isBefore(_gateWritesUntil!);

  // ------------------------------------------------------------------
  // 事件推进(握手状态机)
  // ------------------------------------------------------------------

  Future<void> _onEvent(BleEvent event) async {
    switch (event) {
      case BlePreConnected():
        // 物理链路建立沿:会话状态机零动作(时序取证事件,页面日志消费)。
        return;
      case BleConnected(:final uuid, :final characteristics):
        if (_state != BleSessionState.pairing) return;
        _connectedUuid = uuid;
        _lastCharacteristics = characteristics;
        // 写闸不在此设:握手期无注入写,Ready 沿统一起闸(_completeIfReady)。
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
          // v7 全表扫描读(2026-10-19 v5/v6 双阴性后):connected 事件
          // 带全服务全特征表,iOS 弹配对窗的经典触发 = 访问挂「加密读」
          // 权限的特征 —— 旧流程只读 6 个已知 LSS 特征,非 LSS 服务与
          // 0x2080s 未知族从未碰过。除握手信道 0x2000 与探针自读的
          // 0x2008 外,凡权限含 read 一律读;失败照常继续不挡握手。
          _trace('全特征表 ${characteristics.length} 项:'
              '${characteristics.entries.map((c) => '${_shortId(c.key)}(${c.value})').join(' ')}');
          _introReads = () async {
            for (final c in characteristics.entries) {
              if (!c.value.contains('read')) continue;
              if (c.key == kNikonCharPairing || c.key == kNikonCharNot1) {
                continue;
              }
              try {
                final v = await _host.read(c.key);
                _trace('read ${_shortId(c.key)} → '
                    '${v == null ? 'null' : '${v.length}B'}');
              } on Exception catch (e) {
                _trace('read ${_shortId(c.key)} 失败:$e');
              }
            }
          }();
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
          _registrationDoneSeen = false;
          await _host.write(kNikonCharPairing, stage1.encode());
          _trace('stage1 → device=${stage1.device.toRadixString(16)} '
              'nonce=${stage1.nonce.toRadixString(16)}'
              '${_resuming ? '(复用)' : '(全新)'}');
        } on Exception catch (e) {
          // 失败落盘(AppLog.e → errorTail/tail.log):握手起始失败的
          // 原生异常串上盘,真机排障唯一持久面(2026-10-21 夜教训)。
          AppLog.e(AppLog.ble, 'handshake start FAIL $e');
          // 连续拒绝计数:kick = 相机接受链路后立刻掐 —— 瞬时态(唤醒
          // 窗/状态切换)2s 快试即可过;持续态(≥6 次)= 相机侧接受通
          // 道楔死(2026-10-21 实证:GEO 写到一半链路死,16-60s 慢试也
          // 不恢复,相机重启才解)→ 换引导文案,别无限刷原始错误。
          _kickStreak++;
          if (_kickStreak >= 6) {
            lastError = (key: 'ble.reconnectRejected', args: null);
          } else {
            lastError =
                (key: 'ble.handshakeStartFail', args: {'e': e.toString()});
            if (_kickStreak < 4) _backoffStep = 0; // 瞬时踢:2s 快试
          }
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
              '${_shortId(uuid)} ← ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        }
      case BleDisconnected():
        if (_state == BleSessionState.pairing) {
          // 失败落盘:配对期断链时序(死在哪一拍)上盘排障。
          AppLog.e(AppLog.ble,
              'handshake DISCONNECTED (stage3Sent=$_stage3Sent)');
          lastError = (key: 'ble.handshakeDisconnected', args: null);
          _failHandshake();
        } else if (_state == BleSessionState.ready) {
          _backoffStep = 0;
          _setState(BleSessionState.reconnecting);
        }
      case BleError(:final code, :final message):
        // 裸平台错误码非键,走直通(原样透出)。
        lastError = (key: '$code:$message', args: null);
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
      lastError = (key: 'ble.pairFrameLength', args: {'n': data.length});
      _trace('PAIR 帧长度异常(${data.length})');
      return;
    }
    final msg = PairingMessage.decode(data);
    _trace('stage2 ← device=${msg.device.toRadixString(16)} '
        'nonce=${msg.nonce.toRadixString(16)}');
    final stage3 = _engine.verifyStage2AndBuildStage3(stage1, msg);
    if (stage3 == null) {
      lastError = (key: 'ble.stage2NoSalt', args: null);
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
      // 失败落盘:stage3 认证写被掐的原生异常串上盘排障。
      AppLog.e(AppLog.ble, 'stage3 write FAIL $e');
      lastError = (key: 'ble.stage3WriteFail', args: {'e': e.toString()});
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
        _registrationDoneSeen = true;
        final w = _registrationWait;
        if (w != null && !w.isCompleted) w.complete(true);
      }
      // 清位应答(SnapBridge 常规语义,2026-10-21 从探针提为常轨):
      // 相机 notify 请求位 = 开口要时间/位置/连接;app 供给(TIME/GEO
      // 帧)后写回清位值确认 —— 不清位则相机悬等、位置会话不开、GEO
      // 静默丢弃(重配对清 GPS 后零进账的真凶候选)。Conn 位应答 v5
      // 已证相机收下。
      // ⚠️ 只在 ready 态应答:配对事务内写 0x2008 疑似搅坏注册
      // (2026-10-21 实证:应答常轨化后的首次重配对,重连 stage1 全
      // 部「连接已断开」,相机亮着也次次掐;13:41 无应答版同流程可连)。
      if (_state == BleSessionState.ready) {
        final raw = data[0] | (data[1] << 8);
        var answer = raw;
        if (time >= 1) answer &= ~0x000F; // 时间由 TIME 帧供给
        if (loc >= 1) answer &= ~0x00F0; // 位置由 GEO 帧供给
        if (conn >= 1) answer &= ~0x0100; // v5 实证
        if (answer != raw) {
          _trace('0x2008 清位应答 '
              '0x${answer.toRadixString(16).padLeft(4, '0')}');
          try {
            await _host.write(kNikonCharNot1,
                Uint8List.fromList([answer & 0xFF, (answer >> 8) & 0xFF]));
          } on Exception catch (e) {
            _trace('0x2008 应答写失败:$e');
          }
        }
      }
    } else {
      _trace('0x2008 ← ${hex(data)}');
    }
  }

  static String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  /// 特征短标识(日志用):SIG 采纳的 16 位 UUID 在 iOS 侧是 4 字符短串
  /// (CBUUID.uuidString 直出,GAP/GATT 族的 2a00 等是短串),截 4-8 位
  /// 会 RangeError —— Error 不被 `on Exception` 拦,直接炸断事件处理
  /// (2026-10-19 v7 首测实证)。短串原样,全长取 4-8。
  static String _shortId(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(4, 8);

  /// 挂在原连接上等注册完成信号(NOT1 01 00;相机在注册挂起态可能于
  /// 原连接上延迟发安全请求 → 用户确认 → bond → 注册 → NOT1)。
  /// 到窗未至返回 false(调用方转第二段直连)。信号先于挂等待到达的
  /// 场景(握手读面触发弹窗、用户秒确认)由 [_registrationDoneSeen]
  /// 粘性兜住,入口即返 true。
  Future<bool> waitRegistration({Duration window = const Duration(seconds: 45)}) async {
    if (_registrationDoneSeen) return true;
    if (_state != BleSessionState.ready) {
      return false;
    }
    final wait = _registrationWait = Completer<bool>();
    final got = await wait.future.timeout(window, onTimeout: () => false);
    if (identical(_registrationWait, wait)) {
      _registrationWait = null;
    }
    return got;
  }

  /// 探针全访问面扫(v9):除握手协议特征外逐特征 读 → 写(零长,
  /// 信息量最小、相机命令解析必然拒长)→ 订阅(CCCD 写同为访问)。
  /// 任一访问撞「Insufficient Authentication」→ iOS 自动弹配对码,
  /// 确认后链路加密、后续访问自然续通。错误只落 trace 不中断(弹窗
  /// 由系统接管,探针不参与)。
  Future<void> _bondAccessSweep() async {
    final chars = _lastCharacteristics;
    if (chars == null) return;
    const protocol = {
      kNikonCharPairing,
      kNikonCharName,
      kNikonCharWifi,
      kNikonCharTime,
      kNikonCharGeo,
      kNikonCharNot1,
      kNikonCharNot2,
      kNikonCharStatusForControl,
      kNikonCharControlPoint,
    };
    for (final c in chars.entries) {
      if (protocol.contains(c.key)) continue;
      final id = _shortId(c.key);
      final props = c.value;
      if (props.contains('read')) {
        try {
          final v = await _host.read(c.key);
          _trace('面扫 read $id → ${v == null ? 'null' : '${v.length}B'}');
        } on Exception catch (e) {
          _trace('面扫 read $id → $e');
        }
      }
      if (props.contains('write')) {
        try {
          await _host.write(c.key, Uint8List(0));
          _trace('面扫 write $id(零长)→ OK');
        } on Exception catch (e) {
          _trace('面扫 write $id → $e');
        }
      }
      if (props.contains('notify') || props.contains('indicate')) {
        try {
          await _host.setNotify(c.key);
          _trace('面扫 sub $id → OK');
        } on Exception catch (e) {
          _trace('面扫 sub $id → $e');
        }
      }
    }
    _trace('面扫完毕(${chars.length} 项)');
  }

  /// iOS 首配 bond 探针(TODO「二」实验链)。**2026-10-20 退役**:手机
  /// unified log 取证定案 —— 弹码机制 = SnapBridge 程序化拉起系统配件选
  /// 择器(ExternalAccessory,见 ble_pair_panel),与线上触发器无关;相
  /// 机对谁都发 SMP 安全请求(本探针九轮阴性系误判其不存在)。本方法留
  /// 档不再被面板调用。
  ///
  /// v5/v6/v7 三轮真机阴性
  /// (2026-10-19):原链清 Conn 位/写 btEstablishment/全表明文读均
  /// 不触发 SMP —— 原链路是死路,弹码若发只能在**重连沿**。v8 二段
  /// 剧本(Android smali BLE1→断开→bond→BLE2ND 的 iOS 形):握手收口
  /// 校时 → 清 Conn 位 → 0x2005=0x02 → 短安顿窗 → 断链 → 重连复用
  /// 握手(连接沿相机可能发 SMP 安全请求 → iOS 弹配对码;握手窗等
  /// 用户确认)→ NOT1 Time 位 = 注册完成。v8 真机:leg-1 全链走通,
  /// 断链后相机**零广播 2 分钟+**(leg-1 收口把相机推进深睡等待态,
  /// 与 v2/v3 断链后仍在广播的态不同)→ **v8b 二段主路改直连**
  /// ([_reconnectDirect],静默等待态唯直连可及),直连未成再重扫兜底
  /// (相机若回广播已轮换 RPA)。v9 追加:0x2005 写后全访问面扫
  /// (读/写/订阅全部非协议特征,补 v7 只读的盲区)。v2/v3(2026-10-14)
  /// 断链前从未答 Conn 位、从未写 btEstablishment —— leg-1 收口后的
  /// 二段是未测组合,非重测。
  ///
  /// 静默纪律:全程除探针自身写外零 GATT 流量(onFix/_flushDueWrites/
  /// 手发件均被 [_bondProbeActive] 拦下;握手期特征面读先行收口;探针
  /// 期相机重发 Conn 请求位由 [_onNot1] 自动清位应答;面板自动重连/
  /// 注入驱动在 [retryReconnect]/[reconnectScan]/[reconnectDirect] 让
  /// 路 —— 真机实证探针断链沿面板重挂自动重连,原生扫描单槽互掐)。
  /// [settle] = 0x2005 写后安顿窗,窗内 NOT1 Time 位到(v5/v6 期待的
  /// 原链收口,三轮真机未再现)则免二段直接成功。[leg2Grace] =
  /// 断链后直连前的让位窗(相机收拾链路;Android 剧本断开即 bond,
  /// iOS 直连稍让)。成功返回 true 且保持 ready 链路(收口沿补答校时
  /// + re-arm 首写);失败(直连/扫描无果/断链/窗满)返回 false,
  /// ready 态下会话主动断链(未注册链路保持无意义,「去系统蓝牙」
  /// 按钮兜底),面板回落系统蓝牙兜底。
  Future<bool> runIosBondProbe(
      {Duration window = const Duration(seconds: 45),
      Duration settle = const Duration(seconds: 3),
      Duration leg2Grace = const Duration(milliseconds: 1500)}) async {
    if (_state != BleSessionState.ready || _bondProbeActive) {
      return false;
    }
    _bondProbeActive = true;
    var ok = false;
    try {
      // 握手期特征面读收口(最多让 3s,防读溢出静默窗)。
      try {
        await _introReads?.timeout(const Duration(seconds: 3));
      } on Exception {
        // 读挂起/超时不挡探针。
      }
      // 收口校时(SnapBridge 配对事务末环;有意绕写闸 —— 闸是 0x2007
      // 拒收减灾,0x2006 校时不在其列)。
      await _sendTime(_now());
      // v5 主探针:读 0x2008 → 清 ConnectionRequest 位应答(SnapBridge
      // Z3/J3 同款;读败照发 `00 00`,写败落 lastError 不中止)。
      var raw = 0;
      try {
        final v = await _host.read(kNikonCharNot1);
        if (v != null && v.length >= 2) {
          raw = v[0] | (v[1] << 8);
        }
      } on Exception catch (e) {
        _trace('探针读 0x2008 失败:$e(照发清位应答)');
      }
      final cleared = raw & ~0x0100;
      _trace('探针 0x2008 读值 0x${raw.toRadixString(16).padLeft(4, '0')} '
          '(Time=${raw & 0x0F} Loc=${(raw >> 4) & 0x0F} '
          'Conn=${(raw >> 8) & 0x01}) → 清位应答 '
          '0x${cleared.toRadixString(16).padLeft(4, '0')}');
      try {
        await _host.write(kNikonCharNot1,
            Uint8List.fromList([cleared & 0xFF, (cleared >> 8) & 0xFF]));
      } on Exception catch (e) {
        lastError = (key: 'ble.probeClearBitWriteFail', args: {'e': e.toString()});
      }
      // v6:0x2005 写 bit1=btEstablishment(SnapBridge Z3 序列 = 清位 →
      // 写 0x2005 建立传输;直发不走 _writeEstablishment —— 那条被
      // 静默旗标拦,探针自身写例外)。
      try {
        await _host.write(kNikonCharWifi, Uint8List.fromList([0x02]));
        _trace('探针 0x2005=0x02(btEstablishment)已发');
      } on Exception catch (e) {
        lastError =
            (key: 'ble.probeEstablishmentWriteFail', args: {'e': e.toString()});
      }
      // v9 全访问面扫(properties 掩码不标加密;加密门只在访问沿以 ATT
      // Insufficient Authentication 现形 → iOS 自动发起配对弹窗)。v7
      // 只盖了读面(全读通=可读面无门);写面与 CCCD 订阅面从未碰过
      // (2083 write、2082/2001/2004/2087 rw、2084/2087 indicate)。
      await _bondAccessSweep();
      // 安顿窗:原链 NOT1 Time 位到 = 原链收口(v5/v6 期待的路),免
      // 二段直接成功;三轮真机 165s+ 静默未再现,只作理论兜收。
      await Future<void>.delayed(settle);
      if (_registrationDoneSeen) {
        _trace('探针原链收口(NOT1 Time 位已到)');
        ok = true;
        return ok;
      }
      // v8b 二段:断链 → 直连重连(静默等待态零广播,唯直连可及;
      // 连接沿相机发 SMP → 弹码)→ 直连未成转重扫兜底(RPA 轮换)。
      _trace('探针二段:断链 → 直连重连(静默等待态)…');
      await disconnect();
      await Future<void>.delayed(leg2Grace);
      var resumed = await _reconnectDirect();
      if (!resumed) {
        _trace('二段直连未成(${lastError?.key ?? '连接超时'})→ 转重扫兜底…');
        resumed = await _reconnectScan();
      }
      if (!resumed) {
        _trace('探针二段未成:${lastError?.key ?? '扫描/连接失败'}');
        return false;
      }
      _trace('二段复用握手完成 → 等注册信号(NOT1 Time 位)…');
      ok = await waitRegistration(window: window);
      return ok;
    } finally {
      _bondProbeActive = false;
      if (ok && _state == BleSessionState.ready) {
        // 成功沿:补答校时(NOT1 Time 位 = 相机开口要时间,协议正答,
        // 顺带重锚 _lastTimeOkAt)+ 重启首写门收口(deferred 醒来时闸已
        // 过、TIME 已锚,只回补窗内缓存的定位)。
        unawaited(_sendTime(_now()));
        unawaited(_deferredFirstWrite());
      }
      if (ok) {
        AppLog.i(AppLog.ble, '配对码探针:注册完成 ✓(二段页内闭环,链路保持)');
      } else {
        // 失败沿:ready 态下会话主动断链(未注册链路保持无意义,且
        // 面板「去系统蓝牙」按钮只在非 ready 态可见);结论走会话级
        // I-log —— 探针断链沿页面重挂会拆掉发起面板,面板日志不可靠。
        if (_state == BleSessionState.ready) {
          await disconnect();
        }
        AppLog.i(AppLog.ble,
            '配对码探针未成(${lastError?.key ?? '静默窗满'}):失败沿亮宿主红色引导卡,系统蓝牙完成绑定');
      }
    }
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
      lastError = (key: 'ble.nameWriteFail', args: {'e': e.toString()});
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
    // 成功沿清陈旧错误(重连几轮失败后终成,错误行不残留)。
    lastError = null;
    // 首写门:Ready 后 writeGate 内不发 GEO/TIME(首配/重连同套 ——
    // 相机 GPS 会话未醒拒收 0x2007,HarmoNiLink 实证;2900099 瞬态同类
    // 减灾,非替代重试)。
    _gateWritesUntil = _now().add(writeGate);
    _lastTimeOkAt = null;
    // 连接/配对成功沿一次定位更新(SnapBridge 同款,2026-10-21 用户定
    // 稿「蓝牙一连接或配对成功就发起一次位置数据更新」):ready 后首个
    // 过闸拍,缓存点带当前时刻立刻补发一笔,不等流首帧/30s 保鲜窗。
    _readyOneShotPending = true;
    _setState(BleSessionState.ready);
    _kickStreak = 0; // 连上即清连续拒绝计数
    _handshake?.complete();
    _handshake = null;
    _trace('配对成功 ✓ device=${stage1.device.toRadixString(16)}');
    // 收口校时(SnapBridge 语义:配对事务末环)保留,但改过首写门才发:
    // 一次性延迟自发([_deferredFirstWrite]),配对页挂起期驱动 tick 停摆
    // 也能落地;闸内到达的定位缓存同沿回补。
    unawaited(_deferredFirstWrite());
  }

  void _failHandshake() {
    _stage1 = null;
    _stage3Sent = false;
    _handshake?.completeError(BlePairingException(lastError?.key ?? '握手失败'));
    _handshake = null;
    // 退避不在此复位:kick 类瞬时失败由 handshakeStartFail 处按连续计
    // 数做 2s 快试;持续踢(相机楔死)让步进照常爬升停止锤击。
    _setState(BleSessionState.idle);
  }

  void _setState(BleSessionState s) {
    if (_state == s) return;
    _state = s;
    // 转出 ready 即完结注册等待(断连/断开/握手失败全路径一处收口,
    // 防悬窗:探针等到窗满才假阴;迟到的 NOT1 由 isCompleted 守卫兜住)。
    if (s != BleSessionState.ready) {
      final w = _registrationWait;
      if (w != null && !w.isCompleted) w.complete(false);
    }
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(s);
    }
  }

  /// trace 双发:原样进 [onTrace](配对页 UI 保持全 hex 供方言核对),
  /// 同时进 AppLog ble 域 —— [masked] 给敏感载荷行(AppLog 环形缓冲会
  /// 随导出外流,凭据只留头尾对拍帧,中段打码)。
  void _trace(String line, {String? masked}) {
    onTrace?.call(line);
    AppLog.d(AppLog.ble, masked ?? line);
  }
}

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
    this.cameraName = '',
  });

  /// 系统 BLE 设备标识(iOS peripheral.identifier / Android MAC)。
  final String peripheralUuid;
  final int deviceId;
  final int nonce;

  /// 相机 BLE 侧序列号(stage4 帧,独立于 USB 序列)。
  final String serial;
  final String name;

  /// 相机 BLE 广播名(如 `Z_f_8014411`)。等待页广播不带 0x0399,
  /// 过滤扫描不可见,重连兜底按归一化广播名认机(2026-11-03)。
  final String cameraName;
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
    this.controllerName = 'ZPill',
    this.handshakeTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 50),
    this.writeGate = const Duration(milliseconds: 2500),
    DateTime Function()? now,
  })  : _host = host,
        _now = now ?? DateTime.now {
    _sub = host.events.listen(_onEvent);
  }

  /// 写 0x2002 的控制器名(32B ASCII 零填充;相机「已配对设备」显示)。
  /// 可变:配对页实验用(SnapBridge 按平台写前缀名 —— Android 版实证
  /// `Android_<机型>_<4位随机>`;相机以名识别客户端类型,见 0x2008 注)。
  /// 装配沿由 AppServices 组装成「<手机型号>-ZPill」
  /// ([composeControllerName]);取不到型号(平台缺失/异常)保持默认
  /// 裸名。
  String controllerName;

  /// 相机侧注册名组装(0x2002 = 32B ASCII 零填充):「<手机型号>-
  /// ZPill」。型号只留可打印 ASCII(连续空白并一,零填充里嵌空格
  /// 无害);型号为空回落裸名 'ZPill';总长钳 32(型号段最多 26)。
  static String composeControllerName(String model) {
    const suffix = '-ZPill';
    const maxBytes = 32;
    final cleaned = String.fromCharCodes(
            model.codeUnits.where((c) => c >= 0x20 && c <= 0x7E))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'ZPill';
    final maxModelLength = maxBytes - suffix.length;
    final head = cleaned.length > maxModelLength
        ? cleaned.substring(0, maxModelLength)
        : cleaned;
    return '$head$suffix';
  }

  /// 握手/连接总闸(15s):连上非相机(扫描全量列表误点)或相机已退出
  /// 配对菜单时,stage1 无应答 —— 没有超时 pair() 会永久挂在 pairing。
  final Duration handshakeTimeout;

  /// 建链(含服务发现)超时。深睡相机唤醒建链 ~7-12s(2026-11-03 真机
  /// 实证:connectGatt 后 7s 才回 CONNECTED、再 ~8s 才完成发现),旧
  /// 15/20s 会把发现窗口挤没 → 直连/扫描回连双双超时。握手帧交换仍
  /// 走 [handshakeTimeout]。
  final Duration connectTimeout;

  /// 写闸:Ready 后首笔 GEO/TIME 与 GEO 失败回补共用的静默窗(相机
  /// GPS 会话未醒拒收 0x2007 的减灾前置;2900099 瞬态同类)。
  final Duration writeGate;

  /// 诊断跟踪(握手/连接关键节点,可随时换绑/清空)。
  ///
  /// 回调只接收已脱敏文本;凭据 blob 与 LSS 密钥材料不得经此出口
  /// 进入 UI、AppLog 或外部日志。
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

  static const _transientRecoveryErrorKeys = {
    'ble.handshakeStartFail',
    'ble.handshakeDisconnected',
    'ble.stage2DirectTimeout',
    'ble.stage2ConnectTimeout',
    'ble.stage2ConnectFail',
    'ble.stage2ScanNoBroadcast',
    'ble.stage2HandshakeTimeout',
    'ble.reconnectScanFail',
  };

  /// 面向固定错误位的消息。单次握手/扫描失败是自动恢复过程中的正常
  /// 中间态，只保留在 [lastError] 与日志里；状态头已显示“重连中”。
  /// 连续 6 次被相机拒绝后转为终态提示。
  L10nMessage? get displayError {
    final error = _lastError;
    if (error == null) return null;
    if (error.key == 'ble.reconnectRejected') return error;
    if (_state == BleSessionState.pairing ||
        _state == BleSessionState.reconnecting) {
      return null;
    }
    if (_pairWaitActive && _transientRecoveryErrorKeys.contains(error.key)) {
      return null;
    }
    if (identity != null &&
        _kickStreak < 6 &&
        _transientRecoveryErrorKeys.contains(error.key)) {
      return null;
    }
    return error;
  }

  /// 最近一次 [retryReconnect] 是否被深睡闸门拦下(下轮尝试开跑即失效;
  /// 上层配对页日志据此区分「无命中」与「被闸」)。
  bool lastRetryGated = false;

  /// 深睡暂停(2026-11-03 用户定稿,三端统一):自动重连扫到待机广播
  /// 即置位并立即停止重连(状态回 idle),**只有手动连接
  /// (gateStandby:false)才清除并尝试唤醒**。驱动/面板的重试排程
  /// 都必须尊重该标志,不再自动发起连接。
  bool autoReconnectPaused = false;

  /// 最近一次命中设备的广播名([pair]/[retryReconnect] 命中沿更新;
  /// iOS 系统缓存 GAP 名基本恒有,Android 重连广播可能无名 = 空)——
  /// ready 沿旧档相机名回填(ConnectionController.healCameraName)消费,
  /// 旧版档案缺 cameraName 字段时免重配补名。
  String lastMatchName = '';

  Completer<void>? _handshake;

  /// 首写门开沿的延迟写(one-shot timer):旧实现是 `Future.delayed`,
  /// 无法取消 —— 会话 dispose 后仍会拿已关的 host 写 TIME/GEO。
  Timer? _deferredWriteTimer;

  /// dispose 已过:迟到回调(通知/定时器/异步续体)据此自灭。
  bool _disposed = false;
  PairingMessage? _stage1;
  bool _stage3Sent = false;
  bool _nameWritten = false;
  /// stage2 未回时的 stage1 重发定时器(深睡相机唤醒,2026-11-04)。
  Timer? _stage1RetryTimer;
  String? _connectedUuid;
  bool _resuming = false;
  String? _serial;

  /// stage2 原始帧(17B):stage4 到达时与 stage1 合成 LSS 密钥材料。
  Uint8List? _stage2Frame;

  /// stage2 命中的 salt 序号(LSS 材料 idx 位)。
  int? _stage2SaltIndex;

  /// LSS 握手密钥材料(0x2004 凭据解密 K 派生输入;握手完成合成,
  /// 下次连接尝试清空重建)。
  LssHandshakeMaterial? _lssMaterial;

  /// 握手合成的 LSS 密钥材料(诊断/测试观察;握手未完成为 null)。
  LssHandshakeMaterial? get lssMaterial => _lssMaterial;

  /// 取消纪元(十三轮):[disconnect] 沿推进 —— 在途连接尝试
  /// (retryReconnect/reconnectDirect/reconnectScan)的迟到收口不再把
  /// 状态翻回 reconnecting。用户取消沿状态已回 idle,若无此闸,握手的
  /// 60s 超时会迟到触发把页面「复活」成连接中(且 manualOff 压着驱动,
  /// 谁也不会真的再连 —— 假在途卡死)。
  int _cancelEpoch = 0;
  int _backoffStep = 0;
  Future<bool>? _retryReconnectInFlight;

  /// 深睡闸门连续跳过轮数(episode 限频日志用;非闸沿归零)。
  int _standbySkips = 0;
  DateTime? _gateWritesUntil;

  GeoFix? _pendingFix;

  /// 上次成功注入的定位与时刻(去重门/保鲜锚;失败沿不更新)。
  GeoFix? _lastOkFix;
  DateTime? _lastOkAt;

  /// 上次成功 TIME 写时刻(保活档位锚;Ready 沿清零 = 首笔校时待发)。
  DateTime? _lastTimeOkAt;

  /// 下次重连建议退避(驱动按此定时调 [retryReconnect])。
  Duration get nextRetryDelay => Duration(
      seconds: _backoffSeconds[min(_backoffStep, _backoffSeconds.length - 1)]);

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
  /// 配对(菜单窗流程):连接 → 复用握手 → ready。2026-10-21 用户定
  /// 稿 SnapBridge 同款「先点配对卡住等相机」:首次握手若被踢(正常
  /// 态相机拒新凭据,T4a 签名 = 连上即掐),**不报错**,进「等配对窗」
  /// 循环 —— 2s 拍重连+握手,直到相机进配对窗收下凭据(实测秒过)或
  /// 60s 上限;取消走 [_cancelEpoch] 纪元闸(面板取消沿即停)。
  /// 配对(菜单窗流程),SnapBridge 同款「先点配对卡住等相机」(用户
  /// 定稿 2026-10-21「配对成功后马上连接」):连接+握手 → 若被踢(正
  /// 常态相机拒新凭据,T4a 签名 = 连上即掐)= 相机还没进窗,**不报
  /// 错**,2s 拍重连+握手等窗 —— 相机点配对(进窗)的下一拍即连上;
  /// 60s 上限;取消经纪元闸(面板收口沿 cancelPairWait)。
  /// [waitTimeout] 等窗上限(测试注短值免真延时;生产默认 60s)。
  Future<void> pair(BleDevice device,
      {Duration waitTimeout = const Duration(seconds: 60)}) {
    // 等窗上限用**真 Timer 的 .timeout**(测试注短值即快断;假时钟
    // deadline 在真延时循环里永不触发,01:30 挂测试实证)。
    return _pairWithWait(device).timeout(waitTimeout, onTimeout: () async {
      _cancelEpoch++; // 纪元推闸:废在途握手/循环(迟到收口沿自灭)
      if (_state == BleSessionState.pairing) _failHandshake();
      lastError = (key: 'ble.pairWaitTimeout', args: null);
      throw BlePairingException('配对等待超时 —— 相机须停在「连接至智能设备」配对页(广播窗约'
          ' 30s)再点扫描连接');
    });
  }

  Future<void> _pairWithWait(BleDevice device) async {
    if (_state != BleSessionState.idle) {
      throw StateError('会话非 idle(state=$_state)');
    }
    lastMatchName = device.name;
    _resuming = false;
    _resetAttemptState();
    final epoch = _cancelEpoch;
    _pairWaitActive = true;
    var attempt = 0;
    try {
      while (_cancelEpoch == epoch) {
        attempt++;
        _setState(BleSessionState.pairing);
        final done = _beginHandshake();
        try {
          AppLog.d(AppLog.ble, 'connect → channel(${device.uuid}) 第$attempt次');
          await _host.connectPaired(device.uuid).timeout(handshakeTimeout);
          AppLog.d(AppLog.ble, 'connect ← channel 已回,等握手');
          await done.future.timeout(handshakeTimeout);
          return; // ready(握手沿置上)
        } on TimeoutException {
          // 15s 无果:原生没回包(connect 挂)或相机没进窗。逐次留痕,
          // 卓易通等容器里 channel 级悬死只有这里能看见。
          AppLog.d(
              AppLog.ble, 'connect/握手 ${handshakeTimeout.inSeconds}s 无果,弃局重试');
          _abandonHandshake(done); // 无应答:相机不在场/深睡,继续等窗
        } on Exception catch (e) {
          // 原生主动落错(容器看门狗「GATT 10s 无回调」/握手首帧被拒)或
          // 被相机踢:与纯超时(上面 TimeoutException)是两条路,留痕区分。
          // 注意绑 catch 变量 —— 本文件裸 import dart:math,无变量时 $e
          // 会取到数学常数 e(2.718…),错误信息全丢(2026-10-24 实证)。
          AppLog.d(AppLog.ble, 'connect 异常:$e');
          _setState(BleSessionState.idle);
          _handshake = null;
          if (_cryptoWallDetected) {
            // 容器加密墙已实锤:不再空转重试,立即给出明确文案。
            throw BlePairingException('此环境蓝牙不支持与相机配对(加密链路无法建立,卓易通等容器环境)');
          }
          // 被踢 = 还没进窗(T4a),继续等
        }
        if (_cancelEpoch != epoch) return; // 已取消:外层超时收口
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      _pairWaitActive = false;
      if (_state == BleSessionState.pairing) {
        _setState(BleSessionState.idle); // 循环退出未成:回 idle 待重试
      }
    }
  }

  /// 面板收口沿取消配对等待(仅配对等待在跑时推纪元;其余态无害)。
  void cancelPairWait() {
    if (_pairWaitActive) _cancelEpoch++;
  }

  /// 容器加密墙已实锤(本次会话内不可恢复,重试只会空转)。
  bool _cryptoWallDetected = false;

  /// 卓易通等容器加密墙特征:0x2000(PAIR)握手首帧写被栈直接拒
  /// (writeCharacteristic 返回 false,不走 GATT 回调、不触发 SMP),
  /// 其余读写/CCCD 全通 —— 配对协议第一帧发不出去,容器安全栈缺口。
  bool _isCryptoWall(Object e) =>
      bleErrorCode(e) == 'writeFailed' && bleErrorMessage(e).contains('被拒');

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
  Future<bool> retryReconnect({bool gateStandby = true}) {
    final active = _retryReconnectInFlight;
    if (active != null) return active;
    final attempt = _retryReconnect(gateStandby: gateStandby);
    _retryReconnectInFlight = attempt;
    return attempt.whenComplete(() {
      if (identical(_retryReconnectInFlight, attempt)) {
        _retryReconnectInFlight = null;
      }
    });
  }

  Future<bool> _retryReconnect({required bool gateStandby}) async {
    if (identity == null ||
        (_state != BleSessionState.reconnecting &&
            _state != BleSessionState.idle)) {
      return false;
    }
    // 手动连接(gateStandby:false)= 显式唤醒意图:清除深睡暂停。
    if (!gateStandby) autoReconnectPaused = false;
    // 断链首轮直连优先:仅手动路生效(自动路一律走扫描 —— 直连会
    // 绕过深睡闸门把待机相机叫醒,2026-11-03 用户定稿:自动不唤醒)。
    final directFirst = directFirstPending && !gateStandby;
    directFirstPending = false;
    if (directFirst) {
      final direct = await _reconnectDirect();
      if (direct) return true;
    }
    final epoch = _cancelEpoch; // 十三轮:取消沿迟到收口不推态。
    final List<BleDevice> devices;
    try {
      devices = await _host.scanForDeviceId(
        identity!.deviceId,
        timeout: const Duration(seconds: 8),
      );
    } on Exception catch (e) {
      // 扫描被系统/另一条流程打断时不能把驱动循环抛出 Future 外:
      // 旧实现会让后续 Timer 回调直接断尾,表现为怎么点都不再重连。
      lastError = (
        key: 'ble.reconnectScanFail',
        args: {'e': bleErrorMessage(e)},
      );
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      if (epoch == _cancelEpoch) {
        _setState(BleSessionState.reconnecting);
      }
      return false;
    }
    lastRetryGated = false;
    var match = devices.isEmpty ? null : devices.first;
    // 等待页广播不带 0x0399(2026-10-27 实锤):过滤扫描必然空。
    // 退一步做无过滤扫描,按归一化广播名认机(与面板配对行同一判
    // 据),拿到当前广播地址再直连 —— 等待页的自动回链由此接住。
    match ??= await _scanByName();
    lastMatchName = match?.name ?? '';
    if (match == null) {
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    }
    if (gateStandby &&
        advertisedPowerState(match.mfgData) == NikonAdvPowerState.standby) {
      // 首闸落一行日志(episode 级限频,防待机数小时刷屏)。
      if (_standbySkips == 0) {
        AppLog.i(AppLog.ble,
            '深睡闸门:相机广播待机位,停止自动重连,等手动连接唤醒');
      }
      _standbySkips++;
      lastRetryGated = true;
      // 2026-11-03 用户定稿:检测到待机立即停自动重连,状态回 idle
      // (UI 回到「已配对,未连接」+「连接」按钮),只有手动连接才
      // 清除暂停并尝试唤醒。
      autoReconnectPaused = true;
      _setState(BleSessionState.idle);
      return false;
    }
    if (epoch != _cancelEpoch) {
      return false; // 已取消:预连接沿也不再推进 —— 否则取消落在扫描窗
      // 内时本尝试照旧入 pairing,僵尸态把后续尝试全挡在门外(十四轮)。
    }
    _standbySkips = 0;
    autoReconnectPaused = false; // 非待机命中:解除深睡暂停
    _resuming = true;
    _serial = null;
    _stage2Frame = null;
    _stage2SaltIndex = null;
    _lssMaterial = null;
    _setState(BleSessionState.pairing);
    final done = _beginHandshake();
    try {
      await _host.connectPaired(match.uuid).timeout(connectTimeout);
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
    if (identical(_handshake, done)) _handshake = null;
    _resetAttemptState();
    unawaited(_host.disconnect());
    _setState(BleSessionState.idle);
  }

  /// 新一轮尝试前的状态清账。
  ///
  /// **必须清 [_nameWritten]**:它是 [ _completeIfReady ] 的唯一阀。旧
  /// 实现弃局只清 stage1/stage3,名字位留着 —— 上一轮写过名、本轮还没
  /// 写时,一条迟到的 stage4 通知就能把本轮的握手提前抬成 ready,并把
  /// 当前(或下一次)的 completer 一并完成(僵尸 ready / 错完成)。
  /// [identity] 不清:那是已配对档,跨尝试保留。
  void _resetAttemptState() {
    _stage1RetryTimer?.cancel();
    _stage1RetryTimer = null;
    _stage1 = null;
    _stage3Sent = false;
    _nameWritten = false;
    _serial = null;
    _stage2Frame = null;
    _stage2SaltIndex = null;
    _lssMaterial = null;
  }

  /// 起一轮握手:清上一轮残留 + 挂唯一 completer。
  Completer<void> _beginHandshake() {
    _resetAttemptState();
    final done = Completer<void>();
    _handshake = done;
    return done;
  }

  /// 直连重连:相机静默等待态无广播可扫,直接按本会话已知
  /// peripheralUuid 连(iOS retrievePeripherals 能找回本会话已见外设)
  /// —— 首配 bond 收尾断链后的相机零广播,唯直连可及(重连路经
  /// [retryReconnect] 的 directFirst 武装走同款)。连接沿相机可能发
  /// SMP 安全请求 → 系统弹配对码 → 确认后 bond 落。握手超时放宽
  /// (60s):等用户确认弹窗。
  Future<bool> reconnectDirect() => _reconnectDirect();

  /// 无过滤扫描按归一化广播名认机(等待页广播无 0x0399 的兜底)。
  /// 名字口径与面板配对行一致:去空白/下划线/控制字符(NUL 填充)后
  /// 小写比对;认到即返回当前广播地址。扫描失败/占用按未命中处理,
  /// 下一轮退避再试(不反噬重连循环)。
  Future<BleDevice?> _scanByName() async {
    final target = _normalizeBleName(identity?.cameraName ?? '');
    if (target.isEmpty) return null;
    try {
      final devices = await _host.scan(timeout: const Duration(seconds: 3));
      final own = identity?.deviceId;
      for (final d in devices) {
        // 已被别的控制器占用(广播期望 deviceId 非我方)不抢连:
        // 相机此时不会接受我们(2026-11-03 三端同配对实证)。
        if (cameraWaitsForOtherController(d.mfgData, own)) continue;
        if (_normalizeBleName(d.name) == target) return d;
      }
    } on Exception {
      // 扫描被占/失败:按未命中处理。
    }
    return null;
  }

  static String _normalizeBleName(String s) =>
      s.replaceAll(RegExp(r'[\s_\x00-\x1F\x7F]+'), '').toLowerCase();

  Future<bool> _reconnectDirect() async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
    final epoch = _cancelEpoch; // 十三轮:取消沿迟到收口不推态。
    final target = reconnectDirectUuid ?? identity!.peripheralUuid;
    reconnectDirectUuid = null;
    _resuming = true;
    _serial = null;
    _stage2Frame = null;
    _stage2SaltIndex = null;
    _lssMaterial = null;
    _setState(BleSessionState.pairing);
    final done = _beginHandshake();
    var linked = false;
    try {
      // 深睡相机:直接寻呼实测优于挂起式(华为上 autoConnect 30s 无
      // 回调,直接寻呼 13.5s 建链,2026-11-03 真机对比);挂起式管
      // 道保留作配置项(host.connectPaired(autoConnect:true))。
      await _host.connectPaired(target).timeout(connectTimeout);
      linked = true;
      await done.future.timeout(const Duration(seconds: 60));
      return true;
    } on TimeoutException {
      // 失败落盘:直连超时(分段=链接建立/握手两段,排障定位用)。
      AppLog.e(
          AppLog.ble, 'direct reconnect TIMEOUT linked=$linked'); // 真实失败,常驻
      lastError = linked
          ? (key: 'ble.stage2HandshakeTimeout', args: null)
          : (key: 'ble.stage2DirectTimeout', args: null);
      _abandonHandshake(done);
      if (epoch != _cancelEpoch) return false; // 已取消:状态留在 idle。
      _setState(BleSessionState.reconnecting);
      _backoffStep = min(_backoffStep + 1, _backoffSeconds.length - 1);
      return false;
    } on Exception catch (e) {
      AppLog.e(AppLog.ble, 'direct reconnect FAIL $e'); // 真实失败,常驻
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
  /// 放宽(45s):等用户确认可能出现的系统配对码弹窗。[retryReconnect]
  /// 直连未成后落回此路(未注册相机 RPA 轮换,重扫拿新 uuid 唯一可走)。
  Future<bool> reconnectScan(
          {Duration scanTimeout = const Duration(seconds: 10)}) =>
      _reconnectScan(scanTimeout: scanTimeout);

  Future<bool> _reconnectScan(
      {Duration scanTimeout = const Duration(seconds: 10)}) async {
    if (identity == null ||
        (_state != BleSessionState.idle &&
            _state != BleSessionState.reconnecting)) {
      return false;
    }
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
    _stage2Frame = null;
    _stage2SaltIndex = null;
    _lssMaterial = null;
    _setState(BleSessionState.pairing);
    final done = _beginHandshake();
    var linked = false;
    try {
      await _host
          .connectPaired(target.uuid)
          .timeout(const Duration(seconds: 20));
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
    directFirstPending = false;
    try {
      // 重连扫描不像面板扫描那样由页面显式停;若用户在 8s 扫描窗内点
      // 重连/断开,旧实现只能等扫描自然收口。先收扫描再拆链,避免旧
      // attempt 继续占着单飞槽。
      await _host.stopScan();
    } on Exception {
      // 平台未起扫/通道不支持时无妨。
    }
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
    try {
      final blob = await _host.read(kNikonCharConfig);
      if (blob == null) {
        _trace('0x2004 ← null');
      } else {
        // 凭据 blob 只保留头尾对拍片段,明文/完整密文都不落 trace。
        _trace('0x2004 ← ${blob.length}B '
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
      final creds = decodeWifiCredentials(blob, lss: _lssMaterial);
      if (creds == null) {
        // 十七轮:解密未中**不上 lastError**(错误位)—— 唤醒流程下
        // 相机 Wi-Fi 已开,错误位让位「去系统连 Wi-Fi」红字提醒;日志
        // 只记材料是否齐全,完整派生输入不落盘。
        final m = _lssMaterial;
        if (m != null) {
          _trace('LSS 材料在(saltIdx=${m.saltIndex},字段已脱敏)');
        }
        AppLog.w(AppLog.ble,
            'AP 凭据解密未中(LSS 派生+定键候选全未命中,blob 仅存脱敏摘要;材料 ${m == null ? '缺' : '在'})');
      } else {
        _trace('0x2004 解密命中 keySource=${creds.keySource}');
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
    try {
      await _host.write(kNikonCharWifi, Uint8List.fromList([value]));
      _trace('$label → 0x2005=0x${value.toRadixString(16)}');
      return true;
    } on Exception catch (e) {
      // 平台错误只取 message(裸 dump 是四段噪音,用户要看的是
      // 「连接已断开」而不是构造参数);其他异常保留普通文本。
      lastError =
          (key: 'ble.opFail', args: {'label': label, 'e': bleErrorMessage(e)});
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _deferredWriteTimer?.cancel();
    _deferredWriteTimer = null;
    _stage1RetryTimer?.cancel();
    _stage1RetryTimer = null;
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

  /// 断链首轮直连优先待办(ready→reconnecting 沿置上,首个
  /// retryReconnect 消费;测试直拨,公开同 geoEnabled 先例)。语义 =
  /// SnapBridge 同款「配对成功后马上连接」(2026-10-21 用户定稿):注
  /// 册后相机进静默等待态零广播,扫描 8s 必空转;链路刚断地址新鲜,直
  /// 连 ~1-2s 对醒着/静默两态都成立,失败才落回扫描(深睡闸门随扫描
  /// 生效)。
  bool directFirstPending = false;

  /// 手动连接时面板注入的「当前广播地址」(配对行扫描行命中沿)。
  /// Android 的 BLE 地址是轮换 RPA:存档地址直连在待机/等待页可能已
  /// 过期,而扫描行里的是此刻广播地址,直连才打得中。消费即清。
  String? reconnectDirectUuid;

  /// 握手起始连续被踢计数(成功 ready 清零;瞬时踢 2s 快试,持续踢换
  /// 引导文案,见 handshakeStartFail 处)。
  int _kickStreak = 0;

  /// 配对等待循环在跑(面板收口沿 cancelPairWait 的推纪元判据)。
  bool _pairWaitActive = false;

  /// 定位到达(定位流回调,事件驱动)。ready、注入开(geoEnabled)、
  /// 过写闸且过去重门(距上次成功注入 <3s 且位移 <1.1m 跳过,见
  /// [BleKeepalive])即写 GEO;写闸期缓存待回补(不弃点)。
  void onFix(GeoFix fix) {
    if (_state != BleSessionState.ready) return;
    if (!geoEnabled) return;
    final t = _now();
    if (_gated(t)) {
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

  /// 过闸写入体(tick 与首写自发沿 [_deferredFirstWrite] 共用)。
  ///
  /// 十六轮单飞:tick(驱动周期)与首写自发沿并发进入会对同一特征
  /// (TIME/GEO)各发一笔 withResponse 写,后笔撞原生「同特征已有写在
  /// 途」busy(iOS 逐特征闸);写是周期性保活,丢一拍下一拍兜底,
  /// 单飞跳过不排队。
  bool _flushing = false;

  Future<void> _flushDueWrites(DateTime t) async {
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
  /// 则弃(驱动下一拍兜底)。可取消(dispose/新一轮 ready 覆盖)。
  void _deferredFirstWrite() {
    _deferredWriteTimer?.cancel();
    _deferredWriteTimer = Timer(writeGate, () {
      _deferredWriteTimer = null;
      if (_disposed || _state != BleSessionState.ready) return;
      final t = _now();
      if (_gated(t)) return;
      unawaited(() async {
        try {
          await _flushDueWrites(t);
        } on Exception catch (e) {
          lastError = (key: 'ble.firstWriteFail', args: {'e': e.toString()});
        }
      }());
    });
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
      if (!isBleDisconnectedError(e)) {
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
      if (!isBleDisconnectedError(e)) {
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
    // 卓易通排障:事件是否真到会话(面板监听收到了、会话订阅没收到
    // 的话,握手永远不会启动且零 trace)。
    // 扫描广播量大且成对,不逐条留痕;其余事件(连接/断开/状态)保留。
    if (event is! BleDeviceFound) {
      _trace('event → ${event.runtimeType} state=$_state');
    }
    switch (event) {
      case BlePreConnected():
        // 物理链路建立沿:会话状态机零动作(时序取证事件,页面日志消费)。
        return;
      case BleConnected(:final uuid, :final characteristics):
        if (_state != BleSessionState.pairing) return;
        _connectedUuid = uuid;
        // 深睡唤醒 poke(2026-11-04 鸿蒙真机:链路连上但相机半睡时
        // GATT 服务器不回 stage2,约 12s 后监督断链):先做一笔带响应
        // 的读(电池 0x2a19)把服务器叫醒再进握手;失败忽略,不挡流程。
        try {
          await _host
              .read(kNikonCharBattery)
              .timeout(const Duration(seconds: 2));
          _trace('唤醒 poke:0x2a19 已读回');
        } on Exception {
          _trace('唤醒 poke 未回,继续握手');
        }
        // 写闸不在此设:握手期无注入写,Ready 沿统一起闸(_completeIfReady)。
        try {
          _trace('握手起始:setNotify → 2000');
          await _host.setNotify(kNikonCharPairing);
          _trace('setNotify 2000 ✓');
          await _host.setNotify(kNikonCharNot1);
          // NOT2(0x200A)留观察窗:方言核对期跟踪信号帧,不参与状态机。
          await _host.setNotify(kNikonCharNot2);
          // v7 全表扫描读(2026-10-19 v5/v6 双阴性后):connected 事件
          // 带全服务全特征表,iOS 弹配对窗的经典触发 = 访问挂「加密读」
          // 权限的特征 —— 旧流程只读 6 个已知 LSS 特征,非 LSS 服务与
          // 0x2080s 未知族从未碰过。除握手信道 0x2000 与 0x2008 外,
          // 凡权限含 read 一律读;失败照常继续不挡握手。
          _trace('全特征表 ${characteristics.length} 项:'
              '${characteristics.entries.map((c) => '${_shortId(c.key)}(${c.value})').join(' ')}');
          //
          // 这组全表读取只为首配触发系统的加密特征访问。复用身份重连时
          // 相机已经注册，继续并发读整表只会增加握手前后 GATT 流量与
          // 被相机踢链的机会，因此不在重连路径执行。
          if (!_resuming) {
            unawaited(() async {
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
            }());
          }
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
          // stage1 device/nonce 是 LSS key2/nonce 的原始输入，只记流程
          // 形态，值本身不落 trace。
          _trace('stage1 → 已发送${_resuming ? '(复用)' : '(全新)'}');
          _armStage1Retry();
        } on Exception catch (e) {
          // 失败落盘(AppLog.e → errorTail/tail.log):握手起始失败的
          // 原生异常串上盘,真机排障唯一持久面(2026-10-21 夜教训)。
          AppLog.e(AppLog.ble, 'handshake start FAIL $e');
          if (_isCryptoWall(e)) {
            // 卓易通等容器:0x2000(PAIR)写被栈直接拒(writeCharacteristic
            // 返回 false,不触发 SMP)—— 配对第一帧发不出去,重试无意义
            // (2026-10-24 实证)。立即收口并给出明确文案。
            _cryptoWallDetected = true;
            final w = _handshake;
            if (w != null && !w.isCompleted) {
              w.completeError(
                  BlePairingException('此环境蓝牙不支持与相机配对(加密链路无法建立,卓易通等容器环境)'));
            }
          }
          // 连续拒绝计数:kick = 相机接受链路后立刻掐 —— 瞬时态(唤醒
          // 窗/状态切换)2s 快试即可过;持续态(≥6 次)= 相机侧接受通
          // 道楔死(2026-10-21 实证:GEO 写到一半链路死,16-60s 慢试也
          // 不恢复,相机重启才解)→ 换引导文案,别无限刷原始错误。
          if (_cryptoWallDetected) {
            // 容器加密墙:红字直接给结论,不展示底层异常串;kickStreak
            // 只数真实踢,不计容器墙。
            lastError = (key: 'ble.cryptoWall', args: null);
          } else {
            _kickStreak++;
            if (_kickStreak >= 6) {
              lastError = (key: 'ble.reconnectRejected', args: null);
            } else {
              lastError = (
                key: 'ble.handshakeStartFail',
                args: {'e': bleErrorMessage(e)},
              );
              if (_kickStreak < 4) _backoffStep = 0; // 瞬时踢:2s 快试
            }
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
          AppLog.e(
              AppLog.ble, 'handshake DISCONNECTED (stage3Sent=$_stage3Sent)');
          lastError = (key: 'ble.handshakeDisconnected', args: null);
          _failHandshake();
        } else if (_state == BleSessionState.ready) {
          _backoffStep = 0;
          // 收线武装直连优先 —— **仅限重连握手后的收线**(_resuming):
          // v8b 静默态相机应答直连。菜单窗配对后的收线**不武装**(实证:
          // 注册后相机静默期不接受直连,20s 超时白 hang 还盖住相机自己
          // 的重连广播窗口,扫描本可接住)—— 该场景走扫描接广播。
          directFirstPending = _resuming;
          _setState(BleSessionState.reconnecting);
        }
      case BleError(:final code, :final message):
        // 权限/蓝牙开关错误给可操作文案;其余裸平台错误码仍直通(诊断用)。
        lastError = switch (code) {
          'permissionDenied' => (key: 'ble.permissionDenied', args: null),
          'bluetoothOff' => (key: 'ble.bluetoothOff', args: null),
          _ => (key: '$code:$message', args: null),
        };
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
        _trace('stage4 → 序列号已收(${_serial?.length ?? 0} 字符)');
        // LSS 密钥材料合成(0x2004 凭据解密 K 派生输入,字段一律线上
        // 原样):key1 = stage4 deviceId 原始 8B(与序列号是两回事,
        // 序列号是它的 ASCII 读法),key2 = 客户端身份(stage1 帧
        // 9..17),N_A/X = 相机/手机 nonce(帧 1..9),idx = stage2
        // 命中 salt 序号。
        final s2 = _stage2Frame;
        if (s2 != null && s2.length == PairingMessage.length) {
          final s1 = stage1.encode();
          _lssMaterial = LssHandshakeMaterial(
            key1: Uint8List.fromList(data.sublist(9, 17)),
            key2: Uint8List.fromList(s1.sublist(9, 17)),
            saltIndex: _stage2SaltIndex ?? 0,
            cameraNonce: Uint8List.fromList(s2.sublist(1, 9)),
            phoneNonce: Uint8List.fromList(s1.sublist(1, 9)),
          );
          _trace('LSS 材料 ∈ saltIdx=$_stage2SaltIndex '
              'key1=${AppLog.hex(_lssMaterial!.key1, sensitive: true)}');
        }
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
    _trace('stage2 ← 挑战已收到');
    final stage3Pair = _engine.verifyStage2AndBuildStage3(stage1, msg);
    if (stage3Pair == null) {
      lastError = (key: 'ble.stage2NoSalt', args: null);
      _trace('stage2 无 salt 命中(8 组 salt 全试未中)');
      _failHandshake();
      return;
    }
    final (stage3, saltIndex) = stage3Pair;
    _stage2Frame = Uint8List.fromList(data);
    _stage2SaltIndex = saltIndex;
    _stage3Sent = true;
    try {
      await _host.write(kNikonCharPairing, stage3.encode());
      _trace('stage3 → 已发送');
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
  /// 成功标志)。
  Future<void> _onNot1(Uint8List data) async {
    if (data.length == 2) {
      final time = data[0] & 0x0F;
      final loc = (data[0] >> 4) & 0x0F;
      final conn = data[1] & 0x0F;
      _trace('0x2008 ← ${hex(data)} '
          '(Time=$time Loc=$loc Conn=$conn)');
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

  /// 写 0x2002 控制器名(32B ASCII 零填充)。真机方言(2026-10-13
  /// Zf):stage4 沿即发;名字落定即收口 —— NOT1 非闸门,实测不回。
  /// stage2 迟迟不回时的 stage1 重发(深睡相机唤醒):每 2s 重发一次
  /// stage1,直到 stage2 到达(stage3 已发)/握手收口/弃局。重复
  /// stage1 是安全的握手起点帧,同时给相机 GATT 服务器持续唤醒刺激
  /// (2026-11-04 鸿蒙深睡真机:只发一次时相机半睡不回、12s 被踢)。
  void _armStage1Retry() {
    _stage1RetryTimer?.cancel();
    _stage1RetryTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (_stage3Sent ||
          _handshake == null ||
          _state != BleSessionState.pairing) {
        t.cancel();
        return;
      }
      final stage1 = _stage1;
      if (stage1 == null) {
        t.cancel();
        return;
      }
      _trace('stage2 未回,重发 stage1(唤醒)');
      try {
        await _host.write(kNikonCharPairing, stage1.encode());
      } on Exception catch (e) {
        _trace('stage1 重发失败:$e');
      }
    });
  }

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
    if (_disposed) return;
    if (!_nameWritten) return;
    // 没有在途握手 = 本次收口无人认领(弃局后的迟到通知),不推态。
    final done = _handshake;
    if (done == null) return;
    final stage1 = _stage1;
    if (stage1 == null) return;
    _stage1RetryTimer?.cancel();
    _stage1RetryTimer = null;
    identity = BleIdentity(
      peripheralUuid: _connectedUuid ?? '',
      deviceId: stage1.device,
      nonce: stage1.nonce,
      serial: _serial ?? identity?.serial ?? '',
      name: controllerName,
      // 相机广播名只在扫描时见过(握手帧没有):本拍 lastMatchName 为
      // 扫描命中名,直连复用沿沿用旧身份。
      cameraName:
          lastMatchName.isNotEmpty ? lastMatchName : (identity?.cameraName ?? ''),
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
    done.complete();
    _handshake = null;
    _trace('配对成功 ✓');
    // 收口校时(SnapBridge 语义:配对事务末环)保留,但改过首写门才发:
    // 一次性延迟自发([_deferredFirstWrite]),配对页挂起期驱动 tick 停摆
    // 也能落地;闸内到达的定位缓存同沿回补。
    _deferredFirstWrite();
  }

  void _failHandshake() {
    final done = _handshake;
    _resetAttemptState();
    done?.completeError(BlePairingException(lastError?.key ?? '握手失败'));
    _handshake = null;
    // 退避不在此复位:kick 类瞬时失败由 handshakeStartFail 处按连续计
    // 数做 2s 快试;持续踢(相机楔死)让步进照常爬升停止锤击。
    _setState(BleSessionState.idle);
  }

  void _setState(BleSessionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(s);
    }
  }

  /// trace 双发:[onTrace] 与 AppLog 都只接收调用方已脱敏的文本。
  void _trace(String line) {
    onTrace?.call(line);
    AppLog.d(AppLog.ble, line);
  }
}

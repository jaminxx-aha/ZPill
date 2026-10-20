/// BLE 配对面板(嵌入连接页蓝牙视图;原独立配对页退役)。
///
/// 相机侧:菜单「连接至智能设备」→ 扫描(广播窗 ~30s,一次连接
/// 即停)→ 点选 → 四步握手(全在 [AppServices.bleSession],本面板零
/// 协议知识)→ NOT1 → 写控制器名 → 身份落盘(ble_identity.json)。
///
/// 2026-10-19 改版定稿(用户七条要求 + 六裁定):①「已配对 / 其它
/// 设备」两段列表,打开沿**自动扫描**(静默 —— 无扫描钮、无「扫描
/// 中」指示);②打开沿**不自动回链**(进入页面不主动连接,后台守候
/// 由注入驱动承担,面板打开期间驱动挂起,页面内全手动);③iOS 首配
/// **自动跳系统蓝牙删除** —— App 侧只断链让相机暴露经典蓝牙,经
/// [onSystemBondNeeded] 通知宿主弹红色引导卡,「打开系统蓝牙设置」为
/// 手动按钮(不点不跳);ohos 程序化经典绑定直达不出卡;④回前台重扫
/// 一轮(挂起期系统可能停掉 BLE 扫描),重连循环在跑则不打扰。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/adv_payload.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/log/app_log.dart';
import '../../data/ble_identity_store.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/ble_scanner.dart';
import '../../platform/services.dart';
import '../common/widgets/confirm_dialog.dart';
import 'connection_widgets.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class BlePairPanel extends StatefulWidget {
  const BlePairPanel({
    super.key,
    this.savedIdentity,
    this.session,
    this.onIdentityChanged,
    this.onSystemBondNeeded,
    this.onRetryingChanged,
  });

  /// 已存身份(宿主预填):嵌入连接页蓝牙视图时传
  /// `controller.bleIdentity` —— 身份源随宿主(测试也走此参注入);null
  /// 时面板自读 AppServices 盘档。宿主身份沿更新经 didUpdateWidget 同步
  /// 进面板态。
  final BlePairedIdentity? savedIdentity;

  /// 会话(十二轮注入):嵌入连接页蓝牙视图时传
  /// `controller.bleSession` —— 生产两者本是同一只(AppServices 常驻
  /// 驱动那只),显式传参免全局耦合;不传回落单例(独立挂面板/旧测试
  /// 兼容)。面板的重连循环/断链/状态行随此会话。
  final BleCameraSession? session;

  /// 身份落盘/解除沿回调宿主(重载 controller.bleIdentity,状态行不
  /// 残留旧身份)。
  final void Function()? onIdentityChanged;

  /// iOS 首配握手落档沿回调宿主(置控制器 bleAwaitSystemBond → 蓝牙页
  /// 弹系统配对红卡;2026-10-19 改版:自动跳系统蓝牙删除,引导收进页内)。
  final void Function()? onSystemBondNeeded;

  /// 重连循环起停沿回调宿主(九轮):蓝牙 hero 的涟漪须跟「正在连」
  /// 走,而无命中轮会话态停在 idle 跟不出 —— 宿主页接住进
  /// ValueNotifier 驱动 hero busy(会话态 ∪ 面板循环)。循环被废
  /// (cancelResume/扫描/解除/拆面板)同样上抛 false。
  final void Function(bool active)? onRetryingChanged;

  @override
  State<BlePairPanel> createState() => BlePairPanelState();
}

/// 面板 State 公开(八轮):宿主页蓝牙 hero「连最近」经
/// [manualResume] 复用本面板「连接」按钮的整条手动重连路(显式意图
/// 解除 manualOff、绕深睡闸门、在途循环不重入);九轮再公开
/// [cancelResume](在途再点 = 取消)与 [retrying](在途判定)。
class BlePairPanelState extends State<BlePairPanel>
    with WidgetsBindingObserver {
  StreamSubscription<BleSessionState>? _stateSub;
  StreamSubscription<BleEvent>? _eventSub;
  List<BleDevice> _devices = [];
  bool _scanning = false;
  BleSessionState _sessionState = BleSessionState.idle;
  BlePairedIdentity? _saved;

  /// 本次配对设备的 BLE 广播名(鸿蒙经典绑定按名匹配用)。
  String _pairedName = '';
  bool _binding = false;

  static const MethodChannel _bleChannel = MethodChannel('nikonpill/ble');

  /// 会话解析:宿主注入优先(十二轮,生产 = 控制器/驱动同一只),回落
  /// AppServices 单例(独立挂面板)。
  BleCameraSession get _session =>
      widget.session ?? AppServices.instance.bleSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 页面存续期挂起注入驱动(自动重连/GEO tick 会与手动流程撞车;
    // 2026-10-19 定稿:页面内绝不自动连,离页恢复驱动守候)。
    AppServices.instance.suspendBleDriver();
    _sessionState = _session.state;
    _stateSub = _session.states.listen((s) {
      if (mounted) setState(() => _sessionState = s);
      // 十五轮:页面开着的重连常驻 —— 掉线自动入 reconnecting 后,面板
      // 就是重连执行者(驱动已挂起),自动循环跑起来(深睡闸门开着,
      // 与驱动同参);相机就绪即连上。就绪/闲态沿不自动起(2026-10-19
      // 「进入页面不主动连接」只限从零连;恢复掉线是 reconnecting 的
      // 题中之义);用户显式断开意图(manualOff)不越。
      if (s == BleSessionState.reconnecting &&
          !_retryActive &&
          !AppServices.instance.bleManualOff) {
        unawaited(_resume(gateStandby: true, autoRearm: true));
      }
    });
    // 开页即 reconnecting(掉线态打开页面):无状态事件,起自动循环。
    if (_sessionState == BleSessionState.reconnecting &&
        !AppServices.instance.bleManualOff) {
      unawaited(_resume(gateStandby: true, autoRearm: true));
    }
    // 事件订阅:设备发现列示(实时,不等扫描窗收口)+ 流程日志。日志
    // 全走统一日志(AppLog ble 域,通用日志页可查;帧级 trace 由
    // AppServices 常年接线,不在此管)。
    _eventSub = PlatformServices.ble.events.listen(_onEvent);
    // 宿主喂的身份首帧即入:重连钮/冲突比较不等异步(盘档读盘悬着时
    // 身份不能跟着悬)。
    _saved = widget.savedIdentity;
    // 打开沿自动扫描(下一帧:setState 路径里有异步,initState 直调
    // 非法)。静默 —— 无扫描钮、无「扫描中」指示。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _autoStartScan();
      }
    });
    unawaited(_loadSaved());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台重扫一轮(挂起期间系统可能停掉 BLE 扫描,iOS 常见)。
    // 页面内**不自动回链**(2026-10-19 用户定稿:进入页面不主动连接
    // —— 回链只由后台注入驱动守候承担,而驱动此刻挂起);重连循环在
    // 跑则不打扰(用户显式发起的不被重扫废掉)。
    if (state == AppLifecycleState.resumed &&
        _sessionState != BleSessionState.ready &&
        _sessionState != BleSessionState.pairing &&
        !_scanning &&
        !_retryActive) {
      _autoStartScan();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRetry(notify: false);
    AppServices.instance.resumeBleDriver();
    _stateSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BlePairPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主身份镜像沿(配对/解除 → onIdentityChanged → 控制器重载 → 回
    // 喂):面板 _saved 跟进,设备行与冲突比较不残留旧身份。实例不等价
    // 才动 —— 同实例回喂(普通重建)不抖。
    if (!identical(widget.savedIdentity, oldWidget.savedIdentity)) {
      _saved = widget.savedIdentity;
    }
  }

  Future<void> _loadSaved() async {
    final saved = widget.savedIdentity ??
        await AppServices.instance.bleIdentityStore.load();
    if (mounted) {
      setState(() => _saved = saved);
    }
  }

  void _log(String line) => AppLog.i(AppLog.ble, line);

  /// 打开沿/回前台沿自动扫描(2026-10-19 用户定稿:扫描静默自动)。
  /// 就绪/握手中不起:就绪态列表整体隐藏;握手期扫描与握手互斥。
  void _autoStartScan() {
    if (_sessionState == BleSessionState.ready ||
        _sessionState == BleSessionState.pairing) {
      return;
    }
    unawaited(_startScan());
  }

  void _onEvent(BleEvent event) {
    switch (event) {
      case BleStateChanged(:final state):
        _log('蓝牙态:$state');
      case BleDeviceFound(:final device):
        // 实时列示:原生每发现一台就推,不等扫描窗收口(30s 全窗太久,
        // 用户对着空列表干等)。原生侧已过尼康过滤,事件即有效命中。
        if (!mounted) return;
        setState(() {
          final i = _devices.indexWhere((d) => d.uuid == device.uuid);
          if (i >= 0) {
            _devices[i] = device;
          } else {
            _devices = [..._devices, device];
          }
        });
      case BleConnected(
          :final uuid,
          :final characteristics,
          :final writeWithoutResponseMtu,
        ):
        _log('已连接 $uuid,无响应写 MTU=$writeWithoutResponseMtu');
        final lss = characteristics.entries
            .where((e) => e.key.endsWith('-3dd4-4255-8d62-6dc7b9bd5561'))
            .map((e) => '${e.key.substring(4, 8)}(${e.value})')
            .join(' ');
        AppLog.d(AppLog.ble, 'LSS 特征表:$lss');
      case BlePreConnected(:final uuid):
        // 物理链路建立沿(iOS didConnect):与「已连接」(特征发现完成)
        // 两行之差 = 150ms 礼让 + 服务发现耗时,深睡重连时序取证用。
        _log('物理连接建立 $uuid');
      case BleDisconnected(:final uuid):
        _log('断连 $uuid');
      case BleNotified(:final uuid, :final data):
        // iOS 对 SIG 采纳 16 位 UUID 回 4 字符短串,裸 substring(4,8) 会
        // RangeError 炸断事件链(2026-10-19 真机实证)。
        AppLog.d(AppLog.ble,
            '← ${uuid.length <= 8 ? uuid : uuid.substring(4, 8)} ${hexOf(data)}');
      case BleError(:final code, :final message, :final uuid):
        AppLog.w(AppLog.ble,
            '错误 $code${uuid == null ? '' : ' @$uuid'}:$message');
    }
  }

  Future<void> _startScan() async {
    if (_scanning || _sessionState == BleSessionState.pairing) return;
    // 扫描与重连循环互踩(扫描互踩扫描,BLE 无线电独占):扫描起步
    // 即废在途重连(打开沿/回前台沿的自动扫描不会走到这 —— 有重连
    // 在跑就不起扫;显式路径已无,保留护栏)。
    _cancelRetry();
    setState(() {
      _scanning = true;
      _devices = [];
    });
    try {
      final devices = await _session.scanForPairing();
      // 台数行带状态字节(Zf 实证 0x1E/0x1F):重连时序取证要能对上
      // 「命中时相机是否深睡」。
      _log('扫描结束:${devices.length} 台(${devices.map(_deviceLabel).join(', ')})');
      if (!mounted) return;
      setState(() => _devices = devices);
    } on Exception catch (e) {
      _log('扫描失败:$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  String _deviceLabel(BleDevice d) {
    final name = d.name.isEmpty ? '(无名)' : d.name;
    final st = advertisedStatusByte(d.mfgData);
    if (st == null) return name;
    return '$name(0x${st.toRadixString(16).toUpperCase().padLeft(2, '0')})';
  }

  /// 首次配对:session 四步握手 → 身份落盘 → 通知注入驱动刷新。
  Future<void> _pair(BleDevice device) async {
    final app = AppServices.instance;
    _cancelRetry();
    app.bleManualOff = false; // 新配对 = 连接意图,解除手动断开压制
    _log('配对 ${device.name}(${device.uuid})…');
    _pairedName = device.name; // 经典绑定匹配用(鸿蒙)
    try {
      await _session.pair(device);
    } on Exception catch (e) {
      _log('配对失败:$e');
      return;
    }
    final id = _session.identity;
    if (id == null) return;
    await app.bleIdentityStore.save(BlePairedIdentity(
      peripheralUuid: id.peripheralUuid,
      deviceId: id.deviceId,
      nonce: id.nonce,
      serial: id.serial,
      controllerName: id.name,
      // 相机广播名只在扫描时见过,握手帧里没有 —— 此刻不存就没地方
      // 再拿(设备行展示名,见 BlePairedIdentity.cameraName)。
      cameraName: device.name,
      pairedAt: DateTime.now(),
    ));
    app.refreshBleInjection();
    widget.onIdentityChanged?.call();
    _log('配对成功 ✓ device=${id.deviceId.toRadixString(16)} '
        'serial=${id.serial} 身份已落盘');
    await _loadSaved();
    // iOS 首配注册走系统蓝牙(2026-10-20 手机 unified log 取证终版):
    // 弹码机制 = SnapBridge 程序化拉起系统配件选择器(ExternalAccessory
    // EAAccessoryPicker,公开 API)完成经典 BR/EDR SSP bond(CTKD 派生
    // BLE 密钥)后重连注册 —— 相机对谁都发 SMP 安全请求,与弹码无关。
    // 我方同款实现四轮真机实证:选择器的托管 sheet 在 Flutter 宿主 +
    // iOS 27.2 上静默不呈现(BLE 链上/断链后、谓词/nil 谓词、原生桥直
    // 调全试),SnapBridge 原生同机正常 —— Flutter 宿主兼容性问题,代
    // 码留档待 Apple 修。回退深链路:App 侧只自动断链 —— 相机等 BLE 释
    // 放才暴露经典蓝牙(技术必需);红色引导卡 + 手动按钮(2026-10-19
    // 裁定,不自动跳页),用户在系统页点相机完成配对后回本页自动重连
    // 注册。ohos 有程序化绑定(_bondClassic)不走此路。
    if (Platform.operatingSystem == 'ios') {
      await _session.disconnect();
      widget.onSystemBondNeeded?.call();
      return;
    }
  }

  /// 已注册相机的重连:按已存 deviceId 扫 0x0399 重连广播,命中即以
  /// 已存 device/nonce 复用握手 —— 相机只认保存过的身份,扫描列表
  /// 再点 = 全新握手,必被秒断(2026-10-13 真机实证)。点一次自动
  /// 重试约 1 分钟(退避节奏),不必连点。
  ///
  /// [gateStandby]:重连按钮 = 显式意图绕深睡闸门(false);自动行为
  /// 已按 2026-10-19 裁定全部退役,页面内只有显式重连。
  bool _retryActive = false;

  /// 重连循环世代号:[_cancelRetry] 自增即废在途循环;每个 await 后
  /// 对账,不等者退场(扫描/配对/解除/拆面板沿即刻止步)。
  int _retryGen = 0;
  Timer? _retryWait;
  Completer<void>? _retryWaitDone;

  bool get _retrying => _retryActive;

  /// 在途重连循环(公开只读,八轮):宿主页蓝牙 hero 连最近的
  /// 不重入守卫。
  bool get retrying => _retryActive;

  /// 废在途重连:退避等待即刻醒(Completer 放行,await 不悬死)。
  /// dispose 沿传 notify:false —— 此时 element 已 defunct(mounted 仍真),
  /// setState 会炸断言。onRetryingChanged 照上抛(九轮:hero 涟漪停
  /// 须即时;拆面板沿宿主通知器还在,落值无害)。
  void _cancelRetry({bool notify = true}) {
    _retryGen++;
    _retryWait?.cancel();
    _retryWait = null;
    final w = _retryWaitDone;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
    _retryWaitDone = null;
    if (_retryActive) {
      _retryActive = false;
      widget.onRetryingChanged?.call(false);
      if (notify && mounted) setState(() {});
    }
  }

  /// 可取消退避等待:取消沿即刻醒,不等满 delay。
  Future<void> _retryDelayWait(Duration d) async {
    final done = Completer<void>();
    _retryWaitDone = done;
    _retryWait = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
  }

  Future<void> _resume({bool gateStandby = true, bool autoRearm = false}) async {
    if (_retryActive) return;
    _retryActive = true;
    final gen = _retryGen;
    widget.onRetryingChanged?.call(true);
    if (mounted) setState(() {});
    _log('重连(复用身份 ${_saved!.deviceId.toRadixString(16)})…');
    var hintedForeign = false;
    for (var attempt = 1; attempt <= 6; attempt++) {
      if (gen != _retryGen || !mounted) break;
      // 配对码探针进行中(含断链二段):让路等收尾 —— 探针自己的
      // 重连在跑,这里再扫会原生单槽互掐(2026-10-19 真机实证)。
      // 成功 = ready(下轮止步);失败 = idle/reconnecting(下轮接力)。
      if (_session.bondProbeActive) {
        _log('配对码探针进行中,自动重连让路…');
        while (_session.bondProbeActive && gen == _retryGen && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        continue;
      }
      if (_session.state == BleSessionState.ready) {
        _log('已就绪 ✓');
        break;
      }
      final ok = await _session.retryReconnect(gateStandby: gateStandby);
      if (!mounted || gen != _retryGen) break;
      if (ok) {
        _log('重连成功 ✓');
        break;
      }
      final err = _session.lastError;
      if (_session.lastRetryGated) {
        _log('第 $attempt 轮:相机待机(深睡闸门拦下),等唤醒…');
      } else {
        _log('第 $attempt 轮无命中${err == null ? '' : '(${err.key})'},'
            '${_session.nextRetryDelay.inSeconds}s 后再试(相机须停在'
            '「连接至智能设备」页或可重连待机)');
      }
      // 重连未命中 + 本页扫描结果里有「在等别的手机」的相机 → 复用同一条
      // 冲突指引(重连扫描被 native 过滤只看我方 deviceId,别家相机只有
      // 本页配对扫描才看得见);每轮重连只提示一次,免刷屏。
      if (!hintedForeign) {
        final foreign = _foreignWaiting();
        final foreignId = foreign == null
            ? null
            : expectedControllerDeviceId(foreign.mfgData);
        if (foreign != null && foreignId != null) {
          hintedForeign = true;
          _log(_conflictHint(context, foreignId));
        }
      }
      await _retryDelayWait(_session.nextRetryDelay);
    }
    // 十五轮:自动重连**常驻**(autoRearm)—— 六轮未中且会话仍停在
    // reconnecting:退避后续跑新六轮。页面开着时驱动被挂起,面板就是
    // 重连的执行者 —— 「断开自动进入重连后应该要能重新连接」:相机
    // 就绪等在广播,循环常驻直到连上或用户取消(点状态词/hero)。退避
    // 走可取消等待(_cancelRetry 即刻醒);续棒静默让位旗标,新棒即刻
    // 重举(onRetryingChanged/涟漪不闪断)。显式单发(manualResume)
    // 不续跑。
    if (autoRearm &&
        gen == _retryGen &&
        mounted &&
        _session.state == BleSessionState.reconnecting) {
      await _retryDelayWait(_session.nextRetryDelay);
      if (gen == _retryGen &&
          mounted &&
          _session.state == BleSessionState.reconnecting) {
        _retryActive = false;
        unawaited(_resume(gateStandby: gateStandby, autoRearm: true));
        return;
      }
    }
    if (gen == _retryGen) {
      _retryActive = false;
      widget.onRetryingChanged?.call(false);
      if (mounted) setState(() {});
    }
  }

  /// 手动唤醒重连:点按即显式意图 —— 打断在场循环,绕闸直连待机相机
  /// (深睡唤醒 ~12s 开销真机实测,6490990 闸门前老行为)。世代号废旧
  /// 循环、退避等待即刻醒,新循环走 [_resume] 同一收尾路。待机机(黄
  /// 点)点行配对同理 —— 显式意图都允许点醒(2026-10-19 裁定⑤)。
  /// 公开面(八轮):宿主页蓝牙 hero「连最近」同走此路。
  ///
  /// 十四轮定样 = **全面接管**:①停面板在途扫描(打开沿自动扫 30s 窗,
  /// 扫描互踩扫描 —— 重连的 scanForDeviceId 与自页扫描并行 = 全程无
  /// 命中,「断开后怎么都连不上」主因);②会话非 idle(驱动在途轮/
  /// 残留握手卡在 pairing)先断链清态再起循环 —— 用户「必须手动停止
  /// 重连再点连接才行」的两步舞收成一步。十五轮:连接中(reconnecting)
  /// 行内不再有「连接」钮(不与状态词并存),接管路仅防御性保留。
  Future<void> manualResume() async {
    // 显式连接 = 解除手动断开意图(守候/驱动恢复资格)。
    AppServices.instance.bleManualOff = false;
    _cancelRetry();
    if (_scanning) {
      setState(() => _scanning = false);
      unawaited(_session.stopScan());
    }
    if (_session.state != BleSessionState.idle) {
      // 接管:清在途(会话 disconnect 弃局握手 + 纪元闸,在途尝试的
      // 迟到收口不再翻状态)。
      await _session.disconnect();
    }
    await _resume(gateStandby: false);
  }

  /// 取消在途连接(九轮公开):宿主页蓝牙 hero 在途再点走此路 —— 与
  /// 「断开」钮同语义:置显式断开意图(manualOff,压离页后驱动自动
  /// 回链)+ 废重连循环(世代号,退避等待即刻醒)+ 断链(在途的
  /// 连接/握手尝试一并了断;首配中途取消 = 身份不落盘,重配重来)。
  Future<void> cancelResume() async {
    AppServices.instance.bleManualOff = true;
    _cancelRetry();
    await _session.disconnect();
  }

  /// 程序化经典蓝牙绑定(鸿蒙独有;iOS 无此 API 只能引导系统设置页,
  /// 见宿主红色引导卡)。相机须先断开 BLE 才暴露经典蓝牙 —— 配对成功
  /// 后 App 已自动断链;绑定完成(系统弹窗确认)后再「连接」即注册落档。
  Future<void> _bondClassic() async {
    if (_binding) {
      return;
    }
    setState(() => _binding = true);
    _log('经典蓝牙绑定:发现+配对中(手机上确认系统弹窗)…');
    try {
      final ok = await _bleChannel.invokeMethod<bool>('bondDevice', {
        'deviceId': _saved!.peripheralUuid,
        'name': _pairedName,
        'serial': _saved!.serial,
      });
      _log(ok == true ? '经典蓝牙绑定完成 ✓ 再点「连接」' : '绑定未完成');
    } on MissingPluginException {
      _log('此平台不支持程序化绑定');
    } on PlatformException catch (e) {
      _log('绑定失败:${e.message ?? e.code}');
    } finally {
      if (mounted) {
        setState(() => _binding = false);
      }
    }
  }

  /// 解除配对确认(2026-10-20:对齐 STA「忘记这台相机」):清配对
  /// 身份 + 断开 + 注入停止,重连须重新走相机菜单 —— 一步到位的
  /// 不可逆操作,弹窗把关。
  Future<void> _confirmUnpair(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('ble.unpairConfirm'),
      content: context.t('ble.unpairBody', {'name': _saved!.displayName}),
      confirmLabel: context.t('ble.unpair'),
      destructive: true,
    );
    if (confirmed) {
      await _unpair();
    }
  }

  Future<void> _unpair() async {
    final app = AppServices.instance;
    _cancelRetry();
    app.bleManualOff = false; // 解除配对清意图(下次配对干净起步)
    await app.bleIdentityStore.clear();
    _session.identity = null;
    await _session.disconnect();
    app.refreshBleInjection();
    _log('已解除配对(注入停止;重连须重新走相机菜单)');
    await _loadSaved();
    widget.onIdentityChanged?.call();
  }

  /// 我方注册身份的 deviceId(已存档优先,会话内存兜底;null = 首次
  /// 配对,无从比较冲突)。
  int? get _ownDeviceId => _saved?.deviceId ?? _session.identity?.deviceId;

  /// 「在等别的手机」指引文案(扫描行提示与重连失败日志共用;动作
  /// 措辞借 HarmoNiLink 真机口径:相机「已配对设备」菜单切换设备)。
  String _conflictHint(BuildContext context, int foreignId) => context.t(
      'ble.waitingOtherPhone',
      {'id': foreignId.toRadixString(16).toUpperCase()});

  /// 当前列表里首个「在等别的手机」的设备(无则 null;重连未命中时的
  /// 指引来源 —— 重连扫描(scanForDeviceId)被 native 按我方 deviceId
  /// 过滤,看不见别家相机,只能翻本页自己的配对扫描结果)。
  BleDevice? _foreignWaiting() {
    final own = _ownDeviceId;
    if (own == null) return null;
    for (final d in _devices) {
      if (cameraWaitsForOtherController(d.mfgData, own)) return d;
    }
    return null;
  }

  /// 扫描行电源态点(2026-10-19 用户定稿:文字换色点):待机黄点
  /// (accentYellow)/ 就绪绿点(success);无状态字节(mfg 不足 7B:
  /// 配对菜单态/异厂商)不出点。待机点是「点连接为何唤不醒」的答案
  /// 面:深睡广播稀,闸门等物理唤醒。
  Widget? _powerStateDot(BuildContext context, BleDevice device) {
    final status = advertisedStatusByte(device.mfgData);
    if (status == null) return null;
    final standby =
        advertisedPowerState(device.mfgData) == NikonAdvPowerState.standby;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color:
            standby ? AppColors.accentYellow : AppColors.success(context),
        shape: BoxShape.circle,
      ),
    );
  }

  /// 扫描行:设备名 + 电源态色点(尾槽);deviceId/冲突指引不显
  /// (冲突指引在重连日志 AppLog)。点行 = 发起配对(待机机也是显式
  /// 意图,允许点醒,裁定⑤)。
  Widget _scanRow(BuildContext context, BleDevice device) {
    return ListTile(
      dense: true,
      enabled: _sessionState == BleSessionState.idle ||
          _sessionState == BleSessionState.reconnecting,
      leading: const Icon(Icons.camera_alt_outlined),
      title: Text(device.name.isEmpty
          ? context.t('ble.unnamed')
          : device.name),
      trailing: _powerStateDot(context, device),
      onTap: () => unawaited(_pair(device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _sessionState == BleSessionState.ready;
    // 嵌入宿主滚动层(蓝牙方式视图 ListView,页面级 padding 由宿主
    // 给):整体 mainAxisSize.min,水平不另缩进。「已配对 / 其它设备」
    // 两段列表(iOS 设置组语言);会话态在宿主状态行,不在此重复。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 已配对组:未就绪 = 档案行(解除配对/连接);就绪 = 档案行 +
        // 断开(显式断开 = 用户意图保持断开:置 manualOff 压制一切自动
        // 回链,显式「连接」/重新配对沿解除);无档 = 空态。十二轮:
        // 就绪沿段名让位「已连接」(conn.connected)—— 列的是当下连着
        // 的这台,不是配对档案;就绪行也不再带「最近」徽(徽语义 =
        // 最近连接条目,已连接时无意义;未就绪档案行保留)。
        ConnSectionHeader(
            label: ready ? 'conn.connected' : 'conn.sectionPaired'),
        ConnTileGroup(
          children: [
            if (_saved == null)
              const _GroupEmpty(text: 'conn.noPairedDevices')
            else if (ready)
              ListTile(
                dense: true,
                leading: const Icon(Icons.camera_alt_outlined),
                // 展示名 = 相机广播名(旧档缺字段回落控制器名)——
                // controllerName 是本机在相机侧的注册名,不是相机。
                // 十二轮:就绪行不带「最近」徽(已连接时无意义)。
                title: Text(_saved!.displayName),
                // 行尾轻量操作(2026-10-19 二轮:描边钮整排太重)。
                trailing: TextButton(
                  onPressed: () {
                    AppServices.instance.bleManualOff = true;
                    unawaited(_session.disconnect());
                  },
                  child: Text(context.t('ble.disconnect')),
                ),
              )
            else
              ListTile(
                dense: true,
                leading: const Icon(Icons.camera_alt_outlined),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_saved!.displayName)),
                    const SizedBox(width: AppSpacing.sm),
                    const ConnRecentBadge(),
                  ],
                ),
                // 行尾轻量操作(2026-10-19 二轮用户裁定:双描边钮太重
                // —— 解除配对收成次级色图标钮,连接降为文字钮)。十轮:
                // 重连反馈不再占名下副文(状态行 + 按钮位已表达);握手
                // 期(pairing)两钮让位「握手中」状态词,行尾不再空着
                // —— 取消走蓝牙 hero 再点(九轮;十四轮:行内「断开」
                // 钮被否)。十一轮:状态词与同行标签同色(primary)。
                // 十三轮:解除配对在握手/连接中(reconnecting)均隐 ——
                // 连接在途身份正派用场,此刻解除既危险也无意义。十四轮:
                // 两状态词本身可点 = 取消(与 hero 再点同路
                // cancelResume)。十五轮:连接中不与「连接」钮并存
                //(用户裁定)—— 重连由常驻自动循环承担(见 _stateSub),
                // 相机就绪即连上,行内只须报态与给取消。
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_sessionState != BleSessionState.pairing &&
                        _sessionState != BleSessionState.reconnecting)
                      IconButton(
                        icon: const Icon(Icons.link_off, size: 20),
                        tooltip: context.t('ble.unpair'),
                        color: theme.colorScheme.onSurfaceVariant,
                        onPressed: () =>
                            unawaited(_confirmUnpair(context)),
                      ),
                    if (_sessionState == BleSessionState.pairing ||
                        _sessionState == BleSessionState.reconnecting)
                      // 十四轮:状态词可点 = 取消连接/握手(与 hero 再点
                      // 同路)。
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(cancelResume()),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm),
                          child: Text(
                            context.t(
                                _sessionState == BleSessionState.pairing
                                    ? 'ble.handshaking'
                                    : 'ble.reconnecting'),
                            style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary),
                          ),
                        ),
                      )
                    else
                      TextButton(
                        // 点按即唤醒:深睡闸门只闸自动路(已退役),
                        // 手动点 = 显式意图 —— 打断在场循环绕闸直连。
                        onPressed: () => unawaited(manualResume()),
                        child: Text(_retrying
                            ? context.t('ble.reconnecting')
                            : context.t('ble.connect')),
                      ),
                  ],
                ),
              ),
          ],
        ),
        // 其它设备组(就绪态整体隐藏:连接后残留的扫描行只有迷惑作用)。
        // 自动扫描静默入列 —— 无扫描钮、无「扫描中」指示,空态只显
        // 「未发现设备」(2026-10-19 用户定稿)。
        if (!ready) ...[
          const SizedBox(height: AppSpacing.md),
          const ConnSectionHeader(label: 'conn.sectionOthers'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              child: _devices.isEmpty
                  ? const _GroupEmpty(text: 'conn.noOtherDevices')
                  // ListTile 在最近 Material 祖先上画底/墨效:透明
                  // Material 垫在 DecoratedBox 与子项之间(ConnTileGroup
                  // 同款)。
                  : LimitedBox(
                      maxHeight: 220,
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: [
                          for (final device in _devices)
                            _scanRow(context, device),
                        ],
                      ),
                    ),
            ),
          ),
        ],
        // 鸿蒙程序化经典绑定(红卡只限 iOS 无程序化绑定 API 的情形,
        // ohos 直达不出卡;2026-10-19 裁定③)。
        if (!ready &&
            _saved != null &&
            (_sessionState == BleSessionState.idle ||
                _sessionState == BleSessionState.reconnecting) &&
            Platform.operatingSystem == 'ohos')
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: OutlinedButton(
              onPressed:
                  _binding ? null : () => unawaited(_bondClassic()),
              child: Text(_binding
                  ? context.t('ble.binding')
                  : context.t('ble.bindClassic')),
            ),
          ),
      ],
    );
  }
}

/// 列表组空态行(组容器内居中次级小字;text 即 t() 键)。
class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      child: Center(
        child: Text(
          context.t(text),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

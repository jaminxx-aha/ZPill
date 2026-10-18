/// BLE 配对面板(嵌入连接页蓝牙工具弹层;原独立配对页退役)。
///
/// 相机侧:菜单「连接至智能设备」→ 扫描(广播窗 ~30s,一次连接
/// 即停)→ 点选 → 四步握手(全在 [AppServices.bleSession],本面板零
/// 协议知识)→ NOT1 → 写控制器名 → 身份落盘(ble_identity.json)。
/// 重连由 AppServices 注入驱动按退避自动跑,面板只管首次配对与状态
/// 查看。
///
/// 2026-10-17 去重定案:①会话态不在此重复(弹层顶部状态行覆盖),
/// 面板只留档案一行 + 未配对引导 + lastError;②GEO/TIME 帧计数删;
/// ③日志并轨统一日志(AppLog ble 域,帧级 trace 由 AppServices 常年
/// 接线),内嵌日志框退役;④动作钮按会话态分型(就绪只剩断开,
/// 扫描列表就绪时隐藏)。手动件全退(申请后台定位 2026-10-18 收编进
/// 设置页 GPS 注入开关;写 TIME / 唤起 WiFi / 读 0x2004 已退役)。
/// 2026-10-19 版式定稿:已配对设备行 = 图标 设备 解除配对 连接
/// (序列/日期文字行退役);扫描钮独立一行(不与配对设备同行);
/// iOS「去系统蓝牙完成注册」手动件退役(首配成功沿自动深链保留)。
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

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class BlePairPanel extends StatefulWidget {
  const BlePairPanel({super.key, this.savedIdentity, this.onIdentityChanged});

  /// 已存身份(宿主预填):嵌入连接页弹层时传 `controller.bleIdentity`
  /// —— 身份源随宿主(测试也走此参注入);null 时面板自读 AppServices
  /// 盘档。宿主身份沿更新经 didUpdateWidget 同步进面板态。
  final BlePairedIdentity? savedIdentity;

  /// 身份落盘/解除沿回调宿主(嵌入蓝牙工具弹层时重载
  /// controller.bleIdentity,状态行不残留旧身份)。
  final void Function()? onIdentityChanged;

  @override
  State<BlePairPanel> createState() => _BlePairPanelState();
}

class _BlePairPanelState extends State<BlePairPanel>
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

  BleCameraSession get _session => AppServices.instance.bleSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 手动配对期间挂起注入驱动(自动重连/GEO tick 会与手动流程撞车)
    AppServices.instance.suspendBleDriver();
    _sessionState = _session.state;
    _stateSub = _session.states.listen((s) {
      if (mounted) setState(() => _sessionState = s);
    });
    // 事件订阅:设备发现列示(实时,不等扫描窗收口)+ 流程日志。日志
    // 全走统一日志(AppLog ble 域,通用日志页可查;帧级 trace 由
    // AppServices 常年接线,不在此管)。
    _eventSub = PlatformServices.ble.events.listen(_onEvent);
    // 宿主喂的身份首帧即入:重连钮/冲突比较不等异步(盘档读盘悬着时
    // 身份不能跟着悬)。
    _saved = widget.savedIdentity;
    // 打开沿自动回链(下一帧:重连路径里有 setState,initState 直调
    // 非法)。宿主身份迟到时(控制器异步装载沿)由 didUpdateWidget 补触发。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    unawaited(_loadSaved());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台:受闸自动回链(2026-10-19 定稿恢复:被动守候 —— 相机睡
    // 时不碰不扰,它自己醒来重新广播即回链;iOS 注册闭环同靠这一步)。
    if (state == AppLifecycleState.resumed &&
        _saved != null &&
        !_binding &&
        !AppServices.instance.bleManualOff &&
        _sessionState == BleSessionState.idle) {
      _log('回到前台:自动回链…');
      unawaited(_resume());
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
    // 才动 —— 同实例回喂(普通重建)不抖。**身份迟到沿不触发自动回链**
    //(2026-10-19 用户定稿:首次配对流程未走完不主动重连 —— 握手落档
    //≠ 配对完成,iOS 侧还有系统蓝牙注册段,回链只由打开沿/回前台的
    // 受闸守候承担)。
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

  /// 打开沿自动回链旗标(每支只发一次;解除配对沿的 _saved 刷新不再
  /// 触发)。
  bool _autoResumeFired = false;

  /// 打开沿自动化(2026-10-19 定稿):有身份且未就绪 → **受闸自动回链**
  /// —— 深睡闸门开着,相机睡时不碰不扰,它自己醒来重新广播即回链;
  /// 点按「连接」才是显式绕闸点醒。**无身份不自动扫描**(2026-10-19
  /// 用户定稿:扫描只认显式点按)。驱动此刻已挂起,自动行为由面板接
  /// 管,闭合恢复驱动 —— 闭环自洽。判定只认宿主喂入的身份(不等盘档
  /// 读盘 —— 自动化不该被磁盘 IO 拖住起步)。
  void _bootstrap() {
    if (_saved != null) {
      if (!_autoResumeFired &&
          !AppServices.instance.bleManualOff &&
          _sessionState != BleSessionState.ready &&
          _sessionState != BleSessionState.pairing) {
        _autoResumeFired = true;
        unawaited(_resume());
      }
    }
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
        AppLog.d(AppLog.ble, '← ${uuid.substring(4, 8)} ${hexOf(data)}');
      case BleError(:final code, :final message, :final uuid):
        AppLog.w(AppLog.ble,
            '错误 $code${uuid == null ? '' : ' @$uuid'}:$message');
    }
  }

  Future<void> _startScan() async {
    if (_scanning || _sessionState == BleSessionState.pairing) return;
    // 扫描与重连循环互踩(扫描互踩扫描,BLE 无线电独占):扫描起步
    // 即废在途重连。
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
    // iOS 首配注册走系统蓝牙(用户裁定 2026-10-14:兜底转正):iOS 无程序
    // 化绑定 API,LE SMP 触发器五轮实验未获(v1-v5 详见 TODO「二」),
    // 系统蓝牙页点一下是 iOS 平台不可省的动作。配对成功即自动断开 +
    // 深链直达蓝牙页;用户在系统页点相机完成配对后回前台,生命周期
    // 监听自动复用身份重连 → 注册落档。
    if (Platform.operatingSystem == 'ios') {
      await _loadSaved();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _goSystemBluetooth();
      return;
    }
    await _loadSaved();
  }

  /// 已注册相机的重连:按已存 deviceId 扫 0x0399 重连广播,命中即以
  /// 已存 device/nonce 复用握手 —— 相机只认保存过的身份,扫描列表
  /// 再点 = 全新握手,必被秒断(2026-10-13 真机实证)。点一次自动
  /// 重试约 1 分钟(退避节奏),不必连点。
  ///
  /// [gateStandby]:重连按钮 = 显式意图绕深睡闸门(false);回前台
  /// 生命周期路 = 自动行为受闸(默认 true,待机广播不连等唤醒)。
  bool _retryActive = false;

  /// 重连循环世代号:[_cancelRetry] 自增即废在途循环;每个 await 后
  /// 对账,不等者退场(扫描/配对/解除/拆面板沿即刻止步)。
  int _retryGen = 0;
  Timer? _retryWait;
  Completer<void>? _retryWaitDone;

  bool get _retrying => _retryActive;

  /// 废在途重连:退避等待即刻醒(Completer 放行,await 不悬死)。
  /// dispose 沿传 notify:false —— 此时 element 已 defunct(mounted 仍真),
  /// setState 会炸断言。
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

  Future<void> _resume({bool gateStandby = true}) async {
    if (_retryActive) return;
    _retryActive = true;
    final gen = _retryGen;
    if (mounted) setState(() {});
    _log('重连(复用身份 ${_saved!.deviceId.toRadixString(16)})…');
    var hintedForeign = false;
    for (var attempt = 1; attempt <= 6; attempt++) {
      if (gen != _retryGen || !mounted) break;
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
        _log('第 $attempt 轮无命中${err == null ? '' : '($err)'},'
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
    if (gen == _retryGen) {
      _retryActive = false;
      if (mounted) setState(() {});
    }
  }

  /// 手动唤醒重连:点按即显式意图 —— 打断在场(受闸)自动循环,绕闸
  /// 直连待机相机(深睡唤醒 ~12s 开销真机实测,6490990 闸门前老行为);
  /// 自动路仍受闸守望,深睡不背景打扰。世代号废旧循环、退避等待即刻
  /// 醒,新循环走 [_resume] 同一收尾路。
  Future<void> _manualResume() async {
    // 显式连接 = 解除手动断开意图(守候/驱动恢复资格)。
    AppServices.instance.bleManualOff = false;
    _cancelRetry();
    await _resume(gateStandby: false);
  }

  /// 程序化经典蓝牙绑定(鸿蒙独有;iOS 无此 API 只能引导系统设置页)。
  /// 相机须先断开 BLE 才暴露经典蓝牙 —— 配对成功后先「断开」再点此钮;
  /// 绑定完成(系统弹窗确认)后再「重连」即注册落档。
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
      _log(ok == true ? '经典蓝牙绑定完成 ✓ 再点「重连」' : '绑定未完成');
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

  /// iOS 注册引导:断开(相机释放 BLE 后才暴露经典蓝牙)→ 深链直达
  /// 系统蓝牙页;用户点相机完成经典绑定,回前台由生命周期监听自动重连
  /// —— iOS 平台把手动路径压缩到「蓝牙页点一下」这唯一不可省的动作。
  Future<void> _goSystemBluetooth() async {
    await _session.disconnect();
    _log('已断开 → 直达系统蓝牙页,点相机完成配对');
    try {
      final direct =
          await _bleChannel.invokeMethod<bool>('openBluetoothSettings');
      if (direct != true) {
        _log('深链未直达蓝牙页(已开 app 设置页),请手动进「蓝牙」');
      }
    } on Exception catch (e) {
      _log('打开系统设置失败:$e');
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
  /// (冲突指引在重连日志 AppLog)。
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
    // 给):整体 mainAxisSize.min,水平不另缩进(与状态胶囊对齐)。
    // 会话态不在此重复(宿主状态行覆盖),只留档案/引导/错误。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 未就绪有档:设备行(2026-10-19 用户定稿:图标 设备 解除配对
        // 连接;序列/日期文字行退役)——连接 = 点按即唤醒(深睡闸门只
        // 闸自动路,手动点 = 显式意图绕闸直连)。
        if (!ready && _saved != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.camera_alt_outlined),
              // 展示名 = 相机广播名(旧档缺字段回落控制器名)——
              // controllerName 是本机在相机侧的注册名,不是相机。
              title: Text(_saved!.displayName),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_sessionState != BleSessionState.pairing)
                    OutlinedButton(
                      onPressed: _unpair,
                      child: Text(context.t('ble.unpair')),
                    ),
                  if (_sessionState == BleSessionState.idle ||
                      _sessionState == BleSessionState.reconnecting)
                    OutlinedButton(
                      // 点按即唤醒(2026-10-18 还原):深睡闸门只闸自动
                      // 路,手动点 = 显式意图 —— 打断在场受闸循环绕闸
                      // 直连;自动路仍受闸守望,待机不背景打扰。
                      onPressed: () => unawaited(_manualResume()),
                      child: Text(_retrying
                          ? context.t('ble.reconnecting')
                          : context.t('ble.connect')),
                    ),
                ],
              ),
            ),
          ),
        // 就绪态只留断开(2026-10-19 用户定稿:设备行/标签不驻留)。
        if (ready)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                // 显式断开 = 用户意图保持断开:置 manualOff 压制一切
                // 自动回链(驱动冷启/打开沿/回前台守候全哑),显式
                // 「连接」/重新配对沿解除。
                onPressed: () {
                  AppServices.instance.bleManualOff = true;
                  unawaited(_session.disconnect());
                },
                child: Text(context.t('ble.disconnect')),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!ready && _session.lastError != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    _session.lastError!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (_saved == null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: AppSpacing.xs),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.t('ble.scanHint'),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (Platform.operatingSystem == 'ios') ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          context.t('ble.iosPairHint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        // 扫描独立一行(2026-10-19 用户定稿:不与配对设备同行);鸿蒙
        // 经典绑定钉在扫描行旁(同为「准备连接」动作,不进设备行)。
        if (!ready)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed:
                      _scanning || _sessionState == BleSessionState.pairing
                          ? null
                          : _startScan,
                  child: Text(_scanning
                      ? context.t('ble.scanning')
                      : context.t('ble.scanButton')),
                ),
                if (_saved != null &&
                    (_sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting) &&
                    Platform.operatingSystem == 'ohos')
                  OutlinedButton(
                    onPressed:
                        _binding ? null : () => unawaited(_bondClassic()),
                    child: Text(_binding
                        ? context.t('ble.binding')
                        : context.t('ble.bindClassic')),
                  ),
              ],
            ),
          ),
        // 扫描列表就绪态隐藏:连接后残留的扫描行只有迷惑作用。
        // 圆角浅底容器包行(iOS 设置组语言),替代裸 Divider 分隔。
        if (!ready && _devices.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            clipBehavior: Clip.antiAlias,
            // ListTile 在最近 Material 祖先上画底/墨效:透明 Material
            // 垫在 DecoratedBox 与子项之间(ConnTileGroup 同款)。
            child: Material(
              type: MaterialType.transparency,
              child: LimitedBox(
                maxHeight: 220,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final device in _devices) _scanRow(context, device),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

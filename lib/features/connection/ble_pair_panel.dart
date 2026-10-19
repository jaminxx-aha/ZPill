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
import '../../l10n/l10n.dart';
import '../../platform/ble_scanner.dart';
import '../../platform/services.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

String _two(int v) => v.toString().padLeft(2, '0');

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
    // 打开沿自动化(下一帧:扫描/重连路径里有 setState,initState 直调
    // 非法)。宿主身份迟到时(控制器异步装载沿)由 didUpdateWidget 补触发。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    unawaited(_loadSaved());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统蓝牙页回来:自动复用重连(注册闭环的最后一步,免手点)。
    // 自动行为受深睡闸门:待机广播不连,被动扫描等唤醒(按钮路才绕闸)。
    if (state == AppLifecycleState.resumed &&
        _saved != null &&
        !_binding &&
        _sessionState == BleSessionState.idle) {
      _log('回到前台:自动重连…');
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
    // 喂):面板 _saved 跟进,状态行与冲突比较不残留旧身份。实例不等价
    // 才动 —— 同实例回喂(普通重建)不抖。
    if (!identical(widget.savedIdentity, oldWidget.savedIdentity)) {
      final hadIdentity = _saved != null;
      _saved = widget.savedIdentity;
      // 身份迟到沿补触发打开沿自动化(首帧宿主控制器还没装载完 → 扫描
      // 已误发的场景:重连靠原生 endScan 礼让收编扫描,自愈)。
      if (!hadIdentity && _saved != null) {
        _bootstrap();
      }
    }
  }

  Future<void> _loadSaved() async {
    final saved = widget.savedIdentity ??
        await AppServices.instance.bleIdentityStore.load();
    if (mounted) {
      setState(() => _saved = saved);
    }
  }

  /// 打开沿自动化旗标(每支只发一次;解除配对/授权复查的 _saved 刷新
  /// 不再触发)。
  bool _autoScanFired = false;
  bool _autoResumeFired = false;

  /// 弹层打开即自动化(2026-10-17 全自动重连定案):无身份 → 自动扫描
  /// (STA 弹层同款);有身份且未就绪 → 自动重连(带深睡闸门,与生命
  /// 周期恢复同语义)。驱动此刻已挂起,自动行为由面板接管,闭合恢复
  /// 驱动 —— 闭环自洽。判定只认宿主喂入的身份(不等盘档读盘 ——
  /// fake-async 外真机读盘快,但自动化不该被磁盘 IO 拖住起步)。
  void _bootstrap() {
    if (_saved != null) {
      if (!_autoResumeFired &&
          _sessionState != BleSessionState.ready &&
          _sessionState != BleSessionState.pairing) {
        _autoResumeFired = true;
        unawaited(_resume());
      }
    } else if (!_autoScanFired) {
      _autoScanFired = true;
      unawaited(_startScan());
    }
  }

  void _log(String line) => AppLog.i(AppLog.ble, line);

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

  String _fmtDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

  /// 扫描行电源态副文(2026-10-18 还原):bit0 待机位,全字节同显供
  /// 方言核对;无状态字节(mfg 不足 7B:配对菜单态/异厂商)不出行。
  /// 待机行是「点重连为何唤不醒」的答案面:深睡广播稀,闸门等物理唤醒。
  String? _powerStateText(BuildContext context, BleDevice device) {
    final status = advertisedStatusByte(device.mfgData);
    if (status == null) return null;
    final b = status.toRadixString(16).toUpperCase().padLeft(2, '0');
    return context.t(
        advertisedPowerState(device.mfgData) == NikonAdvPowerState.standby
            ? 'ble.advStandby'
            : 'ble.advAwake',
        {'b': b});
  }

  /// 扫描行:设备名 + 电源态副文;deviceId/冲突指引不显(冲突指引在
  /// 重连日志 AppLog)。
  Widget _scanRow(BuildContext context, BleDevice device) {
    final state = _powerStateText(context, device);
    return ListTile(
      dense: true,
      enabled: _sessionState == BleSessionState.idle ||
          _sessionState == BleSessionState.reconnecting,
      leading: const Icon(Icons.camera_alt_outlined),
      title: Text(device.name.isEmpty
          ? context.t('ble.unnamed')
          : device.name),
      subtitle: state == null ? null : Text(state),
      onTap: () => unawaited(_pair(device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _sessionState == BleSessionState.ready;
    // 嵌入宿主滚动层(蓝牙工具弹层 ListView):整体 mainAxisSize.min。
    // 会话态不在此重复(弹层顶部状态行覆盖),只留档案/引导/错误。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_saved != null)
                Text(
                  context.t('ble.pairedInfo', {
                    'name': _saved!.controllerName,
                    'serial': _saved!.serial.isEmpty
                        ? ''
                        : context.t('ble.serialLine', {'s': _saved!.serial}),
                    'date': _fmtDate(_saved!.pairedAt.toLocal()),
                  }).trimRight(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (!ready && _session.lastError != null)
                Text(
                  _session.lastError!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error),
                ),
              if (_saved == null) ...[
                Text(
                  context.t('ble.scanHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (Platform.operatingSystem == 'ios')
                  Text(
                    context.t('ble.iosPairHint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!ready)
                FilledButton(
                  onPressed:
                      _scanning || _sessionState == BleSessionState.pairing
                          ? null
                          : _startScan,
                  child: Text(_scanning
                      ? context.t('ble.scanning')
                      : context.t('ble.scanButton')),
                ),
              if (_saved != null && !ready)
                OutlinedButton(
                  onPressed:
                      _sessionState == BleSessionState.pairing ? null : _unpair,
                  child: Text(context.t('ble.unpair')),
                ),
              if (_saved != null &&
                  (_sessionState == BleSessionState.idle ||
                      _sessionState == BleSessionState.reconnecting))
                OutlinedButton(
                  // 点按即唤醒(2026-10-18 还原):深睡闸门只闸自动路,
                  // 手动点 = 显式意图 —— 打断在场受闸循环绕闸直连,深睡
                  // 相机 ~12s 开销唤醒(6490990 闸门前老行为)。自动路
                  // 仍受闸守望,待机不背景打扰。
                  onPressed: () => unawaited(_manualResume()),
                  child: Text(_retrying
                      ? context.t('ble.reconnecting')
                      : context.t('ble.reconnectReuse')),
                ),
              if (_saved != null &&
                  (_sessionState == BleSessionState.idle ||
                      _sessionState == BleSessionState.reconnecting) &&
                  Platform.operatingSystem == 'ohos')
                OutlinedButton(
                  onPressed: _binding ? null : () => unawaited(_bondClassic()),
                  child: Text(_binding
                      ? context.t('ble.binding')
                      : context.t('ble.bindClassic')),
                ),
              if (_saved != null &&
                  !ready &&
                  Platform.operatingSystem == 'ios') ...[
                OutlinedButton(
                  onPressed: () => unawaited(_goSystemBluetooth()),
                  child: Text(context.t('ble.goSystemBt')),
                ),
                Text(
                  context.t('ble.reRegisterHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (ready) ...[
                OutlinedButton(
                  onPressed: () => _session.disconnect(),
                  child: Text(context.t('ble.disconnect')),
                ),
              ],
            ],
          ),
        ),
        // 扫描列表就绪态隐藏:连接后残留的扫描行只有迷惑作用。
        if (!ready && _devices.isNotEmpty) ...[
          const Divider(height: 1),
          LimitedBox(
            maxHeight: 220,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in _devices) _scanRow(context, device),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

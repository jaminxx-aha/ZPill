/// BLE 配对面板(嵌入连接页蓝牙工具弹层;原独立配对页退役)。
///
/// 相机侧:菜单「连接至智能设备」→ 扫描(广播窗 ~30s,一次连接
/// 即停)→ 点选 → 四步握手(全在 [AppServices.bleSession],本面板零
/// 协议知识)→ NOT1 → 写控制器名 → 身份落盘(ble_identity.json)。
/// 重连由 AppServices 注入驱动按退避自动跑,面板只管首次配对与状态
/// 查看。
///
/// 手动件(2026-10-17 收敛):只剩申请后台定位(两段式授权第二段)。
/// 写 TIME / 唤起 WiFi / 读 0x2004 退役 —— TIME 收口自动校时、WiFi
/// 唤醒走弹层正门(带凭据全程)、凭据有「读凭据」钮,裸读 hex 无产品
/// 价值;原始帧 hex 日志保留,排方言时用。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/adv_payload.dart';
import '../../core/ble/ble_camera_session.dart';
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
  Timer? _statusTimer;
  final List<String> _lines = [];
  List<BleDevice> _devices = [];
  bool _scanning = false;
  BleSessionState _sessionState = BleSessionState.idle;
  BlePairedIdentity? _saved;
  String? _auth;

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
    _session.onTrace = _log; // 帧级诊断(→ stage1/3、← stage2/4 全落日志)
    _stateSub = _session.states.listen((s) {
      if (mounted) setState(() => _sessionState = s);
    });
    // 原始帧日志(M2 方言核对保留):PAIR/NOT1 帧 + 连接事件落 hex。
    _eventSub = PlatformServices.ble.events.listen(_onEvent);
    // 状态行活刷新(GEO/TIME 计数每秒跟一眼;dispose 显式撤销,不靠
    // mounted 自裁 —— 嵌入宿主(连接页弹层)拆树时须立即停摆)。
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) setState(() {});
    });
    // 宿主喂的身份首帧即入:重连钮/冲突比较不等异步(_loadSaved 还要
    // 查定位授权,授权查询悬着时身份不能跟着悬)。
    _saved = widget.savedIdentity;
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
    _retrying = false;
    AppServices.instance.resumeBleDriver();
    _session.onTrace = null;
    _stateSub?.cancel();
    _eventSub?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BlePairPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主身份镜像沿(配对/解除 → onIdentityChanged → 控制器重载 → 回
    // 喂):面板 _saved 跟进,状态行与冲突比较不残留旧身份。实例不等价
    // 才动 —— 同实例回喂(普通重建)不抖。
    if (!identical(widget.savedIdentity, oldWidget.savedIdentity)) {
      _saved = widget.savedIdentity;
    }
  }

  Future<void> _loadSaved() async {
    final saved = widget.savedIdentity ??
        await AppServices.instance.bleIdentityStore.load();
    String? auth;
    try {
      auth = await PlatformServices.locationStream.authorizationStatus();
    } on Exception {
      auth = null;
    }
    if (mounted) {
      setState(() {
        _saved = saved;
        _auth = auth;
      });
    }
  }

  void _log(String line) {
    if (!mounted) return;
    final n = DateTime.now();
    final stamp = '${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}'
        '.${n.millisecond.toString().padLeft(3, '0')}';
    setState(() {
      _lines.add('$stamp $line');
      if (_lines.length > 400) _lines.removeAt(0);
    });
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
        _log('LSS 特征表:$lss');
      case BlePreConnected(:final uuid):
        // 物理链路建立沿(iOS didConnect):与「已连接」(特征发现完成)
        // 两行之差 = 150ms 礼让 + 服务发现耗时,深睡重连时序取证用。
        _log('物理连接建立 $uuid');
      case BleDisconnected(:final uuid):
        _log('断连 $uuid');
      case BleNotified(:final uuid, :final data):
        _log('← ${uuid.substring(4, 8)} ${hexOf(data)}');
      case BleError(:final code, :final message, :final uuid):
        _log('错误 $code${uuid == null ? '' : ' @$uuid'}:$message');
    }
  }

  Future<void> _startScan() async {
    if (_scanning || _sessionState == BleSessionState.pairing) return;
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
  bool _retrying = false;

  Future<void> _resume({bool gateStandby = true}) async {
    if (_retrying) return;
    _retrying = true;
    if (mounted) setState(() {});
    _log('重连(复用身份 ${_saved!.deviceId.toRadixString(16)})…');
    var hintedForeign = false;
    for (var attempt = 1; attempt <= 6 && _retrying; attempt++) {
      if (_session.state == BleSessionState.ready) {
        _log('已就绪 ✓');
        break;
      }
      final ok = await _session.retryReconnect(gateStandby: gateStandby);
      if (!mounted || !_retrying) break;
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
      await Future<void>.delayed(_session.nextRetryDelay);
    }
    _retrying = false;
    if (mounted) setState(() {});
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
    await app.bleIdentityStore.clear();
    _session.identity = null;
    await _session.disconnect();
    app.refreshBleInjection();
    _log('已解除配对(注入停止;重连须重新走相机菜单)');
    await _loadSaved();
    widget.onIdentityChanged?.call();
  }

  Future<void> _requestAlways() async {
    try {
      await PlatformServices.locationStream.requestAlwaysAuthorization();
    } on Exception catch (e) {
      _log('申请后台定位失败:$e');
      return;
    }
    // 系统弹窗异步落定,延迟两拍再查授权态。
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      await _loadSaved();
    }());
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

  /// 广告厂商数据展示:0x0399 可解 → 结构化 deviceId(相机当前配对
  /// 关系的 ID)+ 电源态(状态字节 bit0,Zf 已实证 0x1E/0x1F,原始
  /// 字节同显);不可解(配对菜单态无 0x0399 / 异厂商数据)保底 hex
  /// 供方言核对。
  String _mfgSuffix(BuildContext context, BleDevice device) {
    final mfg = device.mfgData;
    if (mfg == null) return '';
    final id = expectedControllerDeviceId(mfg);
    if (id == null) return '  mfg ${hexOf(mfg)}';
    final suffix =
        context.t('ble.deviceId', {'id': id.toRadixString(16).toUpperCase()});
    final status = advertisedStatusByte(mfg);
    if (status == null) return '  $suffix';
    final stateText = advertisedPowerState(mfg) == NikonAdvPowerState.standby
        ? context.t('ble.advStandby',
            {'b': status.toRadixString(16).toUpperCase().padLeft(2, '0')})
        : context.t('ble.advAwake',
            {'b': status.toRadixString(16).toUpperCase().padLeft(2, '0')});
    return '  $suffix · $stateText';
  }

  /// 状态行文案(需 context 走 t():getter 拿不到 BuildContext,消费点
  /// 全在 build,故改带参方法)。
  String _stateLabel(BuildContext context) => switch (_sessionState) {
        BleSessionState.idle => _saved == null
            ? context.t('ble.notPaired')
            : context.t('ble.disconnected'),
        BleSessionState.pairing => context.t('ble.handshaking'),
        BleSessionState.ready => context.t('ble.connectedReady'),
        BleSessionState.reconnecting => context.t(
            'ble.reconnectBackoff', {'n': _session.nextRetryDelay.inSeconds}),
      };

  @override
  Widget build(BuildContext context) {
    final ready = _sessionState == BleSessionState.ready;
    // 嵌入宿主滚动层(蓝牙工具弹层 ListView):整体 mainAxisSize.min,
    // 原整页的 Expanded 弹性区改定高箱(设备列表 220 / 日志 260)。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  _sessionState == BleSessionState.ready
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 18,
                  color: _sessionState == BleSessionState.ready
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Text(_stateLabel(context)),
                const Spacer(),
                if (_auth != null)
                  Text(context.t('ble.locAuth', {'a': _auth!}),
                      style: Theme.of(context).textTheme.bodySmall),
              ]),
              if (_saved != null)
                Text(
                  context.t('ble.pairedInfo', {
                    'name': _saved!.controllerName,
                    'serial': _saved!.serial.isEmpty
                        ? ''
                        : context.t('ble.serialLine', {'s': _saved!.serial}),
                    'date': _saved!.pairedAt.toLocal(),
                  }).trimRight(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              Text(
                context.t(
                  _session.lastError == null
                      ? 'ble.sessionLine'
                      : 'ble.sessionLineErr',
                  {
                    'state': _stateLabel(context),
                    'fix': _session.lastFix == null
                        ? context.t('common.none')
                        : _session.lastFix!.utcTime
                            .toLocal()
                            .toString()
                            .substring(11, 19),
                    'geo': _session.geoWriteCount,
                    'time': _session.timeWriteCount,
                    if (_session.lastError != null) 'err': _session.lastError!,
                  },
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
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
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _scanning || _sessionState == BleSessionState.pairing
                    ? null
                    : _startScan,
                child: Text(_scanning
                    ? context.t('ble.scanning')
                    : context.t('ble.scanButton')),
              ),
              if (_saved != null)
                OutlinedButton(
                  onPressed:
                      _sessionState == BleSessionState.pairing ? null : _unpair,
                  child: Text(context.t('ble.unpair')),
                ),
              if (_saved != null &&
                  (_sessionState == BleSessionState.idle ||
                      _sessionState == BleSessionState.reconnecting))
                OutlinedButton(
                  onPressed: _retrying
                      ? null
                      : () => unawaited(_resume(gateStandby: false)),
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
              OutlinedButton(
                onPressed: _auth == 'always' ? null : _requestAlways,
                child: Text(context.t('ble.requestBgLoc')),
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
        const Divider(height: 1),
        if (_devices.isNotEmpty)
          LimitedBox(
            maxHeight: 220,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in _devices)
                  ListTile(
                    dense: true,
                    enabled: _sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting,
                    leading: const Icon(Icons.camera_alt_outlined),
                    title: Text(device.name.isEmpty
                        ? context.t('ble.unnamed')
                        : device.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${device.uuid}  RSSI ${device.rssi}'
                            '${_mfgSuffix(context, device)}'),
                        // 冲突指引(HarmoNiLink 口径):相机广播的是它
                        // 当前配对目标的 deviceId —— 解出来不是我们 =
                        // 它在等别的手机,点连必被拒。
                        if (cameraWaitsForOtherController(
                            device.mfgData, _ownDeviceId))
                          Text(
                            _conflictHint(context,
                                expectedControllerDeviceId(device.mfgData)!),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(context).colorScheme.error),
                          ),
                      ],
                    ),
                    onTap: () => unawaited(_pair(device)),
                  ),
              ],
            ),
          ),
        SizedBox(
          height: 260,
          child: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(children: [
                  Text(context.t('ble.logHint'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: context.t('ble.copyAllLogs'),
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: _lines.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                                ClipboardData(text: _lines.join('\n')));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(context.t('ble.logCopied')),
                                      duration: const Duration(seconds: 1)));
                            }
                          },
                  ),
                ]),
                Expanded(
                  child: SelectionArea(
                    child: ListView.builder(
                      itemCount: _lines.length,
                      itemBuilder: (context, index) => Text(
                        _lines[index],
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

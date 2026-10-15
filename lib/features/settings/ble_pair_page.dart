/// BLE 配对页(设置页入口;M2 调试件升级为正式配对 UX,M4)。
///
/// 相机侧:菜单「连接至智能设备」→ 本页扫描(广播窗 ~30s,一次连接
/// 即停)→ 点选 → 四步握手(全在 [AppServices.bleSession],本页零协议
/// 知识)→ NOT1 → 写控制器名 → 身份落盘(ble_identity.json)。重连
/// 由 AppServices 注入驱动按退避自动跑,本页只管首次配对与状态查看。
///
/// 保留手动件(M2 方言核对 + M7 原型):写 TIME / 唤起 WiFi(0x2005)/
/// 读 0x2004 / 申请后台定位(两段式授权第二段;原始帧 hex 日志保留,
/// 排方言时用)。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/adv_payload.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/ble/gatt_uuids.dart';
import '../../core/ble/time_payload.dart';
import '../../data/ble_identity_store.dart';
import '../../l10n/l10n.dart';
import '../../platform/ble_scanner.dart';
import '../../platform/services.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class BlePairPage extends StatefulWidget {
  const BlePairPage({super.key, this.savedIdentity});

  /// 预置已存身份:测试注入用(生产不传 —— 走盘档异步加载)。有值时
  /// 跳过盘档读取,首帧即可参与「在等别的手机」冲突比较;真盘档的
  /// File IO 在页测试的 fake-async 里永不落地,身份只能注入。
  @visibleForTesting
  final BlePairedIdentity? savedIdentity;

  @override
  State<BlePairPage> createState() => _BlePairPageState();
}

class _BlePairPageState extends State<BlePairPage> with WidgetsBindingObserver {
  StreamSubscription<BleSessionState>? _stateSub;
  StreamSubscription<BleEvent>? _eventSub;
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
    // 状态行活刷新(GEO/TIME 计数每秒跟一眼;页面销毁即停)。
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {});
    });
    unawaited(_loadSaved());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统蓝牙页回来:自动复用重连(注册闭环的最后一步,免手点)。
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
    super.dispose();
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
    setState(() {
      _lines.add(line);
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
      _log('扫描结束:${devices.length} 台(${devices.map((d) => d.name.isEmpty ? '(无名)' : d.name).join(', ')})');
      if (!mounted) return;
      setState(() => _devices = devices);
    } on Exception catch (e) {
      _log('扫描失败:$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
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
  bool _retrying = false;

  Future<void> _resume() async {
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
      final ok = await _session.retryReconnect();
      if (!mounted || !_retrying) break;
      if (ok) {
        _log('重连成功 ✓');
        break;
      }
      final err = _session.lastError;
      _log('第 $attempt 轮无命中${err == null ? '' : '($err)'},'
          '${_session.nextRetryDelay.inSeconds}s 后再试(相机须停在'
          '「连接至智能设备」页或可重连待机)');
      // 重连未命中 + 本页扫描结果里有「在等别的手机」的相机 → 复用同一条
      // 冲突指引(重连扫描被 native 过滤只看我方 deviceId,别家相机只有
      // 本页配对扫描才看得见);每轮重连只提示一次,免刷屏。
      if (!hintedForeign) {
        final foreign = _foreignWaiting();
        final foreignId =
            foreign == null ? null : expectedControllerDeviceId(foreign.mfgData);
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

  Future<void> _manual(String label, Future<void> Function() action) async {
    try {
      await action();
      _log('$label 已执行');
    } on Exception catch (e) {
      _log('$label 失败:$e');
    }
  }

  /// 我方注册身份的 deviceId(已存档优先,会话内存兜底;null = 首次
  /// 配对,无从比较冲突)。
  int? get _ownDeviceId =>
      _saved?.deviceId ?? _session.identity?.deviceId;

  /// 「在等别的手机」指引文案(扫描行提示与重连失败日志共用;动作
  /// 措辞借 HarmoNiLink 真机口径:相机「已配对设备」菜单切换设备)。
  String _conflictHint(BuildContext context, int foreignId) => context.t(
      '此相机在等别的手机(设备ID 0x{id}):请在相机「已配对设备」菜单'
      '断开现有连接或改选本机,或确认相机没被其他手机(如 SnapBridge)占用',
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
  /// 关系的 ID);不可解(配对菜单态无 0x0399 / 异厂商数据)保底 hex
  /// 供方言核对。
  String _mfgSuffix(BuildContext context, BleDevice device) {
    final mfg = device.mfgData;
    if (mfg == null) return '';
    final id = expectedControllerDeviceId(mfg);
    return id == null
        ? '  mfg ${hexOf(mfg)}'
        : '  ${context.t('设备ID 0x{id}', {
            'id': id.toRadixString(16).toUpperCase()
          })}';
  }

  /// 状态行文案(需 context 走 t():getter 拿不到 BuildContext,消费点
  /// 全在 build,故改带参方法)。
  String _stateLabel(BuildContext context) => switch (_sessionState) {
        BleSessionState.idle => _saved == null
            ? context.t('未配对')
            : context.t('已断开'),
        BleSessionState.pairing => context.t('握手中…'),
        BleSessionState.ready => context.t('已连接(注入就绪)'),
        BleSessionState.reconnecting => context.t('重连中(退避 {n}s)',
            {'n': _session.nextRetryDelay.inSeconds}),
      };

  @override
  Widget build(BuildContext context) {
    final ready = _sessionState == BleSessionState.ready;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('BLE 配对 / GPS 注入'))),
      body: Column(
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
                    Text(context.t('定位授权:{a}', {'a': _auth!}),
                        style: Theme.of(context).textTheme.bodySmall),
                ]),
                if (_saved != null)
                  Text(
                    context.t('已配对:{name}{serial}  {date}', {
                      'name': _saved!.controllerName,
                      'serial': _saved!.serial.isEmpty
                          ? ''
                          : context.t('  序列 {s}', {'s': _saved!.serial}),
                      'date': _saved!.pairedAt.toLocal(),
                    }).trimRight(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  context.t(
                    _session.lastError == null
                        ? '会话:{state} · 定位:{fix} · GEO {geo} 帧 · TIME {time} 帧'
                        : '会话:{state} · 定位:{fix} · GEO {geo} 帧 · TIME {time} 帧 · 错误:{err}',
                    {
                      'state': _stateLabel(context),
                      'fix': _session.lastFix == null
                          ? context.t('无')
                          : _session.lastFix!.utcTime.toLocal().toString().substring(11, 19),
                      'geo': _session.geoWriteCount,
                      'time': _session.timeWriteCount,
                      if (_session.lastError != null)
                        'err': _session.lastError!,
                    },
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  context.t(
                      '相机先进菜单「连接至智能设备」(广播窗约 30 秒),再点扫描。'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (Platform.operatingSystem == 'ios')
                  Text(
                    context.t(
                        'iOS:配对成功后自动断开并跳系统蓝牙页,点相机完成配对'
                        '(核对配对码)→ 回本页自动重连注册。'),
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
                  onPressed:
                      _scanning || _sessionState == BleSessionState.pairing
                          ? null
                          : _startScan,
                  child: Text(_scanning
                      ? context.t('扫描中…')
                      : context.t('扫描(30s)')),
                ),
                if (_saved != null)
                  OutlinedButton(
                    onPressed: _sessionState == BleSessionState.pairing
                        ? null
                        : _unpair,
                    child: Text(context.t('解除配对')),
                  ),
                if (_saved != null &&
                    (_sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting))
                  OutlinedButton(
                    onPressed: _retrying ? null : () => unawaited(_resume()),
                    child: Text(_retrying
                        ? context.t('重连中…')
                        : context.t('重连(复用身份)')),
                  ),
                if (_saved != null &&
                    (_sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting) &&
                    Platform.operatingSystem == 'ohos')
                  OutlinedButton(
                    onPressed:
                        _binding ? null : () => unawaited(_bondClassic()),
                    child: Text(_binding
                        ? context.t('绑定中…')
                        : context.t('绑定经典蓝牙')),
                  ),
                OutlinedButton(
                  onPressed: _auth == 'always' ? null : _requestAlways,
                  child: Text(context.t('申请后台定位')),
                ),
                if (_saved != null &&
                    !ready &&
                    Platform.operatingSystem == 'ios') ...[
                  OutlinedButton(
                    onPressed: () => unawaited(_goSystemBluetooth()),
                    child: Text(context.t('去系统蓝牙完成注册')),
                  ),
                  Text(
                    context.t(
                        '未注册时可再跳一次:系统蓝牙页点相机配对(核对配对码)'
                        '→ 回本页自动重连(配对成功后通常已自动跳过一次)'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (ready) ...[
                  OutlinedButton(
                    onPressed: () => _manual(
                        '写 TIME',
                        () => PlatformServices.ble.write(kNikonCharTime,
                            TimePayload.build(DateTime.now().toUtc()))),
                    child: Text(context.t('写 TIME')),
                  ),
                  OutlinedButton(
                    onPressed: () => _manual(
                        '0x2005=0x01',
                        () => PlatformServices.ble.write(kNikonCharWifi,
                            Uint8List.fromList([0x01]))),
                    child: Text(context.t('唤起 WiFi')),
                  ),
                  OutlinedButton(
                    onPressed: () => _manual('读 0x2004', () async {
                      final value =
                          await PlatformServices.ble.read(kNikonCharConfig);
                      _log(
                          '0x2004 ${value == null ? '(null)' : '${value.length}B ${hexOf(value.sublist(0, value.length.clamp(0, 48)))}…'}');
                    }),
                    child: Text(context.t('读 0x2004')),
                  ),
                  OutlinedButton(
                    onPressed: () => _session.disconnect(),
                    child: Text(context.t('断开')),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (_devices.isNotEmpty)
            Expanded(
              flex: 2,
              child: ListView(
                children: [
                  for (final device in _devices)
                    ListTile(
                      dense: true,
                      enabled: _sessionState == BleSessionState.idle ||
                          _sessionState == BleSessionState.reconnecting,
                      leading: const Icon(Icons.camera_alt_outlined),
                      title: Text(device.name.isEmpty
                          ? context.t('(无名)')
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
                              _conflictHint(
                                  context,
                                  expectedControllerDeviceId(
                                      device.mfgData)!),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error),
                            ),
                        ],
                      ),
                      onTap: () => unawaited(_pair(device)),
                    ),
                ],
              ),
            ),
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Row(children: [
                    Text(context.t('日志(长按可选中,或点右侧复制全部)'),
                        style: Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: context.t('复制全部日志'),
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: _lines.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: _lines.join('\n')));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            context.t('日志已复制')),
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
      ),
    );
  }
}

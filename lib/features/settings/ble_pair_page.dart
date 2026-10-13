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
import '../../core/ble/ble_camera_session.dart';
import '../../core/ble/gatt_uuids.dart';
import '../../core/ble/time_payload.dart';
import '../../data/ble_identity_store.dart';
import '../../platform/ble_scanner.dart';
import '../../platform/services.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class BlePairPage extends StatefulWidget {
  const BlePairPage({super.key});

  @override
  State<BlePairPage> createState() => _BlePairPageState();
}

class _BlePairPageState extends State<BlePairPage> {
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
  void dispose() {
    _retrying = false;
    _session.onTrace = null;
    _stateSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final saved = await AppServices.instance.bleIdentityStore.load();
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

  String get _stateLabel => switch (_sessionState) {
        BleSessionState.idle => _saved == null ? '未配对' : '已断开',
        BleSessionState.pairing => '握手中…',
        BleSessionState.ready => '已连接(注入就绪)',
        BleSessionState.reconnecting => '重连中(退避 '
            '${_session.nextRetryDelay.inSeconds}s)',
      };

  @override
  Widget build(BuildContext context) {
    final ready = _sessionState == BleSessionState.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('BLE 配对 / GPS 注入')),
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
                  Text(_stateLabel),
                  const Spacer(),
                  if (_auth != null)
                    Text('定位授权:$_auth',
                        style: Theme.of(context).textTheme.bodySmall),
                ]),
                if (_saved != null)
                  Text(
                    '已配对:${_saved!.controllerName}'
                    '${_saved!.serial.isEmpty ? '' : '  序列 ${_saved!.serial}'}'
                    '  ${_saved!.pairedAt.toLocal()}'.trimRight(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  '会话:$_stateLabel · 定位:'
                  '${_session.lastFix == null ? '无' : _session.lastFix!.utcTime.toLocal().toString().substring(11, 19)}'
                  ' · GEO ${_session.geoWriteCount} 帧'
                  ' · TIME ${_session.timeWriteCount} 帧'
                  '${_session.lastError == null ? '' : ' · 错误:${_session.lastError}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '相机先进菜单「连接至智能设备」(广播窗约 30 秒),再点扫描。',
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
                  child: Text(_scanning ? '扫描中…' : '扫描(30s)'),
                ),
                if (_saved != null)
                  OutlinedButton(
                    onPressed: _sessionState == BleSessionState.pairing
                        ? null
                        : _unpair,
                    child: const Text('解除配对'),
                  ),
                if (_saved != null &&
                    (_sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting))
                  OutlinedButton(
                    onPressed: _retrying ? null : () => unawaited(_resume()),
                    child: Text(_retrying ? '重连中…' : '重连(复用身份)'),
                  ),
                if (_saved != null &&
                    (_sessionState == BleSessionState.idle ||
                        _sessionState == BleSessionState.reconnecting) &&
                    Platform.operatingSystem == 'ohos')
                  OutlinedButton(
                    onPressed:
                        _binding ? null : () => unawaited(_bondClassic()),
                    child: Text(_binding ? '绑定中…' : '绑定经典蓝牙'),
                  ),
                OutlinedButton(
                  onPressed: _auth == 'always' ? null : _requestAlways,
                  child: const Text('申请后台定位'),
                ),
                if (ready) ...[
                  OutlinedButton(
                    onPressed: () => _manual(
                        '写 TIME',
                        () => PlatformServices.ble.write(kNikonCharTime,
                            TimePayload.build(DateTime.now().toUtc()))),
                    child: const Text('写 TIME'),
                  ),
                  OutlinedButton(
                    onPressed: () => _manual(
                        '0x2005=0x01',
                        () => PlatformServices.ble.write(kNikonCharWifi,
                            Uint8List.fromList([0x01]))),
                    child: const Text('唤起 WiFi'),
                  ),
                  OutlinedButton(
                    onPressed: () => _manual('读 0x2004', () async {
                      final value =
                          await PlatformServices.ble.read(kNikonCharConfig);
                      _log(
                          '0x2004 ${value == null ? '(null)' : '${value.length}B ${hexOf(value.sublist(0, value.length.clamp(0, 48)))}…'}');
                    }),
                    child: const Text('读 0x2004'),
                  ),
                  OutlinedButton(
                    onPressed: () => _session.disconnect(),
                    child: const Text('断开'),
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
                      title:
                          Text(device.name.isEmpty ? '(无名)' : device.name),
                      subtitle: Text('${device.uuid}  RSSI ${device.rssi}'
                          '${device.mfgData == null ? '' : '  mfg ${hexOf(device.mfgData!)}'}'),
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
                    Text('日志(长按可选中,或点右侧复制全部)',
                        style: Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制全部日志',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: _lines.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: _lines.join('\n')));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('日志已复制'),
                                        duration: Duration(seconds: 1)));
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

/// 连接页(TODO.md §七 P1):连接/断开、状态着色、状态提示。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// 双路径单连接:USB(C-to-C 直连)与 PTP-IP 无线(扫描发现或手动
/// IP,默认 192.168.1.1:15740),同一状态机互斥。
///
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中弹配对码确认(相机记录本设备,见
/// CameraConnectionImpl 类注),已配对/手动 IP 直连。手动输入保留为
/// 扫描失效(AP 模式未广播等)时的兜底。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../data/paired_cameras_store.dart';
import '../../platform/nsd_scanner.dart';
import '../remote/remote_page.dart';
import '../settings/settings_page.dart';

class ConnectionController extends ChangeNotifier {
  /// 注入应用级连接(全局单例状态,经 AppServices 收口)+ 扫描器与
  /// 配对档案(均可空:测试/未装配平台降级)。
  ConnectionController({
    this.connection,
    this.scanner,
    this.pairedCameras,
  }) {
    connection?.states.listen(_onState);
    // 常驻订阅:浏览期间增删相机,未浏览时静默无流。
    scanner?.events.listen(_onNsdEvent, onError: (Object _) {});
  }

  final CameraConnection? connection;
  final NsdScanner? scanner;
  final PairedCamerasStore? pairedCameras;

  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;

  /// 扫描到的相机(按实例名去重;解析失败无 IP 的不上榜)。
  final Map<String, DiscoveredIpCamera> _cameras = {};
  List<DiscoveredIpCamera> get cameras => _cameras.values.toList(growable: false);

  /// 扫描进行中(未装配扫描器/平台未实现时永远 false)。
  bool scanning = false;

  /// 已配对/曾连接过的相机(最近优先),用于快速重连。
  List<CameraInfo> savedCameras = const [];

  /// 状态提示:失败原因(含插线/解锁/热点指引)、成功后的去向(分链路)。
  String? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    return switch (state) {
      CameraLinkState.connected =>
        '${c.isWireless ? 'Wi-Fi' : 'USB'} 已连接${c.deviceName == null ? '' : ':${c.deviceName}'}。到「浏览」页查看照片',
      CameraLinkState.pairing => '相机请求配对确认(见弹窗)',
      CameraLinkState.failed => c.error ?? '连接失败',
      _ => null,
    };
  }

  void _onState(CameraLinkState s) {
    state = s;
    notifyListeners();
  }

  void _onNsdEvent(NsdEvent event) {
    switch (event) {
      case NsdCameraFound(:final camera):
        if (camera.host.isNotEmpty) {
          _cameras[camera.name] = camera;
        }
      case NsdCameraLost(:final name):
        _cameras.remove(name);
    }
    notifyListeners();
  }

  /// 开始扫描(mDNS `_ptp._tcp`)。未装配扫描器或平台未实现时静默降级
  /// (提示手动输入)。
  Future<void> startScan() async {
    final s = scanner;
    if (s == null) {
      return;
    }
    _cameras.clear();
    scanning = true;
    notifyListeners();
    await _reloadSaved();
    try {
      await s.startBrowsing();
    } on Exception {
      // MissingPluginException(ohos/Android 未落地)等:停止扫描态,
      // UI 引导手动输入。
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    scanning = false;
    notifyListeners();
    final s = scanner;
    if (s != null) {
      try {
        await s.stopBrowsing();
      } on Exception {
        // 停止失败不致命(页面退出/断连路径都会走到)
      }
    }
  }

  Future<void> _reloadSaved() async {
    final store = pairedCameras;
    if (store == null) {
      return;
    }
    savedCameras = await store.list();
    notifyListeners();
  }

  /// 页面首帧拉一次配对档案(快速重连入口)。
  Future<void> loadSaved() => _reloadSaved();

  Future<void> connect() async {
    final c = connection;
    if (c == null) {
      return;
    }
    // 状态经 states 流回(本地 state 只是流的镜像)。
    await c.connect();
  }

  /// 连接扫描到的相机(实例名随连接传给配对档案)。
  Future<void> connectDiscovered(DiscoveredIpCamera camera) async {
    final c = connection;
    if (c == null) {
      return;
    }
    await stopScan();
    await c.connect(ip: camera.host, instanceName: camera.name);
  }

  /// 快速重连上次相机(直连记录里的 IP;失效时再扫描/手动)。
  Future<void> connectSaved(CameraInfo camera) async {
    final c = connection;
    final ip = camera.lastIp;
    if (c == null || ip == null) {
      return;
    }
    await c.connect(ip: ip, instanceName: camera.name);
  }

  /// 无线连接(手动 IP 兜底):输入为空时回落默认网关地址。
  Future<void> connectWireless() async {
    final c = connection;
    if (c == null) {
      return;
    }
    var ip = ipController.text.trim();
    if (ip.isEmpty) {
      ip = kDefaultCameraIp;
    }
    await c.connect(ip: ip);
  }

  Future<void> confirmPairing() async {
    await connection?.confirmPairing();
  }

  Future<void> cancelPairing() async {
    await connection?.cancelPairing();
  }

  Future<void> disconnect() async {
    final c = connection;
    if (c == null) {
      return;
    }
    await c.disconnect();
  }

  @override
  void dispose() {
    ipController.dispose();
    super.dispose();
  }
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, this.controller});

  /// 测试注入;缺省取应用级单例(连接是全局单例状态)。
  final ConnectionController? controller;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  ConnectionController get _controller =>
      widget.controller ?? AppServices.instance.connectionController;

  /// 配对弹窗只弹一次的哨兵(state 离开 pairing 即复位)。
  bool _pairingDialogShown = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _controller.loadSaved();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (controller.state == CameraLinkState.pairing) {
      if (!_pairingDialogShown && mounted) {
        _pairingDialogShown = true;
        _showPairingDialog(controller);
      }
    } else {
      _pairingDialogShown = false;
    }
  }

  Future<void> _showPairingDialog(ConnectionController controller) async {
    // 弹窗内容跟随控制器:等待期间链路死亡(状态离开 pairing)自动关窗。
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ListenableBuilder(
        listenable: controller,
        builder: (dialogContext, _) {
          if (controller.state != CameraLinkState.pairing) {
            // 断链/外部断开已收口:下一帧关窗(gate 已不在,
            // confirm/cancel 均为 no-op)。
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => Navigator.of(dialogContext).maybePop());
            return const SizedBox.shrink();
          }
          final code = controller.connection?.pairingCode ?? '';
          return AlertDialog(
            title: const Text('配对确认'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('配对码', style: Theme.of(dialogContext).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(code,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(letterSpacing: 12)),
                const SizedBox(height: 12),
                const Text(
                  '确认后相机会把「NikonPill」记为已配对设备,之后免配对直连;'
                  '如相机屏幕出现提示,请在机身上按 OK 确认。',
                  textAlign: TextAlign.start,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('跳过配对'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认配对'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed == true) {
      await controller.confirmPairing();
    } else {
      await controller.cancelPairing();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('相机'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 状态着色:disconnected 灰 / connecting 蓝 / pairing 橙
              // / connected 绿 / failed 红
              _StatusCard(state: controller.state),
              if (controller.hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(controller.hint!),
                ),
              const SizedBox(height: 16),
              // USB:C-to-C 数据线直连
              Card(
                child: ListTile(
                  leading: const Icon(Icons.usb),
                  title: const Text('USB 连接'),
                  subtitle:
                      const Text('用 C-to-C 数据线连接相机与手机,解锁相机后点「连接」'),
                ),
              ),
              FilledButton(
                onPressed: switch (controller.state) {
                  CameraLinkState.connected => controller.disconnect,
                  CameraLinkState.connecting ||
                  CameraLinkState.pairing => null,
                  _ => controller.connect,
                },
                child: Text(
                    controller.state == CameraLinkState.connected ? '断开' : '连接'),
              ),
              const SizedBox(height: 16),
              // 无线(PTP-IP):扫描发现 → 点选连接;手动 IP 兜底
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.wifi),
                          const SizedBox(width: 8),
                          Text('无线连接(Wi-Fi)',
                              style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: Icon(controller.scanning
                              ? Icons.stop_circle_outlined
                              : Icons.wifi_find),
                          label: Text(
                              controller.scanning ? '扫描中…(点按停止)' : '扫描相机'),
                          onPressed: controller.scanning
                              ? controller.stopScan
                              : controller.startScan,
                        ),
                      ),
                      for (final camera in controller.cameras)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.photo_camera_outlined),
                          title: Text(camera.name),
                          subtitle: Text(camera.host),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: switch (controller.state) {
                            CameraLinkState.connecting ||
                            CameraLinkState.connected ||
                            CameraLinkState.pairing => null,
                            _ => () => controller.connectDiscovered(camera),
                          },
                        ),
                      if (controller.savedCameras.isNotEmpty &&
                          controller.state != CameraLinkState.connected)
                        for (final saved in controller.savedCameras)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history),
                            title: Text('上次:${saved.name}'),
                            subtitle: Text(saved.lastIp ?? ''),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: switch (controller.state) {
                              CameraLinkState.connecting ||
                              CameraLinkState.connected ||
                              CameraLinkState.pairing => null,
                              _ => () => controller.connectSaved(saved),
                            },
                          ),
                      const Divider(height: 24),
                      TextField(
                        controller: controller.ipController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: '相机 IP(扫描不到时手动输入)',
                          hintText: kDefaultCameraIp,
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.wifi),
                          label: const Text('手动连接'),
                          onPressed: switch (controller.state) {
                            CameraLinkState.connecting ||
                            CameraLinkState.connected ||
                            CameraLinkState.pairing => null,
                            _ => controller.connectWireless,
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '两种模式(相机菜单:网络 → 连接至智能设备 → Wi-Fi 连接):\n'
                        '· STA 模式:相机与你手机加入同一个 Wi-Fi,'
                        '点「扫描相机」发现后连接;\n'
                        '· AP 模式:相机当热点,先在系统 Wi-Fi 设置里加入它'
                        '(扫描找不到时手动输入,IP 默认 192.168.1.1)。\n'
                        '首次连接会请求配对确认(相机记录本设备,之后免配对);\n'
                        '相机同一时间只允许一个客户端:若被 SnapBridge(尼享)'
                        '抢先连上会遭拒,请先彻底关闭它。\n'
                        '首次连接若失败,请在系统弹窗中允许访问本地网络后重试;'
                        '下载大文件期间请保持 App 在前台、屏幕点亮。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RemotePage()),
                ),
                child: const Text('遥控拍摄'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final CameraLinkState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      CameraLinkState.disconnected => ('未连接', Colors.grey),
      CameraLinkState.detecting => ('检测相机 WiFi…', Colors.blue),
      CameraLinkState.connecting => ('连接中…', Colors.blue),
      CameraLinkState.pairing => ('等待配对确认…', Colors.orange),
      CameraLinkState.connected => ('已连接', Colors.green),
      CameraLinkState.failed => ('连接失败', Colors.red),
    };
    return Card(
      color: color.withValues(alpha: 0.15),
      child: ListTile(
        leading: Icon(Icons.lan, color: color),
        title: Text(label),
        trailing: Icon(Icons.circle, color: color, size: 12),
      ),
    );
  }
}

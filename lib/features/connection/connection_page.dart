/// 连接页(TODO.md §七 P1):WiFi 检测提示、IP 输入、连接/重试/断开、状态着色。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
library;

import 'package:flutter/material.dart';

import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../remote/remote_page.dart';
import '../settings/settings_page.dart';

class ConnectionController extends ChangeNotifier {
  ConnectionController({CameraConnection? connection})
      : _connection = connection; // TODO(P1): 注入 CameraConnectionImpl

  final CameraConnection? _connection;
  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;
  String? wifiHint; // 「检测到相机热点 NIKON-XXXX」/「请先连接相机 WiFi」

  // TODO(P1): 订阅 connection.states 与 PlatformServices.network.link,
  // 驱动 state / wifiHint;重试 = 失败态下再次 connect()。
  Future<void> connect() async {
    state = CameraLinkState.connecting;
    notifyListeners();
    // TODO(P1): _connection?.connect(ip: ipController.text)
    await Future<void>.delayed(Duration.zero);
    state = CameraLinkState.failed;
    notifyListeners();
  }

  Future<void> disconnect() async {
    // TODO(P1): _connection?.disconnect()
    state = CameraLinkState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    ipController.dispose();
    super.dispose();
  }
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  // TODO(P1): 提升为应用级共享实例(连接是全局单例状态,引入 DI 时收口)
  final ConnectionController _controller = ConnectionController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
          final c = context;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 状态着色:disconnected 灰 / connecting 蓝 / connected 绿 / failed 红
              _StatusCard(state: controller.state),
              if (controller.wifiHint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(controller.wifiHint!),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: controller.ipController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '相机 IP(默认 192.168.1.1)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: controller.state == CameraLinkState.connected
                    ? controller.disconnect
                    : controller.connect,
                child: Text(
                  controller.state == CameraLinkState.connected ? '断开' : '连接',
                  style: TextStyle(color: c.colorScheme.onPrimary),
                ),
              ),
              const SizedBox(height: 8),
              // TODO(P3): 遥控拍摄入口(连接成功后可用)
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RemotePage()),
                ),
                child: const Text('遥控拍摄(P3)'),
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
      CameraLinkState.connected => ('已连接', Colors.green),
      CameraLinkState.failed => ('连接失败(待实现:P1)', Colors.red),
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

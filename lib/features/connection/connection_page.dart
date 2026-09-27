/// 连接页(TODO.md §七 P1):连接/断开、状态着色、状态提示。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// P0 为 USB 主线:IP 输入框属 PTP-IP 无线线,暂不参与连接逻辑。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../remote/remote_page.dart';
import '../settings/settings_page.dart';

class ConnectionController extends ChangeNotifier {
  /// 注入应用级连接(全局单例状态,经 AppServices 收口)。
  ConnectionController({this.connection}) {
    connection?.states.listen(_onState);
  }

  final CameraConnection? connection;

  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;

  /// 状态提示:失败原因(含插线/解锁引导)、连接成功后的去向。
  String? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    return switch (state) {
      CameraLinkState.connected =>
        'USB 已连接${c.deviceName == null ? '' : ':${c.deviceName}'}。到「浏览」页查看照片',
      CameraLinkState.failed => c.error ?? '连接失败',
      _ => null,
    };
  }

  void _onState(CameraLinkState s) {
    state = s;
    notifyListeners();
  }

  Future<void> connect() async {
    final c = connection;
    if (c == null) {
      return;
    }
    // 状态经 states 流回(本地 state 只是流的镜像)。
    await c.connect();
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
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  // 应用级共享实例(连接是全局单例状态);本页不持有、不 dispose。
  ConnectionController get _controller => AppServices.instance.connectionController;

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
              // 状态着色:disconnected 灰 / connecting 蓝 / connected 绿 / failed 红
              _StatusCard(state: controller.state),
              if (controller.hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(controller.hint!),
                ),
              const SizedBox(height: 16),
              // USB 主线提示(无线线接入后替换为 IP 输入 + WiFi 检测提示)。
              Card(
                child: ListTile(
                  leading: const Icon(Icons.usb),
                  title: const Text('USB 连接'),
                  subtitle: const Text('用 C-to-C 数据线连接相机与手机,解锁相机后点「连接」'),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: switch (controller.state) {
                  CameraLinkState.connected => controller.disconnect,
                  CameraLinkState.connecting => null,
                  _ => controller.connect,
                },
                child: Text(
                    controller.state == CameraLinkState.connected ? '断开' : '连接'),
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

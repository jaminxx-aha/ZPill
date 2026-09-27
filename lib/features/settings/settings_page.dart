/// 设置页(TODO.md §五)。
library;

import 'package:flutter/material.dart';

import '../../data/settings_store.dart';

class SettingsController extends ChangeNotifier {
  /// P2:注入持久化实现(shared_preferences,DataStore 等价)
  SettingsController({this.store});

  final SettingsStore? store;
  AppSettings settings = const AppSettings();

  // TODO(P2): 订阅 store.settings;autoTransfer 开关持久化
  Future<void> setAutoTransfer(bool value) async {
    settings = settings.copyWith(autoTransfer: value);
    notifyListeners();
    // TODO(P2): await store?.update(settings)
  }

  // TODO(P3): quality / batterySaver / customSavePath
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsController _controller = SettingsController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('自动传输'),
              subtitle: const Text('连接相机后自动下载新照片(P2)'),
              value: controller.settings.autoTransfer,
              onChanged: controller.setAutoTransfer,
            ),
            // TODO(P3): 传输质量(原图/压缩)、省电模式、自定义存储路径
          ],
        ),
      ),
    );
  }
}

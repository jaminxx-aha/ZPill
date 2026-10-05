/// 应用主框架:底部导航四 tab(相机 / 拍摄 / 图库 / 设置)。
///
/// 相机 = 连接 + 相机信息总览(相册入口);拍摄 = 遥控监看;
/// 图库 = 「下载到应用」的文件(传输徽标入口);设置 = 全局配置。
/// IndexedStack 常驻保状态;拍摄 tab 离开前台即停取景(见 RemotePage
/// 的 active 参数)。
library;

import 'package:flutter/material.dart';

import '../connection/connection_page.dart';
import '../library/local_library_page.dart';
import '../remote/remote_page.dart';
import '../settings/settings_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        // 拍摄 tab 非前台即停 Live View(IndexedStack 不卸载,须显式告知)。
        children: [
          const ConnectionPage(),
          RemotePage(active: _index == 1),
          const LocalLibraryPage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_camera_outlined), selectedIcon: Icon(Icons.photo_camera), label: '相机'),
          NavigationDestination(icon: Icon(Icons.camera_outlined), selectedIcon: Icon(Icons.camera), label: '拍摄'),
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: '图库'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

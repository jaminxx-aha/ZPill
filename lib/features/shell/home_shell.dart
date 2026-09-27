/// 应用主框架:底部导航三 tab(相机 / 浏览 / 传输,TODO.md §七 P1)。
///
/// 设置、遥控(P3)从相机页 push 进入,不占 tab。
library;

import 'package:flutter/material.dart';

import '../browser/browser_page.dart';
import '../connection/connection_page.dart';
import '../transfers/transfers_page.dart';

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
        children: const [ConnectionPage(), BrowserPage(), TransfersPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_camera_outlined), selectedIcon: Icon(Icons.photo_camera), label: '相机'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: '浏览'),
          NavigationDestination(icon: Icon(Icons.download_outlined), selectedIcon: Icon(Icons.download), label: '传输'),
        ],
      ),
    );
  }
}

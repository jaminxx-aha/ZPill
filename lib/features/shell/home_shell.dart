/// 应用主框架:四 tab 导航(相机 / 拍摄 / 图库 / 设置)—— 竖屏底部
/// NavigationBar,横屏换左侧 NavigationRail(80px 底栏会吃掉监看画面
/// 高度)。
///
/// 相机 = 连接 + 相机信息总览(相册入口);拍摄 = 遥控监看;
/// 图库 = 「下载到应用」的文件(传输徽标入口);设置 = 全局配置。
/// IndexedStack 常驻保状态;拍摄 tab 离前台即挂起帧轮询(相机侧取景
/// 保持 —— 取景生命周期跟连接走,见 RemotePage 的 active 参数)。
///
/// 连接转正沿(有线/无线同一状态机)只做一件事:调 RemoteController
/// .autoLiveViewOnConnect 连接即取景(OpenZCine 口径:连接成功直接
/// 驱动进监看,相机侧由此进及时取景)。**应用侧不因连接切 tab**
/// (2026-10-07 用户明示:连接后停在原页,跳拍摄 tab 是反需求)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/camera/camera_connection.dart';
import '../connection/connection_page.dart';
import '../library/local_library_page.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_page.dart';
import '../settings/settings_page.dart';

/// 四 tab 定义(NavigationBar / NavigationRail 共用)。
const _tabs = <({IconData icon, IconData selectedIcon, String label})>[
  (icon: Icons.photo_camera_outlined,
      selectedIcon: Icons.photo_camera, label: '相机'),
  (icon: Icons.camera_outlined, selectedIcon: Icons.camera, label: '拍摄'),
  (icon: Icons.photo_library_outlined,
      selectedIcon: Icons.photo_library, label: '图库'),
  (icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置'),
];

class HomeShell extends StatefulWidget {
  const HomeShell(
      {super.key, this.connectionController, this.remoteController});

  /// 注入覆盖(测试);缺省取 AppServices 单例。
  final ConnectionController? connectionController;
  final RemoteController? remoteController;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  ConnectionController? _conn;
  RemoteController? _remote;
  CameraLinkState _lastLinkState = CameraLinkState.disconnected;

  @override
  void initState() {
    super.initState();
    _conn =
        widget.connectionController ?? AppServices.instance.connectionController;
    _remote =
        widget.remoteController ?? AppServices.instance.remoteController;
    _lastLinkState = _conn!.state;
    _conn!.addListener(_onConnChanged);
  }

  @override
  void dispose() {
    _conn?.removeListener(_onConnChanged);
    super.dispose();
  }

  void _onConnChanged() {
    final s = _conn!.state;
    final becameConnected = s == CameraLinkState.connected &&
        _lastLinkState != CameraLinkState.connected;
    _lastLinkState = s;
    // 连接即取景,不切 tab:相机侧进及时取景(用户在哪页就停在哪页,
    // 拍摄页可见性自行管理帧轮询挂起/恢复)。
    if (becameConnected) {
      unawaited(_remote!.autoLiveViewOnConnect());
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      // 内容槽挂 key:横竖切换时 Row 头部增删 rail,无 key 会按
      // 位置+类型失配从断点起整树重建 —— IndexedStack 里的页面 State
      // (拍摄页网格开关/面板状态等)全丢;挂 key 走 key 配对保状态。
      body: Row(
        children: [
          if (wide)
            SafeArea(
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final t in _tabs)
                    NavigationRailDestination(
                      icon: Icon(t.icon),
                      selectedIcon: Icon(t.selectedIcon),
                      label: Text(t.label),
                    ),
                ],
              ),
            ),
          Expanded(
            key: const ValueKey('shell-content'),
            child: IndexedStack(
              index: _index,
              // 拍摄 tab 非前台即挂起帧轮询(相机侧取景保持,不发 0x9202)。
              children: [
                const ConnectionPage(),
                RemotePage(
                  controller: widget.remoteController,
                  active: _index == 1,
                ),
                const LocalLibraryPage(),
                const SettingsPage(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(
                    icon: Icon(t.icon),
                    selectedIcon: Icon(t.selectedIcon),
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}

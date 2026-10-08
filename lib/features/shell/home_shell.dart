/// 应用主框架:三 tab 导航(相机 / 图库 / 设置)—— 竖屏底部
/// NavigationBar,横屏换左侧 NavigationRail(80px 底栏会吃掉监看画面
/// 高度)。
///
/// 相机 = 连接 + 相机信息总览(相册入口);图库 = 「下载到应用」的
/// 文件(传输徽标入口);设置 = 全局配置。拍摄页不再是 tab(2026-10-08
/// 用户明示):由相机页已连接视图「进入拍摄」全屏 push,返回即回相机
/// 页 —— 底栏/侧栏全程不占监看画面。IndexedStack 常驻保三 tab 状态。
///
/// 连接转正沿(有线/无线同一状态机)只做一件事:调 RemoteController
/// .autoLiveViewOnConnect 连接即取景(OpenZCine 口径:连接成功直接
/// 驱动进监看,相机侧由此进及时取景)。**应用侧不因连接切 tab**
/// (2026-10-07 用户明示:连接后停在原页,进拍摄页由用户点击)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/camera/camera_connection.dart';
import '../connection/connection_page.dart';
import '../library/local_library_page.dart';
import '../remote/remote_controller.dart';
import '../settings/settings_page.dart';

/// 三 tab 定义(NavigationBar / NavigationRail 共用;拍摄页不在列 ——
/// 由相机页已连接视图「进入拍摄」push 进入)。
const _tabs = <({IconData icon, IconData selectedIcon, String label})>[
  (icon: Icons.photo_camera_outlined,
      selectedIcon: Icons.photo_camera, label: '相机'),
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
    // 拍摄页不再常驻 tab:未 push 挂载即不可见(原 tab 模式由
    // RemotePage(active:false) initState 汇报)。push 进页/返回由页面
    // 自身翻转;本句管住「停在相机页期间不流 USB 帧」(相机侧取景照
    // 开,只挂轮询)。
    _remote!.setViewerVisible(false);
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
              children: [
                // 注入转发:测试经 HomeShell 注入的控制器要一路传到
                // 相机页(「进入拍摄」push 的拍摄页用它),生产为 null
                // 走 AppServices 单例。
                ConnectionPage(
                  controller: widget.connectionController,
                  remoteController: widget.remoteController,
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

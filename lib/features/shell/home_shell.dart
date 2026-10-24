/// 应用主框架:三 tab 导航(相机 / 图库 / 设置)—— 竖屏底部
/// NavigationBar(高度钉 56,见 app_theme navigationBarTheme),横屏
/// 换左侧 NavigationRail(底栏再矮也会吃掉监看画面高度)。
///
/// 相机 = 连接 + 相机信息总览(相册入口);图库 = 「下载到应用」的
/// 文件(传输徽标入口);设置 = 全局配置。拍摄页不再是 tab(2026-10-08
/// 用户明示):由相机页已连接视图「进入拍摄」全屏 push,返回即回相机
/// 页 —— 底栏/侧栏全程不占监看画面。
///
/// 内容槽 PageView(2026-10-20 用户明示):跟手横滑切台,相机→图库→
/// 设置线性往复、尽头不回绕;底栏/侧栏点选仍即时 jump(保留即切手感,
/// 不播跨页滑行动画)。每页包 [_KeepAlivePage] 常驻 —— 滑出 cacheExtent
/// 外 State 也不丢,等价旧 IndexedStack 常驻语义。三页主体均为竖向
/// ListView,横向 PageView 都在全屏 push 的查看器路由里,不与滑台
/// 抢手势;滑台只挂起帧轮询,取景生命周期跟连接走(见下)。
///
/// 连接转正沿(有线/无线同一状态机)的「连接即取景」由 RemoteController
/// 在自己的 states 订阅串链驱动([RemoteController._onConnectedChain],
/// 2026-10-11 移入:原先在本地听 ConnectionController 通知沿调用,装配
/// 序使通知先于控制器置位 _linkUp,重连沿取景无人重启)。
/// **应用侧不因连接切 tab**(2026-10-07 用户明示:连接后停在原页,
/// 进拍摄页由用户点击)。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_page.dart';
import '../library/local_library_page.dart';
import '../remote/remote_controller.dart';
import '../settings/settings_page.dart';

/// 三 tab 定义(NavigationBar / NavigationRail 共用;拍摄页不在列 ——
/// 由相机页已连接视图「进入拍摄」push 进入)。
const _tabs = <({IconData icon, IconData selectedIcon, String label})>[
  (icon: Icons.photo_camera_outlined,
      selectedIcon: Icons.photo_camera, label: 'shell.camera'),
  (icon: Icons.photo_library_outlined,
      selectedIcon: Icons.photo_library, label: 'shell.gallery'),
  (icon: Icons.settings_outlined,
      selectedIcon: Icons.settings, label: 'common.settings'),
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

  final PageController _pages = PageController();

  RemoteController? _remote;

  @override
  void initState() {
    super.initState();
    _remote =
        widget.remoteController ?? AppServices.instance.remoteController;
    // 拍摄页不再常驻 tab:未 push 挂载即不可见(原 tab 模式由
    // RemotePage(active:false) initState 汇报)。push 进页/返回由页面
    // 自身翻转;本句管住「停在相机页期间不流 USB 帧」(相机侧取景照
    // 开,只挂轮询)。连接即取景由 RemoteController 的 connected 沿
    // 串链自驱(见类注),本组件不再监听连接状态。
    _remote!.setViewerVisible(false);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// 底栏/侧栏点选:高亮即时,内容 jump 即切(IndexedStack 时代手感;
  /// 跟手滑行动画只属于真横滑)。jump 触发的 onPageChanged 再 setState
  /// 同值,幂等。
  void _select(int i) {
    setState(() => _index = i);
    _pages.jumpToPage(i);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      // 内容槽挂 key:横竖切换时 Row 头部增删 rail,无 key 会按
      // 位置+类型失配从断点起整树重建 —— PageView 里的页面 State
      // (拍摄页网格开关/面板状态等)全丢;挂 key 走 key 配对保状态。
      body: Row(
        children: [
          if (wide)
            SafeArea(
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final t in _tabs)
                    NavigationRailDestination(
                      icon: Icon(t.icon),
                      selectedIcon: Icon(t.selectedIcon),
                      label: Text(context.t(t.label)),
                    ),
                ],
              ),
            ),
          Expanded(
            key: const ValueKey('shell-content'),
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _index = i),
              // 相邻页预建(图库随相机页常建,等价旧 IndexedStack 全常
              // 驻的起步状态);设置页首访惰性建,建成后 keepalive 钉住。
              allowImplicitScrolling: true,
              children: [
                // 注入转发:测试经 HomeShell 注入的控制器要一路传到
                // 相机页(「进入拍摄」push 的拍摄页用它),生产为 null
                // 走 AppServices 单例。
                _KeepAlivePage(
                  child: ConnectionPage(
                    controller: widget.connectionController,
                    remoteController: widget.remoteController,
                  ),
                ),
                const _KeepAlivePage(child: LocalLibraryPage()),
                const _KeepAlivePage(child: SettingsPage()),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          // 图标下沉(2026-10-24 用户反馈两轮定标:栏不动,图标再下
          // 8):栏带 = 顶垫 6 + 栏 56,网格视口下缘与栏带高度都不动;
          // Transform.translate 把内容(胶囊/图标/文字,含点按与语义
          // 盒)整体画低 8,布局盒不变 —— 胶囊/图标/文字相对几何不走
          // 样。多出的 8 落在安全区上沿(文字底距屏底 28,与 iOS 原生
          // 相仿);垫条/安全区/栏三者同为 surface 色(M3 脚手架背景
          // 即 colorScheme.surface),越界绘制无缝,明暗主题皆然。
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Transform.translate(
                offset: const Offset(0, 8),
                child: NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  destinations: [
                    for (final t in _tabs)
                      NavigationDestination(
                        icon: Icon(t.icon),
                        selectedIcon: Icon(t.selectedIcon),
                        label: context.t(t.label),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// tab 页常驻包装:keepalive 把页钉住,滑出 PageView cacheExtent(相邻
/// 一页)外也不卸载 —— 页面 State(设置开关滚动位、相机页连接向导状态
/// 等)跨横滑往返保留,等价旧 IndexedStack 常驻。旧外壳横竖切换的整树
/// 重建防护仍在内容槽 key(shell-content)上,与本包装各管一头。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // keepalive 声明沿(AutomaticKeepAlive 必经)
    return widget.child;
  }
}

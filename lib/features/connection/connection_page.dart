/// 相机页(底部导航首 tab):连接入口 + 已连接相机信息总览。
///
/// 未连接(2026-10-19 连接页改版定稿):AppBar 三分(六轮)——「相机」
/// 挪左,当前方式(弹窗同款图标+标题+ⓘ 说明入口)居中接管原标题位,
/// 右上角统一连接图标(Icons.link)开方式弹层;body = 状态行(圆点+状态词:
/// 灰未连/黄在途/红失败/绿就绪)+ 固定错误位(空置也占位,错误出现不
/// 推挤布局)+ 各方式自己的连接图标 hero(四方式统一大小同坐标,连接
/// 在途沿涟漪外扩,八轮用户图示;九轮调小调慢,蓝牙的涟漪跟面板重连
/// 循环走;蓝牙就绪 hero 实底统一黄,十一轮)。**进入任何方式都不主动连接**
/// (用户裁定 2026-10-19):hero 点按即连接(五轮:中央「连接相机」钮
/// 退役;八轮扩到四方式 —— USB/AP 直连,STA/蓝牙连最近),在途再点
/// 即取消(九轮补齐蓝牙;STA 底部「取消连接」钮随之退役);说明弹窗入口在方式位 ⓘ(hero 角标迁此);STA/蓝牙为
///「已配对 / 其它设备」两段列表(首条带绿底「最近」徽,八轮),进页
/// 自动扫描(静默,无扫描钮)、离页停、全手动点行连接。方式弹层(有线 USB /
/// AP 热点 / 同一 Wi-Fi / 蓝牙)选中仅切换视图。蓝牙是**工具通道**(不建立相机 PTP 连接,不传图不遥控),
/// 只承载 GPS 注入与唤醒相机 WiFi(2026-10-14);iOS 首配经典配对与
/// 唤起 Wi-Fi 手动入网均以页内红色引导卡承接(App 不主动跳系统设置,
/// 手动按钮不点不跳 —— 2026-10-19 裁定;能程序化直连的平台直达:
/// ohos 绑定、Android 入热)。已连接(2026-10-17 bento 卡片风 v24
/// 交付稿定样):状态行(绿点 + 电池 + 链路纯图标 pill)+ 机身整行
/// 卡(竖线居中:型号 pill | 固件/序列号裸值)+ 镜头信息|存储双列
/// 卡 + 底部双钮(左相册灰右进入拍摄黄;「进入拍摄」全屏 push 遥控
/// 监看页 —— 2026-10-08 拍摄页从底栏 tab 改制)。详情与断开分家
/// (2026-10-23 定稿):状态行只有「已连接」状态词可点 = 弹确认框、
/// 确认才断开,行其余部分(电池壳/链路 pill)不吃点按;连接详情弹层
/// (设备名/型号/链路/快门数,纯信息无断开钮)由机身卡型号 pill 点
/// 按弹出。图标扛语义(固件/序列号/焦距/光圈沿用原 info 行图标)。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层。
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中自动配对(验证码不回传相机),相机侧弹「配对
/// 完成」等按 OK,应用保持重连等它(见 awaitingCameraConfirm);已
/// 配对直连。AP 模式相机 IP 候选序 = mDNS 发现 → join 网关(相机
/// 热点的 DHCP 网关,native 读)→ 默认 192.168.1.1(手填已砍,候选
/// 序自动兜底)。
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show pi;

import 'connection_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/ble/wifi_credentials.dart';
import '../../core/browser/album.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../core/log/app_log.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../design/app_haptics.dart';
import '../../l10n/l10n.dart';
import '../../l10n/message.dart';
import '../../platform/network_monitor.dart';
import '../../platform/nsd_scanner.dart';
import '../browser/photo_grid_page.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/kv_row.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_page.dart';
import 'ble_pair_panel.dart';
import 'sta_antenna_icon.dart';
import 'camera_overview_controller.dart';
import 'connected_overview.dart';
import 'connection_widgets.dart';


/// 蓝牙工具卡状态文案(未配对/已配对未连/握手中/已连接/重连中/等待
/// 系统配对)。返回 = t() 键,消费端统一包 t()。
String bleStateLabel(ConnectionController c) => switch (c.bleState) {
      BleSessionState.pairing => 'ble.handshaking',
      BleSessionState.ready => 'conn.connected',
      BleSessionState.reconnecting => 'ble.reconnecting',
      BleSessionState.idle when c.bleAwaitSystemBond => 'ble.awaitSystemBond',
      BleSessionState.idle =>
        c.bleIdentity == null ? 'ble.notPaired' : 'conn.pairedNotConnected',
    };

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    this.controller,
    this.overview,
    this.remoteController,
  });

  /// 测试注入;缺省取应用级单例(连接是全局单例状态)。
  final ConnectionController? controller;

  /// 测试注入;缺省取应用级单例。
  final CameraOverviewController? overview;

  /// 测试注入(「进入拍摄」push 的拍摄页控制器);缺省取应用级单例。
  /// 懒取 —— 只在点「进入拍摄」时解析,不点不实例化 AppServices。
  final RemoteController? remoteController;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage>
    with WidgetsBindingObserver {
  ConnectionController get _controller =>
      widget.controller ?? AppServices.instance.connectionController;

  CameraOverviewController get _overview =>
      widget.overview ?? AppServices.instance.cameraOverview;

  RemoteController get _remote =>
      widget.remoteController ?? AppServices.instance.remoteController;

  /// 无感配对哨兵:进 pairing 态自动确认一次(state 离开即复位,
  /// 防多次 notify 重复触发)。
  bool _pairingAutoConfirmed = false;

  /// 状态机上一拍(只在「连接 → 断开」沿上刷新档案列表,防通知循环)。
  CameraLinkState? _lastState;

  /// 拍摄模式事件订阅在挂(已连接期,[_syncModeFollow] 管理)。
  bool _remoteModeListened = false;

  /// 视频档代持取景可见性(2026-10-17):帧头 @816 只随取景帧来,
  /// 连接页视频档时恢复拉帧(setViewerVisible(true) —— 相机侧取景
  /// 连接沿已开,只是 app 侧挂起),可录时长与拍摄页同源。拍摄页
  /// 打开期间可见性主权归它,代持即让;切回照片档代持即撤。
  bool _viewerByConnPage = false;

  /// 拍摄页在前台(路由在册):此时 setViewerVisible 主权归拍摄页。
  bool _shootingOpen = false;

  /// 蓝牙配对面板句柄(八轮):蓝牙 hero 点按 = 连最近,经面板
  /// 「连接」同一条手动重连路(显式意图/绕深睡闸门/在途循环不重入,
  /// 守卫都在面板态里)。
  final GlobalKey<BlePairPanelState> _blePanelKey =
      GlobalKey<BlePairPanelState>();

  /// 蓝牙面板重连循环在途(九轮):蓝牙 hero 涟漪的数据源 —— 无命中
  /// 轮会话态停在 idle(会话态跟不出「正在连」),面板循环起停经
  /// onRetryingChanged 上抛到此,hero busy = 会话态 ∪ 面板循环。
  final ValueNotifier<bool> _bleRetrying = ValueNotifier<bool>(false);

  /// 拍摄模式跟随(0xD1A6 镜像)走事件通道,页内不再自设轮询
  /// (2026-10-22 撤 2s 单读):AppServices 级事件轮询器(GetEventEx
  /// 0x941C,2s 节拍,连接沿启动)把 0x4006(0xD1A6)并入
  /// session.events,RemoteController 消费后重读镜像并 notifyListeners
  /// (连接沿初读也在其 _onConnectedChain 打头)—— 存储卡脚注(消费
  /// 在 _connectedView 的 merge 监听)与视频档取景代持由通知沿驱动,
  /// 页内轮询是与事件通道重复的 2s 事务。(旧注释「事件沿只在拍摄页
  /// 事件轮询内达」与装配不符:轮询器 2026-10-07 起即挂在 AppServices
  /// 连接沿,与页面无关;连接页的镜头卡实时追平同走此通道。)
  /// 已连接期挂 [_remote] 通知监听、断开即摘;懒解析 _remote ——
  /// 未连接态不触碰 AppServices(与已连接视图消费 _remote 同一时刻
  /// 才解析)。
  void _syncModeFollow() {
    final connected = _controller.state == CameraLinkState.connected;
    if (connected && !_remoteModeListened) {
      _remote.addListener(_onRemoteChanged);
      _remoteModeListened = true;
      // 连接沿即重判代持:重连同档时 RemoteController 不发通知
      // (cameraMode 跨断连保值),本沿是重新代持的锚点。
      _syncViewerForMode();
    } else if (!connected && _remoteModeListened) {
      _remote.removeListener(_onRemoteChanged);
      _remoteModeListened = false;
      // 断开沿撤代持:视频态不再成立。
      _syncViewerForMode();
    }
  }

  /// RemoteController 通知沿(模式翻转 = 0x4006 事件重读 / 切换链定态
  /// / 连接沿初读):重判视频档取景代持。
  void _onRemoteChanged() {
    _syncViewerForMode();
  }

  /// 按当前档位代持/撤回取景可见性。只在「视频档 + 自己前台」时顶
  /// 真;照片档或断开只撤自己顶的(拍摄页顶的不动 —— 它在照片档
  /// 取景合法)。
  void _syncViewerForMode() {
    if (_shootingOpen) return;
    final video = _controller.state == CameraLinkState.connected &&
        _remote.cameraMode == CaptureMode.video;
    if (video && !_viewerByConnPage) {
      _remote.setViewerVisible(true);
      _viewerByConnPage = true;
    } else if (!video && _viewerByConnPage) {
      _remote.setViewerVisible(false);
      _viewerByConnPage = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _controller.loadSaved();
    _syncModeFollow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    if (_remoteModeListened) {
      _remote.removeListener(_onRemoteChanged);
      _remoteModeListened = false;
    }
    if (_viewerByConnPage) {
      _remote.setViewerVisible(false);
      _viewerByConnPage = false;
    }
    // 面板(子)先拆:在途循环收尾回调落值在先,此处只收通知器。
    _bleRetrying.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    // 后台恢复重启扫描:挂起期间系统可能停掉 mDNS 查询,浏览器名义
    // 在跑但收不到新服务(「有时候扫不出来」的一种来源)。
    if (lifecycleState == AppLifecycleState.resumed) {
      _controller.rescanIfScanning();
    }
  }

  void _onControllerChanged() {
    // 连接沿起停模式事件订阅(已连接才挂)。
    _syncModeFollow();
    final controller = _controller;
    // 无感配对:验证码仅展示用(不回传相机,0x935A 参数与码无关),
    // 进 pairing 态即自动确认 —— 用户全程不感知,状态卡橙灯一闪而过。
    if (controller.state == CameraLinkState.pairing) {
      if (!_pairingAutoConfirmed) {
        _pairingAutoConfirmed = true;
        controller.confirmPairing();
      }
    } else {
      _pairingAutoConfirmed = false;
    }
    // 回到连接卡时刷新快速重连列表(本次连接可能刚落账;只在
    // connected → disconnected/failed 的沿上刷,loadSaved 的
    // notifyListeners 会再进本监听,靠沿判定终止级联)。
    final prev = _lastState;
    _lastState = controller.state;
    if (prev == CameraLinkState.connected &&
        (controller.state == CameraLinkState.disconnected ||
            controller.state == CameraLinkState.failed)) {
      _controller.loadSaved();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      // AppBar 三分(六~七轮):「相机」挪左;当前方式(图标+标题+ⓘ)
      // 居中接管原标题位;右上角统一连接图标(Icons.link,七轮自「连接」
      // 文字改,方法无关)仍开方式弹层。已连接后方式位与钮都退场。
      appBar: AppBar(
        // 二十一轮:72 → 104 —— leading 槽要装下 EN「Camera」(titleLarge
        // 22px 约 77px + 左缘 16 padding;56px 槽 EN 必换行,真机截图实证)。
        // Align centerLeft 左缘 16 不动,与图库同槽;居中方式 chip
        // 在常见屏宽不受推挤(NavigationToolbar 仅重叠时才让位)。
        leadingWidth: 104,
        leading: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.lg),
          // 二十轮:Align centerLeft(勿用 Center)—— AppBar 把 leading
          // 钉成 leadingWidth 宽,Center 会把文字在余宽里水平也
          // 居中(左缘 ~22px),与图库标题(左 16px)错位。
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(context.t('shell.camera'),
                style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        centerTitle: true,
        title: ListenableBuilder(
          listenable: controller,
          builder: (context, _) =>
              controller.state == CameraLinkState.connected
                  ? const SizedBox.shrink()
                  : _modeChip(context, controller.method),
        ),
        actions: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.state == CameraLinkState.connected) {
                return const SizedBox.shrink();
              }
              final busy = _busyState(controller);
              return IconButton(
                key: const ValueKey('conn_mode_picker'),
                tooltip: context.t('conn.chooseMethod'),
                // 十八轮:链环斜扣(用户从设计稿选 J)——「正在接上」的
                // 动作方向;十九轮:再转 90°,共 135° 换另一条对角线。
                // 命中区仍是按钮 48dp,旋转只动绘制。
                icon: Transform.rotate(
                  angle: 3 * pi / 4,
                  child: const Icon(Icons.link),
                ),
                onPressed: busy
                    ? null
                    : () => _showModePickerSheet(context, controller),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.state == CameraLinkState.connected) {
            return _connectedView(context, controller);
          }
          return _methodsView(context, controller);
        },
      ),
    );
  }

  // ── 未连接:改版主视图(2026-10-19 定稿) ────────────────────────
  // 状态行(圆点+状态词)+ 固定错误位;方式图标即页面主视觉(USB/AP
  // 点按即连接,在途再点取消);进入任何方式都不发起连接;当前方式与
  // ⓘ 说明入口在 AppBar 方式位(六轮);STA/蓝牙为「已配对 / 其它设备」
  // 两段列表(自动扫描,静默)。

  /// 连接中/配对/重连 = busy(方式切换与发起新连接被锁)。
  static bool _busyState(ConnectionController controller) =>
      switch (controller.state) {
        CameraLinkState.connecting ||
        CameraLinkState.pairing ||
        CameraLinkState.reconnecting =>
          true,
        _ => false,
      };

  static IconData _methodIcon(ConnectionMethod m) => switch (m) {
        ConnectionMethod.usb => Icons.usb,
        ConnectionMethod.ap => Icons.wifi_tethering,
        // STA 不走这里(见 [_methodIconWidget]),留 wifi 仅作穷尽占位。
        ConnectionMethod.sta => Icons.wifi,
        ConnectionMethod.ble => Icons.bluetooth,
      };

  /// 方式图标(组件形态):STA 用自绘天线 [StaAntennaIcon] 复刻相机
  /// Wi-Fi 菜单原图(2026-10-20 用户定稿「和相机一样」,Material 内置
  /// 无一同型),其余走 Material 字形;size/color 语义同 [Icon]。
  static Widget _methodIconWidget(ConnectionMethod m,
          {double? size, Color? color}) =>
      m == ConnectionMethod.sta
          ? StaAntennaIcon(size: size, color: color)
          : Icon(_methodIcon(m), size: size, color: color);

  /// 方式短名(弹层条目用;键即中文原文)。
  static String _methodLabel(ConnectionMethod m) => switch (m) {
        ConnectionMethod.usb => 'conn.wired',
        ConnectionMethod.ap => 'conn.apHotspot',
        ConnectionMethod.sta => 'conn.sameWifi',
        ConnectionMethod.ble => 'conn.bluetooth',
      };

  /// 方式一句说明(弹层条目副文)。
  static String _methodDesc(ConnectionMethod m) => switch (m) {
        ConnectionMethod.usb => 'conn.descUsb',
        ConnectionMethod.ap => 'conn.descAp',
        ConnectionMethod.sta => 'conn.descSta',
        ConnectionMethod.ble => 'conn.descBle',
      };

  /// PTP 链路状态行表现(状态词 t() 键,点色,busy)。黄 = 统一黄
  /// [AppColors.accentYellow](在途),灰 = outline(未连接),红 =
  /// error(失败),绿 = success(已连接;本视图不出现,已连接走
  /// 信息总览)。
  static (String, Color, bool) _ptpStatusPresentation(
      ConnectionController c, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (c.state) {
      CameraLinkState.disconnected => ('conn.notConnected', scheme.outline, false),
      CameraLinkState.detecting =>
        ('conn.detectingWifi', AppColors.accentYellow, true),
      CameraLinkState.connecting when c.awaitingCameraConfirm => (
          'conn.waitingPairConfirm',
          AppColors.accentYellow,
          true
        ),
      CameraLinkState.connecting =>
        ('conn.connecting', AppColors.accentYellow, true),
      CameraLinkState.pairing =>
        ('conn.waitingPairing', AppColors.accentYellow, true),
      CameraLinkState.reconnecting =>
        ('conn.reconnecting', AppColors.accentYellow, true),
      CameraLinkState.failed => ('conn.failed', scheme.error, false),
      CameraLinkState.connected =>
        ('conn.connected', AppColors.success(context), false),
    };
  }

  /// 蓝牙通道状态行表现(独立于 PTP 链路:工具通道不建相机连接)。
  /// 绿点在此页面有真实常驻场景 —— 蓝牙就绪不跳页。
  static (String, Color, bool) _bleStatusPresentation(
      ConnectionController c, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (c.bleState) {
      BleSessionState.ready =>
        ('conn.connected', AppColors.success(context), false),
      BleSessionState.pairing =>
        ('ble.handshaking', AppColors.accentYellow, true),
      BleSessionState.reconnecting =>
        ('ble.reconnecting', AppColors.accentYellow, true),
      BleSessionState.idle => (
          bleStateLabel(c),
          c.bleAwaitSystemBond ? AppColors.accentYellow : scheme.outline,
          false
        ),
    };
  }

  /// 各方式提示行(t() 键):全部收进 AppBar 方式位 ⓘ 点开的说明弹窗,
  /// 正文不再常驻(2026-10-19 用户定稿;二轮:展开框改弹窗;五轮:入口
  /// 自 hero 迁方式行;六轮:随方式位挪 AppBar)。
  static List<String> _hintLines(ConnectionMethod m) => switch (m) {
        ConnectionMethod.usb => const ['conn.descUsb', 'conn.errNoUsbCamera'],
        ConnectionMethod.ap => const ['conn.descAp', 'conn.apTakeoverNote'],
        ConnectionMethod.sta => const [
            'conn.descSta',
            'conn.staHint',
            'conn.wirelessNotes',
          ],
        ConnectionMethod.ble => [
            'conn.descBle',
            'conn.btToolsHint',
            'ble.scanHint',
            if (Platform.operatingSystem == 'ios') 'ble.iosPairHint',
          ],
      };

  /// 方式说明弹窗(点 AppBar 方式位 ⓘ 弹出;二轮:说明不再页面内下方
  /// 展开;五轮:入口自 hero 角标迁方式行;六轮:随方式位挪 AppBar,
  /// hero 点按已让位给连接/取消)。首行方式说明加粗,其余次级色逐行排。
  void _showHintSheet(BuildContext context, ConnectionMethod m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        final lines = _hintLines(m);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    _methodIconWidget(m, size: 20, color: scheme.primary),
                    const SizedBox(width: AppSpacing.sm),
                    Text(context.t(_methodLabel(m)),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                for (var i = 0; i < lines.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.xs),
                    child: Text(
                      context.t(lines[i]),
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.5,
                        color: i == 0
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: i == 0 ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// AppBar 方式位(五轮方式行,六轮挪 AppBar 正中接管「相机」原标题
  /// 位):弹窗同款图标+标题;ⓘ 说明入口随后(六轮:去外圈裸图标,
  /// InkWell padding 撑命中区)。ⓘ 点按弹说明弹窗 —— hero 点按已让位
  /// 给连接/取消(见 [_heroPressed])。首侧补一格空(八轮「左右两侧
  /// 居中」):ⓘ 尾垫只出不进,行内可视内容整体右偏 —— 首侧对称补空
  /// 后可视重心落回屏幕正中(centerTitle 是整条工具栏宽居中)。
  Widget _modeChip(BuildContext context, ConnectionMethod m) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: AppSpacing.sm),
        _methodIconWidget(m, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Text(
          context.t(_methodLabel(m)),
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        InkWell(
          key: const ValueKey('conn_method_info'),
          onTap: () => _showHintSheet(context, m),
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Icon(Icons.info_outline,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// hero 点按(五轮:中央「连接相机」钮退役,图标即连接钮;八轮:四
  /// 方式全可点):USB/AP 直连,STA 连最近(已配对档案首条,行点按仍
  /// 全保留),蓝牙连最近(配对面板「连接」同一条手动重连路)。
  /// PTP 三方式在途(connecting/reconnecting)沿取消;busy 中间态
  /// (pairing/detecting)不动作(同旧按钮禁用语义)。
  void _heroPressed(ConnectionController controller) {
    switch (controller.method) {
      case ConnectionMethod.usb ||
            ConnectionMethod.ap ||
            ConnectionMethod.sta:
        _ptpHeroPressed(controller);
      case ConnectionMethod.ble:
        _bleHeroPressed(controller);
    }
  }

  /// AP hero 点按(2026-10-22 用户定稿「一键直达已连接」):ohos 且
  /// BLE 在链 → 走 BLE→WiFi 交接全链([_wakeWifiWithCredentials]:
  /// 0x2004 凭据 → 0x2005 唤醒断链 → 程序化加入相机热点 → 自动发射
  /// AP 连接,connected 沿连接卡自动翻已连接总览,不再手点 AP 方式);
  /// 其余(非 ohos / BLE 不在链 / 手机已在相机网)照旧直发
  /// connectWireless(既有语义)。
  static Future<void> _apHeroConnect(
      BuildContext context, ConnectionController controller) async {
    if (Platform.operatingSystem == 'ohos' && controller.bleReady) {
      await _wakeWifiWithCredentials(context, controller);
      return;
    }
    unawaited(controller.connectWireless());
  }

  void _ptpHeroPressed(ConnectionController controller) {
    final inFlight = controller.state == CameraLinkState.connecting ||
        controller.state == CameraLinkState.reconnecting;
    if (inFlight) {
      unawaited(controller.disconnect());
      return;
    }
    if (_busyState(controller)) {
      return;
    }
    switch (controller.method) {
      case ConnectionMethod.usb:
        unawaited(controller.connect());
      case ConnectionMethod.ap:
        unawaited(_apHeroConnect(context, controller));
      case ConnectionMethod.sta:
        // 八轮:连最近 —— 档案最近优先,首条即最近(与列表行同路
        // connectSaved;无档案不动作,列表行点按仍是主入口)。
        if (controller.savedCameras.isEmpty) {
          return;
        }
        unawaited(controller.connectSaved(controller.savedCameras.first));
      case ConnectionMethod.ble:
        break; // unreachable:ble 走 _bleHeroPressed
    }
  }

  /// 蓝牙 hero 点按(八轮连最近 + 九轮在途取消 + 十一轮就绪断开 +
  /// 十三轮重连态停止):**除闲态外的每一态,点按都是「了结」** ——
  /// 就绪 = 断开、握手/重连循环/重连态 = 停止,均与面板「断开」钮同
  /// 语义(manualOff 压离页后驱动自动回链 + 废循环 + 断链),经
  /// [BlePairPanelState.cancelResume]。重连态并进取消(十三轮):断链
  /// 后驱动自动重连期间会话停在 reconnecting(busy 涟漪在跑),此时
  /// 点按若走「连接」路 = 又起一条重连循环,用户看到的是「取消不了,
  /// 反而继续重连」—— 修正为与 USB/AP/STA 同款在途取消语义。闲态 +
  /// 已配对 = 连最近 —— 复用配对面板「连接」按钮同一条手动重连路
  /// ([BlePairPanelState.manualResume]:显式意图解除 manualOff、绕深睡
  /// 闸门、面板在途循环不重入)。未配对不动作(配对走列表行)。
  void _bleHeroPressed(ConnectionController controller) {
    final panel = _blePanelKey.currentState;
    final s = controller.bleState;
    // 就绪 = 断开(十一轮);在途 = 取消(九轮,与 USB/AP/STA hero 同
    // 语义;首配握手也在取消 —— pairing 期列表行全禁用,hero 是唯一
    // 逃生口);重连态 = 停止重连(十三轮)。
    if (panel != null &&
        (s == BleSessionState.ready ||
            s == BleSessionState.reconnecting ||
            panel.retrying ||
            s == BleSessionState.pairing)) {
      unawaited(panel.cancelResume());
      return;
    }
    if (s != BleSessionState.idle) {
      return; // 面板缺席的边角(未装配回落视图):不动作
    }
    if (controller.bleIdentity == null) {
      return; // 未配对:无可连的最近设备
    }
    if (panel == null) {
      return;
    }
    unawaited(panel.manualResume());
  }

  /// 未连接/连接中视图(2026-10-19 改版):按方式分派 —— USB/AP 走
  /// hero 视图,STA/蓝牙走两段列表视图(原地替换,无路由无弹窗)。
  /// 右上角统一连接图标(七轮)随时切回。
  Widget _methodsView(BuildContext context, ConnectionController controller) {
    return switch (controller.method) {
      // BLE 未装配(bleSession 缺席的边角:仅持久化名残留可直达)回落
      // hero 视图,防 _bleView 的会话空断言。
      ConnectionMethod.ble when controller.bleSession != null =>
        _bleView(context, controller),
      ConnectionMethod.sta => _StaScanBody(controller: controller, page: this),
      _ => _heroView(context, controller),
    };
  }

  /// hero 顶距(2026-10-19 三轮同位 + 四轮上移 + 六轮方式位挪 AppBar +
  /// 七轮下移):状态行+错误位之下到图标顶的固定空隙 —— 图标坐标四方
  /// 式恒定(底部凭据卡/列表的高度都不再影响它)。六轮两笔对冲(方式
  /// 行挪 AppBar -36、缩径 116→96 中心不漂 +10)得 130;七轮裁定
  /// 「图标往下移」+40 → 170(hero 中心落屏体视觉中心)。四轮裁定
  /// 「配对信息往上移」仍有效:列表紧随图标之下,剩余空间全在底部
  /// (内容短则留白,长则区内滚动)。2026-10-21:状态行与已连接侧
  /// ConnectedHeader 同几何(行高 21→30:竖 pad 4 + 钉
  /// kConnStatusRowHeight 26,+9),170-9=161 回收,图标坐标不动。
  static const double _heroTopGap = 161;

  /// USB/AP 主视图:状态行 + 固定错误位 + 方式 hero(**点按即连接、
  /// 在途点按取消**,五轮中央连接钮退役)+ AP 凭据卡(沉底)。失败态
  /// 错误行落在固定错误位,重试 = 再点图标;当前方式在 AppBar 方式位
  /// (六轮,[_modeChip])。
  Widget _heroView(BuildContext context, ConnectionController controller) {
    final busy = _busyState(controller);
    final (label, dot, busySpin) = _ptpStatusPresentation(controller, context);
    final isAp = controller.method == ConnectionMethod.ap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppSpacing.screenPadding,
          child: ConnStatusHeader(
              dotColor: dot, label: context.t(label), busy: busySpin),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: ConnErrorSlot(
            hint: controller.hint?.key,
            args: controller.hint?.args,
            error: controller.state == CameraLinkState.failed,
          ),
        ),
        // 图标坐标恒定(见 _heroTopGap):凭据卡出现/消失、busy 与否
        // 都不影响图标位置。
        const SizedBox(height: _heroTopGap),
        Center(
          child: _MethodHero(
            method: controller.method,
            busy: busy,
            // 五轮:图标即连接钮 —— 闲/败发起,在途取消(见 _heroPressed)。
            onTap: () => _heroPressed(controller),
          ),
        ),
        // 弹性空档:凭据卡沉底。
        const Expanded(child: SizedBox.shrink()),
        // AP 方式的热点凭据卡(蓝牙通道解出才显示):SSID/密码/安全 +
        // 复制 —— 系统设置加入热点用。
        if (isAp && controller.cameraApCredentials != null)
          Padding(
            padding: AppSpacing.screenPadding.copyWith(top: 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _apCredentialBlock(context, controller),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 蓝牙工具视图(2026-10-19 改版):状态行(通道态;绿=已连接,本页
  /// 唯一绿点常驻场景)+ 固定错误位(会话 lastError)+ 蓝牙 hero(**八轮
  /// 可点 = 连最近,九轮在途再点 = 取消,十一轮就绪点按 = 断开,十三轮
  /// 重连态点按 = 停止重连**;连接中涟漪 = 会话态 ∪ 面板重连循环,九轮;
  /// **就绪实底统一黄**,十一轮)+ 红卡(等待系统配对 /
  /// Wi-Fi 手动入网,按态出)+ 就绪态「远程连接相机」+ 配对面板两段列
  /// 表;当前方式在 AppBar 方式位(六轮)。进入页面不回链不连接(驱动
  /// 已挂起)全手动;扫描打开沿自动起、静默。
  Widget _bleView(BuildContext context, ConnectionController controller) {
    final session = controller.bleSession!;
    final ready = controller.bleReady;
    final creds = controller.cameraApCredentials;
    final (label, dot, busy) = _bleStatusPresentation(controller, context);
    // 错误位消息(键+参记录):唤醒未直连 → 固定红字提醒压过会话杂错
    //(解密未中已改写 AppLog 不上屏);否则沿会话 lastError 如实。
    final L10nMessage? hintMsg = !ready
        ? (controller.wifiAwakePending
            ? const (key: 'conn.wifiManualConnectHint', args: null)
            : session.lastError)
        : null;
    // 图标坐标恒定(见 _heroTopGap,四方式同位);四轮裁定「配对信息
    // 往上移」:红卡/按钮/配对面板紧随图标之下,剩余空间全在底部
    //(内容短则留白,长则区内滚动)。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppSpacing.screenPadding,
          child: ConnStatusHeader(
              dotColor: dot, label: context.t(label), busy: busy),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: ConnErrorSlot(
            // 错误位数据源见上方 hintMsg(键+参记录,ConnHintText 统一落地)。
            hint: !ready ? hintMsg?.key : null,
            args: hintMsg?.args,
            error: true,
          ),
        ),
        const SizedBox(height: _heroTopGap),
        // 九轮:涟漪数据源 = 会话态 ∪ 面板重连循环(无命中轮会话停在
        // idle,循环在途经 onRetryingChanged 上抛 —— 否则蓝牙连接全程
        // 不出圈)。
        ValueListenableBuilder<bool>(
          valueListenable: _bleRetrying,
          builder: (context, bleRetrying, _) => _MethodHero(
            method: ConnectionMethod.ble,
            busy: busy || bleRetrying,
            // 十一轮:蓝牙已连接(ready)hero 实底统一黄 —— 蓝牙页连接
            // 后不跳页,图标色承载「已连」(与 App 按钮实底同深;十轮
            // 淡绿被否)。
            ready: ready,
            // 八轮:图标即连接钮 —— 连最近;九轮:在途再点 = 取消;
            // 十一轮:就绪点按 = 断开(均与面板「连接/断开」同路,见
            // _bleHeroPressed)。
            onTap: () => _heroPressed(controller),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: AppSpacing.screenPadding.copyWith(top: AppSpacing.md),
            children: [
              // 唤起 Wi-Fi 手动入网红卡(仅无程序化 joiner 平台,2026-10-19
              // 裁定③④;App 不主动跳 Wi-Fi 设置,手动按钮不点不跳)。
              if (controller.wifiAwakePending && creds != null) ...[
                const SizedBox(height: AppSpacing.lg),
                ConnGuideCard(
                  title: context.t('conn.wifiAwakeCardTitle'),
                  steps: [
                    context.t('conn.wifiAwakeStep1', {'ssid': creds.ssid}),
                    context.t('conn.wifiAwakeStep2'),
                    context.t('conn.wifiAwakeStep3'),
                  ],
                  children: [
                    if (creds.password.isNotEmpty)
                      _credentialRow(context, 'conn.password', creds.password),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton(
                  onPressed: controller.connectAfterWifiJoin,
                  child: Text(context.t('conn.wifiAwakeJoin')),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: () => unawaited(_openWifiSettings()),
                  child: Text(context.t('conn.openWifiSettings')),
                ),
              ],
              // iOS 系统蓝牙配对红卡(2026-10-19 裁定②③:自动跳转删除,
              // ohos 程序化绑定不出卡;手动按钮保留,点了才跳)。
              if (controller.bleAwaitSystemBond) ...[
                const SizedBox(height: AppSpacing.lg),
                ConnGuideCard(
                  title: context.t('ble.bondCardTitle'),
                  steps: [
                    context.t('ble.bondStep1'),
                    context.t('ble.bondStep2'),
                    context.t('ble.bondStep3'),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton(
                  onPressed: () => unawaited(_openSystemBluetooth(controller)),
                  child: Text(context.t('ble.openSystemBluetooth')),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              // 配对面板(原独立配对页整体迁入):「已配对 / 其它设备」两段
              // 列表;打开沿自动扫描(静默)。2026-10-21 用户定稿:面板在
              // 唤醒动作**之前** —— 已连接行与已配对行位置重叠,连接前后
              // 设备行不跳位(唤醒动作让位到面板之后);打开沿不再挂起驱
              // 动(ready 会话不挂起,见 AppServices.suspendBleDriver)。
              // key = hero 连最近/取消的句柄(八/九轮);重连循环起停上抛
              //(九轮,hero 涟漪跟面板循环,不只跟会话态);session =
              // 控制器会话(十二轮注入:生产与 AppServices 驱动同一只,
              // 显式传参免全局耦合)。
              BlePairPanel(
                key: _blePanelKey,
                session: session,
                savedIdentity: controller.bleIdentity,
                onIdentityChanged: () => unawaited(controller.loadBleIdentity()),
                onSystemBondNeeded: controller.markAwaitSystemBond,
                onRetryingChanged: (active) => _bleRetrying.value = active,
              ),
              // 相机 Wi-Fi 动作(就绪才挂):唤醒 = 读 0x2004 凭据(SnapBridge
              // 序)再写 0x2005,成功沿断 BLE —— 相机等链路释放才开热点。
              // 2026-10-21 移到面板之后(换位定稿,见上)。
              if (ready) ...[
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(context.t('conn.wakeCameraWifi')),
                  onPressed: () =>
                      unawaited(_wakeWifiWithCredentials(context, controller)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 系统设置深链通道(红卡手动按钮共用;蓝牙原有,Wi-Fi 为本次新增)。
  static const MethodChannel _settingsChannel = MethodChannel('nikonpill/ble');

  /// 打开系统 Wi-Fi 设置(红卡手动钮;不点不跳,深链失败静默 —— 用户
  /// 按引导手动进设置)。
  Future<void> _openWifiSettings() async {
    try {
      await _settingsChannel.invokeMethod<bool>('openWifiSettings');
    } on Exception {
      // 深链失败静默(回落方案由用户手动进系统设置)
    }
  }

  /// 蓝牙红卡手动钮:先断本机 BLE(相机释放链路后才暴露经典蓝牙)再
  /// 深链系统蓝牙页;用户点相机完成配对后回本页点「连接」。
  Future<void> _openSystemBluetooth(ConnectionController controller) async {
    await controller.bleSession?.disconnect();
    try {
      await _settingsChannel.invokeMethod<bool>('openBluetoothSettings');
    } on Exception {
      // 深链失败静默
    }
  }

  /// 方式弹层(入口 = 右上角统一连接图标,七轮):图标 + 短名 +
  /// 一句说明 + 当前项打勾。busy 时条目禁用(连接进行中不可换方式,原
  /// 分段语义)。蓝牙仅在 BLE 通道装配时出现(未装配平台不出)。**选中
  /// 仅切换视图**(2026-10-19 用户定稿:进入任何方式页面都不主动连接)
  /// —— USB/AP 也不再当场发起,连接由各方式页内的图标/行点按触发
  /// (USB/AP 图标即连接钮)。
  Future<void> _showModePickerSheet(
    BuildContext context,
    ConnectionController controller,
  ) {
    final busy = _busyState(controller);
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
              child: Text(context.t('conn.chooseMethod'),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final m in ConnectionMethod.values)
              if (m != ConnectionMethod.ble || controller.bleEnabled)
                ListTile(
                  leading: _methodIconWidget(m),
                  title: Text(context.t(_methodLabel(m))),
                  subtitle: Text(context.t(_methodDesc(m))),
                  trailing:
                      controller.method == m ? const Icon(Icons.check) : null,
                  onTap: busy
                      ? null
                      : () {
                          controller.selectMethod(m);
                          Navigator.pop(sheetContext);
                        },
                ),
          ],
        ),
      ),
    );
  }

  /// 唤醒相机 WiFi(BLE→WiFi 交接):[ConnectionController.wakeCameraWifi]
  /// 全程 = 读 0x2004(SnapBridge 序)→ 写 0x2005=0x01 → 成功沿断 BLE
  /// (相机等链路释放才开热点)。后续按平台能力分流(2026-10-19 裁定
  /// ③④:红卡只限无法直连的情形):joiner 装配(Android)→ 程序化加
  /// 入热点并自动发射 AP 连接([ConnectionController.joinCameraAp],
  /// 成功直达连接页,现状直连路径保留);无 joiner(iOS/ohos)且凭据
  /// 解出 → 留蓝牙页弹红卡引导手动入网;凭据未解出 → 不弹提示条,置
  /// wifiAwakePending 让错误位出红字「去系统连 Wi-Fi」提醒(十七轮,
  /// 解密未中改写 AppLog)。GPS 注入随断链暂停。
  static Future<void> _wakeWifiWithCredentials(
      BuildContext context, ConnectionController controller) async {
    final ok = await controller.wakeCameraWifi();
    if (!context.mounted) return;
    if (!ok) {
      _showHintStatic(
          context,
          controller,
          context.tm((key: 'conn.wakeFailed', args: {
            'e': controller.bleLastError ??
                (key: 'common.unknown', args: null),
          })));
      return;
    }
    final creds = controller.cameraApCredentials;
    if (creds == null) {
      // 凭据未解出(读失败/空/解密未中 —— 0x2004 解密是挂账研究项,
      // 2026-10-22 离线穷举固定键+会话派生键 12k 发全灭,真机 blob 还
      // 是 102B 非文档 97B)。ohos 走 B 路:扫描锁定相机热点 SSID +
      // 相机屏幕密码一次录入永久保存;其余平台维持红卡手动指引。
      if (Platform.operatingSystem == 'ohos') {
        await _joinOhosByScan(context, controller);
        return;
      }
      // 十七轮:下方 SnackBar 提醒撤(用户裁定),置 wifiAwakePending:
      // 错误位出红字「去系统连 Wi-Fi」固定提醒(解密未中细节已改写
      // AppLog,不上屏)。
      controller.markWifiAwakePending();
      return;
    }
    if (controller.wifiJoiner == null) {
      // 无程序化入热能力(iOS):留蓝牙页弹红卡,用户手动入网后
      // 显式点「已加入热点,开始连接」(App 不主动跳 Wi-Fi 设置)。
      controller.markWifiAwakePending();
      return;
    }
    // 自动加入路上:join 看门狗 30s 兜底,过渡提示给足时长。
    _showHintStatic(context,
        controller, context.t('conn.joiningHotspot', {'ssid': creds.ssid}),
        duration: const Duration(seconds: 30));
    final outcome = await controller.joinCameraAp();
    if (!context.mounted) return;
    if (outcome == ApJoinOutcome.joined) {
      _showHintStatic(
          context, controller, context.t('conn.joinedHotspot', {'ssid': creds.ssid}),
          duration: const Duration(seconds: 5));
    } else if (outcome == ApJoinOutcome.failed) {
      _showHintStatic(
        context,
        controller,
        context.t('conn.autoJoinFailed',
            {'e': controller.apJoinError ?? context.t('common.unknown')}),
        duration: const Duration(seconds: 5),
      );
    } else {
      // skipped:防御路(joiner 在 wake 后被置空等)—— 红卡兜底。
      controller.markWifiAwakePending();
    }
  }

  /// ohos B 路 join(0x2004 解密未中):扫描锁定相机热点 → 密码(已存
  /// 用存档;没有则弹一次录入框,见相机屏幕)→ 凭据就位走
  /// [ConnectionController.joinCameraAp] 既定路(成功沿密码落档,下次
  /// 免录入)。相机匹配 = 尼康启发式或含相机广播名(空格/下划线归一,
  /// BLE 名与 AP SSID 同族但分隔符不定);多台取最强 RSSI。
  ///
  /// 扫描轮询:相机热点在 BLE 释放后要数秒才开播(真机实证),单轮
  /// 2.5s 常扑空 —— 最多 5 轮 × 3s;每轮列表落 AppLog(SSID 真名取证,
  /// 匹配启发式失配时好补)。
  static Future<ApJoinOutcome> _joinOhosByScan(
      BuildContext context, ConnectionController controller) async {
    final joiner = controller.wifiJoiner;
    if (joiner == null) {
      controller.markWifiAwakePending();
      return ApJoinOutcome.skipped;
    }
    _showHintStatic(context, controller, context.t('conn.scanningHotspot'),
        duration: const Duration(seconds: 30));
    final camName = controller.bleIdentity?.cameraName ?? '';
    String norm(String s) =>
        s.replaceAll(RegExp(r'[\s_]+'), '').toUpperCase();
    final camNorm = norm(camName);
    WifiApScan? pick;
    for (var round = 1; round <= 5 && pick == null; round++) {
      final aps = await joiner.scanAps();
      if (!context.mounted) return ApJoinOutcome.skipped;
      AppLog.d(AppLog.ble,
          'Wi-Fi 扫描轮 $round:${aps.map((a) => '${a.ssid}(${a.rssi},0x${a.security.toRadixString(16)})').join(' ')}');
      var bestRssi = -999;
      for (final ap in aps) {
        final hit = isLikelyCameraSsid(ap.ssid) ||
            (camNorm.isNotEmpty && norm(ap.ssid).contains(camNorm));
        if (!hit || ap.rssi <= bestRssi) continue;
        bestRssi = ap.rssi;
        pick = ap;
      }
      if (pick == null && round < 5) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!context.mounted) return ApJoinOutcome.skipped;
      }
    }
    if (pick == null) {
      _showHintStatic(context, controller, context.t('conn.noCameraAp'),
          duration: const Duration(seconds: 5));
      controller.markWifiAwakePending();
      return ApJoinOutcome.failed;
    }
    // 密码策略(2026-10-23 真机定案):Zf 热点是**开放网络**(相机屏
    // 幕虽有提示密码,系统直连免输)—— 扫描安全类型即真相:开放
    // (0x01)直接连,零弹框;加密 AP 才要密码(已存用存档,没有弹
    // 一次录入框)。
    String? password = '';
    if (pick.security != 0x01) {
      password = controller.savedWifiPassword;
      if (password.isEmpty) {
        password =
            await _promptWifiPassword(context, controller, pick.ssid);
        if (!context.mounted) return ApJoinOutcome.skipped;
        if (password == null || password.isEmpty) {
          controller.markWifiAwakePending();
          return ApJoinOutcome.skipped;
        }
      }
    }
    // 凭据就位(借 controller 既有 joinCameraAp 路:join → 网关落账 →
    // 切 AP 方式 → 发射 connectWireless)。
    controller.cameraApCredentials = WifiCredentials(
      ssid: pick.ssid,
      password: password,
      security: pick.security,
      keySource: 'scan',
    );
    final outcome = await controller.joinCameraAp();
    if (!context.mounted) return outcome;
    if (outcome == ApJoinOutcome.joined) {
      if (password.isNotEmpty && controller.savedWifiPassword.isEmpty) {
        await controller.saveWifiPassword(password);
        if (!context.mounted) return outcome;
      }
      _showHintStatic(
          context,
          controller,
          context.t('conn.joinedHotspot', {'ssid': pick.ssid}),
          duration: const Duration(seconds: 5));
    } else if (outcome == ApJoinOutcome.failed) {
      _showHintStatic(
        context,
        controller,
        context.t('conn.autoJoinFailed',
            {'e': controller.apJoinError ?? context.t('common.unknown')}),
        duration: const Duration(seconds: 5),
      );
    }
    return outcome;
  }

  /// 相机热点密码录入框(一次;密码显示在相机屏幕的 Wi-Fi 连接画面)。
  static Future<String?> _promptWifiPassword(BuildContext context,
      ConnectionController controller, String ssid) async {
    final field = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('conn.wifiPasswordTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ssid, style: Theme.of(dialogContext).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: field,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                hintText: dialogContext.t('conn.wifiPasswordHint'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.t('conn.wifiPasswordSave')),
          ),
        ],
      ),
    );
    return ok == true ? field.text.trim() : null;
  }

  /// 提示收口的静态面(整页组件共用):先撤在场提示再显 ——
  /// showSnackBar 是排队不替换,30s 的过渡提示会把终态消息压到 30s 后。
  static void _showHintStatic(BuildContext context, ConnectionController controller,
      String message,
      {Duration duration = const Duration(seconds: 3)}) {
    ScaffoldMessenger.of(context)
      // 先撤在场提示再显:showSnackBar 是排队不替换,30s 的过渡提示
      // 会把终态消息压到 30s 后(真机/测试同病)。
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: duration,
      ));
  }

  /// AP 方式凭据块(蓝牙通道解出才显示):SSID/密码/安全 + 复制钮 ——
  /// 系统设置加入热点用;密码空(开放网络)不渲染行。显示在未连接
  /// 主视图下方(原 AP 卡凭据区,2026-10-17 随卡撤销迁此)。
  List<Widget> _apCredentialBlock(
    BuildContext context,
    ConnectionController controller,
  ) {
    final creds = controller.cameraApCredentials;
    if (creds == null) {
      return const [];
    }
    // 标签列宽:卡内各行(SSID/密码)按整组标签实测共用一宽 —— 列对齐
    // 不因行而异;zh 短标签落 44 下限观感不变(原钉宽),EN「Password」
    // 放行不折行(原 44 钉宽 EN 长词折行/微溢出的根治)。
    final labelWidth = kvLabelWidth(
      context,
      labels: [
        context.t('conn.ssid'),
        if (creds.password.isNotEmpty) context.t('conn.password'),
      ],
      style: Theme.of(context).textTheme.bodyMedium!,
      minWidth: 44,
    );
    return [
      Text(context.t('conn.hotspotCred'),
          style: Theme.of(context).textTheme.labelMedium),
      _credentialRow(context, 'conn.ssid', creds.ssid,
          labelWidth: labelWidth),
      if (creds.password.isNotEmpty)
        _credentialRow(context, 'conn.password', creds.password,
            labelWidth: labelWidth),
      Text(context.t('conn.security', {'s': creds.securityLabel}),
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  /// 凭据行(KvRow 收编):[labelWidth] 缺省按本行标签实测(红卡单行
  /// 用);同卡多行由调用方传共用宽保持列对齐。44 下限 = zh 短标签的
  /// 现行观感(原钉宽)。标签随行结构单行省略,正常文案实测宽放行。
  Widget _credentialRow(
    BuildContext context,
    String label,
    String value, {
    double? labelWidth,
  }) {
    // label 原文即词表键(凭据两行均真键化;SSID 技术专名 zh/en 同值);
    // tooltip/SnackBar 以 {label} 参数复用同一模板。
    final localizedLabel = context.t(label);
    return KvRow(
      labelWidth: labelWidth ??
          kvLabelWidth(context,
              labels: [localizedLabel],
              style: Theme.of(context).textTheme.bodyMedium!,
              minWidth: 44),
      label: localizedLabel,
      value: Text(value.isEmpty ? context.t('common.empty') : value,
          style: const TextStyle(fontFamily: 'monospace')),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 18),
        tooltip: context.t('conn.copyLabel', {'label': localizedLabel}),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          unawaited(AppHaptics.success()); // 复制成功震感(与 remote_banner 复制统一)
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  context.t('conn.copiedLabel', {'label': localizedLabel})),
              duration: const Duration(seconds: 2),
            ));
          }
        },
      ),
    );
  }

  /// 删除确认:忘记这台相机(清档案 + 配对过的换新身份 → 全新配对)。
  static Future<void> _confirmRemoveSaved(
    BuildContext context,
    ConnectionController controller,
    CameraInfo saved,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('conn.forgetConfirm'),
      content: context.t('conn.forgetBody', {'name': saved.name}),
      confirmLabel: context.t('common.delete'),
      destructive: true,
    );
    if (confirmed) {
      await controller.removeSaved(saved);
    }
  }

  // ── 已连接:相机信息总览 ─────────────────────────────────────────

  Widget _connectedView(BuildContext context, ConnectionController controller) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller.connection;
    final wireless = c?.isWireless ?? false;
    return ListenableBuilder(
      // 存储卡脚注随档位/可录时长走(帧头 @816),拍摄模式镜像在
      // RemoteController 上 —— 与总览一并监听。
      listenable: Listenable.merge([_overview, _remote]),
      builder: (context, _) => ListView(
        padding: AppSpacing.screenPadding,
        children: [
          // 状态行:绿点已连接 + 电池 + 链路纯图标 pill;只有「已连接」
          // 状态词可点 = 弹确认框,确认才断开(2026-10-23 定稿,详情
          // 弹层迁机身卡)。
          ConnectedHeader(
            batteryPercent: _overview.batteryPercent,
            linkIcon: wireless ? Icons.wifi : Icons.usb,
            onDisconnect: () => unawaited(_confirmDisconnect(context, controller)),
          ),
          const SizedBox(height: AppSpacing.md),
          // 整行:机身卡(竖线居中:型号 pill | 固件/序列号裸值);
          // 型号 pill 可点 → 连接详情弹层(2026-10-23 自状态行迁此)。
          CameraCard(
            model: _overview.deviceInfo?.model,
            firmware: _overview.deviceInfo?.deviceVersion,
            serial: _overview.deviceInfo?.serialNumber,
            onModelTap: () => _showConnectionSheet(context, controller),
          ),
          const SizedBox(height: AppSpacing.md),
          // 双列:镜头信息卡(名+焦距+光圈)| 存储卡(卡型/已用条)。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LensCard(
                    lensName: _overview.lensDisplay,
                    focalMm: _overview.focalLengthMm,
                    fNumber: _overview.fNumber,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: StorageCard(
                    model: _overview.deviceInfo?.model,
                    mode: _remote.cameraMode,
                    videoRemainingMs: _remote.videoRemainingMs,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // 底部双钮:左相册(灰底次级)右进入拍摄(黄主钮);断开
          // 连接收状态行「已连接」状态词点按(2026-10-23 定稿)。
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: FilledButton.tonalIcon(
                    onPressed: _openAlbum,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(context.t('conn.album')),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHigh,
                      foregroundColor: scheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: SizedBox(
                  height: 48,
                  // 进入拍摄(遥控监看):全屏 push,底栏不占监看画面,
                  // 拍摄页自带返回钮。
                  child: FilledButton.icon(
                    onPressed: _openRemote,
                    icon: const Icon(Icons.camera),
                    label: Text(context.t('conn.enterShooting')),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 点「已连接」状态词 → 确认弹框,确认才断开(2026-10-23 用户裁定:
  /// 直断一步误触代价高,补确认 —— 与「忘记这台相机」同一确认框语言,
  /// 确认钮红底接旧弹层红色断开的视觉)。
  Future<void> _confirmDisconnect(
      BuildContext context, ConnectionController controller) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('conn.disconnectConfirm'),
      content: context.t('conn.disconnectBody'),
      confirmLabel: context.t('conn.disconnectConn'),
      destructive: true,
    );
    if (confirmed) {
      await controller.disconnect();
    }
  }

  /// 机身卡型号 pill 点按 → 连接详情弹层(2026-10-23 自状态行迁此):
  /// 设备名/型号/链路/快门数四行,纯信息 —— 断开走状态行「已连接」
  /// 状态词点按,弹层内不再放断开钮。设备名与链路串从主页面收编至此
  /// (2026-10-17)。快门数千分位分组:15963 → '15,963'。
  static String _groupShutter(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      b.write(s[i]);
      final rem = s.length - i;
      if (rem > 1 && rem % 3 == 1) b.write(',');
    }
    return b.toString();
  }

  void _showConnectionSheet(
      BuildContext context, ConnectionController controller) {
    final c = controller.connection;
    final wireless = c?.isWireless ?? false;
    // 链路串:无线带 IP(动态串直通),USB 复用既有本地化文案。
    final link = wireless
        ? (controller.activeIp == null ? 'Wi-Fi' : 'Wi-Fi(${controller.activeIp})')
        : context.t('conn.usbCable');
    // 弹层在场期间快门数实时跟随(controller 状态 + 拍照沿自动重读):
    // 置 live 后触发现读,关闭沿(pop/滑删)撤销 live。
    _overview.shutterLive = true;
    unawaited(_overview.refreshShutterCount());
    // 标签列宽:整组标签实测共用一宽(kv_row 同机制)—— EN 长标签
    // (Device Name/Shutter count)在原 56 钉宽(v26 zh 口径定稿)下
    // 折行、行高跳,实测放行;zh 短标签 56 下限观感不变。
    final sheetLabelWidth = kvLabelWidth(
      context,
      labels: [
        context.t('conn.sheetDevice'),
        context.t('conn.sheetModel'),
        context.t('conn.sheetLink'),
        context.t('conn.camInfoShutter'),
      ],
      style: Theme.of(context).textTheme.bodySmall!,
      minWidth: 56,
    );
    Widget row(String labelKey, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              // 标签列定宽,数值列统一左对齐成一条(v25/v26 定稿;宽随
              // 语言实测,见 sheetLabelWidth)。
              SizedBox(
                width: sheetLabelWidth,
                child: Text(context.t(labelKey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ],
          ),
        );
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: AppColors.success(sheetContext),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      sheetContext.t('conn.connected'),
                      style: Theme.of(sheetContext).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                row('conn.sheetDevice', c?.deviceName ?? '--'),
                row('conn.sheetModel', _overview.deviceInfo?.model ?? '--'),
                row('conn.sheetLink', link),
                // 快门数现读(卡上最新照片 MakerNote 0x00A7;口径 =
                // 拍一张 +1):弹层在场跟随 controller 状态,拍照沿自动
                // 重读当场涨;读取中出「读取中…」,失败静默 '--'。
                ListenableBuilder(
                  listenable: _overview,
                  builder: (context, _) {
                    String value;
                    if (_overview.shutterReading) {
                      value = sheetContext.t('conn.camInfoReading');
                    } else {
                      final v = _overview.shutterCount;
                      value = v == null ? '--' : _groupShutter(v);
                    }
                    return row('conn.camInfoShutter', value);
                  },
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() => _overview.shutterLive = false);
  }

  /// 进入拍摄:全屏 push 遥控监看页(返回即回相机页;拍摄页离页自动
  /// 挂起帧轮询,取景生命周期跟连接走,相机侧保持取景)。
  void _openRemote() {
    // 拍摄页在前台:可见性主权移交(setViewerVisible 由它汇报),
    // 连接页的模式事件跟随不再代持顶真;返回沿收回主权并按档位重判。
    _shootingOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => RemotePage(controller: _remote),
          ),
        )
        .whenComplete(() {
      _shootingOpen = false;
      _syncViewerForMode();
    });
  }

  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGridPage(
          controller: AppServices.instance.browserController,
          folderHandle: CameraAlbum.allPhotosHandle,
          fallbackName: context.t('conn.cameraAlbum'),
        ),
      ),
    );
  }
}

/// 方式图标 hero(2026-10-19 六轮定稿):四方式统一 96 径/44 图标
/// (六轮缩径,原 116/54),固定顶距之下正中(四方式同位,
/// [_ConnectionPageState._heroTopGap]);连接在途沿**涟漪外扩**(八轮
/// 用户图示:三圈错相自圆缘外扩淡出,替换六轮的缩放脉冲;九轮调小调慢
/// —— 上限 1.5、周期 2400ms)+ 描边转黄;**蓝牙就绪实底统一黄**(十
/// 一轮:accentYellow 实底 + onBrandYellow 深字,十轮淡绿被否)。**图标即连接钮**(USB/AP:
/// 直连/取消;STA/蓝牙:连最近/取消 —— 八/九轮,蓝牙就绪点按断开,
/// 十一轮,重连态点按停止重连,十三轮,
/// [_ConnectionPageState._heroPressed]);说明入口在 AppBar 方式位
/// ⓘ([_ConnectionPageState._modeChip])。五轮中央连接钮退役。
class _MethodHero extends StatefulWidget {
  const _MethodHero({
    required this.method,
    required this.busy,
    this.ready = false,
    this.onTap,
  });

  final ConnectionMethod method;

  /// 连接在途(驱动涟漪;false 沿即停即回位)。
  final bool busy;

  /// 已连接(十轮引入,十一轮定样:仅蓝牙页用 —— 连接后页面不跳转,
  /// hero 转**实底统一黄** [AppColors.accentYellow] + [AppColors.
  /// onBrandYellow] 深字图标,与按钮实底同深;十轮的淡绿被否。busy
  /// 优先 —— 在途黄描边+涟漪)。
  final bool ready;

  /// 点按(USB/AP = 连接/取消;STA/蓝牙 = 连最近/取消;null = 纯展示)。
  final VoidCallback? onTap;

  @override
  State<_MethodHero> createState() => _MethodHeroState();
}

class _MethodHeroState extends State<_MethodHero>
    with SingleTickerProviderStateMixin {
  static const double _circle = 96;
  static const int _ringCount = 3;

  /// 九轮「圈小一点,速度慢一点」:外扩上限 1.9→1.5、周期 1500→2400ms
  ///(一圈的可见寿命 = 整周期,错相 1/3 不变)。
  static const double _ringMaxScale = 1.5;
  static const Duration _ringPeriod = Duration(milliseconds: 2400);

  /// 涟漪驱动。**initState 现建,不做内联惰性初始化** —— 闲态 hero 终生
  /// 不碰涟漪,首次访问落在 dispose 沿:unmount 期 createTicker 查
  /// TickerMode 祖先必炸(debug 守卫「deactivated widget's ancestor」,
  /// f82e8eb 起全量 app 骨架类用例全挂的根因)。
  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(vsync: this, duration: _ringPeriod);
    if (widget.busy) _ripple.repeat();
  }

  @override
  void didUpdateWidget(covariant _MethodHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy == oldWidget.busy) return;
    if (widget.busy) {
      _ripple.repeat();
    } else {
      _ripple
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  /// 一圈涟漪(进度 0→1:自圆缘外扩 + 淡出;easeOutCubic 外扩减速)。
  Widget _ring(double progress) {
    final scale =
        1.0 + (_ringMaxScale - 1.0) * Curves.easeOutCubic.transform(progress);
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: (1 - progress) * 0.5,
        child: Container(
          width: _circle,
          height: _circle,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accentYellow, width: 2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 外层 96×96 不变(命中区 = 圆);涟漪环经 Clip.none 溢出绘制,
    // 溢出区不吃点按(盒外 hitTest 不达)。
    return SizedBox(
      width: _circle,
      height: _circle,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (widget.busy)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) => Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < _ringCount; i++)
                      _ring((_ripple.value + i / _ringCount) % 1.0),
                  ],
                ),
              ),
            ),
          InkWell(
            key: const ValueKey('conn_method_hero'),
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _circle,
              height: _circle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 十一轮:蓝牙就绪 = 实底统一黄(与按钮实底同深,配
                // onBrandYellow 深字;十轮淡绿被否);在途黄描边优先。
                color: widget.ready && !widget.busy
                    ? AppColors.accentYellow
                    : theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.45),
                border: Border.all(
                    color: widget.busy || widget.ready
                        ? AppColors.accentYellow
                        : theme.colorScheme.outlineVariant),
              ),
              child: Center(
                child: _ConnectionPageState._methodIconWidget(widget.method,
                    size: 44,
                    color: widget.ready && !widget.busy
                        ? AppColors.onBrandYellow
                        : theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// STA 扫描视图体(2026-10-19 改版):进方式即自动扫描(静默 —— 无
/// 扫描钮、无「扫描中」指示,2026-10-19 用户定稿),离方式停扫
/// (dispose);内容 = 状态行 + 固定错误位 + Wi-Fi hero(**八轮可点 =
/// 连最近**)+「已配对 / 其它设备」两段列表;当前方式在 AppBar 方式位
/// (六轮)。已配对行 = 档案最近优先,首条带绿底「最近」徽(八轮);
/// 连接由行点按或 hero 点按触发;取消 = 再点 hero(connecting/
/// reconnecting 在途点按即断,与 USB/AP 同语义 —— 九轮底部「取消
/// 连接」按钮退役)。没有路由可退(原地替换),状态行在视图顶部。
class _StaScanBody extends StatefulWidget {
  const _StaScanBody({required this.controller, required this.page});

  final ConnectionController controller;

  /// 宿主页 State(hero/提示卡/状态表现等页内件复用;同库私有可达)。
  final _ConnectionPageState page;

  @override
  State<_StaScanBody> createState() => _StaScanBodyState();
}

class _StaScanBodyState extends State<_StaScanBody> {
  @override
  void initState() {
    super.initState();
    // 帧尾起扫:initState 在 build 期,同步 startScan 会同步 notify,
    // 炸 ListenableBuilder 的「build 期 markNeedsBuild」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.controller.startScan());
      }
    });
  }

  @override
  void dispose() {
    // 离开 STA 视图停扫(扫描只在本页面存续期运行,2026-10-19 定稿;
    // 切到其它方式页同样不经此体,不触发扫描)。
    if (widget.controller.scanning) {
      unawaited(widget.controller.stopScan());
    }
    super.dispose();
  }

  /// 「其它设备」列示源:mDNS 发现里滤掉已配对相机(2026-10-21 用户
  /// 定稿,与 BLE 面板同款)—— 匹配 = 归一化名相等(两侧都是 mDNS 实
  /// 例名)或 host == lastIp(最强信号)。
  List<DiscoveredIpCamera> _othersIpCameras(ConnectionController controller) {
    bool paired(DiscoveredIpCamera c) => controller.savedCameras.any((s) {
          String norm(String v) =>
              v.replaceAll(RegExp(r'[\s_]+'), '').toLowerCase();
          if (s.lastIp != null && s.lastIp == c.host) return true;
          return s.name.isNotEmpty &&
              c.name.isNotEmpty &&
              norm(s.name) == norm(c.name);
        });
    return controller.cameras.where((c) => !paired(c)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final busy = _ConnectionPageState._busyState(controller);
        final (label, dot, busySpin) =
            _ConnectionPageState._ptpStatusPresentation(controller, context);
        // 图标坐标恒定(见 _ConnectionPageState._heroTopGap,四方式
        // 同位);四轮裁定「配对信息往上移」:两段列表紧随图标之下,
        // 剩余空间全在底部(内容短则留白,长则区内滚动)。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppSpacing.screenPadding,
              child: ConnStatusHeader(
                  dotColor: dot, label: context.t(label), busy: busySpin),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: ConnErrorSlot(
                hint: controller.hint?.key,
                args: controller.hint?.args,
                error: controller.state == CameraLinkState.failed,
              ),
            ),
            const SizedBox(height: _ConnectionPageState._heroTopGap),
            Center(
              child: _MethodHero(
                method: ConnectionMethod.sta,
                busy: busy,
                // 八轮:图标即连接钮 —— 连最近(档案首条),在途点按
                // 取消(与 USB/AP hero 同语义)。
                onTap: () => widget.page._heroPressed(controller),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: AppSpacing.screenPadding.copyWith(top: AppSpacing.md),
                children: [
                  // 已配对:paired_cameras.json 快连档案(最近优先,点行
                  // 连接,忘记 = 清档案 + 配对过的换新身份 → 全新配对,
                  // 无感)。首条 = 最近连接条目,名后带绿底「最近」徽
                  //(八轮;hero 点按连的就是它)。
                  const ConnSectionHeader(label: 'conn.sectionPaired'),
                  ConnTileGroup(
                    children: [
                      if (controller.savedCameras.isEmpty)
                        const _EmptyGroupRow(text: 'conn.noPairedDevices')
                      else
                        for (final (i, saved) in controller.savedCameras.indexed)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.photo_camera_outlined),
                            title: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: Text(saved.name)),
                                if (i == 0) ...[
                                  const SizedBox(width: AppSpacing.sm),
                                  const ConnRecentBadge(),
                                ],
                              ],
                            ),
                            subtitle: saved.lastIp == null
                                ? null
                                : Text(saved.lastIp!),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: context.t('conn.forgetCamera'),
                              onPressed: busy
                                  ? null
                                  : () => _ConnectionPageState
                                      ._confirmRemoveSaved(
                                          context, controller, saved),
                            ),
                            onTap: busy
                                ? null
                                : () =>
                                    unawaited(controller.connectSaved(saved)),
                          ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 其它设备:mDNS 发现(点行连接),已配对相机滤除不重复
                  // 列示(2026-10-21 用户定稿,与 BLE 面板同款)。扫描静默
                  // —— 无「扫描中」指示,结果静默入列;相机须停留在「等
                  // 待连接」画面等解释收进 hero 说明(点图标弹说明弹窗)。
                  const ConnSectionHeader(label: 'conn.sectionOthers'),
                  ConnTileGroup(
                    children: [
                      if (_othersIpCameras(controller).isEmpty)
                        const _EmptyGroupRow(text: 'conn.noOtherDevices')
                      else
                        for (final camera in _othersIpCameras(controller))
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.photo_camera_outlined),
                            title: Text(camera.name),
                            subtitle: Text(camera.host),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: busy
                                ? null
                                : () => unawaited(
                                    controller.connectDiscovered(camera)),
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 列表组空态行(组容器内居中次级小字;text 即 t() 键)。
class _EmptyGroupRow extends StatelessWidget {
  const _EmptyGroupRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      child: Center(
        child: Text(
          context.t(text),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

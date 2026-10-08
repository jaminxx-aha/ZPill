/// 相机页(底部导航首 tab):连接入口 + 已连接相机信息总览。
///
/// 未连接:连接方式分段切换(有线 USB / AP 热点 / 同一 Wi-Fi)——
/// 切到哪种方式,下方只出该方式的连接卡;已连接:信息卡组(连接/
/// 机身/镜头/存储卡)+「进入拍摄」(主操作,全屏 push 遥控监看页 ——
/// 2026-10-08 拍摄页从底栏 tab 改制,置状态卡正下方不滚动即可见)
/// +「相册」入口 +「断开连接」。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中自动配对(验证码不回传相机),相机侧弹「配对
/// 完成」等按 OK,应用保持重连等它(见 awaitingCameraConfirm);已
/// 配对直连。AP 模式保留手动 IP 兜底(默认 192.168.1.1)。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../data/client_identity_store.dart';
import '../../data/paired_cameras_store.dart';
import '../../design/app_dimens.dart';
import '../../platform/nsd_scanner.dart';
import '../browser/photo_grid_page.dart';
import '../common/widgets/confirm_dialog.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_page.dart';
import 'camera_overview_controller.dart';
import 'connection_status_card.dart';

/// 连接方式(未连接视图的分段选择;切到哪种出哪种卡)。
enum ConnectionMethod { usb, ap, sta }

class ConnectionController extends ChangeNotifier {
  /// 注入应用级连接(全局单例状态,经 AppServices 收口)+ 扫描器与
  /// 配对档案(均可空:测试/未装配平台降级)。
  ConnectionController({
    this.connection,
    this.scanner,
    this.pairedCameras,
    this.identityStore,
  }) {
    connection?.states.listen(_onState);
    // 常驻订阅:浏览期间增删相机,未浏览时静默无流。
    scanner?.events.listen(_onNsdEvent, onError: (Object _) {});
  }

  final CameraConnection? connection;
  final NsdScanner? scanner;
  final PairedCamerasStore? pairedCameras;

  /// 客户端身份(删除已配对相机时换新,触发全新配对;见 [removeSaved])。
  final ClientIdentityStore? identityStore;

  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;

  /// 配对后的机身确认等待窗:pairing → connecting 沿置位(连接层此窗
  /// 保持 connecting 安静重试),离开 connecting 即清。真机(2026-10-06):
  /// 0x935A 后相机弹「配对完成」等机身上按 OK,按之前重连全被拒 ——
  /// UI 用此旗出「请在相机上按 OK」指引,不闪失败横幅。
  bool awaitingCameraConfirm = false;

  /// 当前选中的连接方式(未连接视图分段;默认有线)。
  ConnectionMethod method = ConnectionMethod.usb;

  /// 切换连接方式;离开 STA 时若在扫描顺手停掉(结果已不可见)。
  void selectMethod(ConnectionMethod m) {
    if (m == method) {
      return;
    }
    if (scanning && m != ConnectionMethod.sta) {
      stopScan();
    }
    method = m;
    notifyListeners();
  }

  /// 本次连接的无线 IP(已连接视图的「连接方式」行;USB 连接为 null)。
  String? activeIp;

  /// 扫描到的相机(按实例名去重;解析失败无 IP 的不上榜)。
  final Map<String, DiscoveredIpCamera> _cameras = {};
  List<DiscoveredIpCamera> get cameras =>
      _cameras.values.toList(growable: false);

  /// 扫描进行中(未装配扫描器/平台未实现时永远 false)。
  bool scanning = false;

  /// 已配对/曾连接过的相机(最近优先),用于快速重连。
  List<CameraInfo> savedCameras = const [];

  /// 删除已保存相机:清应用侧档案;若该相机完成过配对,同时换新
  /// 客户端身份 —— 相机眼里的旧记录失配,下次连接走**全新配对**
  /// (无感自动确认),即「忘记这台相机」。
  Future<void> removeSaved(CameraInfo camera) async {
    final store = pairedCameras;
    if (store == null) {
      return;
    }
    await store.remove(camera.id);
    if (camera.wirelessPaired) {
      await identityStore?.regenerate();
    }
    await _reloadSaved();
  }

  /// 状态提示:失败原因(含插线/解锁/热点指引)、配对等待去向。
  /// 已连接不在此列 —— 已连接视图(信息卡组)自带全部信息。
  String? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    if (awaitingCameraConfirm && state == CameraLinkState.connecting) {
      return '配对信息已发送:请在相机屏幕上按「OK」完成配对,'
          '应用将自动重连(最长约 1 分钟)';
    }
    return switch (state) {
      CameraLinkState.pairing => '正在配对(自动确认)',
      CameraLinkState.failed => c.error ?? '连接失败',
      _ => null,
    };
  }

  void _onState(CameraLinkState s) {
    // pairing → connecting 只发生在配对后的重连等待窗(连接层语义),
    // 以此沿识别机身确认等待;其余任何状态离开即清。
    if (s == CameraLinkState.connecting) {
      if (state == CameraLinkState.pairing) {
        awaitingCameraConfirm = true;
      }
    } else {
      awaitingCameraConfirm = false;
    }
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

  /// 后台恢复时重启浏览:挂起期间系统可能停掉 mDNS 查询(iOS 常见),
  /// 浏览器名义上还在跑但收不到新服务 —— 停起一轮重新发查询。结果
  /// 不清(还在网的相机会随 found 重播回来,按键去重不闪)。
  Future<void> rescanIfScanning() async {
    if (!scanning) {
      return;
    }
    final s = scanner;
    if (s == null) {
      return;
    }
    try {
      await s.stopBrowsing();
      await s.startBrowsing();
    } on Exception {
      // 重启失败不致命:原浏览若还活着照常工作
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

  /// 有线连接(USB):状态经 states 流回(本地 state 只是流的镜像)。
  Future<void> connect() async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = connect;
    activeIp = null;
    await c.connect();
  }

  /// 连接扫描到的相机(实例名随连接传给配对档案)。
  Future<void> connectDiscovered(DiscoveredIpCamera camera) async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = () => connectDiscovered(camera);
    await stopScan();
    activeIp = camera.host;
    await c.connect(ip: camera.host, instanceName: camera.name);
  }

  /// 快速重连上次相机(直连记录里的 IP;失效时再扫描/手动)。
  Future<void> connectSaved(CameraInfo camera) async {
    final c = connection;
    final ip = camera.lastIp;
    if (c == null || ip == null) {
      return;
    }
    _lastAttempt = () => connectSaved(camera);
    activeIp = ip;
    await c.connect(ip: ip, instanceName: camera.name);
  }

  /// STA 手动 IP(扫描兜底):独立控制器,**不预填** —— AP 卡默认的
  /// 192.168.1.1 在 STA 网段多半是路由器,预填即误拨。
  final manualIpController = TextEditingController();

  /// AP 连接(手动 IP 兜底):输入为空时回落默认网关地址。
  Future<void> connectWireless() async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = connectWireless;
    var ip = ipController.text.trim();
    if (ip.isEmpty) {
      ip = kDefaultCameraIp;
    }
    activeIp = ip;
    await c.connect(ip: ip);
  }

  /// STA 手动 IP 连接(扫描不到时的兜底):**不回落默认地址** ——
  /// 192.168.1.1 在 STA 网络里多半是路由器,连它只会得到一个莫名的
  /// 超时失败;空输入直接不动作。
  Future<void> connectManualIp() async {
    final c = connection;
    final ip = manualIpController.text.trim();
    if (c == null || ip.isEmpty) {
      return;
    }
    _lastAttempt = connectManualIp;
    activeIp = ip;
    await c.connect(ip: ip);
  }

  /// 最近一次连接尝试(失败重试重放):各 connect* 入口落账。重放会
  /// 再次走完整入口(停扫/预填等副作用幂等);CameraConnection.connect
  /// 自带 connected/connecting/pairing 态护栏,重入安全。
  void Function()? _lastAttempt;

  /// 重试上次失败的连接(仅 failed 态有意义,UI 只在该态出重试钮;
  /// 无记录时静默 —— 如启动即 failed 从未尝试过)。
  void retry() {
    if (state != CameraLinkState.failed) {
      return;
    }
    _lastAttempt?.call();
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
    manualIpController.dispose();
    super.dispose();
  }
}

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _controller.loadSaved();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
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
      appBar: AppBar(title: const Text('相机')),
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

  // ── 未连接:连接方式分段切换 ─────────────────────────────────────

  Widget _methodsView(BuildContext context, ConnectionController controller) {
    final busy = switch (controller.state) {
      CameraLinkState.connecting || CameraLinkState.pairing => true,
      _ => false,
    };
    return GestureDetector(
      // 点空白散焦收键盘:AP IP 输入框点开后,页面里没有任何收起手段
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: AppSpacing.screenPadding,
        children: [
          // 状态着色:disconnected 灰 / connecting 红 / pairing 金 /
          // connected 绿 / failed 红;busy 态尾槽 spinner;失败原因并入
          // 副文(首句加粗)+ 重试钮。配对后的机身确认等待窗显示专属
          // 文案(不闪失败)。
          ConnectionStatusCard(
            state: controller.state,
            waitingConfirm: controller.awaitingCameraConfirm,
            hint: controller.hint,
            onRetry: controller.retry,
          ),
          // connecting 逃生口:输入框/按钮全禁用期间(死 IP 的 TCP 超时
          // 最长 ~3s,建链/开会话/切模式另有 10s 总预算),用户得有取
          // 消手段,否则像「卡死」。
          if (controller.state == CameraLinkState.connecting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('取消连接'),
                onPressed: controller.disconnect,
              ),
            ),
          const SizedBox(height: 16),

          // 分段切换:切到哪种方式,下方只出该方式的连接卡。
          SegmentedButton<ConnectionMethod>(
            segments: const [
              ButtonSegment(
                  value: ConnectionMethod.usb,
                  icon: Icon(Icons.usb),
                  label: Text('有线')),
              ButtonSegment(
                  value: ConnectionMethod.ap,
                  icon: Icon(Icons.wifi_tethering),
                  label: Text('AP 热点')),
              ButtonSegment(
                  value: ConnectionMethod.sta,
                  icon: Icon(Icons.wifi),
                  label: Text('同一 Wi-Fi')),
            ],
            selected: {controller.method},
            onSelectionChanged: busy
                ? null
                : (selection) => controller.selectMethod(selection.first),
          ),
          const SizedBox(height: 12),

          switch (controller.method) {
            ConnectionMethod.usb => _usbCard(context, controller, busy: busy),
            ConnectionMethod.ap => _apCard(context, controller, busy: busy),
            ConnectionMethod.sta => _staCard(context, controller, busy: busy),
          },
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              '· 首次无线连接会请求配对确认(相机记录本设备,之后免配对);'
              '相机屏幕出现提示时请在机身上按 OK。\n'
              '· 相机同一时间只允许一个客户端:若被 SnapBridge(尼享)抢先连上'
              '会遭拒,请先彻底关闭它。\n'
              '· 首次连接若失败,请在系统弹窗中允许访问本地网络后重试;'
              '下载大文件期间请保持 App 在前台、屏幕点亮。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 方式一:有线(USB C-to-C 数据线直连)。
  Widget _usbCard(
    BuildContext context,
    ConnectionController controller, {
    required bool busy,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _methodTitle(context, Icons.usb, '有线连接(USB)'),
            const SizedBox(height: 4),
            const Text('用 C-to-C 数据线连接相机与手机,解锁相机后点「USB 连接」'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : controller.connect,
                child: const Text('USB 连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 方式二:AP(相机当热点,手机加入后连固定网段)。
  Widget _apCard(
    BuildContext context,
    ConnectionController controller, {
    required bool busy,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _methodTitle(context, Icons.wifi_tethering, 'AP 连接(相机当热点)'),
            const SizedBox(height: 4),
            const Text('相机菜单:网络 → 连接至智能设备 → Wi-Fi 连接(热点模式)。'
                '先在系统 Wi-Fi 设置里加入相机热点,再回来连接。'),
            const SizedBox(height: 12),
            TextField(
              controller: controller.ipController,
              keyboardType: TextInputType.url,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: '相机 IP(默认 192.168.1.1)',
                hintText: kDefaultCameraIp,
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : controller.connectWireless,
                child: const Text('AP 连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 方式三:STA(相机与手机加入同一 Wi-Fi,扫描发现)。
  Widget _staCard(
    BuildContext context,
    ConnectionController controller, {
    required bool busy,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _methodTitle(context, Icons.wifi, 'STA 连接(同一 Wi-Fi)'),
            const SizedBox(height: 4),
            const Text('相机与手机加入同一个 Wi-Fi(相机菜单同上,选择连接到'
                '路由器网络),扫描发现相机后点选连接。'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // 扫描中 icon 槽换 spinner(标签文案不变):
                // mDNS 发现是慢活,转圈才有进度感。
                icon: controller.scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: Text(controller.scanning ? '扫描中…(点按停止)' : '扫描相机'),
                onPressed: busy
                    ? null
                    : (controller.scanning
                        ? controller.stopScan
                        : controller.startScan),
              ),
            ),
            // 空扫指引:相机只在「等待连接」画面广播(退出即停),刚
            // 配对完的相机还停在确认画面 —— 两种都不广播,是「有时候
            // 扫不出来」的主因(2026-10-06 真机)。
            if (controller.scanning && controller.cameras.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '未发现:相机须停留在「等待连接」画面才会广播(退出该'
                  '画面即停止);若刚在相机上完成配对,先在相机上按 OK。'
                  '也可在下方手填 IP 直连。',
                  style: Theme.of(context).textTheme.bodySmall,
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
                onTap: busy ? null : () => controller.connectDiscovered(camera),
              ),
            // 扫描兜底:mDNS 发现依赖相机主动广播(菜单在「等待连接」
            // 状态才广播);已知 IP 时手填直连(独立控制器,不预填 ——
            // 预填 AP 默认地址会误拨路由器)。
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller.manualIpController,
                    keyboardType: TextInputType.url,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: '相机 IP(扫描不到时手填)',
                      hintText: '如 192.168.1.4',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : controller.connectManualIp,
                  child: const Text('连接'),
                ),
              ],
            ),
            if (controller.savedCameras.isNotEmpty)
              for (final saved in controller.savedCameras)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text('上次:${saved.name}'),
                  subtitle: Text(saved.lastIp ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 删除 = 忘记这台相机:清档案;配对过的同时换新
                      // 客户端身份,下次连接走全新配对(无感)。
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '忘记这台相机',
                        onPressed: busy
                            ? null
                            : () => _confirmRemoveSaved(context, controller, saved),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: busy ? null : () => controller.connectSaved(saved),
                ),
          ],
        ),
      ),
    );
  }

  /// 删除确认:忘记这台相机(清档案 + 配对过的换新身份 → 全新配对)。
  Future<void> _confirmRemoveSaved(
    BuildContext context,
    ConnectionController controller,
    CameraInfo saved,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '忘记这台相机?',
      content: '删除「${saved.name}」的连接记录。已配对的相机会同时换新配对身份,'
          '下次连接重新配对(自动确认,无需操作)。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed) {
      await controller.removeSaved(saved);
    }
  }

  Widget _methodTitle(BuildContext context, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        Text(text, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  // ── 已连接:相机信息总览 ─────────────────────────────────────────

  Widget _connectedView(BuildContext context, ConnectionController controller) {
    return ListenableBuilder(
      listenable: _overview,
      builder: (context, _) => ListView(
        padding: AppSpacing.screenPadding,
        children: [
          ConnectionStatusCard(state: controller.state),
          const SizedBox(height: AppSpacing.md),
          // 主操作:进入拍摄(遥控监看)。连上后第一动作,置状态卡
          // 正下方不滚动即可见;全屏 push,底栏不占监看画面,拍摄页
          // 自带返回钮。
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _openRemote,
              icon: const Icon(Icons.camera),
              label: const Text('进入拍摄'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _linkCard(context, controller),
          const SizedBox(height: AppSpacing.md),
          _bodyCard(context),
          const SizedBox(height: AppSpacing.md),
          _lensCard(context),
          const SizedBox(height: AppSpacing.md),
          const StoragePanel(),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 48,
            child: FilledButton.tonalIcon(
              onPressed: _openAlbum,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('相册'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: controller.disconnect,
              child: const Text('断开连接'),
            ),
          ),
        ],
      ),
    );
  }

  /// 连接信息卡:链路方式(有线/无线·IP)+ 设备名。
  Widget _linkCard(BuildContext context, ConnectionController controller) {
    final c = controller.connection;
    final wireless = c?.isWireless ?? false;
    final link = wireless
        ? (controller.activeIp == null
            ? 'Wi-Fi'
            : 'Wi-Fi(${controller.activeIp})')
        : 'USB 数据线';
    return Card(
      child: Column(
        children: [
          _infoRow(context, Icons.link, '连接方式', link),
          _infoRow(
              context, Icons.photo_camera_outlined, '设备', c?.deviceName ?? '--',
              last: true),
        ],
      ),
    );
  }

  /// 机身信息卡:GetDeviceInfo(型号/固件/序列号)+ 电池(属性门禁)。
  Widget _bodyCard(BuildContext context) {
    final info = _overview.deviceInfo;
    return Card(
      child: Column(
        children: [
          _infoRow(context, Icons.camera_outlined, '型号', info?.model ?? '读取中…'),
          _infoRow(context, Icons.system_update_alt_outlined, '固件版本',
              info?.deviceVersion ?? '--'),
          _infoRow(
              context, Icons.tag_outlined, '序列号', info?.serialNumber ?? '--'),
          if (_overview.batteryPercent != null)
            _infoRow(context, Icons.battery_std_outlined, '电池',
                '${_overview.batteryPercent}%',
                last: true),
        ],
      ),
    );
  }

  /// 镜头信息卡:型号(最近一张 JPG 的 EXIF)+ 焦距/光圈
  /// (属性门禁;缺读时 EXIF 兜底,行标换「最近照片」)。
  /// 光圈 0x5007 是 f 值 ×100(ISO 15740 定点)。
  Widget _lensCard(BuildContext context) {
    final overview = _overview;
    final f = overview.fNumber;
    return Card(
      child: Column(
        children: [
          _infoRow(context, Icons.camera, '镜头型号(最近照片)', overview.lens ?? '--'),
          _infoRow(
              context,
              Icons.straighten_outlined,
              overview.focalLengthFromExif ? '焦距(最近照片)' : '当前焦距',
              overview.focalLengthMm == null
                  ? '--'
                  : '${overview.focalLengthMm}mm'),
          _infoRow(
              context,
              Icons.camera_outlined,
              overview.fNumberFromExif ? '光圈(最近照片)' : '当前光圈',
              f == null ? '--' : 'ƒ/${(f / 100).toStringAsFixed(1)}',
              last: true),
        ],
      ),
    );
  }

  Widget _infoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    bool last = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 6, 16, last ? 10 : 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 进入拍摄:全屏 push 遥控监看页(返回即回相机页;拍摄页离页自动
  /// 挂起帧轮询,取景生命周期跟连接走,相机侧保持取景)。
  void _openRemote() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemotePage(controller: _remote),
      ),
    );
  }

  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGridPage(
          controller: AppServices.instance.browserController,
          folderHandle: CameraAlbum.allPhotosHandle,
          fallbackName: '相机相册',
        ),
      ),
    );
  }
}

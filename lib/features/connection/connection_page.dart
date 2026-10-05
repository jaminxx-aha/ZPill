/// 相机页(底部导航首 tab):连接入口 + 已连接相机信息总览。
///
/// 未连接:连接方式分段切换(有线 USB / AP 热点 / 同一 Wi-Fi)——
/// 切到哪种方式,下方只出该方式的连接卡;已连接:信息卡组(连接/
/// 机身/镜头/存储卡)+「相册」入口 +「断开连接」。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中弹配对码确认(相机记录本设备),已配对直连。
/// AP 模式保留手动 IP 兜底(热点下广播未实证,默认 192.168.1.1)。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/storage_info.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../data/paired_cameras_store.dart';
import '../../platform/nsd_scanner.dart';
import '../browser/photo_grid_page.dart';
import '../common/format.dart';
import 'camera_overview_controller.dart';

/// 连接方式(未连接视图的分段选择;切到哪种出哪种卡)。
enum ConnectionMethod { usb, ap, sta }

class ConnectionController extends ChangeNotifier {
  /// 注入应用级连接(全局单例状态,经 AppServices 收口)+ 扫描器与
  /// 配对档案(均可空:测试/未装配平台降级)。
  ConnectionController({
    this.connection,
    this.scanner,
    this.pairedCameras,
  }) {
    connection?.states.listen(_onState);
    // 常驻订阅:浏览期间增删相机,未浏览时静默无流。
    scanner?.events.listen(_onNsdEvent, onError: (Object _) {});
  }

  final CameraConnection? connection;
  final NsdScanner? scanner;
  final PairedCamerasStore? pairedCameras;

  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;

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

  /// 状态提示:失败原因(含插线/解锁/热点指引)、配对等待去向。
  /// 已连接不在此列 —— 已连接视图(信息卡组)自带全部信息。
  String? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    return switch (state) {
      CameraLinkState.pairing => '相机请求配对确认(见弹窗)',
      CameraLinkState.failed => c.error ?? '连接失败',
      _ => null,
    };
  }

  void _onState(CameraLinkState s) {
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
    activeIp = null;
    await c.connect();
  }

  /// 连接扫描到的相机(实例名随连接传给配对档案)。
  Future<void> connectDiscovered(DiscoveredIpCamera camera) async {
    final c = connection;
    if (c == null) {
      return;
    }
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
    activeIp = ip;
    await c.connect(ip: ip, instanceName: camera.name);
  }

  /// AP 连接(手动 IP 兜底):输入为空时回落默认网关地址。
  Future<void> connectWireless() async {
    final c = connection;
    if (c == null) {
      return;
    }
    var ip = ipController.text.trim();
    if (ip.isEmpty) {
      ip = kDefaultCameraIp;
    }
    activeIp = ip;
    await c.connect(ip: ip);
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
    super.dispose();
  }
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, this.controller, this.overview});

  /// 测试注入;缺省取应用级单例(连接是全局单例状态)。
  final ConnectionController? controller;

  /// 测试注入;缺省取应用级单例。
  final CameraOverviewController? overview;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  ConnectionController get _controller =>
      widget.controller ?? AppServices.instance.connectionController;

  CameraOverviewController get _overview =>
      widget.overview ?? AppServices.instance.cameraOverview;

  /// 配对弹窗只弹一次的哨兵(state 离开 pairing 即复位)。
  bool _pairingDialogShown = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _controller.loadSaved();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (controller.state == CameraLinkState.pairing) {
      if (!_pairingDialogShown && mounted) {
        _pairingDialogShown = true;
        _showPairingDialog(controller);
      }
    } else {
      _pairingDialogShown = false;
    }
  }

  Future<void> _showPairingDialog(ConnectionController controller) async {
    // 弹窗内容跟随控制器:等待期间链路死亡(状态离开 pairing)自动关窗。
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ListenableBuilder(
        listenable: controller,
        builder: (dialogContext, _) {
          if (controller.state != CameraLinkState.pairing) {
            // 断链/外部断开已收口:下一帧关窗(gate 已不在,
            // confirm/cancel 均为 no-op)。
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => Navigator.of(dialogContext).maybePop());
            return const SizedBox.shrink();
          }
          final code = controller.connection?.pairingCode ?? '';
          return AlertDialog(
            title: const Text('配对确认'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('配对码', style: Theme.of(dialogContext).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(code,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(letterSpacing: 12)),
                const SizedBox(height: 12),
                const Text(
                  '确认后相机会把「NikonPill」记为已配对设备,之后免配对直连;'
                  '如相机屏幕出现提示,请在机身上按 OK 确认。',
                  textAlign: TextAlign.start,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('跳过配对'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认配对'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed == true) {
      await controller.confirmPairing();
    } else {
      await controller.cancelPairing();
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
        padding: const EdgeInsets.all(16),
        children: [
          // 状态着色:disconnected 灰 / connecting 蓝 / pairing 橙 / failed 红
          _StatusCard(state: controller.state),
          if (controller.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(controller.hint!),
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
          const SizedBox(height: 12),
          Text(
            '· 首次无线连接会请求配对确认(相机记录本设备,之后免配对);'
            '相机屏幕出现提示时请在机身上按 OK。\n'
            '· 相机同一时间只允许一个客户端:若被 SnapBridge(尼享)抢先连上'
            '会遭拒,请先彻底关闭它。\n'
            '· 首次连接若失败,请在系统弹窗中允许访问本地网络后重试;'
            '下载大文件期间请保持 App 在前台、屏幕点亮。',
            style: Theme.of(context).textTheme.bodySmall,
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
                icon: Icon(controller.scanning
                    ? Icons.stop_circle_outlined
                    : Icons.wifi_find),
                label: Text(controller.scanning ? '扫描中…(点按停止)' : '扫描相机'),
                onPressed: busy
                    ? null
                    : (controller.scanning
                        ? controller.stopScan
                        : controller.startScan),
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
            if (controller.savedCameras.isNotEmpty)
              for (final saved in controller.savedCameras)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text('上次:${saved.name}'),
                  subtitle: Text(saved.lastIp ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy ? null : () => controller.connectSaved(saved),
                ),
          ],
        ),
      ),
    );
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
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(state: controller.state),
          const SizedBox(height: 12),
          _linkCard(context, controller),
          const SizedBox(height: 12),
          _bodyCard(context),
          const SizedBox(height: 12),
          _lensCard(context),
          const SizedBox(height: 12),
          const _StoragePanel(),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
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

  /// 镜头信息卡:型号(最近一张 JPG 的 EXIF)+ 当前焦距/光圈
  /// (属性门禁;缺读时 EXIF 兜底,语义同为「最近一张」)。
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
              '当前焦距',
              overview.focalLengthMm == null
                  ? '--'
                  : '${overview.focalLengthMm}mm'),
          _infoRow(context, Icons.camera_outlined, '当前光圈',
              f == null ? '--' : 'ƒ/${(f / 10).toStringAsFixed(1)}',
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final CameraLinkState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      CameraLinkState.disconnected => ('未连接', Colors.grey),
      CameraLinkState.detecting => ('检测相机 WiFi…', Colors.blue),
      CameraLinkState.connecting => ('连接中…', Colors.blue),
      CameraLinkState.pairing => ('等待配对确认…', Colors.orange),
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

/// 双卡槽余量卡:每槽一行(名 + 剩余/总容量 + 余量进度条)。相机未上报
/// 容量只显示名字;无槽不占位。(相册页删除后随相机信息卡组落户此处。)
class _StoragePanel extends StatelessWidget {
  const _StoragePanel();

  @override
  Widget build(BuildContext context) {
    final overview = AppServices.instance.storageOverview;
    return ListenableBuilder(
      listenable: overview,
      builder: (context, _) {
        final storages = overview.storages;
        if (storages.isEmpty) {
          return const SizedBox.shrink();
        }
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              children: [
                for (final storage in storages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _StorageRow(storage: storage),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.storage});

  final CameraStorage storage;

  @override
  Widget build(BuildContext context) {
    final ratio = storage.freeRatio;
    final colorScheme = Theme.of(context).colorScheme;
    // 低余量(<10%)转警示色。
    final barColor =
        ratio != null && ratio < 0.1 ? colorScheme.error : colorScheme.primary;
    return Row(
      children: [
        Icon(Icons.sd_card_outlined,
            size: 20, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(storage.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium),
              if (ratio != null) ...[
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: 1 - ratio, // 已用占比
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          storage.maxCapacityBytes > 0
              ? '${formatBytes(storage.freeSpaceBytes)} 可用 / ${formatBytes(storage.maxCapacityBytes)}'
              : '容量未知',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 相机页(底部导航首 tab):连接入口 + 已连接相机信息总览。
///
/// 未连接:连接方式分段切换(有线 USB / AP 热点 / 同一 Wi-Fi / 蓝牙)
/// —— 切到哪种方式,下方只出该方式的连接卡;蓝牙是**工具通道**(不建
/// 立相机 PTP 连接,不传图不遥控),只承载 GPS 注入与唤醒相机 WiFi
/// (2026-10-14)。已连接:信息卡组(连接/机身/镜头/存储卡)+「进入
/// 拍摄」(主操作,全屏 push 遥控监看页 —— 2026-10-08 拍摄页从底栏
/// tab 改制,置状态卡正下方不滚动即可见)+「相册」入口 +「断开连接」。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中自动配对(验证码不回传相机),相机侧弹「配对
/// 完成」等按 OK,应用保持重连等它(见 awaitingCameraConfirm);已
/// 配对直连。AP 模式相机 IP 候选序 = mDNS 发现 → join 网关(相机
/// 热点的 DHCP 网关,native 读)→ 手填兜底(默认 192.168.1.1)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/ble/wifi_credentials.dart';
import '../../core/browser/album.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../core/ptpip/probe.dart';
import '../../core/ptpip/subnet_scan.dart';
import '../../data/ble_identity_store.dart';
import '../../data/client_identity_store.dart';
import '../../data/paired_cameras_store.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/interface_addresses.dart';
import '../../platform/network_monitor.dart';
import '../../platform/nsd_scanner.dart';
import '../browser/photo_grid_page.dart';
import '../common/widgets/confirm_dialog.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_page.dart';
import '../settings/ble_pair_page.dart';
import '../settings/settings_page.dart';
import 'camera_overview_controller.dart';
import 'connection_status_card.dart';

/// 连接方式(未连接视图的分段选择;切到哪种出哪种卡)。
enum ConnectionMethod { usb, ap, sta, ble }

/// 程序化加入相机热点的结局([ConnectionController.joinCameraAp])。
enum ApJoinOutcome {
  /// 加入成功且已自动发起 AP 连接(状态沿走既定连接路)。
  joined,

  /// 加入失败(reason 在 [ConnectionController.apJoinError])。
  failed,

  /// 无法自动加入(凭据未解出 / joiner 未装配):维持手动指引。
  skipped,
}

/// AP 连接的相机 IP 候选序([ConnectionController.connectWireless]):
/// 自定义手填 → mDNS 发现 → join 网关 → 默认 192.168.1.1。相机热点
/// 网段因机型而异,网关是 join 定局沿 native 读出的 DHCP 网关(= 相机
/// 本机 IP),默认 192.168.1.1 只兜网关缺席;手填框预填默认,与默认
/// 相同即视为未自定义,顺势让位给网关(其余手填一律用户明示,直接
/// 透传)。**STA 绝不消费此序**(STA 的网关是路由器,见
/// [ConnectionController.manualIpController] 的教训注释)。
String apCameraIp({
  required String manual,
  required List<DiscoveredIpCamera> discovered,
  String? gateway,
}) {
  final typed = manual.trim();
  if (typed.isNotEmpty && typed != kDefaultCameraIp) {
    return typed;
  }
  // mDNS 候选(AP 路当前无扫描入口,为后续接入预留;旧 STA 网段的
  // 结果切进 AP 分段即清 —— 跨网段连过去只会超时):取首个发现。
  if (discovered.isNotEmpty) {
    return discovered.first.host;
  }
  final gw = gateway?.trim() ?? '';
  if (gw.isNotEmpty) {
    return gw;
  }
  return typed.isNotEmpty ? typed : kDefaultCameraIp;
}

class ConnectionController extends ChangeNotifier {
  /// 注入应用级连接(全局单例状态,经 AppServices 收口)+ 扫描器与
  /// 配对档案(均可空:测试/未装配平台降级)。BLE 三件 + 设置控制器
  /// 同样可空 —— 蓝牙工具通道在未装配平台整体降级为「未启用」。
  ConnectionController({
    this.connection,
    this.scanner,
    this.pairedCameras,
    this.identityStore,
    this.bleSession,
    this.bleIdentityStore,
    this.wifiJoiner,
    this.settingsController,
    this.onBleInjectChanged,
    this.subnetScanner,
  }) {
    connection?.states.listen(_onState);
    // 常驻订阅:浏览期间增删相机,未浏览时静默无流。
    scanner?.events.listen(_onNsdEvent, onError: (Object _) {});
    bleSession?.states.listen((s) {
      bleState = s;
      notifyListeners();
    });
    unawaited(loadBleIdentity());
  }

  final CameraConnection? connection;
  final NsdScanner? scanner;
  final PairedCamerasStore? pairedCameras;

  /// /24 网段扫描器(测试注入;null = 生产默认:真 socket 端口检查 +
  /// probeCamera 轻探测 + platform 接口地址 glue)。
  final SubnetCameraScanner? subnetScanner;

  /// 客户端身份(删除已配对相机时换新,触发全新配对;见 [removeSaved])。
  final ClientIdentityStore? identityStore;

  /// 蓝牙工具通道(GPS 注入 / 唤醒 WiFi;不参与相机 PTP 连接状态)。
  final BleCameraSession? bleSession;
  final BleIdentityStore? bleIdentityStore;

  /// 程序化加入相机热点(`nikonpill/network` join;Android 已实现,
  /// iOS/ohos 未装配 → joinCameraAp 走 skipped 手动指引)。
  final WifiJoiner? wifiJoiner;
  final SettingsController? settingsController;

  /// BLE 注入开关落库后的刷新钩子(装配沿接 AppServices.refreshBle
  /// Injection,驱动按开关起停;测试注入可空)。
  final void Function()? onBleInjectChanged;

  final ipController = TextEditingController(text: kDefaultCameraIp);

  CameraLinkState state = CameraLinkState.disconnected;

  /// 配对后的机身确认等待窗:pairing → connecting 沿置位(连接层此窗
  /// 保持 connecting 安静重试),离开 connecting 即清。真机(2026-10-06):
  /// 0x935A 后相机弹「配对完成」等机身上按 OK,按之前重连全被拒 ——
  /// UI 用此旗出「请在相机上按 OK」指引,不闪失败横幅。
  bool awaitingCameraConfirm = false;

  /// 当前选中的连接方式(未连接视图分段;默认有线)。
  ConnectionMethod method = ConnectionMethod.usb;

  /// 切换连接方式;离开 STA 时若在扫描顺手停掉(结果已不可见)。切进
  /// AP 分段清 mDNS 结果:那是旧网络(路由器网段)的发现,拿去连相机
  /// 热点只会得到跨网段的超时失败。
  void selectMethod(ConnectionMethod m) {
    if (m == method) {
      return;
    }
    if (scanning && m != ConnectionMethod.sta) {
      stopScan();
    }
    if (m == ConnectionMethod.ap) {
      _cameras.clear();
      // /24 扫描结果同 mDNS 结果一并清:那是旧网络(路由器网段)的
      // 发现,拿去连相机热点只会得到跨网段的超时失败。
      _subnetCameras.clear();
      _subnetScanCompleted = false;
    }
    method = m;
    notifyListeners();
  }

  /// 本次连接的无线 IP(已连接视图的「连接方式」行;USB 连接为 null)。
  String? activeIp;

  // ── 蓝牙工具通道(GPS 注入 / 唤醒 WiFi;独立于 PTP 链路) ─────────

  /// BLE 会话状态镜像(bleSession.states 回放;未装配恒 idle)。
  BleSessionState bleState = BleSessionState.idle;

  /// 已配对身份(身份存储镜像;配对页落档后经 [loadBleIdentity] 刷新)。
  BlePairedIdentity? bleIdentity;

  /// BLE 注入开关镜像(settingsController 变更即跟;未装配恒 false)。
  bool get bleGpsInject => settingsController?.value.bleGpsInject ?? false;

  /// BLE 就绪 = 会话 ready(GPS 开关/唤醒 WiFi 的门禁)。
  bool get bleReady => bleState == BleSessionState.ready;

  /// BLE 通道是否装配(未装配平台不出蓝牙分段)。
  bool get bleEnabled =>
      bleSession != null && bleIdentityStore != null;

  /// 重载已配对身份(页面进沿/配对页返回沿调用;身份落档后卡片即从
  /// 「未配对」翻到「已配对」)。
  Future<void> loadBleIdentity() async {
    final saved = await bleIdentityStore?.load();
    if (bleIdentity != saved) {
      bleIdentity = saved;
      notifyListeners();
    }
  }

  /// BLE 手动重连一次(复用身份;失败原因看会话 lastError,UI 读
  /// [bleHint])。自动重连由注入驱动承担(开关开着时),此钮覆盖「只
  /// 想唤醒 WiFi 不开注入」的场景。
  Future<void> bleReconnect() async {
    final session = bleSession;
    if (session == null ||
        session.identity == null ||
        (bleState != BleSessionState.idle &&
            bleState != BleSessionState.reconnecting)) {
      return;
    }
    await session.retryReconnect();
  }

  /// BLE 断开(身份保留)。
  Future<void> bleDisconnect() async {
    await bleSession?.disconnect();
  }

  /// GPS 注入开关(连接页/拍摄浮层芯片双入口,同一条设置路);落库
  /// 后经钩子刷新注入驱动。
  Future<void> setBleGpsInject(bool on) async {
    await settingsController?.setBleGpsInject(on);
    onBleInjectChanged?.call();
  }

  /// 唤醒相机 WiFi 全程(SnapBridge 序,反编译实证 CameraConnectByWiFi
  /// UseCase):①ready 态先读 0x2004(凭据配对期已生成,官方读在写前;
  /// 读失败不清旧值 —— 凭据随机身配置不轮换,瞬时失败不该抹掉已展示
  /// 的卡)②写 0x2005=0x01 ③成功沿**主动断开 BLE** —— 相机要等链路
  /// 释放才真正开热点(真机 2026-10-14:握着链路热点不出来),SnapBridge
  /// 写后也不等 BLE 应答直接转 Wi-Fi 路(Join AP → Bonjour → PTP/IP)。
  /// 身份保留,「重连」即回;GPS 注入随断链暂停。返回唤醒是否成功;
  /// 失败原因看 [bleLastError](读凭据或写 0x2005 的,读失败不清旧错)。
  Future<bool> wakeCameraWifi() async {
    final session = bleSession;
    if (session == null) return false;
    final creds = await session.readWifiCredentials();
    final ok = await session.wakeCameraWifi();
    if (!ok) return false;
    if (creds != null) {
      cameraApCredentials = creds;
      notifyListeners();
    }
    await session.disconnect();
    return true;
  }

  /// 最近一次程序化加入失败原因(joinCameraAp 落账;终态文案如实用)。
  String? apJoinError;

  /// 最近一次 join 相机热点的 DHCP 网关(= 相机 IP 候选;join 定局沿
  /// native 读,拿不到/失败为 null,失败保留上次 —— 相机 AP 的网段不
  /// 随连接轮次变)。**只有 AP 路(connectWireless)消费**:STA 的
  /// 网关是路由器,连它只会得到莫名超时。
  String? apGateway;

  /// 断链后程序化加入相机热点并自动接续 AP 连接(BLE→WiFi 交接最后
  /// 一段,SnapBridge 全程:0x2004 凭据 → 写 0x2005 断 BLE → join →
  /// PTP/IP)。凭据缺 / joiner 未装配(iOS/ohos/测试)→ skipped,UI
  /// 维持手动指引;join 成功沿切到 AP 分段并**发射** connectWireless
  /// (不等待 —— 连接进度/失败/重试全走既定连接卡状态机,与手点
  /// 「AP 连接」同路;进程路由已由 native 在 onAvailable 沿绑到相机
  /// 网,socket 直达网关(缺席回落默认 192.168.1.1))。
  Future<ApJoinOutcome> joinCameraAp() async {
    final joiner = wifiJoiner;
    final creds = cameraApCredentials;
    if (joiner == null || creds == null) {
      return ApJoinOutcome.skipped;
    }
    final r = await joiner.join(
      ssid: creds.ssid,
      password: creds.password,
      security: creds.security,
    );
    if (!r.ok) {
      apJoinError = r.reason;
      return ApJoinOutcome.failed;
    }
    // join 定局沿的网关落账(候选序见 connectWireless;失败保留上次)
    apGateway = r.gateway;
    selectMethod(ConnectionMethod.ap);
    unawaited(connectWireless());
    return ApJoinOutcome.joined;
  }

  /// 关闭相机 Wi-Fi(0x2005=0x80)。「关闭」接口必须传图后够得着:
  /// 传图全程 BLE 断开,故非 ready 态先补链(retryReconnect 至多 2 轮)
  /// 再写。相机热点期可能不广播蓝牙(n-link 实证 Z50II 热点在 PTP 会话
  /// 结束 ~34s 后自行消失 —— 机身本就有自动收尾,0x80 是显式关断的补
  /// 充),两轮无命中如实落 lastError,相机菜单可关。成功后 BLE 保持
  /// 连接(无线单元空出),注入驱动 ready 沿自动续定位流。
  Future<bool> closeCameraWifi() async {
    final session = bleSession;
    if (session == null) return false;
    if (bleState != BleSessionState.ready) {
      var reconnected = false;
      for (var attempt = 0; attempt < 2 && !reconnected; attempt++) {
        reconnected = await session.retryReconnect();
        if (!reconnected && attempt == 0) {
          await Future<void>.delayed(session.nextRetryDelay);
        }
      }
      if (!reconnected) {
        session.lastError = '重连无命中(相机热点期可能不广播蓝牙),'
            '可从相机菜单关闭 Wi-Fi';
        return false;
      }
    }
    return await session.closeCameraWifi();
  }

  /// 相机 AP 凭据(0x2004 蓝牙通道解出;null = 未读/解密未中/未 ready)。
  /// BLE→WiFi 二期:唤醒成功沿自动读取,AP 卡凭据块展示。
  WifiCredentials? cameraApCredentials;

  /// 读相机 AP 凭据(0x2004 读 + 解密;唤醒沿自动调,也可手动重读)。
  /// 返回是否取得;失败原因看 [bleLastError]。
  Future<bool> loadCameraApCredentials() async {
    final creds = await bleSession?.readWifiCredentials();
    cameraApCredentials = creds;
    notifyListeners();
    return creds != null;
  }

  /// BLE 卡状态副文(未装配不显示卡;状态全映射)。
  String? get bleHint {
    final session = bleSession;
    if (session == null) {
      return null;
    }
    if (bleState == BleSessionState.reconnecting ||
        (bleState == BleSessionState.idle &&
            session.lastError != null)) {
      return session.lastError;
    }
    return null;
  }

  /// 最近一次会话错误(WiFi 动作失败的 SnackBar 用;bleHint 只在
  /// 重连/断开态回错误,ready 态写失败也能如实带出原因)。
  String? get bleLastError => bleSession?.lastError;

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
  /// 文案即 t() 键(测试断言中文原文,故控制器存中文不存消息记录),
  /// 消费端 ConnectionStatusCard._HintText 统一包 t();连接层 error
  /// 未抽取的如实回落中文。
  String? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    if (awaitingCameraConfirm && state == CameraLinkState.connecting) {
      return 'conn.pairingSent';
    }
    return switch (state) {
      CameraLinkState.pairing => 'conn.pairingAuto',
      // 恢复循环的动态文案(退避分类/busy 慢拍/初始断链原因):连接层
      // 只改 error 不发状态沿,本页 build 期读到的是最近一次。
      CameraLinkState.reconnecting => c.error ?? 'conn.reconnectAuto',
      CameraLinkState.failed => c.error ?? 'conn.failed',
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
    // 无线链路收尾沿释放进程网络绑定:join 相机热点沿 native 把路由
    // 绑到了相机网(specifier 网络无互联网),不释放会吃掉外网路由。
    // 幂等,未持有时无操作。
    if (s == CameraLinkState.disconnected || s == CameraLinkState.failed) {
      final joiner = wifiJoiner;
      if (joiner != null) {
        unawaited(joiner.release());
      }
    }
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

  // ── /24 网段扫描(mDNS 无结果时的 STA 发现兜底) ────────────────
  // 真机教训硬约束(完整版见 core/ptpip/probe.dart 库注):未完成方言
  // 的连接可能占配对槽(相机一次只认一个会话)。因此:
  // ① 只有 mDNS 结果为空时才允许扫描;
  // ② 会话活跃(已连接/连接中)时禁止探测;
  // ③ 扫描轮内不重入,开放主机串行探测、失败不重试同一主机;
  // ④ 绝不并发对同一主机双探测(扫描器内部保证串行)。

  /// /24 扫描结果(相机名/name 空 = 相机被拒 InitFail,UI 以 IP 展示)。
  final _subnetCameras = <ProbedCamera>[];
  List<ProbedCamera> get subnetCameras =>
      List.unmodifiable(_subnetCameras);

  /// /24 扫描进行中(入口按钮转圈/禁用)。
  bool scanningSubnet = false;

  /// 最近一轮 /24 扫描已收口(空结果提示的判据)。
  bool _subnetScanCompleted = false;

  /// 最近一轮 /24 扫描已收口(UI 只读判据)。
  bool get subnetScanCompleted => _subnetScanCompleted;

  /// 扫描本机所在 /24 网段(用户显式触发,不自动):端口检查收集
  /// 15740 开放主机 → 串行 InitCommandRequest 轻探测(相机名+GUID)。
  /// 门禁(硬约束①②③):mDNS 已有结果 / 会话活跃 / 扫描在途 → 不动作。
  Future<void> scanSubnet() async {
    // ① mDNS 已发现相机:探测连接纯属对单连接槽位的无谓打扰。
    if (_cameras.isNotEmpty) {
      return;
    }
    // ② 会话活跃(已连接/连接中/配对/恢复中):探测 socket 可能占槽,
    //    把正轨连接挤成 InitFail 0x1。
    switch (state) {
      case CameraLinkState.connected:
      case CameraLinkState.connecting:
      case CameraLinkState.pairing:
      case CameraLinkState.reconnecting:
        return;
      case CameraLinkState.disconnected:
      case CameraLinkState.failed:
      case CameraLinkState.detecting:
        break;
    }
    // ③ 扫描轮内不重入(重入会并发对同一主机双探测)。
    if (scanningSubnet) {
      return;
    }
    scanningSubnet = true;
    _subnetCameras.clear();
    _subnetScanCompleted = false;
    notifyListeners();
    try {
      final identity = await identityStore?.load();
      final scanner = subnetScanner ??
          SubnetCameraScanner(
            interfaceIps: currentIpv4InterfaceAddresses,
            // 探测与真连接同一客户端身份(相机按 GUID 识别客户端,
            // 陌生 GUID 的半开会话更易呛住,见 probe.dart 库注)。
            clientGuid: identity?.uuid,
            hostname: identity?.name ?? 'Android Device',
          );
      final found = await scanner.scan();
      // 收口沿才落账:扫描期间切走分段,迟到的结果如实可见(仍在
      // 同一网络;切到 AP 分段已由 selectMethod 清空)。
      _subnetCameras
        ..clear()
        ..addAll(found);
    } finally {
      scanningSubnet = false;
      _subnetScanCompleted = true;
      notifyListeners();
    }
  }

  /// 点选 /24 扫描结果连接:走既有 STA 连接流(真方言 13 步 + 配对相;
  /// 探测只是问路,连接不复用探测 socket)。被拒相机(InitFail)也照
  /// 连 —— 占用指引由连接层失败文案给出。
  Future<void> connectProbed(ProbedCamera camera) async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = () => connectProbed(camera);
    activeIp = camera.host;
    await c.connect(
      ip: camera.host,
      instanceName: camera.name.isNotEmpty ? camera.name : null,
    );
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
  /// 192.168.1.1 在 STA 网段多半是路由器,预填即误拨;网关同理
  /// (join 网关只进 AP 路,STA 的网关是路由器)。
  final manualIpController = TextEditingController();

  /// AP 连接:相机 IP 候选序 = 自定义手填 → mDNS 发现 → join 网关 →
  /// 默认 192.168.1.1(见 [apCameraIp];手填框预填默认,未自定义时
  /// 顺势网关优先)。**绝不消费于 STA**(STA 网关是路由器)。
  Future<void> connectWireless() async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = connectWireless;
    final ip = apCameraIp(
      manual: ipController.text,
      discovered: cameras,
      gateway: apGateway,
    );
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

/// 蓝牙工具卡状态文案(未配对/已配对未连/握手中/已连接/重连中)。
/// 返回 = t() 键(与 ble_pair_page 共用),消费端 _bleCard 里包 t()。
String bleStateLabel(ConnectionController c) => switch (c.bleState) {
      BleSessionState.pairing => 'ble.handshaking',
      BleSessionState.ready => 'conn.connected',
      BleSessionState.reconnecting => 'ble.reconnecting',
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
      appBar: AppBar(title: Text(context.t('shell.camera'))),
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
      CameraLinkState.connecting ||
      CameraLinkState.pairing ||
      CameraLinkState.reconnecting => true,
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
          // 文案(不闪失败)。蓝牙分段下不出 PTP 状态卡(蓝牙不建
          // 立相机连接,PTP 链路态与本卡无关,防误导)。
          if (controller.method != ConnectionMethod.ble)
            ConnectionStatusCard(
              state: controller.state,
              waitingConfirm: controller.awaitingCameraConfirm,
              hint: controller.hint,
              onRetry: controller.retry,
            ),
          // connecting/reconnecting 逃生口:输入框/按钮全禁用期间(死 IP
          // 的 TCP 超时最长 ~3s,建链/开会话/切模式另有 10s 总预算;自动
          // 重连的退避可拖到分钟级),用户得有取消手段,否则像「卡死」。
          if (controller.method != ConnectionMethod.ble &&
              (controller.state == CameraLinkState.connecting ||
                  controller.state == CameraLinkState.reconnecting))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: controller.state == CameraLinkState.reconnecting
                    ? Text(context.t('conn.cancelReconnect'))
                    : Text(context.t('conn.cancelConnect')),
                onPressed: controller.disconnect,
              ),
            ),
          const SizedBox(height: 16),

          // 分段切换:切到哪种方式,下方只出该方式的连接卡。蓝牙分段
          // 仅在 BLE 通道装配时出现(未装配平台不出)。
          SegmentedButton<ConnectionMethod>(
            segments: [
              ButtonSegment(
                  value: ConnectionMethod.usb,
                  icon: const Icon(Icons.usb),
                  label: Text(context.t('conn.wired'))),
              ButtonSegment(
                  value: ConnectionMethod.ap,
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(context.t('conn.apHotspot'))),
              ButtonSegment(
                  value: ConnectionMethod.sta,
                  icon: const Icon(Icons.wifi),
                  label: Text(context.t('conn.sameWifi'))),
              if (controller.bleEnabled)
                ButtonSegment(
                    value: ConnectionMethod.ble,
                    icon: const Icon(Icons.bluetooth),
                    label: Text(context.t('conn.bluetooth'))),
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
            ConnectionMethod.ble => _bleCard(context, controller),
          },
          if (controller.method != ConnectionMethod.ble) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                context.t(
                  'conn.wirelessNotes',
                ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 蓝牙工具卡:连接(配对/重连/断开)+ GPS 注入开关 + 唤醒/关闭
  /// 相机 WiFi。蓝牙**不建立相机连接**(不传图不遥控)—— PTP 链路
  /// 状态卡在本分段下隐藏,防把工具通道误读成已连接。
  Widget _bleCard(BuildContext context, ConnectionController controller) {
    final theme = Theme.of(context);
    final ready = controller.bleReady;
    final hasIdentity = controller.bleIdentity != null;
    final stateColor = switch (controller.bleState) {
      BleSessionState.ready => Colors.green,
      BleSessionState.pairing || BleSessionState.reconnecting => Colors.orange,
      BleSessionState.idle =>
        hasIdentity ? theme.colorScheme.outline : Colors.grey,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _methodTitle(context, Icons.bluetooth, 'conn.btTools'),
            const SizedBox(height: 4),
            Text(context.t('conn.btToolsHint')),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.circle, size: 10, color: stateColor),
              const SizedBox(width: 6),
              Text(context.t(bleStateLabel(controller))),
              if (hasIdentity)
                Text('  ·  ${controller.bleIdentity!.controllerName}',
                    style: theme.textTheme.bodySmall),
            ]),
            if (controller.bleHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(controller.bleHint!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 12),
            // 状态动作行:未配对 → 配对;已配对未连 → 重连;就绪 → 断开。
            SizedBox(
              width: double.infinity,
              child: !hasIdentity
                  ? FilledButton.icon(
                      icon: const Icon(Icons.bluetooth_searching),
                      label: Text(context.t('conn.pairCamera')),
                      onPressed: () => _openBlePairPage(controller),
                    )
                  : (ready
                      ? OutlinedButton(
                          onPressed: controller.bleDisconnect,
                          child: Text(context.t('conn.disconnectBt')),
                        )
                      : OutlinedButton(
                          onPressed: controller.bleState ==
                                  BleSessionState.pairing
                              ? null
                              : () => unawaited(controller.bleReconnect()),
                          child: Text(
                              controller.bleState == BleSessionState.pairing
                                  ? context.t('ble.handshaking')
                                  : context.t('conn.reconnect')),
                        )),
            ),
            const SizedBox(height: 8),
            // GPS 注入开关(就绪才可用;开着时驱动自动维持重连与注入)。
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: controller.bleGpsInject,
              // 门禁:已配对即可开 —— 开关注入驱动自己会连(重连退避),
              // 不必先手动重连成功(与拍摄浮层「GPS」芯片同语义)。
              onChanged: hasIdentity
                  ? (on) => unawaited(controller.setBleGpsInject(on))
                  : null,
              title: Text(context.t('conn.gpsInjection')),
              subtitle: Text(context.t('conn.gpsInjectionHint')),
            ),
            // WiFi 唤起(就绪才可用):先读 0x2004 凭据(SnapBridge 序)
            // 再写 0x2005,成功沿断 BLE —— 相机等链路释放才开热点;关闭
            // = 反义 op(0x80),不断链。
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(context.t('conn.wakeCameraWifi')),
                  onPressed: ready
                      ? () => unawaited(_wakeWifiWithCredentials(controller))
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  // 门禁 = 有身份(传图后 BLE 断开是常态,方法内先补链
                  // 再写 0x80);握手/relink 中禁用。
                  onPressed: hasIdentity &&
                          controller.bleState != BleSessionState.pairing
                      ? () => unawaited(_bleWifiAction(
                          controller, controller.closeCameraWifi,
                          success: context.t('conn.wifiOffRequested')))
                      : null,
                  child: Text(context.t('common.off')),
                ),
              ),
            ]),
            TextButton(
              onPressed: ready
                  ? () => unawaited(_loadApCredentials(controller))
                  : null,
              child: Text(context.t('conn.readCredentials')),
            ),
            TextButton(
              onPressed: () => _openBlePairPage(controller),
              child: Text(context.t('conn.pairingManage')),
            ),
          ],
        ),
      ),
    );
  }

  /// 唤醒相机 WiFi(BLE→WiFi 交接):[ConnectionController.wakeCameraWifi]
  /// 全程 = 读 0x2004(SnapBridge 序)→ 写 0x2005=0x01 → 成功沿断 BLE
  /// (相机等链路释放才开热点)。凭据解出且平台装配 joiner → 接着程序
  /// 化加入热点并自动发起 AP 连接([ConnectionController.joinCameraAp],
  /// SnapBridge 全程);否则维持手动指引(密码看相机屏幕)。GPS 注入随
  /// 断链暂停,传图完蓝牙卡「关闭」关相机 Wi-Fi、「重连」恢复蓝牙。
  Future<void> _wakeWifiWithCredentials(ConnectionController controller) async {
    final ok = await controller.wakeCameraWifi();
    if (!mounted) return;
    if (!ok) {
      _showHint(
          controller,
          context.t('conn.wakeFailed',
              {'e': controller.bleLastError ?? context.t('common.unknown')}));
      return;
    }
    final creds = controller.cameraApCredentials;
    if (creds == null || controller.wifiJoiner == null) {
      // 无法自动加入(凭据未解出 / 平台未装配 joiner):手动指引如实。
      _showHint(
        controller,
        creds != null
            ? context.t(
                'conn.wifiAwakeCred',
                {'ssid': creds.ssid})
            : context.t(
                'conn.wifiAwakeNoCred',
                {'e': controller.bleLastError ?? context.t('conn.notSent')}),
        duration: const Duration(seconds: 5),
      );
      return;
    }
    // 自动加入路上:join 看门狗 30s 兜底,过渡提示给足时长。
    _showHint(
        controller,
        context.t('conn.joiningHotspot',
            {'ssid': creds.ssid}),
        duration: const Duration(seconds: 30));
    final outcome = await controller.joinCameraAp();
    if (!mounted) return;
    if (outcome == ApJoinOutcome.joined) {
      _showHint(
          controller,
          context.t('conn.joinedHotspot',
              {'ssid': creds.ssid}),
          duration: const Duration(seconds: 5));
    } else if (outcome == ApJoinOutcome.failed) {
      _showHint(
        controller,
        context.t('conn.autoJoinFailed',
            {'e': controller.apJoinError ?? context.t('common.unknown')}),
        duration: const Duration(seconds: 5),
      );
    } else {
      // skipped:防御路(joiner 在 wake 后被置空等)—— 手动指引兜底。
      _showHint(
        controller,
        context.t(
            'conn.wifiAwake',
            {'ssid': creds.ssid}),
        duration: const Duration(seconds: 5),
      );
    }
  }

  /// 手动读凭据(唤醒早于配对/重试场景):结果如实回 SnackBar。
  Future<void> _loadApCredentials(ConnectionController controller) async {
    final got = await controller.loadCameraApCredentials();
    if (!mounted) return;
    final creds = controller.cameraApCredentials;
    _showHint(
        controller,
        got && creds != null
            ? context.t('conn.hotspotDecoded',
                {'ssid': creds.ssid})
            : context.t('conn.noCredentials',
                {'e': controller.bleLastError ?? context.t('common.unknown')}));
  }

  void _showHint(ConnectionController controller, String message,
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

  /// 配对页往返:返回沿重载身份(配对/解除后卡片状态即翻新)。
  Future<void> _openBlePairPage(ConnectionController controller) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BlePairPage()),
    );
    await controller.loadBleIdentity();
  }

  /// WiFi 唤起/关闭动作收口:失败 SnackBar 如实(含原因),成功提示
  /// 下一步去向(到系统 Wi-Fi 加入热点)。
  Future<void> _bleWifiAction(
    ConnectionController controller,
    Future<bool> Function() action, {
    required String success,
  }) async {
    final ok = await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? success
          : context.t('conn.opFailed',
              {'e': controller.bleLastError ?? context.t('common.unknown')})),
      duration: const Duration(seconds: 3),
    ));
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
            _methodTitle(context, Icons.usb, 'conn.methodUsb'),
            const SizedBox(height: 4),
            Text(context.t('conn.usbHint')),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : controller.connect,
                child: Text(context.t('conn.usbConnect')),
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
            _methodTitle(context, Icons.wifi_tethering, 'conn.methodAp'),
            const SizedBox(height: 4),
            Text(context.t('conn.apMenuHint')),
            ..._apCredentialBlock(context, controller),
            const SizedBox(height: 12),
            TextField(
              controller: controller.ipController,
              keyboardType: TextInputType.url,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: context.t('conn.cameraIpDefault'),
                hintText: kDefaultCameraIp,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : controller.connectWireless,
                child: Text(context.t('conn.apConnect')),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.t('conn.apTakeoverNote'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// AP 卡凭据块(蓝牙通道解出才显示):SSID/密码/安全 + 复制钮 ——
  /// 系统设置加入热点用;密码空(开放网络)不渲染行。
  List<Widget> _apCredentialBlock(
    BuildContext context,
    ConnectionController controller,
  ) {
    final creds = controller.cameraApCredentials;
    if (creds == null) {
      return const [];
    }
    return [
      const SizedBox(height: 12),
      Text(context.t('conn.hotspotCred'),
          style: Theme.of(context).textTheme.labelMedium),
      _credentialRow(context, 'SSID', creds.ssid),
      if (creds.password.isNotEmpty)
        _credentialRow(context, 'conn.password', creds.password),
      Text(
          context.t('conn.security',
              {'s': creds.securityLabel}),
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  Widget _credentialRow(
    BuildContext context,
    String label,
    String value,
  ) {
    // label 原文即键(SSID 非中文,未命中原文直返);tooltip/SnackBar
    // 以 {label} 参数复用同一模板。
    final localizedLabel = context.t(label);
    return Row(
      children: [
        SizedBox(width: 44, child: Text(localizedLabel)),
        Expanded(
          child: Text(value.isEmpty ? context.t('common.empty') : value,
              style: const TextStyle(fontFamily: 'monospace')),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: context.t('conn.copyLabel', {'label': localizedLabel}),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(context.t('conn.copiedLabel',
                    {'label': localizedLabel})),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
      ],
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
            _methodTitle(context, Icons.wifi, 'conn.methodSta'),
            const SizedBox(height: 4),
            Text(context.t('conn.staHint')),
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
                label: Text(controller.scanning
                    ? context.t('conn.scanningStop')
                    : context.t('conn.scanCameras')),
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
                  context.t('conn.scanNothingHint'),
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
            // /24 网段扫描兜底(mDNS 无结果时;用户显式触发,不自动):
            // 端口检查 + InitCommandRequest 轻探测(约束与真机教训见
            // core/ptpip/probe.dart 库注)。mDNS 已有结果时不出 —— 探测
            // 连接是对相机单连接槽位的打扰,能免则免。
            if (controller.cameras.isEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  // 扫描中 icon 槽换 spinner(全网段一轮最坏 ~10s)。
                  icon: controller.scanningSubnet
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                  label: Text(controller.scanningSubnet
                      ? context.t('conn.scanningSubnet')
                      : context.t('conn.scanSubnet')),
                  onPressed: busy || controller.scanningSubnet
                      ? null
                      : controller.scanSubnet,
                ),
              ),
              for (final camera in controller.subnetCameras)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.photo_camera_outlined),
                  // name 空(InitFail 被拒)→ 显示 IP;被拒相机也照连,
                  // 占用指引由连接层失败文案给出。
                  title: Text(
                      camera.name.isNotEmpty ? camera.name : camera.host),
                  subtitle: Text(camera.rejected
                      ? context.t('conn.probeRejected')
                      : camera.host),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () => controller.connectProbed(camera),
                ),
              if (controller.subnetScanCompleted &&
                  controller.subnetCameras.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.t('conn.subnetNothing'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
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
                    decoration: InputDecoration(
                      labelText: context.t('conn.cameraIpManual'),
                      hintText: context.t('conn.ipExample'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : controller.connectManualIp,
                  child: Text(context.t('conn.connect')),
                ),
              ],
            ),
            if (controller.savedCameras.isNotEmpty)
              for (final saved in controller.savedCameras)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(context.t('conn.lastCamera', {'name': saved.name})),
                  subtitle: Text(saved.lastIp ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 删除 = 忘记这台相机:清档案;配对过的同时换新
                      // 客户端身份,下次连接走全新配对(无感)。
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: context.t('conn.forgetCamera'),
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
      title: context.t('conn.forgetConfirm'),
      content: context.t(
          'conn.forgetBody',
          {'name': saved.name}),
      confirmLabel: context.t('common.delete'),
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
        // 四处调用全传中文原文(即键),就地统一包 t()。
        Text(context.t(text), style: Theme.of(context).textTheme.titleMedium),
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
              label: Text(context.t('conn.enterShooting')),
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
              label: Text(context.t('conn.album')),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: controller.disconnect,
              child: Text(context.t('conn.disconnectConn')),
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
        : context.t('conn.usbCable');
    return Card(
      child: Column(
        children: [
          _infoRow(context, Icons.link, 'info.link', link),
          _infoRow(
              context, Icons.photo_camera_outlined, 'info.device', c?.deviceName ?? '--',
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
          _infoRow(context, Icons.camera_outlined, 'info.model', info?.model ?? 'info.loading'),
          _infoRow(context, Icons.system_update_alt_outlined, 'info.firmware',
              info?.deviceVersion ?? '--'),
          _infoRow(context, Icons.tag_outlined, 'info.serial',
              info?.serialNumber ?? '--'),
          if (_overview.batteryPercent != null)
            _infoRow(context, Icons.battery_std_outlined, 'info.battery',
                '${_overview.batteryPercent}%',
                last: true),
        ],
      ),
    );
  }

  /// 镜头信息卡:型号([CameraOverviewController.lensDisplay] ——
  /// LensID 映射营销名全称,未收录退规格描述,不拍照)+ 焦距/光圈
  /// (属性门禁)。光圈 0x5007 是 f 值 ×100、焦距 0x5008 是 0.01mm
  /// (ISO 15740 定点族)。
  Widget _lensCard(BuildContext context) {
    final overview = _overview;
    final f = overview.fNumber;
    return Card(
      child: Column(
        children: [
          _infoRow(context, Icons.camera, 'info.lensModel',
              overview.lensDisplay ?? '--'),
          _infoRow(
            context,
            Icons.straighten_outlined,
            'info.focal',
            overview.focalLengthMm == null
                ? '--'
                : _formatFocalMm(overview.focalLengthMm!),
          ),
          _infoRow(
            context,
            Icons.camera_outlined,
            'info.aperture',
            f == null ? '--' : 'ƒ/${(f / 100).toStringAsFixed(1)}',
            last: true,
          ),
        ],
      ),
    );
  }

  /// 焦距显示:整值不带小数(40mm),非整带一位(35.5mm)。
  String _formatFocalMm(double mm) => mm == mm.roundToDouble()
      ? '${mm.toInt()}mm'
      : '${mm.toStringAsFixed(1)}mm';

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
          // 定宽标签列 + 左对齐值列:各卡所有行同 x 起点成表格状
          //(2026-10-09 真机反馈「数据歪歪扭扭」修 —— 原右对齐值列
          // 左缘参差)。label/值都可能传 UI 中文(连接方式/USB 数据线/
          // 读取中…),就地统一包 t();相机上报值未命中目录原样直返。
          SizedBox(
            width: 68,
            child: Text(context.t(label),
                style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.t(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
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
          fallbackName: context.t('conn.cameraAlbum'),
        ),
      ),
    );
  }
}

/// ConnectionController:连接 ViewModel(ChangeNotifier)—— 连接/
/// 扫描/配对/AP 加入/蓝牙工具通道的全部业务沿;页面层禁止直连协议层。
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

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart' show TextEditingController;

import '../../l10n/message.dart';
import '../settings/settings_page.dart';

import '../../core/ble/ble_camera_session.dart';
import '../../core/ble/wifi_credentials.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/camera/camera_discovery.dart';
import '../../core/camera/camera_info.dart';
import '../../core/ptpip/probe.dart';
import '../../core/ptpip/subnet_scan.dart';
import '../../data/ble_identity_store.dart';
import '../../data/client_identity_store.dart';
import '../../core/camera/paired_cameras_store.dart';
import '../../platform/interface_addresses.dart';
import '../../platform/network_monitor.dart';
import '../../platform/nsd_scanner.dart';

/// 连接方式(未连接视图;右上角弹层选择,中央按钮按方式直连)。
enum ConnectionMethod { usb, ap, sta, ble }

/// 持久化名 → 方式(表外值/未知名回 null,调用方兜底;data 层
/// AppSettings.connectionMethod 只存枚举名,不反向依赖本枚举)。
ConnectionMethod? connectionMethodFromName(String? name) {
  for (final m in ConnectionMethod.values) {
    if (m.name == name) {
      return m;
    }
  }
  return null;
}

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
/// mDNS 发现 → join 网关 → 默认 192.168.1.1(2026-10-17 砍手填:候选
/// 序自动兜底)。相机热点网段因机型而异,网关是 join 定局沿 native
/// 读出的 DHCP 网关(= 相机本机 IP),默认只兜网关缺席。**STA 绝不
/// 消费此序**(STA 的网关是路由器,STA 手填 IP 是另一条路
/// [ConnectionController.connectManualIp])。
String apCameraIp({
  required List<DiscoveredIpCamera> discovered,
  String? gateway,
}) {
  // mDNS 候选(AP 路当前无扫描入口,为后续接入预留;旧 STA 网段的
  // 结果切进 AP 方式即清 —— 跨网段连过去只会超时):取首个发现。
  if (discovered.isNotEmpty) {
    return discovered.first.host;
  }
  final gw = gateway?.trim() ?? '';
  if (gw.isNotEmpty) {
    return gw;
  }
  return kDefaultCameraIp;
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
    this.subnetScanner,
  }) {
    connection?.states.listen(_onState);
    // 常驻订阅:浏览期间增删相机,未浏览时静默无流。
    scanner?.events.listen(_onNsdEvent, onError: (Object _) {});
    bleSession?.states.listen((s) {
      bleState = s;
      // 会话离开 idle(连接/握手中/就绪)= 系统蓝牙配对环节已被越过或
      // 无需再做:iOS 首配红卡即时撤下。
      if (s != BleSessionState.idle) {
        bleAwaitSystemBond = false;
      }
      notifyListeners();
    });
    // 错误沿实时上屏:失败/成功清空都即时刷新,不等无关状态跃迁
    //(BLE 弹层 ListenableBuilder 直吃这里)。
    _bleErrorSub = bleSession?.errors.listen((_) => notifyListeners());
    unawaited(loadBleIdentity());
    // 上次选中的连接方式恢复:settingsController 异步装载,装载沿经
    // 监听回填(用户本会话已选过则不覆盖,见 _onSettingsChanged)。
    settingsController?.addListener(_onSettingsChanged);
  }

  final CameraConnection? connection;
  final NsdScanner? scanner;

  /// BLE 错误沿订阅(lastError 实时刷新用),dispose 收。
  StreamSubscription<L10nMessage?>? _bleErrorSub;
  final PairedCamerasStore? pairedCameras;

  /// /24 网段扫描器(测试注入;null = 生产默认:真 socket 端口检查 +
  /// probeCamera 轻探测 + platform 接口地址 glue)。
  final SubnetCameraScanner? subnetScanner;

  /// 客户端身份(删除已配对相机时换新,触发全新配对;见 [removeSaved])。
  final ClientIdentityStore? identityStore;

  /// 蓝牙工具通道(GPS 注入 / 唤醒 WiFi;不参与相机 PTP 连接状态)。
  final BleCameraSession? bleSession;
  final BleIdentityStore? bleIdentityStore;

  /// 程序化加入相机热点(`nikonpill/network` join;Android/ohos 已实
  /// 现,iOS 未装配 → joinCameraAp 走 skipped 手动指引)。
  final WifiJoiner? wifiJoiner;
  final SettingsController? settingsController;

  CameraLinkState state = CameraLinkState.disconnected;

  /// 配对后的机身确认等待窗:pairing → connecting 沿置位(连接层此窗
  /// 保持 connecting 安静重试),离开 connecting 即清。真机(2026-10-06):
  /// 0x935A 后相机弹「配对完成」等机身上按 OK,按之前重连全被拒 ——
  /// UI 用此旗出「请在相机上按 OK」指引,不闪失败横幅。
  bool awaitingCameraConfirm = false;

  /// 当前选中的连接方式(未连接视图右上角弹层选择;默认有线,冷启
  /// 沿从设置回填上次选中 —— 记住上一次)。
  ConnectionMethod method = ConnectionMethod.usb;

  /// 用户本会话是否已选过方式(选中即落库;设置装载沿不再回填覆盖)。
  bool _methodTouched = false;

  /// 切换连接方式;离开 STA 时若在扫描顺手停掉(结果已不可见)。切进
  /// AP 方式清 mDNS 结果:那是旧网络(路由器网段)的发现,拿去连相机
  /// 热点只会得到跨网段的超时失败。切离蓝牙方式撤两张国别红卡(系统
  /// 配对/手动入网引导只在蓝牙页内有效)。
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
    if (m != ConnectionMethod.ble) {
      bleAwaitSystemBond = false;
      wifiAwakePending = false;
    }
    method = m;
    _methodTouched = true;
    // 记住上一次:落库走设置页同一条 AppSettings 路(失败仅本次会话
    // 内生效,不持久,同 SettingsController._update 口径)。
    unawaited(settingsController?.setConnectionMethod(m.name));
    notifyListeners();
  }

  /// 设置装载/变更沿:恢复上次选中的连接方式(一次性 —— 用户本会话
  /// 选过即以会话内选择为准;同名空转不发通知)。
  void _onSettingsChanged() {
    if (_methodTouched) {
      return;
    }
    final restored =
        connectionMethodFromName(settingsController?.value.connectionMethod);
    if (restored != null && restored != method) {
      method = restored;
      notifyListeners();
    }
  }

  /// 本次连接的无线 IP(已连接视图的「连接方式」行;USB 连接为 null)。
  String? activeIp;

  // ── 蓝牙工具通道(GPS 注入 / 唤醒 WiFi;独立于 PTP 链路) ─────────

  /// BLE 会话状态镜像(bleSession.states 回放;未装配恒 idle)。
  BleSessionState bleState = BleSessionState.idle;

  /// 已配对身份(身份存储镜像;配对页落档后经 [loadBleIdentity] 刷新)。
  BlePairedIdentity? bleIdentity;

  /// BLE 就绪 = 会话 ready(唤醒 WiFi 的门禁)。
  bool get bleReady => bleState == BleSessionState.ready;

  /// iOS 首配握手落档后的「等待系统配对」态(蓝牙页红卡;2026-10-19
  /// 用户裁定:自动跳系统蓝牙删除,改为页内引导 + 手动按钮;ohos 走
  /// 程序化经典绑定不出卡)。面板配对沿置位;会话离开 idle / 身份清空
  /// / 切离蓝牙方式即清。
  bool bleAwaitSystemBond = false;

  /// 唤起 Wi-Fi 成功但本平台无程序化入热能力(iOS):蓝牙页红卡
  /// 等用户手动入网(2026-10-19 用户裁定③④:红卡只限无法直连的情形,
  /// Android/ohos joiner 直达不动)。显式「已加入热点,开始连接」或
  /// 切离蓝牙方式即清。
  bool wifiAwakePending = false;

  /// 唤醒成功沿置红卡(无 joiner 才走此路,见 [_wakeWifiWithCredentials])。
  void markWifiAwakePending() {
    wifiAwakePending = true;
    notifyListeners();
  }

  /// iOS 首配握手落档沿置系统配对红卡(面板 onSystemBondNeeded 回调;
  /// 自动跳系统蓝牙删除,引导收进页内)。
  void markAwaitSystemBond() {
    bleAwaitSystemBond = true;
    notifyListeners();
  }

  /// 「已加入热点,开始连接」(蓝牙页 Wi-Fi 红卡主钮):显式用户意图
  /// —— 切到 AP 方式并发起连接(入网由用户手动完成,发射动作仍走
  /// 既定连接状态机,与手点「连接相机」同路)。
  void connectAfterWifiJoin() {
    wifiAwakePending = false;
    selectMethod(ConnectionMethod.ap);
    unawaited(connectWireless());
  }

  /// BLE 通道是否装配(未装配平台不出蓝牙分段)。
  bool get bleEnabled => bleSession != null && bleIdentityStore != null;

  /// 重载已配对身份(页面进沿/配对页返回沿调用;身份落档后卡片即从
  /// 「未配对」翻到「已配对」)。身份清空(解除配对)沿撤系统配对红卡。
  Future<void> loadBleIdentity() async {
    final saved = await bleIdentityStore?.load();
    if (saved == null) {
      bleAwaitSystemBond = false;
      savedWifiPassword = '';
    }
    if (bleIdentity != saved) {
      bleIdentity = saved;
      savedWifiPassword = saved?.wifiPassword ?? '';
      notifyListeners();
    }
  }

  /// 相机热点密码(0x2004 解密未中的 B 路凭据;身份档持久化,一次录
  /// 入之后一键直达)。装载见 [loadBleIdentity]。
  String savedWifiPassword = '';

  /// 密码落档(扫描+用户录入的 join 成功沿调用;凭据随机身配置不轮
  /// 换,一次管到解除配对/重配为止)。
  Future<void> saveWifiPassword(String password) async {
    final saved = bleIdentity;
    final store = bleIdentityStore;
    if (saved == null || store == null || password.isEmpty) return;
    final updated = BlePairedIdentity(
      peripheralUuid: saved.peripheralUuid,
      deviceId: saved.deviceId,
      nonce: saved.nonce,
      serial: saved.serial,
      controllerName: saved.controllerName,
      cameraName: saved.cameraName,
      wifiPassword: password,
      pairedAt: saved.pairedAt,
    );
    await store.save(updated);
    bleIdentity = updated;
    savedWifiPassword = password;
    notifyListeners();
  }

  /// ready 沿旧档相机名回填(2026-10-19):cameraName 自配对沿起才落
  /// 档,此前配过的旧档案缺字段 —— 重连扫描沿广播名再现时补写,免解
  /// 除重配一次。幂等(档已对即短路);只认「会话现役身份 = 档案身
  /// 份」的沿,跨相机残留名不回填。AppServices 常驻 states 监听在
  /// ready 沿触发(配对沿档案已带名,此路自然空转)。
  Future<void> healCameraName() async {
    final session = bleSession;
    final id = session?.identity;
    final name = session?.lastMatchName ?? '';
    if (session == null || id == null || name.isEmpty) return;
    final saved = await bleIdentityStore?.load();
    if (saved == null || saved.deviceId != id.deviceId) return;
    if (saved.cameraName == name) return;
    await bleIdentityStore!.save(BlePairedIdentity(
      peripheralUuid: saved.peripheralUuid,
      deviceId: saved.deviceId,
      nonce: saved.nonce,
      serial: saved.serial,
      controllerName: saved.controllerName,
      cameraName: name,
      pairedAt: saved.pairedAt,
    ));
    await loadBleIdentity();
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
    // 手动重连 = 显式用户意图,绕深睡闸门(retryReconnect 默认闸)。
    await session.retryReconnect(gateStandby: false);
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
  /// PTP/IP)。凭据缺 / joiner 未装配(iOS/测试)→ skipped,UI
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

  /// 相机 AP 凭据(0x2004 蓝牙通道解出;null = 未读/解密未中/未 ready)。
  /// BLE→WiFi 二期:唤醒成功沿自动读取,AP 卡凭据块展示。
  WifiCredentials? cameraApCredentials;

  /// 最近一次会话错误(WiFi 动作失败的 SnackBar 用;面板错误行只在
  /// 重连/断开态回错误,ready 态写失败也能如实带出原因)。
  L10nMessage? get bleLastError => bleSession?.lastError;

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
  /// 即 t() 键 + 占位参数(消费端 ConnErrorSlot→ConnHintText 统一
  /// 包 t(key, args);技术取证串两表未命中经直通原样回落)。
  L10nMessage? get hint {
    final c = connection;
    if (c == null) {
      return null;
    }
    if (awaitingCameraConfirm && state == CameraLinkState.connecting) {
      return (key: 'conn.pairingSent', args: null);
    }
    return switch (state) {
      CameraLinkState.pairing => (key: 'conn.pairingAuto', args: null),
      // 恢复循环的动态文案(退避分类/busy 慢拍/初始断链原因):连接层
      // 只改 error 不发状态沿,本页 build 期读到的是最近一次。
      CameraLinkState.reconnecting =>
        c.error ?? (key: 'conn.reconnectAuto', args: null),
      CameraLinkState.failed => c.error ?? (key: 'conn.failed', args: null),
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
  List<ProbedCamera> get subnetCameras => List.unmodifiable(_subnetCameras);

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

  /// AP 连接:相机 IP 候选序 = mDNS 发现 → join 网关 → 默认 192.168.1.1
  /// (见 [apCameraIp];手填已砍,候选序自动兜底)。**绝不消费于 STA**
  /// (STA 网关是路由器)。
  Future<void> connectWireless() async {
    final c = connection;
    if (c == null) {
      return;
    }
    _lastAttempt = connectWireless;
    final ip = apCameraIp(discovered: cameras, gateway: apGateway);
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
    settingsController?.removeListener(_onSettingsChanged);
    unawaited(_bleErrorSub?.cancel());
    manualIpController.dispose();
    super.dispose();
  }
}

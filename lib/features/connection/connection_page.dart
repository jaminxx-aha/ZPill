/// 相机页(底部导航首 tab):连接入口 + 已连接相机信息总览。
///
/// 未连接(2026-10-17 SnapBridge 式重排):主视图只留状态卡 + 居中
/// 「连接相机」大按钮 —— 按当前方式直连(USB/AP 直接发起;STA 弹扫描
/// 面板;蓝牙弹工具面板),右上角 AppBar 按钮弹底部弹层切换连接方式
/// (有线 USB / AP 热点 / 同一 Wi-Fi / 蓝牙)。蓝牙是**工具通道**(不
/// 建立相机 PTP 连接,不传图不遥控),只承载 GPS 注入与唤醒相机 WiFi
/// (2026-10-14)。已连接(2026-10-17 bento 卡片风 v24 交付稿定样):
/// 状态行(绿点 + 电池 + 链路纯图标 pill,点按弹详情/断开弹层)+
/// 机身整行卡(竖线居中:型号 pill | 固件/序列号裸值)+ 镜头信息|
/// 存储双列卡 + 底部双钮(左相册灰右进入拍摄黄;「进入拍摄」全屏
/// push 遥控监看页 —— 2026-10-08 拍摄页从底栏 tab 改制;断开连接在
/// 弹层)。图标扛语义(固件/序列号/焦距/光圈沿用原 info 行图标)。
///
/// Controller = ViewModel(ChangeNotifier);**所有按钮必须绑定到
/// Controller 方法**,禁止 UI 层直连协议层(TODO.md §三 注意事项)。
/// 无线流程(2026-10-04):扫描(mDNS `_ptp._tcp`)→ 点选相机 → 连接;
/// 未配对相机在连接中自动配对(验证码不回传相机),相机侧弹「配对
/// 完成」等按 OK,应用保持重连等它(见 awaitingCameraConfirm);已
/// 配对直连。AP 模式相机 IP 候选序 = mDNS 发现 → join 网关(相机
/// 热点的 DHCP 网关,native 读)→ 默认 192.168.1.1(手填已砍,候选
/// 序自动兜底)。
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
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/interface_addresses.dart';
import '../../platform/network_monitor.dart';
import '../../platform/nsd_scanner.dart';
import '../browser/photo_grid_page.dart';
import '../common/widgets/confirm_dialog.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_page.dart';
import 'ble_pair_panel.dart';
import '../settings/settings_page.dart';
import 'camera_overview_controller.dart';
import 'connected_overview.dart';
import 'connection_status_card.dart';
import 'connection_widgets.dart';

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
  StreamSubscription<String?>? _bleErrorSub;
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

  /// BLE 通道是否装配(未装配平台不出蓝牙分段)。
  bool get bleEnabled => bleSession != null && bleIdentityStore != null;

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
    // 手动重连 = 显式用户意图,绕深睡闸门(retryReconnect 默认闸)。
    await session.retryReconnect(gateStandby: false);
  }

  /// BLE 断开(身份保留)。
  Future<void> bleDisconnect() async {
    await bleSession?.disconnect();
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
        // 用户刚点「关闭 Wi-Fi」= 要够得着相机,绕深睡闸门。
        reconnected = await session.retryReconnect(gateStandby: false);
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

  /// BLE 卡状态副文(未装配不显示卡;状态全映射)。
  String? get bleHint {
    final session = bleSession;
    if (session == null) {
      return null;
    }
    if (bleState == BleSessionState.reconnecting ||
        (bleState == BleSessionState.idle && session.lastError != null)) {
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

/// 蓝牙工具卡状态文案(未配对/已配对未连/握手中/已连接/重连中)。
/// 返回 = t() 键,消费端 _bleCard 里包 t()。
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

  /// 已连接期间的拍摄模式轮询(2s 单读 0xD1A6):0x4006 事件沿依赖
  /// 拍摄页的厂商事件队列轮询,连接页不开取景就收不到 —— 拨杆翻转
  /// 在这里只能靠轮询跟随(2026-10-17 实证:连接沿初读后不再更新)。
  /// triggerRefresh:false 不拉参数链(本页无参数面板,且不与拍摄页
  /// 争锁)。断开/离页即停。
  Timer? _modePollTimer;

  /// 视频档代持取景可见性(2026-10-17):帧头 @816 只随取景帧来,
  /// 连接页视频档时恢复拉帧(setViewerVisible(true) —— 相机侧取景
  /// 连接沿已开,只是 app 侧挂起),可录时长与拍摄页同源。拍摄页
  /// 打开期间可见性主权归它,代持即让;切回照片档代持即撤。
  bool _viewerByConnPage = false;

  /// 拍摄页在前台(路由在册):此时 setViewerVisible 主权归拍摄页。
  bool _shootingOpen = false;

  void _syncModePoll() {
    final connected = _controller.state == CameraLinkState.connected;
    if (connected && _modePollTimer == null) {
      _modePollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(() async {
          await _remote.refreshCameraMode(triggerRefresh: false);
          _syncViewerForMode();
        }());
      });
    } else if (!connected && _modePollTimer != null) {
      _modePollTimer?.cancel();
      _modePollTimer = null;
    }
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
    _syncModePoll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _modePollTimer?.cancel();
    if (_viewerByConnPage) {
      _remote.setViewerVisible(false);
      _viewerByConnPage = false;
    }
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
    // 连接沿起停模式轮询(已连接才轮)。
    _syncModePoll();
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
      appBar: AppBar(
        title: Text(context.t('shell.camera')),
        // 右上角连接方式选择(未连接视图专属;已连接后方式无意义)。
        actions: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.state == CameraLinkState.connected) {
                return const SizedBox.shrink();
              }
              final busy = _busyState(controller);
              return IconButton(
                tooltip: context.t('conn.chooseMethod'),
                icon: Icon(_methodIcon(controller.method)),
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

  // ── 未连接:SnapBridge 式主视图(状态卡 + 居中连接按钮) ─────────

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
        ConnectionMethod.sta => Icons.wifi,
        ConnectionMethod.ble => Icons.bluetooth,
      };

  /// 方式短名(状态副文/弹层条目用;键即中文原文)。
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

  /// 中央按钮按当前方式直连(USB/AP;这两方式无独立连接视图)。
  /// STA/蓝牙的视图由 body 原地替换承接,不落这里。
  void _connectPressed(BuildContext context, ConnectionController controller) {
    switch (controller.method) {
      case ConnectionMethod.usb:
        controller.connect();
      case ConnectionMethod.ap:
        controller.connectWireless();
      case ConnectionMethod.sta || ConnectionMethod.ble:
        break; // 视图即流程,无中央按钮
    }
  }

  /// 未连接/连接中视图(2026-10-18 原地替换定稿):STA/蓝牙选中后
  /// **本视图直接变成该方式的连接界面**(无路由无弹窗),USB/AP 仍
  /// 是状态卡 + 居中主操作。右上角方式图标随时切回。
  Widget _methodsView(BuildContext context, ConnectionController controller) {
    // 蓝牙:工具内容即本视图(蓝牙不建相机连接,无 PTP 状态卡)。
    if (controller.method == ConnectionMethod.ble) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: AppSpacing.screenPadding,
        children: _bleToolsContents(context, controller),
      );
    }
    final theme = Theme.of(context);
    final busy = _busyState(controller);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 状态区:connecting 红 / pairing 金 / failed 红;busy 态尾槽
        // spinner;失败原因并入副文(首句加粗)+ 重试钮;connecting/
        // reconnecting 逃生口(死 IP 超时/退避期间可取消)。配对后的
        // 机身确认等待窗显示专属文案(不闪失败)。disconnected 静置态
        // 不出卡(2026-10-17:未连接组件退场)。
        if (controller.state != CameraLinkState.disconnected)
          Padding(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConnectionStatusCard(
                  state: controller.state,
                  waitingConfirm: controller.awaitingCameraConfirm,
                  hint: controller.hint,
                  onRetry: controller.retry,
                ),
                if (controller.state == CameraLinkState.connecting ||
                    controller.state == CameraLinkState.reconnecting)
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
              ],
            ),
          ),
        // 主体:STA 模式 = 扫描视图(原地替换,进方式即起扫);USB/AP
        // = 居中主操作(相机图标 + 「连接相机」大按钮 + 当前方式副文,
        // AP 附接管预告 —— 连接动作即锁盘,如实告知)。
        if (controller.method == ConnectionMethod.sta)
          Expanded(child: _StaScanBody(controller: controller))
        else
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                // 主操作 hero:相机图标套淡染圆 + hairline 描边(素图标
                // 悬空太瘦;2026-10-17 界面对齐拍摄页语言)。
                Container(
                  width: 128,
                  height: 128,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.45),
                    border:
                        Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Icon(Icons.photo_camera_outlined,
                      size: 56, color: theme.colorScheme.onSecondaryContainer),
                ),
                const SizedBox(height: AppSpacing.xl),
                SizedBox(
                  width: 260,
                  height: 52,
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () => _connectPressed(context, controller),
                    child: Text(
                      context.t('conn.connectCamera'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.t('conn.currentMethod', {
                    'm': context.t(_methodLabel(controller.method)),
                  }),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (controller.method == ConnectionMethod.ap)
                  Padding(
                    padding: const EdgeInsets.only(
                        top: AppSpacing.sm,
                        left: AppSpacing.xl,
                        right: AppSpacing.xl),
                    child: Text(
                      context.t('conn.apTakeoverNote'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // AP 方式的热点凭据卡(蓝牙通道解出才显示):SSID/密码/安全 +
        // 复制 —— 系统设置加入热点用(取代原 AP 卡)。
        if (controller.method == ConnectionMethod.ap &&
            controller.cameraApCredentials != null)
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

  /// 右上角连接方式弹层:图标 + 短名 + 一句说明 + 当前项打勾。busy 时
  /// 条目禁用(连接进行中不可换方式,原分段语义)。蓝牙仅在 BLE 通道
  /// 装配时出现(未装配平台不出)。**选中即进该方式的连接流程**
  /// (2026-10-17 定稿):USB/AP 当场发起连接;STA/BLE 先正常收弹层
  /// 再推整页 —— 弹层路由出栈后 push,无 pop/push 竞态(pop 动画期
  /// 推新路由会被吞、pop 又只弹栈顶,真机/测试双实证),不再回落主
  /// 视图让用户再点一次「连接相机」。
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
                  leading: Icon(_methodIcon(m)),
                  title: Text(context.t(_methodLabel(m))),
                  subtitle: Text(context.t(_methodDesc(m))),
                  trailing:
                      controller.method == m ? const Icon(Icons.check) : null,
                  onTap: busy
                      ? null
                      : () {
                          controller.selectMethod(m);
                          // USB/AP 当场发起;STA/BLE 由 body 原地替换
                          // 承接(2026-10-18:无路由,无竞态)。
                          if (m == ConnectionMethod.usb) {
                            controller.connect();
                          } else if (m == ConnectionMethod.ap) {
                            controller.connectWireless();
                          }
                          Navigator.pop(sheetContext);
                        },
                ),
          ],
        ),
      ),
    );
  }

  /// 蓝牙工具面板(中央按钮在蓝牙方式下的去向):连接(配对/重连/
  /// 断开)+ GPS 注入开关 + 唤醒/关闭相机 WiFi。蓝牙**不建立相机连接**
  /// (不传图不遥控)。joiner 全程(唤醒→自动加入→发射 AP 连接)发起
  /// PTP 连接沿自动收面板 —— 连接进度/取消在主视图状态卡,面板不该
  /// 盖住它。

  static List<Widget> _bleToolsContents(
    BuildContext context,
    ConnectionController controller,
  ) {
    final theme = Theme.of(context);
    final ready = controller.bleReady;
    final hasIdentity = controller.bleIdentity != null;
    // 点色走 token(2026-10-17 界面对齐):就绪绿 = AppColors.success
    //(明暗双档),在途 = secondary,空闲 = outline;裸 Colors.* 退役。
    final stateColor = switch (controller.bleState) {
      BleSessionState.ready => AppColors.success(context),
      BleSessionState.pairing ||
      BleSessionState.reconnecting => theme.colorScheme.secondary,
      BleSessionState.idle => theme.colorScheme.outline,
    };
    return [
      _ConnectionPageState._methodTitle(
          context, Icons.bluetooth, 'conn.btTools'),
      const SizedBox(height: 4),
      Text(context.t('conn.btToolsHint')),
      const SizedBox(height: AppSpacing.sm),
      ConnStatusPill(
        dotColor: stateColor,
        label: context.t(bleStateLabel(controller)),
        trailing: hasIdentity ? controller.bleIdentity!.controllerName : null,
      ),
      if (controller.bleHint != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(controller.bleHint!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ),
      const SizedBox(height: AppSpacing.sm),
      // 相机 Wi-Fi 动作(GPS 注入开关在设置页,2026-10-18 迁出):唤起
      // = 读 0x2004 凭据(SnapBridge 序)再写 0x2005,成功沿断 BLE ——
      // 相机等链路释放才开热点;关闭 = 反义 op(0x80),不断链。
      ConnTileGroup(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.wifi_tethering),
                label: Text(context.t('conn.wakeCameraWifi')),
                onPressed: ready
                    ? () => unawaited(_wakeWifiWithCredentials(context, controller))
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
                        context, controller, controller.closeCameraWifi,
                        success: context.t('conn.wifiOffRequested')))
                    : null,
                child: Text(context.t('common.off')),
              ),
            ),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      // 配对面板(原独立「BLE 配对 / GPS 注入」页整体迁入):扫描点选
      // 配对、复用重连、解除、经典绑定、后台定位授权、手动件与 hex
      // 日志。身份落盘/解除沿回调重载 controller.bleIdentity。
      BlePairPanel(
        savedIdentity: controller.bleIdentity,
        onIdentityChanged: () => unawaited(controller.loadBleIdentity()),
      ),
    ];
  }

  /// 唤醒相机 WiFi(BLE→WiFi 交接):[ConnectionController.wakeCameraWifi]
  /// 全程 = 读 0x2004(SnapBridge 序)→ 写 0x2005=0x01 → 成功沿断 BLE
  /// (相机等链路释放才开热点)。凭据解出且平台装配 joiner → 接着程序
  /// 化加入热点并自动发起 AP 连接([ConnectionController.joinCameraAp],
  /// SnapBridge 全程);否则维持手动指引(密码看相机屏幕)。GPS 注入随
  /// 断链暂停,传图完蓝牙卡「关闭」关相机 Wi-Fi、「重连」恢复蓝牙。
  static Future<void> _wakeWifiWithCredentials(
      BuildContext context, ConnectionController controller) async {
    final ok = await controller.wakeCameraWifi();
    if (!context.mounted) return;
    if (!ok) {
      _showHintStatic(
          context,
          controller,
          context.t('conn.wakeFailed',
              {'e': controller.bleLastError ?? context.t('common.unknown')}));
      return;
    }
    final creds = controller.cameraApCredentials;
    if (creds == null || controller.wifiJoiner == null) {
      // 无法自动加入(凭据未解出 / 平台未装配 joiner):手动指引如实。
      _showHintStatic(
        context,
        controller,
        creds != null
            ? context.t('conn.wifiAwakeCred', {'ssid': creds.ssid})
            : context.t('conn.wifiAwakeNoCred',
                {'e': controller.bleLastError ?? context.t('conn.notSent')}),
        duration: const Duration(seconds: 5),
      );
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
      // skipped:防御路(joiner 在 wake 后被置空等)—— 手动指引兜底。
      _showHintStatic(
        context,
        controller,
        context.t('conn.wifiAwake', {'ssid': creds.ssid}),
        duration: const Duration(seconds: 5),
      );
    }
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

  /// WiFi 唤起/关闭动作收口:失败 SnackBar 如实(含原因),成功提示
  /// 下一步去向(到系统 Wi-Fi 加入热点)。
  static Future<void> _bleWifiAction(
    BuildContext context,
    ConnectionController controller,
    Future<bool> Function() action, {
    required String success,
  }) async {
    final ok = await action();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? success
          : context.t('conn.opFailed',
              {'e': controller.bleLastError ?? context.t('common.unknown')})),
      duration: const Duration(seconds: 3),
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
    return [
      Text(context.t('conn.hotspotCred'),
          style: Theme.of(context).textTheme.labelMedium),
      _credentialRow(context, 'SSID', creds.ssid),
      if (creds.password.isNotEmpty)
        _credentialRow(context, 'conn.password', creds.password),
      Text(context.t('conn.security', {'s': creds.securityLabel}),
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
                content: Text(
                    context.t('conn.copiedLabel', {'label': localizedLabel})),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
      ],
    );
  }

  /// STA 扫描面板(中央按钮在同一 Wi-Fi 方式下的去向):打开沿自动

  /// STA 页主体:扫描钮 + 结果 + 网段兜底 + 手填 IP + 已存相机。
  /// 点选连接 await 落地后 pop(mounted 防御);生产上 connecting 沿
  /// 页面监听先退,这里为兜底/测试路径。
  /// STA 扫描视图内容(2026-10-18 定稿):扫描钮 + 空扫指引 +
  /// mDNS 结果 + 已存相机快连。连接沿的退页由宿主 _StaScanBody 的
  /// 无路由语义自理(状态卡在宿主视图顶部)。
  static List<Widget> _staScanContents(
    BuildContext context,
    ConnectionController controller, {
    required bool busy,
  }) {
    return [
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
          onTap: busy
              ? null
              : () => unawaited(controller.connectDiscovered(camera)),
        ),
      // 已存相机快连(上次连过的,按最近优先);删除 = 忘记这台
      // 相机(清档案 + 配对过的换新身份 → 全新配对,无感)。
      if (controller.savedCameras.isNotEmpty)
        for (final saved in controller.savedCameras)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title:
                Text(context.t('conn.lastCamera', {'name': saved.name})),
            subtitle: Text(saved.lastIp ?? ''),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
            onTap: busy
                ? null
                : () => unawaited(controller.connectSaved(saved)),
          ),
    ];
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

  /// 方式标题行(图标 + 短名;STA 视图头)。
  static Widget _methodTitle(BuildContext context, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        // 键即中文原文,就地统一包 t()。
        Text(context.t(text), style: Theme.of(context).textTheme.titleMedium),
      ],
    );
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
          // 状态行:绿点已连接 + 电池 + 链路纯图标 pill;整行可点弹
          // 详情/断开弹层(设备名/链路串随迁,2026-10-17 定稿)。
          ConnectedHeader(
            batteryPercent: _overview.batteryPercent,
            linkIcon: wireless ? Icons.wifi : Icons.usb,
            onTap: () => _showConnectionSheet(context, controller),
          ),
          const SizedBox(height: AppSpacing.md),
          // 整行:机身卡(竖线居中:型号 pill | 固件/序列号裸值)。
          CameraCard(
            model: _overview.deviceInfo?.model,
            firmware: _overview.deviceInfo?.deviceVersion,
            serial: _overview.deviceInfo?.serialNumber,
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
          // 连接移入状态行弹层(2026-10-17 定稿)。
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

  /// 状态行点按 → 连接详情弹层:设备名/型号/链路/电池四行 + 红色
  /// 「断开连接」。设备名与链路串从主页面收编至此(2026-10-17)。
  void _showConnectionSheet(
      BuildContext context, ConnectionController controller) {
    final c = controller.connection;
    final wireless = c?.isWireless ?? false;
    // 链路串:无线带 IP(动态串直通),USB 复用既有本地化文案。
    final link = wireless
        ? (controller.activeIp == null ? 'Wi-Fi' : 'Wi-Fi(${controller.activeIp})')
        : context.t('conn.usbCable');
    Widget row(String labelKey, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              // 标签列定宽,数值列统一左对齐成一条(v25/v26 定稿)。
              SizedBox(
                width: 56,
                child: Text(context.t(labelKey),
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
                const SizedBox(height: AppSpacing.sm),
                Divider(color: scheme.outlineVariant, height: 1),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      controller.disconnect();
                    },
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    child: Text(
                      sheetContext.t('conn.disconnectConn'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
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

  /// 进入拍摄:全屏 push 遥控监看页(返回即回相机页;拍摄页离页自动
  /// 挂起帧轮询,取景生命周期跟连接走,相机侧保持取景)。
  void _openRemote() {
    // 拍摄页在前台:可见性主权移交(setViewerVisible 由它汇报),
    // 连接页的模式轮询不再代持顶真;返回沿收回主权并按档位重判。
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


/// STA 扫描视图体(2026-10-18 原地替换):进方式即起扫,离方式停扫
/// (dispose);内容 = mDNS 扫描/结果 + 网段兜底 + 手填 IP + 已存相机
/// + 无线注意事项。连接沿的状态卡在宿主视图顶部,本体不管退页 ——
/// 没有路由可退(原地替换)。
class _StaScanBody extends StatefulWidget {
  const _StaScanBody({required this.controller});

  final ConnectionController controller;

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
    // 离开 STA 视图停扫(等价原「离开 STA 分段停扫」)。
    if (widget.controller.scanning) {
      unawaited(widget.controller.stopScan());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final busy = _ConnectionPageState._busyState(widget.controller);
        return ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: AppSpacing.screenPadding,
          children: [
            _ConnectionPageState._methodTitle(
                context, Icons.wifi, 'conn.methodSta'),
            const SizedBox(height: 4),
            Text(context.t('conn.staHint')),
            const SizedBox(height: 12),
            ..._ConnectionPageState._staScanContents(
                context, widget.controller, busy: busy),
            const SizedBox(height: AppSpacing.md),
            // 无线注意事项(原未连接主视图常显,随重排收进本视图)。
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                context.t('conn.wirelessNotes'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }
}

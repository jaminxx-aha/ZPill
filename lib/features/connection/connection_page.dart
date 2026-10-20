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
/// 交付稿定样):状态行(绿点 + 电池 + 链路纯图标 pill,点按弹详情/
/// 断开弹层)+ 机身整行卡(竖线居中:型号 pill | 固件/序列号裸值)+
/// 镜头信息|存储双列卡 + 底部双钮(左相册灰右进入拍摄黄;「进入拍摄」
/// 全屏 push 遥控监看页 —— 2026-10-08 拍摄页从底栏 tab 改制;断开连
/// 接在弹层)。图标扛语义(固件/序列号/焦距/光圈沿用原 info 行图标)。
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
import 'dart:io' show Platform;
import 'dart:math' show pi;

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
import '../../l10n/message.dart';
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

  /// 唤起 Wi-Fi 成功但本平台无程序化入热能力(iOS/ohos):蓝牙页红卡
  /// 等用户手动入网(2026-10-19 用户裁定③④:红卡只限无法直连的情形,
  /// Android joiner 直达不动)。显式「已加入热点,开始连接」或切离
  /// 蓝牙方式即清。
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
    }
    if (bleIdentity != saved) {
      bleIdentity = saved;
      notifyListeners();
    }
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

  /// 蓝牙配对面板句柄(八轮):蓝牙 hero 点按 = 连最近,经面板
  /// 「连接」同一条手动重连路(显式意图/绕深睡闸门/在途循环不重入,
  /// 守卫都在面板态里)。
  final GlobalKey<BlePairPanelState> _blePanelKey =
      GlobalKey<BlePairPanelState>();

  /// 蓝牙面板重连循环在途(九轮):蓝牙 hero 涟漪的数据源 —— 无命中
  /// 轮会话态停在 idle(会话态跟不出「正在连」),面板循环起停经
  /// onRetryingChanged 上抛到此,hero busy = 会话态 ∪ 面板循环。
  final ValueNotifier<bool> _bleRetrying = ValueNotifier<bool>(false);

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
      // AppBar 三分(六~七轮):「相机」挪左;当前方式(图标+标题+ⓘ)
      // 居中接管原标题位;右上角统一连接图标(Icons.link,七轮自「连接」
      // 文字改,方法无关)仍开方式弹层。已连接后方式位与钮都退场。
      appBar: AppBar(
        // 二十一轮:72 → 104 —— leading 槽要装下 EN「Camera」(titleLarge
        // 22px 约 77px + 左缘 16 padding;56px 槽 EN 必换行,真机截图实证)。
        // Align centerLeft 左缘 16 不动,与图库/设置同槽;居中方式 chip
        // 在常见屏宽不受推挤(NavigationToolbar 仅重叠时才让位)。
        leadingWidth: 104,
        leading: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.lg),
          // 二十轮:Align centerLeft(勿用 Center)—— AppBar 把 leading
          // 钉成 leadingWidth 宽,Center 会把文字在余宽里水平也
          // 居中(左缘 ~22px),与图库/设置标题(左 16px)错位。
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
        ConnectionMethod.sta => Icons.wifi,
        ConnectionMethod.ble => Icons.bluetooth,
      };

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
                    Icon(_methodIcon(m), size: 20, color: scheme.primary),
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
        Icon(_methodIcon(m), size: 20, color: theme.colorScheme.primary),
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
        unawaited(controller.connectWireless());
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
  /// (内容短则留白,长则区内滚动)。
  static const double _heroTopGap = 170;

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
              // 相机 Wi-Fi 动作(就绪才挂):唤醒 = 读 0x2004 凭据(SnapBridge
              // 序)再写 0x2005,成功沿断 BLE —— 相机等链路释放才开热点。
              if (ready) ...[
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(context.t('conn.wakeCameraWifi')),
                  onPressed: () =>
                      unawaited(_wakeWifiWithCredentials(context, controller)),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              // 配对面板(原独立配对页整体迁入):「已配对 / 其它设备」两段
              // 列表;打开沿自动扫描(静默)并挂起注入驱动,页面内全手动。
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
                  leading: Icon(_methodIcon(m)),
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
      // 十七轮:凭据未解出(读失败/空/解密未中)—— 下方 SnackBar 提醒
      // 撤(用户裁定),置 wifiAwakePending:错误位出红字「去系统连
      // Wi-Fi」固定提醒(解密未中细节已改写 AppLog,不上屏)。
      controller.markWifiAwakePending();
      return;
    }
    if (controller.wifiJoiner == null) {
      // 无程序化入热能力(iOS/ohos):留蓝牙页弹红卡,用户手动入网后
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

  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
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
                child: Icon(_ConnectionPageState._methodIcon(widget.method),
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
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: context.t('conn.forgetCamera'),
                                  onPressed: busy
                                      ? null
                                      : () => _ConnectionPageState
                                          ._confirmRemoveSaved(
                                              context, controller, saved),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: busy
                                ? null
                                : () =>
                                    unawaited(controller.connectSaved(saved)),
                          ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 其它设备:mDNS 发现(点行连接)。扫描静默 —— 无「扫描中」
                  // 指示,结果静默入列;相机须停留在「等待连接」画面等解释
                  // 收进 hero 说明(点图标弹说明弹窗)。
                  const ConnSectionHeader(label: 'conn.sectionOthers'),
                  ConnTileGroup(
                    children: [
                      if (controller.cameras.isEmpty)
                        const _EmptyGroupRow(text: 'conn.noOtherDevices')
                      else
                        for (final camera in controller.cameras)
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

/// 相机连接状态机(TODO.md §二 P1):驱动 UI 的单一事实来源。
///
/// 等价于 TODO.md 中的「连接状态机 + StateFlow」:状态经 Stream 广播,
/// UI 订阅渲染,按钮操作走方法调用。
library;

import 'dart:async';
import 'dart:io';

import '../../data/paired_cameras_store.dart';
import '../../platform/usb/usb_host.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_link_router.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';
import '../ptpip/transport.dart';
import 'camera_info.dart';

enum CameraLinkState {
  /// 未连接(初始 / 已清理)。
  disconnected,

  /// 正在检测当前 WiFi 是否为相机热点。
  detecting,

  /// 正在建立链路 + OpenSession。
  connecting,

  /// 无线首次连接的配对确认期:配对码就绪([CameraConnection.pairingCode]),
  /// 等待用户确认([CameraConnection.confirmPairing])或跳过
  /// ([CameraConnection.cancelPairing])。
  pairing,

  /// 会话已建立,可浏览 / 传输。
  connected,

  /// 失败(超时 / 无设备 / 会话拒绝),错误信息见 [CameraConnection.error]。
  failed,
}

abstract interface class CameraConnection {
  CameraLinkState get state;
  Stream<CameraLinkState> get states;
  String? get error;

  /// 已连接设备的展示名(如 "NIKON ZF";来自 GetDeviceInfo);
  /// 未连接为 null。
  String? get deviceName;

  /// 当前(或最近一次)连接是否走无线(PTP-IP);false = USB。
  /// 连接页据此区分提示文案。
  bool get isWireless;

  /// 配对等待期(state == pairing)的验证码;其余状态为 null。
  String? get pairingCode;

  /// 连接:[ip] == null 走 USB;非空则连 `ip:15740` 的 PTP-IP 无线链路
  /// (相机 Wi-Fi 热点,先在相机菜单 网络 → 连接至智能设备 打开)。
  /// [instanceName] 为 mDNS 实例名(扫描发现时传入,如 Z_f_8014411),
  /// 用于配对记录的展示名;手动输入 IP 时可空。
  Future<void> connect({String? ip, String? instanceName});

  /// 确认配对:发 CompletePairing,相机把本客户端记为已配对设备,
  /// 随后自动重连转正(见类注配对流程)。
  Future<void> confirmPairing();

  /// 跳过配对:当前会话照常转正(相机不记录,下次连接再问)。
  Future<void> cancelPairing();

  /// 断开清理:关会话、释放 USB 接口、复位状态(TODO.md §二 P1)。
  Future<void> disconnect();
}

/// 双路径连接实现(USB P0 闭环 + PTP-IP 无线 Phase 2):
///
/// **USB**(ip == null):listCameras → open(独占 STI 接口)→
/// GetDeviceInfo → OpenSession(0x201E 自动恢复在 [PtpSession.open] 内)→
/// connected。
///
/// **无线**(ip != null):新建 [PtpIpTransport](每次连接一个实例,
/// close 后报废;客户端 GUID 取自 [ClientIdentityStore] 的持久身份)→
/// 双通道 MTP/IP 握手 → attach 到 [PtpLinkRouter] →
/// 后续流程与 USB 共用(GetDeviceInfo → OpenSession)。
///
/// **无线配对**(2026-10-04,NiConn_DEMO/SnapBridge 语义):OpenSession
/// 后查 [PairedCamerasStore],未配对则进入配对相 —— GetPtpIpPairingCode
/// (0x952B)取验证码 → state = pairing 等用户确认 → CompletePairing
/// (0x935A)→ 相机把本客户端 UUID 记为已配对设备并自行结束会话 →
/// teardown 后全流程重连(免配对相)→ connected。「已配对」是纯客户端
/// 记账(相机不回答配对状态),记录键 = GetDeviceInfo 序列号。
///
/// 会话层永远只见 [PtpLinkRouter];attach/detach 在 connect/teardown
/// 里驱动,下游对象图(repository/下载器)不感知链路切换。
///
/// 2026-10-01 补两道防线:
/// - GetDeviceInfo 后检查受限画像(仅 USB:op 表缺 GetObject → 连接期
///   拦截,给出「关机重启」对策,不再让用户面对满屏 0x200F。无线路径
///   2026-10-04 真机实证不适用:STA 模式 op 表只报 9 项、连
///   GetObjectHandles 都不在,但照片级 GetThumb/GetObject 照常 0x2001
///   —— 声明表与实际能力无关,按表拒连会误杀 STA);
/// - 订阅链路 breakages(USB 看门狗 / 无线毒化):相机中途拔出或
///   链路死亡时 connected 即刻转 failed;pairing 态的断链按失败收口
///   (唯一例外:CompletePairing 发出后的收线是相机预期行为)。
///
/// teardown 顺序(压测修正,原方案会把串行门挂满 15s):
/// `link.detach()`(挡新请求)→ 无线实例 close()(毒化在途,gate 秒
/// 释放)→ `session.close()`(本地状态复位;CloseSession 不再下链路,
/// 相机侧残留由 0x201E 自愈处理)→ `usb.close()`。
final class CameraConnectionImpl implements CameraConnection {
  CameraConnectionImpl({
    required UsbHostChannel usb,
    required PtpTransport usbTransport,
    required PtpLinkRouter link,
    required PtpSession session,
    Future<PtpIpTransport> Function()? createIpTransport,
    PairedCamerasStore? pairedCameras,
  })  : _usb = usb,
        _usbTransport = usbTransport,
        _link = link,
        _session = session,
        _createIpTransport = createIpTransport ?? _defaultIpTransport,
        _pairedCameras = pairedCameras {
    // 断链事件只在 connected/pairing 态生效;connecting 态的失败由
    // connect() 自己的 catch 上报,failed/disconnected 已无会话可清。
    _usb.breakages.listen(_onLinkBreakage);
  }

  /// 默认传输工厂:固定 SnapBridge 生态 GUID(测试/无身份注入时的
  /// 兜底;生产装配传入持久身份,见 [ClientIdentityStore])。
  static Future<PtpIpTransport> _defaultIpTransport() async =>
      PtpIpTransport();

  final UsbHostChannel _usb;
  final PtpTransport _usbTransport;
  final PtpLinkRouter _link;
  final PtpSession _session;
  final Future<PtpIpTransport> Function() _createIpTransport;

  /// 已配对相机记录;null = 不做配对相(纯链路测试装配)。
  final PairedCamerasStore? _pairedCameras;

  /// 当前无线链路实例(连接期间非 null);teardown 收尾后清空。
  PtpIpTransport? _wirelessTransport;
  StreamSubscription<String>? _wirelessBreakageSub;
  bool _wireless = false;

  final StreamController<CameraLinkState> _statesCtrl =
      StreamController<CameraLinkState>.broadcast();

  CameraLinkState _state = CameraLinkState.disconnected;
  String? _error;
  String? _deviceName;

  /// 配对等待门:true = 用户确认,false = 跳过/外部收口。
  Completer<bool>? _pairingGate;
  String? _pairingCode;

  /// CompletePairing 已发出:随后的断链是相机收线(预期),不按失败处理。
  bool _pairingCompleting = false;

  @override
  CameraLinkState get state => _state;

  @override
  Stream<CameraLinkState> get states => _statesCtrl.stream;

  @override
  String? get error => _error;

  @override
  String? get deviceName => _deviceName;

  @override
  bool get isWireless => _wireless;

  @override
  String? get pairingCode => _pairingCode;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {
    if (_state == CameraLinkState.connected ||
        _state == CameraLinkState.connecting ||
        _state == CameraLinkState.pairing) {
      return;
    }
    _transition(CameraLinkState.connecting);
    if (ip == null) {
      await _connectUsb();
    } else {
      await _connectWireless(ip, instanceName: instanceName);
    }
  }

  Future<void> _connectUsb() async {
    try {
      final cameras = await _usb.listCameras();
      if (cameras.isEmpty) {
        await _failConnect('未发现尼康相机:请插好 USB 数据线并解锁相机后重试');
        return;
      }
      await _usb.open(cameras.first);
      _link.attach(_usbTransport);
      _wireless = false;
      await _openSessionOrReject();
    } on Exception catch (e) {
      await _failConnect('USB 连接失败:$e');
    } on Error catch (e) {
      // TypeError/StateError 等 Error 不受 on Exception 约束 —— 真机吃过
      // 大亏:通道返回类型不符的 TypeError 逃逸后 connect 静默死亡,状态
      // 机永远 connecting(无限转圈)。宁可显式 failed 把错误亮出来。
      await _failConnect('USB 连接失败:$e');
    }
  }

  Future<void> _connectWireless(String ip, {String? instanceName}) async {
    final transport = await _createIpTransport();
    // 先登记:握手/会话任一步失败,catch 里的 teardown 都能收尾实例
    _wirelessTransport = transport;
    try {
      // breakages 只在 connected/pairing 态生效,与 USB 同一入口;teardown 取消订阅
      _wirelessBreakageSub = transport.breakages.listen(_onLinkBreakage);
      await transport.connect(ip);
      _link.attach(transport);
      _wireless = true;
      // 无线不做 USB 那道受限画像拦截(STA 的 9 op 小表是常态人设,见类注)
      final info = await _session.getDeviceInfo(force: true);
      await _session.open();
      _deviceName = info.model;
      if (await _needsPairing(info)) {
        switch (await _runPairing(info, ip, instanceName)) {
          case _PairResult.newlyPaired:
            // 相机记录本设备后自收会话(Z50II 实测;Zf 待核对):
            // teardown 后全流程重连,免配对相。
            await _teardown();
            _transition(CameraLinkState.connecting);
            return await _connectWireless(ip, instanceName: instanceName);
          case _PairResult.alreadyPaired:
          case _PairResult.declined:
            break; // 当前会话照常转正
          case _PairResult.aborted:
            return; // 外部 disconnect / 断链已收口状态
        }
      }
      _error = null;
      _transition(CameraLinkState.connected);
    } on Exception catch (e) {
      await _failConnect(_wirelessErrorMessage(ip, e));
    } on Error catch (e) {
      await _failConnect('无线连接失败:$e');
    }
  }

  /// 配对子流程:GetPtpIpPairingCode → 等用户确认 → CompletePairing。
  ///
  /// 仅在 [CameraLinkState.pairing] 态阻塞等待;任何外部状态变化
  /// (disconnect/断链)都以 [_PairResult.aborted] 退出,不重复收口。
  Future<_PairResult> _runPairing(
      PtpDeviceInfo info, String ip, String? instanceName) async {
    final code = await _session.getPairingCode();
    if (code == null) {
      // 0x952B 响应非 OK:多半是本客户端已配对或相机不要求配对。
      // 不落配对记录(下次再问,避免误记导致永不配对);当前会话转正。
      return _PairResult.alreadyPaired;
    }
    final gate = _pairingGate = Completer<bool>();
    _pairingCode = code;
    _transition(CameraLinkState.pairing);
    final confirmed = await gate.future;
    _pairingGate = null;
    _pairingCode = null;
    if (_state != CameraLinkState.pairing) {
      // 等待期间被 disconnect()/断链收口(它们负责清理与状态)
      return _PairResult.aborted;
    }
    if (!confirmed) {
      return _PairResult.declined; // 用户跳过:相机不记录,当前会话转正
    }
    // CompletePairing:相机随后可能不等我们收线就关连接(预期),
    // 链路异常一律按配对完成处理;明确的非 OK 拒答(链路还活着)按
    // 跳过处理,下次连接再问(拒答形态未实测,防御分支)。
    _pairingCompleting = true;
    Object? refusal;
    try {
      await _session.completePairing();
    } on PtpResponseException catch (e) {
      refusal = e;
    } on Exception {
      // 相机收线 → PtpLinkException;按配对完成继续
    }
    if (refusal != null) {
      return _PairResult.declined;
    }
    // _pairingCompleting 不复位:离开 pairing 态那一刻统一清(见
    // _transition)—— 0x935A 之后到重连转 connecting 之前,相机收线
    // 都是预期行为,不得按断链失败处理。
    await _markPaired(info, ip, instanceName);
    return _PairResult.newlyPaired;
  }

  Future<bool> _needsPairing(PtpDeviceInfo info) async {
    final store = _pairedCameras;
    if (store == null) return false;
    final id = _cameraId(info);
    return !(await store.list()).any((c) => c.id == id);
  }

  /// 记配对档案(键 = 序列号,稳定;补全最近 IP 与展示名,方便快速重连)。
  Future<void> _markPaired(
      PtpDeviceInfo info, String ip, String? instanceName) async {
    final store = _pairedCameras;
    if (store == null) return;
    final id = _cameraId(info);
    CameraInfo updated = CameraInfo(
      id: id,
      name: instanceName ?? info.model,
      model: info.model,
      lastIp: ip,
      lastConnectedAt: DateTime.now(),
    );
    for (final existing in await store.list()) {
      if (existing.id == id) {
        updated = existing.copyWith(
          name: instanceName ?? existing.name,
          model: info.model,
          lastIp: ip,
          lastConnectedAt: DateTime.now(),
        );
        break;
      }
    }
    await store.save(updated);
  }

  /// 相机稳定标识:GetDeviceInfo 序列号(mDNS 实例名的尾段与之同源,
  /// 如 Z_f_8014411 的 8014411);缺失时退型号(同型多机不区分,可接受)。
  static String _cameraId(PtpDeviceInfo info) =>
      info.serialNumber ?? info.model;

  /// USB 专属:GetDeviceInfo(受限画像检查)→ OpenSession → connected。
  /// 无线路径不走这里(有配对相,见 [_connectWireless])。
  Future<void> _openSessionOrReject() async {
    // GetDeviceInfo 是 OpenSession 之前唯一允许的操作,顺带拿到型号名。
    // force:相机重启后 op 表可能变化(受限画像 ⇄ 全量),不能吃上次
    // 连接的缓存。
    final info = await _session.getDeviceInfo(force: true);
    if (!info.supportsOperation(PtpOperationCode.getObject)) {
      // 受限画像(USB 真机 2026-10-01:op 表只剩元数据/属性/事件,
      // GetObject/GetThumb 等数据操作全 0x200F;触发器未明,自行翻回)。
      // 与其让缩略图/下载逐个莫名失败,不如连接期就拦下并给出对策。
      // 无线不做此检查,理由见类注(STA 的 9 op 小表是常态人设)。
      await _failConnect('相机处于受限连接状态(数据操作被禁用):'
          '请关闭相机电源,重新开机后再连接');
      return;
    }
    await _session.open();
    _deviceName = info.model;
    _error = null;
    _transition(CameraLinkState.connected);
  }

  /// 连接失败的统一收口:connecting/pairing 守卫(disconnect 竞态下迟到
  /// catch 不得把 disconnected 覆盖成 failed;pairing 入围是因为配对
  /// 子流程抛出时状态还在 pairing,再无人收口就会卡死)+ failed +
  /// teardown。
  Future<void> _failConnect(String message) async {
    if (_state != CameraLinkState.connecting &&
        _state != CameraLinkState.pairing) {
      return;
    }
    _error = message;
    _transition(CameraLinkState.failed);
    await _teardown();
  }

  /// 无线连接失败的用户指引(与纯异常串区分开)。
  String _wirelessErrorMessage(String ip, Object e) {
    if (e is PtpInitRejectException) {
      // 2026-10-04 真机:STA 模式下 reason=0x1 完全可复现的场景是
      // 单连接槽位被 SnapBridge 抢占;释放后同样的 Init 秒过。
      return '相机拒绝了连接(InitFail reason=0x${e.reason.toRadixString(16)}):'
          '相机同一时间只允许一个客户端,'
          '可能被 SnapBridge(尼享)等已配对应用占用;'
          '请在其设备上断开或彻底关闭 SnapBridge 后重试';
    }
    if (e is SocketException) {
      return '连不上 $ip:请先在系统 Wi-Fi 设置里加入相机热点'
          '(相机菜单:网络 → 连接至智能设备),再点「无线连接」;'
          '首次连接若失败,请在系统弹窗中允许访问本地网络后重试';
    }
    if (e is TimeoutException) {
      return '连接 $ip 超时:相机 Wi-Fi 可能已关闭或 IP 不对';
    }
    return '无线连接失败:$e';
  }

  @override
  Future<void> confirmPairing() async {
    final gate = _pairingGate;
    if (gate == null || gate.isCompleted) return;
    gate.complete(true);
  }

  @override
  Future<void> cancelPairing() async {
    final gate = _pairingGate;
    if (gate == null || gate.isCompleted) return;
    gate.complete(false);
  }

  @override
  Future<void> disconnect() async {
    // 状态先行离开 pairing:配对等待的 connect() 醒来据此走 aborted,
    // 不会把 disconnected 又覆盖成 connected。
    _transition(CameraLinkState.disconnected);
    final gate = _pairingGate;
    _pairingCode = null;
    gate?.complete(false);
    await _teardown();
    _error = null;
  }

  /// 链路与会话清理(尽力而为:链路已死时各步必然失败,不能互相吞)。
  Future<void> _teardown() async {
    _deviceName = null;
    await _wirelessBreakageSub?.cancel();
    _wirelessBreakageSub = null;
    _link.detach(); // 1. 挡新请求(会话清理不再往链路发指令)
    final wireless = _wirelessTransport;
    _wirelessTransport = null;
    await wireless?.close(); // 2. 无线毒化在途(串行门秒释放);USB 无此步
    try {
      await _session.close();
    } on Object {
      // 链路已断:会话层的本地状态已复位,足够
    }
    try {
      await _usb.close();
    } on Object {
      // 同上
    }
  }

  /// 断链回调:connected → failed(带原因),并尽力清理;
  /// pairing 态同理(等待确认期间相机收线/断网),除非 CompletePairing
  /// 已发出(相机自收会话,预期内)。
  void _onLinkBreakage(String reason) {
    if (_state == CameraLinkState.pairing && !_pairingCompleting) {
      // 先转 failed 再放行配对门:_runPairing 醒来见状态非 pairing,
      // 走 aborted 退出,不再收口。
      _error = '等待配对确认期间连接断开:$reason';
      _transition(CameraLinkState.failed);
      final gate = _pairingGate;
      _pairingCode = null;
      gate?.complete(false);
      // 链路已毒化,teardown 各步快速失败,由其内部兜底吞掉。
      unawaited(_teardown());
      return;
    }
    if (_state != CameraLinkState.connected) return;
    _error = reason;
    _transition(CameraLinkState.failed);
    // 链路已毒化,teardown 各步快速失败,由其内部兜底吞掉。
    unawaited(_teardown());
  }

  void _transition(CameraLinkState s) {
    // 离开 pairing 态即解除「相机收线不算断链」豁免:_pairingCompleting
    // 只在 pairing 态被读取,清在这里保证任何出口(重连/失败/断开)都不漏。
    if (s != CameraLinkState.pairing) _pairingCompleting = false;
    _state = s;
    _statesCtrl.add(s);
  }
}

/// 配对子流程的四种出口。
enum _PairResult {
  /// 0x952B 拒答(已配对/不要求):当前会话照常转正,不落记录。
  alreadyPaired,

  /// 0x935A 完成:相机已记录本设备并自收会话,须 teardown 后重连。
  newlyPaired,

  /// 用户跳过(或相机明确拒答 0x935A,防御分支):相机不记录,当前
  /// 会话照常转正,下次连接再问。
  declined,

  /// 等待期间被 disconnect()/断链收口:状态已处理,直接退出。
  aborted,
}

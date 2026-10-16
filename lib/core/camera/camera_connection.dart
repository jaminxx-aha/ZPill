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
import 'reconnect_policy.dart';

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

  /// 断链后的自动恢复期:按退避节拍重拨中(见 [CameraConnectionImpl] 类注)。
  /// 取景页保留冻结帧不弹回根页;disconnect 即止,预算耗尽转 failed。
  reconnecting,

  /// 失败(超时 / 无设备 / 会话拒绝),错误信息见 [CameraConnection.error]。
  failed,
}

abstract interface class CameraConnection {
  CameraLinkState get state;
  Stream<CameraLinkState> get states;
  String? get error;

  /// 已连接设备的展示名(答「哪一台」):无线 = mDNS 实例名(型号_序列
  /// 号,如 Z_f_8014411),手动 IP/USB 无实例名退 GetDeviceInfo 型号;
  /// 未连接为 null。
  String? get deviceName;

  /// 已连接设备的型号(GetDeviceInfo model,如 Zf):拍摄页胶囊左上
  /// 角只答「什么机型」,不答「哪一台」(2026-10-17 用户定案);未连接
  /// 为 null。
  String? get deviceModel;

  /// 当前(或最近一次)连接是否走无线(PTP-IP);false = USB。
  /// 相机页据此区分提示文案。
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
/// (0x935A)→ 相机把本客户端 UUID 记为已配对设备并自行结束会话,机身
/// 上弹「配对完成」等按 OK(按之前连接槽位不可用)→ teardown 后全流程
/// 重连(免配对相;按退避节拍等机身按 OK,默认 ~60s 窗)→ connected。
/// 「已配对」是纯客户端记账(相机不回答配对状态),记录键 =
/// GetDeviceInfo 序列号。
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
///
/// **自动重连**(2026-10-10,OpenZCine ReconnectBackoff/SessionRecovery
/// 理念):connected 断链 → [CameraLinkState.reconnecting],按 [_lastGood]
/// 档案完整重握手(重连 = 真实连接意图,相机单连接服务器的 mDNS
/// 铁律不破坏),抖动退避 + busy 慢拍 + 风暴保护见 [ReconnectPolicy];
/// 世代号护栏保证 disconnect/新恢复接管时旧循环安静退出。取景流冻结
/// 多次重启未恢复时由引擎经 [CameraConnectionImpl.requestRecovery]
/// 升级到同一条恢复路。
final class CameraConnectionImpl implements CameraConnection {
  CameraConnectionImpl({
    required UsbHostChannel usb,
    required PtpTransport usbTransport,
    required PtpLinkRouter link,
    required PtpSession session,
    Future<PtpIpTransport> Function()? createIpTransport,
    PairedCamerasStore? pairedCameras,
    List<Duration>? postPairingRetryDelays,
    Duration? wirelessConnectBudget,
    ReconnectPolicy? reconnectPolicy,
    Future<void> Function(Duration)? delay,
  })  : _usb = usb,
        _usbTransport = usbTransport,
        _link = link,
        _session = session,
        _createIpTransport = createIpTransport ?? _defaultIpTransport,
        _pairedCameras = pairedCameras,
        _postPairingRetryDelays =
            postPairingRetryDelays ?? _defaultPostPairingDelays,
        _wirelessConnectBudget =
            wirelessConnectBudget ?? _defaultWirelessConnectBudget,
        _reconnectPolicy = reconnectPolicy ?? ReconnectPolicy(),
        _delay = delay ?? Future<void>.delayed {
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

  /// 配对后重连的退避节拍(测试注入零/短延迟)。相机记录本设备后在
  /// 机身上弹「配对完成」画面等按 OK,按之前单连接槽位不可用(Zf
  /// 真机 2026-10-06:不等按 OK 立刻重连必失败,旧节拍 1s/2s×2 远短于
  /// 用户走过去按的时间)。默认 1s/2s 快试两拍后 3s 一拍,总窗 ~60s。
  final List<Duration> _postPairingRetryDelays;

  /// 默认节拍:1 + 2 + 19×3 = 60s,共 21 次重试。
  static final List<Duration> _defaultPostPairingDelays = [
    const Duration(seconds: 1),
    const Duration(seconds: 2),
    ...List.filled(19, const Duration(seconds: 3)),
  ];

  /// 无线连接总预算(测试注入短窗),覆盖建链+开会话(TCP 双通道握手 →
  /// GetDeviceInfo → OpenSession)与切应用模式两段。分步超时是逐级叠加
  /// 的:TCP 5s + 每步事务 15s,相机半哑(IP 通但 Init 不答、或收下会话
  /// 却对 op 死寂)时单次尝试最坏 30s+ 才收口,且 op 死寂还会带毒转
  /// connected(2026-10-08 用户反馈「上次」连接很久才失败)。健康链路
  /// ~2s 走完全部阶段,10s 预算只砍哑巴链路,不碰慢而活的链路;会话内
  /// 长事务(下载)有各自看门狗。
  final Duration _wirelessConnectBudget;

  /// 默认预算(见 [_wirelessConnectBudget] 注)。
  static const Duration _defaultWirelessConnectBudget = Duration(seconds: 10);

  /// 当前无线链路实例(连接期间非 null);teardown 收尾后清空。
  PtpIpTransport? _wirelessTransport;
  StreamSubscription<String>? _wirelessBreakageSub;
  bool _wireless = false;

  /// 自动重连策略(2026-10-10):抖动退避 + busy 慢拍 + 风暴保护,数值为
  /// OpenZCine ZR 标定起点(verify-on-HW);测试注入小预算短窗。
  final ReconnectPolicy _reconnectPolicy;

  /// 恢复循环节拍的时钟注入(单测零真实挂钟)。
  final Future<void> Function(Duration) _delay;

  /// 最近一次成功连接的档案(无线 = IP/实例名;USB = ip:null)。
  /// connected 断链后据此选路自动重连;手动 disconnect 清空。
  ({String? ip, String? instanceName})? _lastGood;

  /// 当前连接是否由恢复循环建立:DROP 记账口径 =「恢复建立的连接再次
  /// 断链」,首断与尝试失败都不计(防秒连秒断风暴把机身 PTP 栈打进
  /// 楔死态,见 [ReconnectPolicy] 类注)。
  bool _establishedByRecovery = false;

  /// 恢复循环世代号:disconnect() 或新一轮恢复接管时自增,旧循环的
  /// 迟到续体据此退出(与状态护栏双保险)。
  int _recoveryGen = 0;

  final StreamController<CameraLinkState> _statesCtrl =
      StreamController<CameraLinkState>.broadcast();

  CameraLinkState _state = CameraLinkState.disconnected;
  String? _error;
  String? _deviceName;
  String? _deviceModel;

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
  String? get deviceModel => _deviceModel;

  @override
  bool get isWireless => _wireless;

  @override
  String? get pairingCode => _pairingCode;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {
    if (_state == CameraLinkState.connected ||
        _state == CameraLinkState.connecting ||
        _state == CameraLinkState.pairing ||
        _state == CameraLinkState.reconnecting) {
      return; // 恢复循环不抢拨号:用户路径 = disconnect 后手动连
    }
    // 操作员动作:清风暴/DROP 账本(仅此处与 disconnect 清,重连成功
    // 绝不清 —— 「成功正是风暴最擅长伪装的东西」)。
    _reconnectPolicy.resetLedger();
    _transition(CameraLinkState.connecting);
    if (ip == null) {
      await _connectUsb();
    } else {
      await _connectWireless(ip, instanceName: instanceName);
    }
  }

  /// [silent] = true 供恢复循环拨号(与 [_connectWireless] 同构):失败
  /// 不上报状态(teardown 后把异常抛回),由恢复循环节拍决定去留;
  /// 相机未归位(listCameras 空)抛 [CameraNotPresentException]
  /// (cameraAbsent 慢拍,不耗预算)。
  Future<void> _connectUsb({bool silent = false}) async {
    try {
      final cameras = await _usb.listCameras();
      if (cameras.isEmpty) {
        if (silent) throw const CameraNotPresentException();
        await _failConnect('conn.errNoUsbCamera');
        return;
      }
      await _usb.open(cameras.first);
      _link.attach(_usbTransport);
      _wireless = false;
      await _openSessionOrReject(silent: silent);
    } on Exception catch (e) {
      if (silent) {
        await _teardown();
        rethrow;
      }
      await _failConnect('USB 连接失败:$e');
    } on Error catch (e) {
      // TypeError/StateError 等 Error 不受 on Exception 约束 —— 真机吃过
      // 大亏:通道返回类型不符的 TypeError 逃逸后 connect 静默死亡,状态
      // 机永远 connecting(无限转圈)。宁可显式 failed 把错误亮出来。
      if (silent) {
        await _teardown();
        rethrow;
      }
      await _failConnect('USB 连接失败:$e');
    }
  }

  /// [silent] = true 供配对后的重试拍:失败不上报状态(teardown 后把
  /// 异常抛回),由调用方的循环节拍决定去留 —— 整个等待窗保持
  /// connecting 态安静重试,不闪失败横幅。
  Future<void> _connectWireless(String ip,
      {String? instanceName, bool silent = false}) async {
    final transport = await _createIpTransport();
    // 先登记:握手/会话任一步失败,catch 里的 teardown 都能收尾实例
    _wirelessTransport = transport;
    try {
      // breakages 只在 connected/pairing 态生效,与 USB 同一入口;teardown 取消订阅
      _wirelessBreakageSub = transport.breakages.listen(_onLinkBreakage);
      // 建链+开会话整体计时(见 _wirelessConnectBudget):超时异常走
      // _wirelessErrorMessage 的 Timeout 分支,按总预算一次收口。
      final info = await _openWirelessLink(transport, ip)
          .timeout(_wirelessConnectBudget);
      _wireless = true;
      // 设备名取 mDNS 实例名(型号_序列号,答「哪一台」,与 SnapBridge
      // 同口径);无实例名(手动 IP)按 GetDeviceInfo 拼同款。UI 型号行
      // 另由 GetDeviceInfo 出,两行不再同源(2026-10-16:原先两行都显示
      // Zf)。USB 路无实例名,同样拼装(见 _openSessionOrReject 沿)。
      _deviceName = _deviceLabel(info, instanceName);
      _deviceModel = info.model;
      if (await _needsPairing(info)) {
        switch (await _runPairing(info, ip, instanceName)) {
          case _PairResult.newlyPaired:
            // 相机记录本设备后自收会话,并在机身上弹「配对完成」画面
            // 等按 OK —— 按之前单连接槽位不可用(Zf 真机 2026-10-06:
            // 立刻重连必失败,用户来不及按)。整个等待窗保持 connecting
            // 态安静重试(silent 拍不闪失败横幅),窗口节奏见
            // _postPairingRetryDelays;期间用户主动断开(disconnect 会
            // 转走 connecting 态)即止,耗尽才报失败并给按 OK 指引。
            await _teardown();
            _error = null;
            _transition(CameraLinkState.connecting);
            for (var attempt = 0;; attempt++) {
              try {
                await _connectWireless(ip,
                    instanceName: instanceName, silent: true);
                return; // connected(或外部收口后的任意态)
              } on Exception catch (e) {
                if (attempt >= _postPairingRetryDelays.length) {
                  await _failConnect('配对信息已发送,但相机迟迟未接受重连:'
                      '请在相机屏幕上按「OK」完成配对后再点连接'
                      '(最后错误:$e)');
                  return;
                }
                await Future<void>.delayed(_postPairingRetryDelays[attempt]);
                if (_state != CameraLinkState.connecting) {
                  return; // 退避期间被外部收口(用户断开等)
                }
              }
            }
          case _PairResult.alreadyPaired:
          case _PairResult.declined:
            break; // 当前会话照常转正
          case _PairResult.aborted:
            return; // 外部 disconnect / 断链已收口状态
        }
      }
      // 切应用模式 + 进 remote 闩(与 USB 路径同款)。2026-10-15 真机:
      // AP 进拍摄取景/对焦全坏 —— 0x9435 在无线上回 OK 但是假钥匙
      // (0x9201 仍被 0xA004 拒),旧无线流只发 0x9435 即返回、0x90C2
      // 全程没拉过;USB 路 2026-10-07 归因梯早已定案唯一解锁 = 0x90C2(1)
      // (开闩即还身 1→0 括号)。同计总预算:相机收下 Init/开完会话却
      // 对 op 死寂的半哑态,旧路径 0x9435 挂满 15s 看门狗后还会带毒转
      // connected(链路已毒、状态机报连上,真机 2026-10-08「上次」连接
      // 很久的场景之一)—— 预算内收不掉就按「连接超时」failed 收口。
      await _session.enableAppControl(remoteLatch: true)
          .timeout(_wirelessConnectBudget);
      // 连接档案落账(不管相机侧配对是否完成):扫描出的 IP/展示名进
      // 快速重连列表 —— STA「连接至计算机」模式相机不答 0x952B,旧
      // 逻辑只配对成功才落账 → 该模式永远存不下来(2026-10-06 真机
      // 反馈)。写盘失败不拦连接(档案是便利功能,非连接前置)。
      try {
        await _rememberCamera(info, ip, instanceName);
      } on Exception {
        // 档案写盘失败:连接照常
      }
      // 迟到续体守卫(同 _openSessionOrReject):拨号在途被 disconnect/
      // 断链收口后,迟到的成功不得覆盖已收口的状态。pairing 态合法
      // (配对 declined/alreadyPaired 的转正路径)。
      if (_state == CameraLinkState.disconnected ||
          _state == CameraLinkState.failed) {
        return;
      }
      _lastGood = (ip: ip, instanceName: instanceName);
      _error = null;
      _transition(CameraLinkState.connected);
    } on Exception catch (e) {
      if (silent) {
        await _teardown();
        rethrow;
      }
      await _failConnect(_wirelessErrorMessage(ip, e));
    } on Error catch (e) {
      if (silent) {
        await _teardown();
        rethrow; // 上抛给外层 _connectWireless 的 on Error 收口
      }
      await _failConnect('无线连接失败:$e');
    }
  }

  /// 无线建链 + 开会话阶段(TCP 双通道握手 → GetDeviceInfo →
  /// OpenSession),由调用方按 [_wirelessConnectBudget] 整体计时。
  ///
  /// 内部不做状态转移:超时后本函数的迟到续体还会走完既有 await,若在
  /// 此 _transition 会用过期结果覆盖已收口的 failed 态(成功路径的
  /// 状态转移全在调用方;_link.attach 不转移状态,后续连接会重新
  /// attach 覆盖,僵尸 attach 无害)。
  Future<PtpDeviceInfo> _openWirelessLink(
      PtpIpTransport transport, String ip) async {
    await transport.connect(ip);
    _link.attach(transport);
    // 无线不做 USB 那道受限画像拦截(STA 的 9 op 小表是常态人设,见类注)
    final info = await _session.getDeviceInfo(force: true);
    await _session.open();
    return info;
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
    await _rememberCamera(info, ip, instanceName, pairedOnCamera: true);
    return _PairResult.newlyPaired;
  }

  Future<bool> _needsPairing(PtpDeviceInfo info) async {
    final store = _pairedCameras;
    if (store == null) return false;
    final id = _cameraId(info);
    // 只认 wirelessPaired(相机侧已完成 0x935A):STA「连接至计算机」
    // 模式相机不答配对 op,应用侧虽已记住(连接即落账),相机侧没
    // 记录 —— 每次连接重问 0x952B(拒答不可见,一发 op 的代价),
    // 直到某次相机答了码走完配对为止。
    return !(await store.list()).any((c) => c.id == id && c.wirelessPaired);
  }

  /// 记连接档案(键 = 序列号,稳定;补全最近 IP 与展示名,方便快速
  /// 重连)。[pairedOnCamera] = 相机侧已记录本设备(0x935A 完成)——
  /// true 置位后不再重问配对;false 只更新连接信息,保留旧旗标。
  Future<void> _rememberCamera(
    PtpDeviceInfo info,
    String ip,
    String? instanceName, {
    bool pairedOnCamera = false,
  }) async {
    final store = _pairedCameras;
    if (store == null) return;
    final id = _cameraId(info);
    CameraInfo updated = CameraInfo(
      id: id,
      name: instanceName ?? info.model,
      model: info.model,
      lastIp: ip,
      lastConnectedAt: DateTime.now(),
      wirelessPaired: pairedOnCamera,
    );
    for (final existing in await store.list()) {
      if (existing.id == id) {
        updated = existing.copyWith(
          name: instanceName ?? existing.name,
          model: info.model,
          lastIp: ip,
          lastConnectedAt: DateTime.now(),
          wirelessPaired: pairedOnCamera ? true : null,
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

  /// 设备名(答「哪一台」):mDNS 实例名优先;无实例名(手动 IP/USB)
  /// 按 GetDeviceInfo 拼「型号_序列号」同款口径,序列号缺失才退纯型号
  /// (2026-10-16 用户定案)。相机页设备行消费;拍摄页胶囊另取型号
  /// [deviceModel](2026-10-17 定案:胶囊只答机型不答哪一台)。
  static String _deviceLabel(PtpDeviceInfo info, String? instanceName) {
    if (instanceName != null) return instanceName;
    final serial = info.serialNumber;
    return (serial == null || serial.isEmpty)
        ? info.model
        : '${info.model}_$serial';
  }

  /// USB 专属:GetDeviceInfo(受限画像检查)→ OpenSession → connected。
  /// 无线路径不走这里(有配对相,见 [_connectWireless])。
  ///
  /// [silent] = true 供恢复循环:受限画像不落 _failConnect(reconnecting
  /// 态会被守卫静默吞掉、循环误判成功),改抛 [ConnectRefusedException]。
  Future<void> _openSessionOrReject({bool silent = false}) async {
    // GetDeviceInfo 是 OpenSession 之前唯一允许的操作,顺带拿到型号名。
    // force:相机重启后 op 表可能变化(受限画像 ⇄ 全量),不能吃上次
    // 连接的缓存。
    final info = await _session.getDeviceInfo(force: true);
    if (!info.supportsOperation(PtpOperationCode.getObject)) {
      // 受限画像(USB 真机 2026-10-01:op 表只剩元数据/属性/事件,
      // GetObject/GetThumb 等数据操作全 0x200F;触发器未明,自行翻回)。
      // 与其让缩略图/下载逐个莫名失败,不如连接期就拦下并给出对策。
      // 无线不做此检查,理由见类注(STA 的 9 op 小表是常态人设)。
      if (silent) {
        throw ConnectRefusedException(
            '相机处于受限连接状态(数据操作被禁用)');
      }
      await _failConnect('conn.errRestricted');
      return;
    }
    await _session.open();
    // 切应用模式 + 进 remote(Z 系真机口径:不切则遥控写被 0x200F
    // AccessDenied 拒)。连接流一律进 remote 模式:2026-10-07 归因梯
    // (macOS-IC 真机)定案 —— 0x9435 回 OK 也是假钥匙,唯一实证解锁
    // 取景门 = 0x90C2(1);remote + 连接即取景 = 机身及时取景
    // (OpenZCine 效果)。尽力而为,失败不拦连接(梯记入
    // session.connectLadder,取景失败时浮出)。
    await _session.enableAppControl(remoteLatch: true);
    // 迟到续体守卫:拨号在途被外部收口(disconnect/断链)时,不得把
    // 已收口的状态覆盖成 connected。pairing 态合法(配对流程经此转正),
    // 只挡 disconnected/failed。
    if (_state == CameraLinkState.disconnected ||
        _state == CameraLinkState.failed) {
      return;
    }
    _lastGood = (ip: null, instanceName: null);
    _deviceName = _deviceLabel(info, null);
    _deviceModel = info.model;
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
      // 双模式通用(2026-10-06:手动 IP 连不上时旧文案只给 AP 热点
      // 指引,STA 场景误导 —— 该地址上根本没有相机,Mac 侧 ARP 探测
      // 实证手动 .5 从未入网)。
      return '连不上 $ip:这个地址上没有相机响应。同一 Wi-Fi 模式请点'
          '「扫描相机」确认相机当前地址(手填 IP 须与相机实际 IP 完全'
          '一致);AP 热点模式请先在系统 Wi-Fi 设置里加入相机热点;'
          '首次连接失败请在系统弹窗中允许访问本地网络后重试';
    }
    if (e is TimeoutException) {
      return '连接 $ip 超时:相机不在线或 IP 不对,建议用「扫描相机」确认';
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
    // 状态先行离开 pairing/reconnecting:配对等待的 connect() 醒来据此
    // 走 aborted 不收口;恢复循环见状态非 reconnecting 即止,迟到续体
    // 都不会把 disconnected 又覆盖成 connected。
    _transition(CameraLinkState.disconnected);
    _recoveryGen++; // 在途恢复循环世代失效
    _reconnectPolicy.resetLedger(); // 操作员动作:清风暴/DROP 账本
    _lastGood = null; // 手动断开:不再自动重连
    final gate = _pairingGate;
    _pairingCode = null;
    gate?.complete(false);
    await _teardown();
    _error = null;
  }

  /// 取景看门狗升级入口:取景流多次重启仍未恢复时,由引擎回调请求整链
  /// 重连(与断链同一条恢复路)。仅 connected 生效;其余态 no-op ——
  /// 链路已断的场景由断链路径接管。**不进 [CameraConnection] 接口**
  /// (仓内测试 8 个 _FakeConnection 不必跟随;AppServices 持具体类型)。
  void requestRecovery(String reason) {
    if (_state != CameraLinkState.connected) return;
    _beginRecovery(reason);
  }

  /// 链路与会话清理(尽力而为:链路已死时各步必然失败,不能互相吞)。
  Future<void> _teardown() async {
    _deviceName = null;
    _deviceModel = null;
    await _wirelessBreakageSub?.cancel();
    _wirelessBreakageSub = null;
    // remote 持有的镜像收尾:连接流的开闩括号(enableAppControl
    // 0x90C2(1)→(0))与取景自愈均已配对退出,这里兜的是用户「接管」
    // /括号退步被拒等仍持有的情形 —— 干净断开(用户点断开/连接失败
    // 回滚)先退 remote 再拆链,不退则机身停「已连接到计算机」屏
    // (2026-10-07 真机:remote 态跨拔插保持,半按快门才退)。链路已死
    // 时必然失败,尽力而为。
    if (_session.remoteModeActive) {
      try {
        await _session.changeCameraMode(0);
      } on Object {
        // 尽力而为:本地持有态由 close() 收口
      }
    }
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
    _beginRecovery(reason);
  }

  /// connected 态断链的统一入口:USB 看门狗 / 无线毒化 / 取景看门狗升级
  /// ([requestRecovery]) 同路。有连接档案([_lastGood])且未被风暴保护
  /// 暂停 → 自动恢复(reconnecting);否则按既有 failed 收口。
  void _beginRecovery(String reason) {
    // DROP 记账:只有「恢复循环建立的连接再次断链」才计(首断、尝试
    // 失败都不计),stormWindow 内 3 次 → 粘住暂停(账本只在操作员动作
    // 清零,重连成功绝不重置)。
    if (_establishedByRecovery) {
      _reconnectPolicy.noteDrop(DateTime.now());
    }
    _establishedByRecovery = false;
    final profile = _lastGood;
    if (profile == null || _reconnectPolicy.stormPaused) {
      // 无档案(本次运行从未成功连上)或风暴保护触发:不自动重连。
      _error = _reconnectPolicy.stormPaused
          ? 'conn.errReconnectPaused'
          : reason;
      _transition(CameraLinkState.failed);
      // 链路已毒化,teardown 各步快速失败,由其内部兜底吞掉。
      unawaited(_teardown());
      return;
    }
    _error = reason;
    _transition(CameraLinkState.reconnecting);
    unawaited(_recoverFromBreakage());
  }

  /// 恢复循环(结构仿配对后 60s 窗):settle 静置(相机拆会话槽需要
  /// 时间,零静置立刻 Init 正是把脆弱重连推入楔死的最后一击)→ 按
  /// [_lastGood] 档案重拨(silent,失败 teardown + rethrow)→ 按失败
  /// 分类取退避拍 → 预算耗尽/未归位超限转 failed。世代号 + 状态双
  /// 护栏:disconnect() 或新一轮恢复接管即退出。iOS 后台 Dart Timer
  /// 挂起 → 循环后台实际暂停、回前台续跑(退避不烧预算),已知形态。
  Future<void> _recoverFromBreakage() async {
    final gen = ++_recoveryGen;
    // 链路已毒化,teardown 各步快速失败,由其内部兜底吞掉。
    await _teardown();
    await _delay(_reconnectPolicy.settleDelay);
    final profile = _lastGood;
    if (profile == null) return; // disconnect 竞态:手动断开即止
    for (;;) {
      if (gen != _recoveryGen || _state != CameraLinkState.reconnecting) {
        return; // 世代失效(新恢复/disconnect)或外部收口
      }
      try {
        if (profile.ip == null) {
          await _connectUsb(silent: true);
        } else {
          await _connectWireless(profile.ip!,
              instanceName: profile.instanceName, silent: true);
        }
        // 转正由拨号路径完成(含配对后 60s 窗嵌套全程);aborted(等待
        // 期被外部收口)时状态已处理,不置恢复标记。
        if (_state == CameraLinkState.connected) {
          _establishedByRecovery = true;
        }
        return;
      } on Exception catch (e) {
        if (gen != _recoveryGen || _state != CameraLinkState.reconnecting) {
          return;
        }
        final kind = e is PtpInitRejectException
            ? ReconnectFailureKind.busy
            : e is CameraNotPresentException
                ? ReconnectFailureKind.cameraAbsent
                : ReconnectFailureKind.normal;
        final next = _reconnectPolicy.nextDelay(kind);
        if (next == null) {
          await _failRecovery(_recoveryGiveUpMessage(kind, e));
          return;
        }
        // 退避等待期的动态文案(无状态沿伴随,不触发重建,尽力而为)。
        _error = _recoveryStatusMessage(kind, e);
        await _delay(next);
      }
    }
  }

  /// 恢复终态文案(busy 不耗预算恒有下一拍,理论到不了终态;防御分支)。
  String _recoveryGiveUpMessage(ReconnectFailureKind kind, Object e) {
    switch (kind) {
      case ReconnectFailureKind.cameraAbsent:
        return '相机未重新接入:请重新插好 USB 数据线(并解锁相机)'
            '后点「重试」(最后错误:$e)';
      case ReconnectFailureKind.busy:
        return '相机持续被占用,自动重连未成功(最后错误:$e):'
            '请在占用它的应用(如 SnapBridge/尼享)里断开后点「重试」';
      case ReconnectFailureKind.normal:
        return '自动重连未成功(已试 ${_reconnectPolicy.maxAttempts + 1} 次,'
            '最后错误:$e):请确认相机已开机/在线后点「重试」';
    }
  }

  /// 退避等待期的状态文案(ConnectionPage hint build 期读)。
  String _recoveryStatusMessage(ReconnectFailureKind kind, Object e) {
    if (kind == ReconnectFailureKind.busy &&
        _reconnectPolicy.busyStreak >= 2) {
      return 'conn.errBusy';
    }
    if (kind == ReconnectFailureKind.cameraAbsent) {
      return 'conn.waitingUsb';
    }
    return '正在自动重连($e)';
  }

  /// 恢复循环终态收口:reconnecting 守卫(disconnect 竞态下的迟到收口
  /// 不得覆盖 disconnected)+ failed + teardown(teardown 幂等)。
  Future<void> _failRecovery(String message) async {
    if (_state != CameraLinkState.reconnecting) return;
    _error = message;
    _transition(CameraLinkState.failed);
    await _teardown();
  }

  void _transition(CameraLinkState s) {
    // 离开 pairing 态即解除「相机收线不算断链」豁免:_pairingCompleting
    // 只在 pairing 态被读取,清在这里保证任何出口(重连/失败/断开)都不漏。
    if (s != CameraLinkState.pairing) _pairingCompleting = false;
    _state = s;
    _statesCtrl.add(s);
  }
}

/// 恢复循环拨号时相机未归位(listCameras 空):cameraAbsent 慢拍分类,
/// 不耗 normal 预算,独立上限拍(USB 拔插等待,分钟级典型时长)。
final class CameraNotPresentException implements Exception {
  const CameraNotPresentException();

  @override
  String toString() => '相机未接入';
}

/// 恢复循环拨号被相机明确拒绝(如受限画像):normal 分类,耗预算。
final class ConnectRefusedException implements Exception {
  const ConnectRefusedException(this.message);

  final String message;

  @override
  String toString() => message;
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

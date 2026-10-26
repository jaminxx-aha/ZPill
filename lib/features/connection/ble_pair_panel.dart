/// BLE 配对面板(嵌入连接页蓝牙视图;原独立配对页退役)。
///
/// 相机侧:菜单「连接至智能设备」→ 扫描(广播窗 ~30s,一次连接
/// 即停)→ 点选 → 四步握手(全在 [AppServices.bleSession],本面板零
/// 协议知识)→ NOT1 → 写控制器名 → 身份落盘(ble_identity.json)。
///
/// 2026-10-19 改版定稿(用户七条要求 + 六裁定):①「已配对 / 其它
/// 设备」两段列表,打开沿**自动扫描**(静默 —— 无扫描钮、无「扫描
/// 中」指示);②打开沿**不自动回链**(进入页面不主动连接,后台守候
/// 由注入驱动承担,面板打开期间驱动挂起,页面内全手动);③iOS 首配
/// **系统配件选择器经典 bond**(2026-10-20 真机判别实验转正):握手
/// 落档后断链让相机暴露经典蓝牙,程序化拉起系统选择器,用户点相机
/// 完成经典配对(CTKD 派生 BLE 密钥)后回本页重连注册;取消/失败落
/// [onSystemBondNeeded] 红色引导卡深链兜底(宿主 Info.plist 须无
/// UIApplicationSceneManifest,见 _pair 内注释);ohos 首配沿自动程序
/// 化经典绑定(2026-10-22 用户定稿:无手动按钮,系统弹窗即确认);
/// ④回前台重扫一轮(挂起期系统可能停掉 BLE 扫描),重连循环在
/// 跑则不打扰。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/ble/adv_payload.dart';
import '../../core/ble/ble_camera_session.dart';
import '../../core/log/app_log.dart';
import '../../data/ble_identity_store.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../design/app_haptics.dart';
import '../../l10n/l10n.dart';
import '../../platform/ble_scanner.dart';
import '../../platform/services.dart';
import '../common/widgets/confirm_dialog.dart';
import 'connection_widgets.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// 扫描行:设备 + 最后见到时刻(过期修剪依据,行自持 —— 合并可改行
/// 的名,新鲜度跟着行走,无键漂移问题)。
class ScanRow {
  ScanRow(this.device, this.seenAt);
  BleDevice device;
  DateTime seenAt;
}

/// 扫描合并键:广播名归一化(去空格/下划线、小写)。广播名自身不可靠:
/// ①写法漂移(正常态/配对态空格/下划线不同);②**缩短名截断** —— BLE
/// 广播包 31B,mfg 数据挤占时名字用缩短名,`Z_f_8014411` 变 `Z_f_`
/// (2026-10-21 截图实证,两行并不上);空名无可信稳定键,退回 uuid
/// 专属键。
String _scanMergeKey(BleDevice d) => d.name.isEmpty
    ? 'uuid:${d.uuid}'
    : 'n:${d.name.replaceAll(RegExp(r'[\s_]+'), '').toLowerCase()}';

/// 行合并(纯函数,原地改行返回同表),四级键从严到宽:
/// ①归一化名键命中 → 整条换新;②**同配对关系(deviceId 相等)即同
/// 机身** —— 相机的次要广播(睡眠/省电载荷)可不带名(2026-10-21 截
/// 图实证:Z_f_8014411 与「(无名)」两行并存),名系规则够不着它,而
/// 0x0399 mfg 里的 deviceId 标识配对关系、重新配对才更换,跨载荷稳
/// 定;③缩短名前缀命中(一方名是另一方前缀,双方非空)→ 同机身:名取
/// **更长**一方(信息多者),行身份随之生长(`Z_f_` 行遇 `Z_f_8014411`
/// 即长成后者);④miss 追加。合并行地址/信号/mfg 恒取最新事件,名取
/// 非空/更长一方。前缀判定在两台同型号机身同播且其一被截断时理论可能
/// 张冠李戴(截断名无序列号可辨),实测单机身场景,接受。
List<ScanRow> mergeScanRow(
    List<ScanRow> current, BleDevice device, DateTime now) {
  ScanRow mergedRow(ScanRow row) => ScanRow(
        BleDevice(
          name: device.name.isEmpty
              ? row.device.name
              : (row.device.name.isEmpty ||
                      device.name.length >= row.device.name.length
                  ? device.name
                  : row.device.name),
          uuid: device.uuid,
          rssi: device.rssi,
          mfgData: device.mfgData,
        ),
        now,
      );
  final key = _scanMergeKey(device);
  final i = current.indexWhere((r) => _scanMergeKey(r.device) == key);
  if (i >= 0) {
    current[i]
      ..device = mergedRow(current[i]).device
      ..seenAt = now;
    return current;
  }
  // 同 uuid 命中(同一播报会话内地址稳定)→ 整条换新但**名取非空/更
  // 长一方**:相机的名放在 scan response 里,iOS 每扫描会话只送一次,
  // 后续 ADV 事件同名空 —— 若按空名键另开行,有名行 5s 无刷新即过期
  // 消失(2026-10-21 实证:设备出现又消失)。
  final u = current.indexWhere((r) => r.device.uuid == device.uuid);
  if (u >= 0) {
    current[u] = mergedRow(current[u]);
    return current;
  }
  final devId = expectedControllerDeviceId(device.mfgData);
  if (devId != null) {
    final j = current
        .indexWhere((r) => expectedControllerDeviceId(r.device.mfgData) == devId);
    if (j >= 0) {
      current[j] = mergedRow(current[j]);
      return current;
    }
  }
  if (device.name.isNotEmpty) {
    for (final r in current) {
      if (r.device.name.isEmpty) continue;
      if (r.device.name.startsWith(device.name) ||
          device.name.startsWith(r.device.name)) {
        final k = current.indexOf(r);
        current[k] = mergedRow(current[k]);
        return current;
      }
    }
  }
  return current..add(ScanRow(device, now));
}

class BlePairPanel extends StatefulWidget {
  const BlePairPanel({
    super.key,
    this.savedIdentity,
    this.session,
    this.onIdentityChanged,
    this.onSystemBondNeeded,
    this.onRetryingChanged,
  });

  /// 已存身份(宿主预填):嵌入连接页蓝牙视图时传
  /// `controller.bleIdentity` —— 身份源随宿主(测试也走此参注入);null
  /// 时面板自读 AppServices 盘档。宿主身份沿更新经 didUpdateWidget 同步
  /// 进面板态。
  final BlePairedIdentity? savedIdentity;

  /// 会话(十二轮注入):嵌入连接页蓝牙视图时传
  /// `controller.bleSession` —— 生产两者本是同一只(AppServices 常驻
  /// 驱动那只),显式传参免全局耦合;不传回落单例(独立挂面板/旧测试
  /// 兼容)。面板的重连循环/断链/状态行随此会话。
  final BleCameraSession? session;

  /// 身份落盘/解除沿回调宿主(重载 controller.bleIdentity,状态行不
  /// 残留旧身份)。
  final void Function()? onIdentityChanged;

  /// iOS 首配握手落档沿回调宿主(置控制器 bleAwaitSystemBond → 蓝牙页
  /// 弹系统配对红卡;2026-10-19 改版:自动跳系统蓝牙删除,引导收进页内)。
  final void Function()? onSystemBondNeeded;

  /// 重连循环起停沿回调宿主(九轮):蓝牙 hero 的涟漪须跟「正在连」
  /// 走,而无命中轮会话态停在 idle 跟不出 —— 宿主页接住进
  /// ValueNotifier 驱动 hero busy(会话态 ∪ 面板循环)。循环被废
  /// (cancelResume/扫描/解除/拆面板)同样上抛 false。
  final void Function(bool active)? onRetryingChanged;

  @override
  State<BlePairPanel> createState() => BlePairPanelState();
}

/// 面板 State 公开(八轮):宿主页蓝牙 hero「连最近」经
/// [manualResume] 复用本面板「连接」按钮的整条手动重连路(显式意图
/// 解除 manualOff、绕深睡闸门、在途循环不重入);九轮再公开
/// [cancelResume](在途再点 = 取消)与 [retrying](在途判定)。
class BlePairPanelState extends State<BlePairPanel>
    with WidgetsBindingObserver {
  StreamSubscription<BleSessionState>? _stateSub;
  StreamSubscription<BleEvent>? _eventSub;
  final List<ScanRow> _scanRows = [];
  bool _scanning = false;
  BleSessionState _sessionState = BleSessionState.idle;
  BlePairedIdentity? _saved;

  /// 本次配对设备的 BLE 广播名(鸿蒙经典绑定按名匹配用)。
  String _pairedName = '';
  bool _binding = false;

  /// 扫描条目新鲜度:行自持 seenAt。「相机退出了,列表里就该消失」的
  /// 用户预期落地 —— **5s 无再见到期**,2s 周期修剪(2026-10-21 定稿,
  /// 用户裁定 20s 太久)。配对窗广播连续,不会误删。
  Timer? _scanPruneTimer;
  Timer? _scanCycleTimer;
  bool _scanWanted = false;
  bool _panelScanHeld = false;
  static const Duration _scanEntryTtl = Duration(seconds: 5);

  static const MethodChannel _bleChannel = MethodChannel('nikonpill/ble');

  /// 会话解析:宿主注入优先(十二轮,生产 = 控制器/驱动同一只),回落
  /// AppServices 单例(独立挂面板)。
  BleCameraSession get _session =>
      widget.session ?? AppServices.instance.bleSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 页面存续期挂起注入驱动(自动重连/GEO tick 会与手动流程撞车;
    // 2026-10-19 定稿:页面内绝不自动连,离页恢复驱动守候)。
    AppServices.instance.suspendBleDriver();
    _sessionState = _session.state;
    _stateSub = _session.states.listen((s) {
      if (mounted) setState(() => _sessionState = s);
      _syncScanOwnership(); // 态变即重算扫描权(idle 面板持有,余态让位)
      // ready 沿驱动接管(2026-10-21 实证:面板在非 ready 态打开 = 挂
      // 起,会话其后连上时挂起无人解除 → 注入层冻死、GPS 零写入;
      // StateTracker updatingLocation=false 实锤)。resume 幂等:驱动已
      // 在跑则仅清挂起旗标,重连循环照旧由驱动承担(bleDriverRunning
      // 让位护栏在)。
      if (s == BleSessionState.ready) {
        AppServices.instance.resumeBleDriver();
      }
      // 十五轮:页面开着的重连常驻 —— 掉线自动入 reconnecting 后,面板
      // 就是重连执行者(驱动已挂起),自动循环跑起来(深睡闸门开着,
      // 与驱动同参);相机就绪即连上。就绪/闲态沿不自动起(2026-10-19
      // 「进入页面不主动连接」只限从零连;恢复掉线是 reconnecting 的
      // 题中之义);用户显式断开意图(manualOff)不越。
      if (s == BleSessionState.reconnecting &&
          !_retryActive &&
          !AppServices.instance.bleDriverRunning && // 驱动在跑则让位(双循环防)
          !AppServices.instance.bleManualOff) {
        unawaited(_resume(gateStandby: true, autoRearm: true));
      }
    });
    // 开页即 reconnecting(掉线态打开页面):无状态事件,起自动循环。
    if (_sessionState == BleSessionState.reconnecting &&
        !AppServices.instance.bleDriverRunning &&
        !AppServices.instance.bleManualOff) {
      unawaited(_resume(gateStandby: true, autoRearm: true));
    }
    // 事件订阅:设备发现列示(实时,不等扫描窗收口)+ 流程日志。日志
    // 全走统一日志(AppLog ble 域,通用日志页可查;帧级 trace 由
    // AppServices 常年接线,不在此管)。
    _eventSub = PlatformServices.ble.events.listen(_onEvent);
    // 条目过期修剪(2s 周期,dispose 收;TTL 5s)。
    _scanPruneTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _pruneStaleDevices();
    });
    // 宿主喂的身份首帧即入:重连钮/冲突比较不等异步(盘档读盘悬着时
    // 身份不能跟着悬)。
    _saved = widget.savedIdentity;
    // 打开沿自动扫描(下一帧:setState 路径里有异步,initState 直调
    // 非法)。静默 —— 无扫描钮、无「扫描中」指示。面板存活期持续扫描
    // (_scanWanted + 状态机仲裁,见 _syncScanOwnership)。
    _scanWanted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _autoStartScan();
      }
    });
    unawaited(_loadSaved());
  }

  /// 扫描权仲裁(2026-10-21):面板存活期只有 **idle 态**由面板循环持
  /// 续扫描 —— 单发 30s 扫描窗过后无人再扫,行 5s 过期清空,「设备出
  /// 现一次就再也不出现」实证。ready/reconnecting = 驱动接管(连接/
  /// 重连扫描 scanForDeviceId),pairing = 会话握手不扫。态变即重算,
  /// _panelScanActive 随持有态同步(驱动扫描让位/归还)。
  void _syncScanOwnership() {
    // manualOff 只压制回链,不压制发现扫描(看设备列表是面板本职能)。
    // **有身份即不持扫描权**(2026-10-21 定稿:回链优先,已配对相机也
    // 不进其它设备 —— 面板发现扫描此时无意义,无线电让给驱动回链)。
    // 无身份(真首配)才由面板持有,持续扫描配对菜单相机。
    final want = mounted &&
        _scanWanted &&
        _sessionState == BleSessionState.idle &&
        _session.identity == null &&
        _saved == null;
    if (want && !_panelScanHeld) {
      _panelScanHeld = true;
      AppServices.instance.setPanelScanActive(true);
      if (!_scanning) unawaited(_startScan());
    } else if (!want && _panelScanHeld) {
      _panelScanHeld = false;
      AppServices.instance.setPanelScanActive(false);
      _scanCycleTimer?.cancel();
      if (mounted && _scanning) unawaited(_session.stopScan());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台重扫一轮(挂起期间系统可能停掉 BLE 扫描,iOS 常见)。
    // 页面内**不自动回链**(2026-10-19 用户定稿:进入页面不主动连接
    // —— 回链只由后台注入驱动守候承担,而驱动此刻挂起);重连循环在
    // 跑则不打扰(用户显式发起的不被重扫废掉)。
    if (state == AppLifecycleState.resumed &&
        _sessionState != BleSessionState.ready &&
        _sessionState != BleSessionState.pairing &&
        !_scanning &&
        !_retryActive) {
      _autoStartScan();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRetry(notify: false);
    _session.cancelPairWait(); // 配对等待循环即停(纪元闸)
    AppServices.instance.resumeBleDriver();
    _stateSub?.cancel();
    _eventSub?.cancel();
    _scanPruneTimer?.cancel();
    _scanCycleTimer?.cancel();
    _scanWanted = false;
    if (_panelScanHeld) {
      _panelScanHeld = false;
      AppServices.instance.setPanelScanActive(false);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BlePairPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主身份镜像沿(配对/解除 → onIdentityChanged → 控制器重载 → 回
    // 喂):面板 _saved 跟进,设备行与冲突比较不残留旧身份。实例不等价
    // 才动 —— 同实例回喂(普通重建)不抖。
    if (!identical(widget.savedIdentity, oldWidget.savedIdentity)) {
      _saved = widget.savedIdentity;
    }
  }

  Future<void> _loadSaved() async {
    final saved = widget.savedIdentity ??
        await AppServices.instance.bleIdentityStore.load();
    if (mounted) {
      setState(() => _saved = saved);
    }
  }

  void _log(String line) => AppLog.i(AppLog.ble, line);

  /// 打开沿/回前台沿自动扫描(2026-10-19 用户定稿:扫描静默自动)。
  /// 就绪/握手中不起:就绪态列表整体隐藏;握手期扫描与握手互斥。
  void _autoStartScan() {
    if (_sessionState == BleSessionState.ready ||
        _sessionState == BleSessionState.pairing) {
      return;
    }
    _syncScanOwnership();
  }

  void _onEvent(BleEvent event) {
    switch (event) {
      case BleStateChanged(:final state):
        _log('蓝牙态:$state');
      case BleDeviceFound(:final device):
        // 实时列示:原生每发现一台就推,不等扫描窗收口(30s 全窗太久,
        // 用户对着空列表干等)。原生侧已过尼康过滤,事件即有效命中。
        if (!mounted) return;
        setState(() => mergeScanRow(_scanRows, device, DateTime.now()));
      case BleConnected(
          :final uuid,
          :final characteristics,
          :final writeWithoutResponseMtu,
        ):
        _log('已连接 $uuid,无响应写 MTU=$writeWithoutResponseMtu');
        final lss = characteristics.entries
            .where((e) => e.key.endsWith('-3dd4-4255-8d62-6dc7b9bd5561'))
            .map((e) => '${e.key.substring(4, 8)}(${e.value})')
            .join(' ');
        AppLog.d(AppLog.ble, 'LSS 特征表:$lss');
      case BlePreConnected(:final uuid):
        // 物理链路建立沿(iOS didConnect):与「已连接」(特征发现完成)
        // 两行之差 = 150ms 礼让 + 服务发现耗时,深睡重连时序取证用。
        _log('物理连接建立 $uuid');
      case BleDisconnected(:final uuid):
        _log('断连 $uuid');
      case BleNotified(:final uuid, :final data):
        // iOS 对 SIG 采纳 16 位 UUID 回 4 字符短串,裸 substring(4,8) 会
        // RangeError 炸断事件链(2026-10-19 真机实证)。
        AppLog.d(AppLog.ble,
            '← ${uuid.length <= 8 ? uuid : uuid.substring(4, 8)} ${hexOf(data)}');
      case BleError(:final code, :final message, :final uuid):
        AppLog.w(AppLog.ble,
            '错误 $code${uuid == null ? '' : ' @$uuid'}:$message');
    }
  }

  /// 「其它设备」列示源:扫描行滤掉已配对相机(它在上面有自己的行 +
  /// 状态点;2026-10-21 用户定稿「其它设备中不再出现已配对的设备」)。
  List<ScanRow> _othersDevices() {
    final paired = _pairedScanRow();
    if (paired == null) return _scanRows;
    return _scanRows.where((r) => !identical(r, paired)).toList();
  }

  /// 过期修剪:行 5s 未再见到即摘除 —— 相机退菜单/睡眠 = 停广播 = 行
  /// 消失(2026-10-21 用户定稿「扫描不到就不该存在」+「20s 太久,5s」)。
  void _pruneStaleDevices() {
    final now = DateTime.now();
    final alive =
        _scanRows.where((r) => now.difference(r.seenAt) <= _scanEntryTtl);
    if (alive.length == _scanRows.length) return;
    if (!mounted) return;
    setState(() => _scanRows
      ..clear()
      ..addAll(alive));
  }

  Future<void> _startScan() async {
    if (_scanning ||
        _sessionState == BleSessionState.pairing ||
        !_panelScanHeld) {
      return; // 非持有态(ready/reconnecting/关页)不扫:驱动接管或无需
    }
    // 扫描与重连循环互踩(扫描互踩扫描,BLE 无线电独占):扫描起步
    // 即废在途重连(打开沿/回前台沿的自动扫描不会走到这 —— 有重连
    // 在跑就不起扫;显式路径已无,保留护栏)。2026-10-21:_cancelRetry
    // 只能废**待发**重连,在途 retryReconnect 的续棒会把驱动扫描带回来
    // 反复顶掉本扫描(发现事件断流、5s 过期剪行实证)→ 面板扫描期置
    // _panelScanActive,驱动让位,收口沿归还并续跑。
    _cancelRetry();
    AppServices.instance.setPanelScanActive(true);
    setState(() {
      _scanning = true;
      // 不清列表(2026-10-21):每窗清空 = 窗切换闪烁(设备出现-消失-
      // 出现实证);行存续由合并+5s 过期修剪唯一裁决,新窗发现即续刷新。
    });
    try {
      final devices = await _session.scanForPairing();
      // 台数行带状态字节(Zf 实证 0x1E/0x1F):重连时序取证要能对上
      // 「命中时相机是否深睡」。
      _log('扫描结束:${devices.length} 台(${devices.map(_deviceLabel).join(', ')})');
      if (!mounted) return;
      // 收口表同样过行合并:原生按地址收集,相机一轮配对换一次 RPA,窗
      // 内多轮配对(用户实测:配对→返回→再配对)会让收口表自身带重复,
      // 直接替换会把实时侧合并好的列表整个覆盖回去(2026-10-21 二次实
      // 证)。
      final now = DateTime.now();
      setState(() {
        // 同上:收口不清列表,合并刷新 + 5s 过期修剪负责存续与淘汰。
        for (final d in devices) {
          mergeScanRow(_scanRows, d, now);
        }
      });
    } on Exception catch (e) {
      _log('扫描失败:$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
      // 持续扫描循环:面板持有期间窗与窗之间留 2s 空隙(<5s TTL,行不
      // 会因窗间静默被剪)。_panelScanActive 横跨整段持有期恒真(驱动
      // 让位),释放只在所有权变更(_syncScanOwnership !want)与 dispose。
      if (mounted && _panelScanHeld) {
        _scanCycleTimer?.cancel();
        _scanCycleTimer = Timer(const Duration(seconds: 2), () {
          if (mounted && _panelScanHeld) unawaited(_startScan());
        });
      }
    }
  }

  String _deviceLabel(BleDevice d) {
    final name = d.name.isEmpty ? '(无名)' : d.name;
    final st = advertisedStatusByte(d.mfgData);
    if (st == null) return name;
    return '$name(0x${st.toRadixString(16).toUpperCase().padLeft(2, '0')})';
  }

  /// 首次配对:session 四步握手 → 身份落盘 → 通知注入驱动刷新。
  Future<void> _pair(BleDevice device) async {
    final app = AppServices.instance;
    _cancelRetry();
    app.bleManualOff = false; // 新配对 = 连接意图,解除手动断开压制
    _log('配对 ${device.name}(${device.uuid})…');
    _pairedName = device.name; // 经典绑定匹配用(鸿蒙)
    try {
      await _session.pair(device);
    } on Exception catch (e) {
      _log('配对失败:$e');
      return;
    }
    final id = _session.identity;
    if (id == null) return;
    await app.bleIdentityStore.save(BlePairedIdentity(
      peripheralUuid: id.peripheralUuid,
      deviceId: id.deviceId,
      nonce: id.nonce,
      serial: id.serial,
      controllerName: id.name,
      // 相机广播名只在扫描时见过,握手帧里没有 —— 此刻不存就没地方
      // 再拿(设备行展示名,见 BlePairedIdentity.cameraName)。
      cameraName: device.name,
      pairedAt: DateTime.now(),
    ));
    // 配对成功即驱动接管(2026-10-21:用户定稿「配对成功后直接连接」
    // —— 旧流程面板挂起驱动直到离页,配对成功后停在面板里注入层永远
    // 不起、定位流不开、GPS 零写入)。resume 清挂起 + 按当前会话态续上
    // (ready → 注入层即刻对齐;重连循环由驱动接管,面板让位)。
    app.resumeBleDriver();
    unawaited(AppHaptics.success()); // 配对成功确认沿(展示「配对成功」处震)
    _log('配对成功 ✓ device=${id.deviceId.toRadixString(16)} '
        'serial=${id.serial} 身份已落盘(驱动接管)');
    widget.onIdentityChanged?.call();
    await _loadSaved();
    // iOS 首配注册 = 系统配件选择器经典 bond(机制:SnapBridge 程序化
    // 拉起 CoreBluetoothUI.BTDevicePickerUI 完成经典 BR/EDR SSP bond,
    // CTKD 派生 BLE 密钥;公开 API 无特权门 —— 2026-10-20 REA 逆向 +
    // 真机 unified log 对照定案)。断链先行:相机等 BLE 释放才暴露经典
    // 蓝牙。宿主要求:Info.plist 不得带 UIApplicationSceneManifest ——
    // 选择器建窗走 legacy 生命周期查法,scene manifest 宿主查不到 scene,
    // 建出无 scene 窗永不可见、回调悬挂(Flutter 3.47 模板自带 manifest,
    // 已摘;2026-10-20 真机判别实验实锤)。Info.plist 同时声明
    // UISupportedExternalAccessoryProtocols + external-accessory 后台
    // 模式(对齐 SnapBridge)。谓词不可用(键名黑盒,评估崩
    // valueForUndefinedKey),恒 nil = 显示全部。
    if (Platform.operatingSystem == 'ios') {
      await _session.disconnect();
      String? outcome;
      try {
        outcome = await _bleChannel.invokeMethod<String>(
            'showAccessoryPicker');
      } on Exception catch (e) {
        _log('配件选择器调用失败:$e');
      }
      _log('配件选择器返回:$outcome');
      if (outcome == 'success' || outcome == 'alreadyConnected') {
        // 经典 bond 已成:重扫让重连钮出位,注册走既有显式重连路。
        _autoStartScan();
      } else {
        // cancelled/failed/通道异常:落红卡深链兜底,用户不被卡死。
        widget.onSystemBondNeeded?.call();
      }
      return;
    }
    // 收尾剧本按「通道面 × 宿主平台」分派,不只看 Platform.operatingSystem
    // —— 卓易通等容器里 Android APK 的通道由 Android 插件应答,宿主平台
    // 表现可能与真机不同,用通道探针(platformTag)对账。
    final nativeFace = await _bleNativeFace();
    if (nativeFace == 'android' && Platform.operatingSystem == 'android') {
      // 真机 Android:createBond 公开 API 可为,剧本同原生 ohos(断链 →
      // 绑定 → 直连先行回链)。
      AppServices.instance.bleManualOff = true;
      await _session.disconnect();
      await Future<void>.delayed(const Duration(seconds: 3));
      await _bondClassic();
      _session.directFirstPending = true;
      await manualResume();
      return;
    }
    if (nativeFace == 'android') {
      // 卓易通等容器:实测配对在握手首帧就被加密墙拦下(0x2000 写被拒,
      // 会话侧 _isCryptoWall fail-fast),正常走不到这里;若未来容器放行
      // 到这儿,也按「不断链」收尾 —— 程序化 bond 在容器的可用性未实证,
      // 断链又会让相机进静默态,风险大于收益。
      _log('容器环境:程序化绑定不可用,注册在当前链上继续(不断链)');
      return;
    }
    if (Platform.operatingSystem == 'ohos') {
      // 鸿蒙首配收尾 = 程序化经典绑定(2026-10-22 用户定稿:对齐 iOS
      // 剧本,配对成功沿自动进行,无手动按钮)。断链先行:相机等 BLE
      // 释放才暴露经典蓝牙;manualOff 先压驱动回链(防回链扫描与经典
      // 发现抢相机)。断链后留让位窗 —— 相机收拾 BLE 链路才在菜单配
      // 对态暴露经典蓝牙(首测零缓冲直发配对把
      // 相机射频楔死,杀应用才解)。绑定收口后 manualResume 绕深睡闸
      // 显式接回:刚配对完的相机多半已回待机,驱动自动回链会守闸干等
      // 唤醒;注册在回链的复用握手上落地(NOT1 随 bond 落地后才出现)。
      AppServices.instance.bleManualOff = true;
      await _session.disconnect();
      await Future<void>.delayed(const Duration(seconds: 3));
      await _bondClassic();
      // 绑定收口(成/败皆然)武装直连先行:断链后的相机在静默等待态
      // 零广播(2026-10-22 真机 hilog 实证:扫描数分钟全空、设备灰,
      // bond 落地与否都不回广播窗),唯直连可及 —— 扫描在直连未成时
      // 照旧接力。manualResume 绕深睡闸显式接回,注册在复用握手上
      // 落地(NOT1 随 bond 落地后才出现)。
      _session.directFirstPending = true;
      await manualResume();
      return;
    }
  }

  /// 已注册相机的重连:按已存 deviceId 扫 0x0399 重连广播,命中即以
  /// 已存 device/nonce 复用握手 —— 相机只认保存过的身份,扫描列表
  /// 再点 = 全新握手,必被秒断(2026-10-13 真机实证)。点一次自动
  /// 重试约 1 分钟(退避节奏),不必连点。
  ///
  /// [gateStandby]:重连按钮 = 显式意图绕深睡闸门(false);自动行为
  /// 已按 2026-10-19 裁定全部退役,页面内只有显式重连。
  bool _retryActive = false;

  /// 重连循环世代号:[_cancelRetry] 自增即废在途循环;每个 await 后
  /// 对账,不等者退场(扫描/配对/解除/拆面板沿即刻止步)。
  int _retryGen = 0;
  Timer? _retryWait;
  Completer<void>? _retryWaitDone;

  bool get _retrying => _retryActive;

  /// 在途重连循环(公开只读,八轮):宿主页蓝牙 hero 连最近的
  /// 不重入守卫。
  bool get retrying => _retryActive;

  /// 废在途重连:退避等待即刻醒(Completer 放行,await 不悬死)。
  /// dispose 沿传 notify:false —— 此时 element 已 defunct(mounted 仍真),
  /// setState 会炸断言。onRetryingChanged 照上抛(九轮:hero 涟漪停
  /// 须即时;拆面板沿宿主通知器还在,落值无害)。
  void _cancelRetry({bool notify = true}) {
    _retryGen++;
    _retryWait?.cancel();
    _retryWait = null;
    final w = _retryWaitDone;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
    _retryWaitDone = null;
    if (_retryActive) {
      _retryActive = false;
      widget.onRetryingChanged?.call(false);
      if (notify && mounted) setState(() {});
    }
  }

  /// 可取消退避等待:取消沿即刻醒,不等满 delay。
  Future<void> _retryDelayWait(Duration d) async {
    final done = Completer<void>();
    _retryWaitDone = done;
    _retryWait = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
  }

  Future<void> _resume({bool gateStandby = true, bool autoRearm = false}) async {
    if (_retryActive) return;
    _retryActive = true;
    final gen = _retryGen;
    widget.onRetryingChanged?.call(true);
    if (mounted) setState(() {});
    _log('重连(复用身份 ${_saved!.deviceId.toRadixString(16)})…');
    var hintedForeign = false;
    for (var attempt = 1; attempt <= 6; attempt++) {
      if (gen != _retryGen || !mounted) break;
      if (_session.state == BleSessionState.ready) {
        _log('已就绪 ✓');
        break;
      }
      final ok = await _session.retryReconnect(gateStandby: gateStandby);
      if (!mounted || gen != _retryGen) break;
      if (ok) {
        _log('重连成功 ✓');
        break;
      }
      final err = _session.lastError;
      if (_session.lastRetryGated) {
        _log('第 $attempt 轮:相机待机(深睡闸门拦下),等唤醒…');
      } else {
        _log('第 $attempt 轮无命中${err == null ? '' : '(${err.key})'},'
            '${_session.nextRetryDelay.inSeconds}s 后再试(相机须停在'
            '「连接至智能设备」页或可重连待机)');
      }
      // 重连未命中 + 本页扫描结果里有「在等别的手机」的相机 → 复用同一条
      // 冲突指引(重连扫描被 native 过滤只看我方 deviceId,别家相机只有
      // 本页配对扫描才看得见);每轮重连只提示一次,免刷屏。
      if (!hintedForeign) {
        final foreign = _foreignWaiting();
        final foreignId = foreign == null
            ? null
            : expectedControllerDeviceId(foreign.mfgData);
        if (foreign != null && foreignId != null) {
          hintedForeign = true;
          _log(_conflictHint(context, foreignId));
        }
      }
      await _retryDelayWait(_session.nextRetryDelay);
    }
    // 十五轮:自动重连**常驻**(autoRearm)—— 六轮未中且会话仍停在
    // reconnecting:退避后续跑新六轮。页面开着时驱动被挂起,面板就是
    // 重连的执行者 —— 「断开自动进入重连后应该要能重新连接」:相机
    // 就绪等在广播,循环常驻直到连上或用户取消(点状态词/hero)。退避
    // 走可取消等待(_cancelRetry 即刻醒);续棒静默让位旗标,新棒即刻
    // 重举(onRetryingChanged/涟漪不闪断)。显式单发(manualResume)
    // 不续跑。
    if (autoRearm &&
        gen == _retryGen &&
        mounted &&
        _session.state == BleSessionState.reconnecting) {
      await _retryDelayWait(_session.nextRetryDelay);
      if (gen == _retryGen &&
          mounted &&
          _session.state == BleSessionState.reconnecting) {
        _retryActive = false;
        unawaited(_resume(gateStandby: gateStandby, autoRearm: true));
        return;
      }
    }
    if (gen == _retryGen) {
      _retryActive = false;
      widget.onRetryingChanged?.call(false);
      if (mounted) setState(() {});
    }
  }

  /// 手动唤醒重连:点按即显式意图 —— 打断在场循环,绕闸直连待机相机
  /// (深睡唤醒 ~12s 开销真机实测,6490990 闸门前老行为)。世代号废旧
  /// 循环、退避等待即刻醒,新循环走 [_resume] 同一收尾路。待机机(黄
  /// 点)点行配对同理 —— 显式意图都允许点醒(2026-10-19 裁定⑤)。
  /// 公开面(八轮):宿主页蓝牙 hero「连最近」同走此路。
  ///
  /// 十四轮定样 = **全面接管**:①停面板在途扫描(打开沿自动扫 30s 窗,
  /// 扫描互踩扫描 —— 重连的 scanForDeviceId 与自页扫描并行 = 全程无
  /// 命中,「断开后怎么都连不上」主因);②会话非 idle(驱动在途轮/
  /// 残留握手卡在 pairing)先断链清态再起循环 —— 用户「必须手动停止
  /// 重连再点连接才行」的两步舞收成一步。十五轮:连接中(reconnecting)
  /// 行内不再有「连接」钮(不与状态词并存),接管路仅防御性保留。
  Future<void> manualResume() async {
    // 显式连接 = 解除手动断开意图(守候/驱动恢复资格)。
    AppServices.instance.bleManualOff = false;
    _cancelRetry();
    if (_scanning) {
      setState(() => _scanning = false);
      unawaited(_session.stopScan());
    }
    if (_session.state != BleSessionState.idle) {
      // 接管:清在途(会话 disconnect 弃局握手 + 纪元闸,在途尝试的
      // 迟到收口不再翻状态)。
      await _session.disconnect();
    }
    await _resume(gateStandby: false);
  }

  /// 取消在途连接(九轮公开):宿主页蓝牙 hero 在途再点走此路 —— 与
  /// 「断开」钮同语义:置显式断开意图(manualOff,压离页后驱动自动
  /// 回链)+ 废重连循环(世代号,退避等待即刻醒)+ 断链(在途的
  /// 连接/握手尝试一并了断;首配中途取消 = 身份不落盘,重配重来)。
  Future<void> cancelResume() async {
    AppServices.instance.bleManualOff = true;
    _cancelRetry();
    await _session.disconnect();
  }

  /// 程序化经典蓝牙绑定(鸿蒙独有;iOS 无此 API,走系统配件选择器,
  /// 见宿主红色引导卡)。首配配对成功沿自动调用(相机须先断开 BLE
  /// 才暴露经典蓝牙 —— 断链与驱动压制由调用方先行);绑定完成(系统
  /// 弹窗确认)后驱动回链,注册落档。失败不拦流程:驱动照常回链,
  /// bond 非运行必需。
  Future<void> _bondClassic() async {
    if (_binding) {
      return;
    }
    setState(() => _binding = true);
    _log('经典蓝牙绑定:发现+配对中(手机上确认系统弹窗)…');
    try {
      final ok = await _bleChannel.invokeMethod<bool>('bondDevice', {
        'deviceId': _saved!.peripheralUuid,
        'name': _pairedName,
        'serial': _saved!.serial,
      });
      _log(ok == true ? '经典蓝牙绑定完成 ✓(驱动回链中)' : '绑定未完成');
    } on MissingPluginException {
      _log('此平台不支持程序化绑定');
    } on PlatformException catch (e) {
      _log('绑定失败:${e.message ?? e.code}');
    } finally {
      if (mounted) {
        setState(() => _binding = false);
      }
    }
  }

  /// 通道面探针:Android 插件面回 'android';iOS/ohos 原生面不实现此
  /// 方法(探针落 null)。卓易通判别用(见首配收尾分派)。
  Future<String?> _bleNativeFace() async {
    try {
      return await _bleChannel.invokeMethod<String>('platformTag');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 解除配对确认(2026-10-20:对齐 STA「忘记这台相机」):清配对
  /// 身份 + 断开 + 注入停止,重连须重新走相机菜单 —— 一步到位的
  /// 不可逆操作,弹窗把关。
  Future<void> _confirmUnpair(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('ble.unpairConfirm'),
      content: context.t('ble.unpairBody', {'name': _saved!.displayName}),
      confirmLabel: context.t('ble.unpair'),
      destructive: true,
    );
    if (confirmed) {
      await _unpair();
    }
  }

  Future<void> _unpair() async {
    final app = AppServices.instance;
    _cancelRetry();
    app.bleManualOff = false; // 解除配对清意图(下次配对干净起步)
    await app.bleIdentityStore.clear();
    _session.identity = null;
    await _session.disconnect();
    app.refreshBleInjection();
    _log('已解除配对(注入停止;重连须重新走相机菜单)');
    await _loadSaved();
    widget.onIdentityChanged?.call();
  }

  /// 我方注册身份的 deviceId(已存档优先,会话内存兜底;null = 首次
  /// 配对,无从比较冲突)。
  int? get _ownDeviceId => _saved?.deviceId ?? _session.identity?.deviceId;

  /// 「在等别的手机」指引文案(扫描行提示与重连失败日志共用;动作
  /// 措辞借 HarmoNiLink 真机口径:相机「已配对设备」菜单切换设备)。
  String _conflictHint(BuildContext context, int foreignId) => context.t(
      'ble.waitingOtherPhone',
      {'id': foreignId.toRadixString(16).toUpperCase()});

  /// 当前列表里首个「在等别的手机」的设备(无则 null;重连未命中时的
  /// 指引来源 —— 重连扫描(scanForDeviceId)被 native 按我方 deviceId
  /// 过滤,看不见别家相机,只能翻本页自己的配对扫描结果)。
  BleDevice? _foreignWaiting() {
    final own = _ownDeviceId;
    if (own == null) return null;
    for (final r in _scanRows) {
      if (cameraWaitsForOtherController(r.device.mfgData, own)) return r.device;
    }
    return null;
  }

  /// 已配对相机在扫描行里的投影(null = 不在播/离线):关系 id 优先
  /// (0x0399 deviceId == 我方),回落归一化广播名 == 档案相机名。
  ScanRow? _pairedScanRow() {
    final own = _ownDeviceId;
    for (final r in _scanRows) {
      if (own != null &&
          expectedControllerDeviceId(r.device.mfgData) == own) {
        return r;
      }
    }
    final name = _saved?.cameraName;
    if (name == null || name.isEmpty) return null;
    final key =
        'n:${name.replaceAll(RegExp(r'[\s_]+'), '').toLowerCase()}';
    for (final r in _scanRows) {
      if (_scanMergeKey(r.device) == key) return r;
    }
    return null;
  }

  /// 已配对行状态点(2026-10-21 用户定稿:状态值进配对行、设备名后):
  /// 连接中 = 绿;未连接但广播可见 = 电源态色(绿/待机黄,配对菜单态
  /// 广播无状态字节,能扫到即在播,按绿);完全不在线(扫描行里都没
  /// 有)= 灰。
  Widget _pairedStatusDot(BuildContext context) {
    final theme = Theme.of(context);
    Color color;
    if (_sessionState == BleSessionState.ready) {
      color = AppColors.success(context);
    } else {
      final row = _pairedScanRow();
      if (row == null) {
        color = theme.disabledColor;
      } else {
        color = advertisedPowerState(row.device.mfgData) ==
                NikonAdvPowerState.standby
            ? AppColors.accentYellow
            : AppColors.success(context);
      }
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  /// 扫描行电源态点(2026-10-19 用户定稿:文字换色点):待机黄点
  /// (accentYellow)/ 就绪绿点(success);无状态字节(mfg 不足 7B:
  /// 配对菜单态/异厂商)不出点。待机点是「点连接为何唤不醒」的答案
  /// 面:深睡广播稀,闸门等物理唤醒。
  Widget? _powerStateDot(BuildContext context, BleDevice device) {
    final status = advertisedStatusByte(device.mfgData);
    if (status == null) return null;
    final standby =
        advertisedPowerState(device.mfgData) == NikonAdvPowerState.standby;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color:
            standby ? AppColors.accentYellow : AppColors.success(context),
        shape: BoxShape.circle,
      ),
    );
  }

  /// 扫描行:设备名 + 电源态色点(尾槽);deviceId/冲突指引不显
  /// (冲突指引在重连日志 AppLog)。点行 = 发起配对(待机机也是显式
  /// 意图,允许点醒,裁定⑤)。
  Widget _scanRow(BuildContext context, BleDevice device) {
    return ListTile(
      dense: true,
      enabled: _sessionState == BleSessionState.idle ||
          _sessionState == BleSessionState.reconnecting,
      leading: const Icon(Icons.camera_alt_outlined),
      title: Text(device.name.isEmpty
          ? context.t('ble.unnamed')
          : device.name),
      trailing: _powerStateDot(context, device),
      onTap: () => unawaited(_pair(device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _sessionState == BleSessionState.ready;
    // 嵌入宿主滚动层(蓝牙方式视图 ListView,页面级 padding 由宿主
    // 给):整体 mainAxisSize.min,水平不另缩进。「已配对 / 其它设备」
    // 两段列表(iOS 设置组语言);会话态在宿主状态行,不在此重复。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 已配对组:未就绪 = 档案行(解除配对/连接);就绪 = 档案行 +
        // 断开(显式断开 = 用户意图保持断开:置 manualOff 压制一切自动
        // 回链,显式「连接」/重新配对沿解除);无档 = 空态。十二轮:
        // 就绪沿段名让位「已连接」(conn.connected)—— 列的是当下连着
        // 的这台,不是配对档案;就绪行也不再带「最近」徽(徽语义 =
        // 最近连接条目,已连接时无意义;未就绪档案行保留)。
        ConnSectionHeader(
            label: ready ? 'conn.connected' : 'conn.sectionPaired'),
        ConnTileGroup(
          children: [
            if (_saved == null)
              const _GroupEmpty(text: 'conn.noPairedDevices')
            else if (ready)
              ListTile(
                dense: true,
                // 行尾钮内衬 12:右距收 4 让钮文本右沿回到 16,与
                // leading 相机图标同距(2026-10-22 用户定稿)。
                contentPadding: const EdgeInsets.only(left: 16, right: 4),
                leading: const Icon(Icons.camera_alt_outlined),
                // 展示名 = 相机广播名(旧档缺字段回落控制器名)——
                // controllerName 是本机在相机侧的注册名,不是相机。
                // 十二轮:就绪行不带「最近」徽(已连接时无意义)。
                // 2026-10-21:名后状态点(绿=连接在线)。
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_saved!.displayName)),
                    const SizedBox(width: AppSpacing.sm),
                    _pairedStatusDot(context),
                  ],
                ),
                // 行尾轻量操作(2026-10-19 二轮:描边钮整排太重)。
                trailing: TextButton(
                  onPressed: () {
                    AppServices.instance.bleManualOff = true;
                    unawaited(_session.disconnect());
                  },
                  child: Text(context.t('ble.disconnect')),
                ),
              )
            else
              ListTile(
                dense: true,
                // 行尾钮内衬 12:右距收 4 让钮文本右沿回到 16,与
                // leading 相机图标同距(2026-10-22 用户定稿)。
                contentPadding: const EdgeInsets.only(left: 16, right: 4),
                leading: const Icon(Icons.camera_alt_outlined),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_saved!.displayName)),
                    const SizedBox(width: AppSpacing.sm),
                    // 2026-10-21:名后状态点(绿=广播在线/待机黄/离线灰)。
                    _pairedStatusDot(context),
                    const SizedBox(width: AppSpacing.sm),
                    const ConnRecentBadge(),
                  ],
                ),
                // 行尾轻量操作(2026-10-19 二轮用户裁定:双描边钮太重
                // —— 解除配对收成次级色图标钮,连接降为文字钮)。十轮:
                // 重连反馈不再占名下副文(状态行 + 按钮位已表达);握手
                // 期(pairing)两钮让位「握手中」状态词,行尾不再空着
                // —— 取消走蓝牙 hero 再点(九轮;十四轮:行内「断开」
                // 钮被否)。十一轮:状态词与同行标签同色(primary)。
                // 十三轮:解除配对在握手/连接中(reconnecting)均隐 ——
                // 连接在途身份正派用场,此刻解除既危险也无意义。十四轮:
                // 两状态词本身可点 = 取消(与 hero 再点同路
                // cancelResume)。十五轮:连接中不与「连接」钮并存
                //(用户裁定)—— 重连由常驻自动循环承担(见 _stateSub),
                // 相机就绪即连上,行内只须报态与给取消。
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_sessionState != BleSessionState.pairing &&
                        _sessionState != BleSessionState.reconnecting)
                      IconButton(
                        icon: const Icon(Icons.link_off, size: 20),
                        tooltip: context.t('ble.unpair'),
                        color: theme.colorScheme.onSurfaceVariant,
                        onPressed: () =>
                            unawaited(_confirmUnpair(context)),
                      ),
                    if (_sessionState == BleSessionState.pairing ||
                        _sessionState == BleSessionState.reconnecting)
                      // 十四轮:状态词可点 = 取消连接/握手(与 hero 再点
                      // 同路)。
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(cancelResume()),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm),
                          child: Text(
                            context.t(
                                _sessionState == BleSessionState.pairing
                                    ? 'ble.handshaking'
                                    : 'ble.reconnecting'),
                            style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary),
                          ),
                        ),
                      )
                    else
                      TextButton(
                        // 点按即唤醒:深睡闸门只闸自动路(已退役),
                        // 手动点 = 显式意图 —— 打断在场循环绕闸直连。
                        onPressed: () => unawaited(manualResume()),
                        child: Text(_retrying
                            ? context.t('ble.reconnecting')
                            : context.t('ble.connect')),
                      ),
                  ],
                ),
              ),
          ],
        ),
        // 其它设备组(就绪态整体隐藏:连接后残留的扫描行只有迷惑作用)。
        // 自动扫描静默入列 —— 无扫描钮、无「扫描中」指示,空态只显
        // 「未发现设备」(2026-10-19 用户定稿)。
        if (!ready) ...[
          const SizedBox(height: AppSpacing.md),
          const ConnSectionHeader(label: 'conn.sectionOthers'),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              // 2026-10-21:已配对相机不再进「其它设备」(它在上面有自己的
              // 行 + 状态点;用户定稿「其它设备中不再出现已配对的设备」)。
              child: _othersDevices().isEmpty
                  ? const _GroupEmpty(text: 'conn.noOtherDevices')
                  // ListTile 在最近 Material 祖先上画底/墨效:透明
                  // Material 垫在 DecoratedBox 与子项之间(ConnTileGroup
                  // 同款)。
                  : LimitedBox(
                      maxHeight: 220,
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: [
                          for (final row in _othersDevices())
                            _scanRow(context, row.device),
                        ],
                      ),
                    ),
            ),
          ),
        ],
        // 鸿蒙程序化经典绑定已并入首配流程(_pair 内自动进行,
        // 2026-10-22 用户定稿:手动按钮退役)。
      ],
    );
  }
}

/// 列表组空态行(组容器内居中次级小字;text 即 t() 键)。
class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty({required this.text});

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

part of 'remote_controller.dart';

mixin _RemotePropOps on _RemoteCore {
  /// 该属性当前是否可调:总门禁 + 目录 readOnly(机身件拥有)+ 模式门
  /// (曝光变量:机身在 M/S 之外拥有快门、M/A 之外拥有光圈 —— A/P 下
  /// 快门自动、S/P 下光圈自动,影控台同状态同样不可调,2026-10-06 真机
  /// 实证)+ 相机 getSet 上报。厂商写路由参数(writeCode != null)跳过
  /// getSet:标准码的 getSet 不代表厂商写码可写性(真机:0x500D/0x500F
  /// 报只读,0xD100/0xD0B4 照常可写)。
  bool propWritable(int propCode) {
    if (!_setPropEnabled()) return false;
    final param = shootingParamByCode[propCode];
    if (param == null || param.readOnly) return false;
    if (_autoControlled(propCode)) return false;
    // 厂商写路由 / 取值域直供 / 拨盘拥有参数:标准码的 getSet 与 desc
    // 都不作数(真机:0x500F/0x500D 报只读但 0xD0B4/0xD100 可写;
    // 0x500E 拨盘拥有报只读 —— 接管(0x90C2 锁转盘)后可写;厂商码
    // PropDesc 拒答时 desc 为空但 pickValues 面板照常可用)。
    if (param.writeCode != null ||
        param.pickValues != null ||
        param.dialOwned) {
      return true;
    }
    return paramProps[propCode]?.desc?.getSet ?? false;
  }

  // ---- 曝光变量模式门(OpenZCine stillAllows* 同款)----

  /// 模式值(U 档 0x805x 段):U 档按内部程序跑,不猜锁交给相机应答。
  static bool _isUserMode(int mode) => mode >= 0x8050 && mode <= 0x8053;

  /// 模式门判定:模式未读(null)或 U 档 → 不锁;否则看 [allowed]。
  bool _modeAllows(Set<int> allowed) {
    final mode = paramProps[PtpDevicePropCode.exposureProgramMode]?.value;
    if (mode == null || _isUserMode(mode)) return true;
    return allowed.contains(mode);
  }

  /// 快门可调:M/S(其余模式机身拥有,A 下快门是自动曝光变量)。
  bool get shutterAdjustable => _modeAllows({1, 4}); // M / S

  /// 光圈可调:M/A。
  bool get apertureAdjustable => _modeAllows({1, 3});

  /// 手动 ISO 可调:P/S/A/M(场景档拥有感光度,OpenZCine 同款门)。
  bool get isoManualAllowed => _modeAllows({1, 2, 3, 4});

  /// 该参数当前是否被写入门拦下(芯片置灰):模式门锁定的快门/光圈
  /// + 场景档锁定的 ISO(自动 ISO 开着**不拦** —— 开关与手动值互不
  /// 干扰,见 [isoAuto];显示标注照打,由「自动 ISO」开关显式控制)。
  bool _autoControlled(int propCode) {
    switch (propCode) {
      case PtpDevicePropCode.exposureTime:
        return !shutterAdjustable;
      case PtpDevicePropCode.fNumber:
        return !apertureAdjustable;
      case PtpDevicePropCode.exposureIndex:
        return !isoManualAllowed;
      default:
        return false;
    }
  }

  /// 该参数当前是否由相机自动控制(页面芯片「(自动)」标注):模式门
  /// 锁定 + 自动 ISO 开启(此时显示的是 0xD0B5 工作值)。
  bool paramAutoControlled(int propCode) {
    if (propCode == PtpDevicePropCode.exposureIndex && isoAuto == true) {
      return true;
    }
    return _autoControlled(propCode);
  }

  /// 控制器无 BuildContext:error/notice 类动态串按既定决策维持中文
  /// 回落;内嵌的参数名/模式名从 zh 词表取渲染形态,避免键名上屏
  /// (2026-10-16:label 键化后 `${p.label}` 直插会显示 ns.key)。
  /// 当前模式展示键(错误提示 {m} 参数用;未读为 null)。渲染端
  /// arg-t 落地,键查不到直通(枚举表外裸值)。
  String? get _modeLabel {
    final mode = paramProps[PtpDevicePropCode.exposureProgramMode]?.value;
    if (mode == null) return null;
    return shootingParamByCode[PtpDevicePropCode.exposureProgramMode]
        ?.display(mode);
  }

  /// 自动 ISO 开关(0xD054,u8):开 = ISO 面板「自动」项;关后手动值
  /// 生效。开关后 ISO 值随即回读(0xD0B5 工作值跟随)。
  Future<void> setIsoAuto(bool enabled) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    writing = true;
    error = null;
    notifyListeners();
    try {
      await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.stillIsoAutoControl,
          dataType: PtpDataType.uint8,
          value: enabled ? 1 : 0));
      isoAuto = enabled;
      await _refreshProp(PtpDevicePropCode.exposureIndex);
    } on Exception catch (e) {
      if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.accessDenied) {
        error = (
          key: 'remote.autoIsoFailDial',
          args: {'e': userFacingError(e)},
        );
      } else {
        error = (key: 'remote.autoIsoFail', args: {'e': userFacingError(e)});
      }
    } finally {
      writing = false;
      if (_linkUp) notifyListeners();
    }
  }

  // ---- APP 接管控制(0x90C2 remote 模式)----

  @override
  bool get takeoverActive => _takeoverActive;

  /// 启用 APP 接管控制(0x90C2 [1] = remote 模式,影控台同款):机身
  /// 拨盘锁定、屏幕可能熄灭;host 写入的会话值仅在持有期保值。
  /// 失败置 [error] 返回 false(0xA003 等,拨盘在释放/AF 中时会被拒)。
  @override
  Future<bool> enableTakeover() async {
    if (_takeoverActive) return true;
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return false;
    }
    try {
      await session.changeCameraMode(1);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.takeoverFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
      );
      notifyListeners();
      return false;
    } on Exception catch (e) {
      error = (key: 'remote.takeoverFail', args: {'e': userFacingError(e)});
      notifyListeners();
      return false;
    }
    _takeoverActive = true;
    engine.remoteHeld = true; // 取景自愈梯不得再碰 0x90C2(会杀会话写入)
    error = null;
    notifyListeners();
    return true;
  }

  /// 解除接管(0x90C2 [0];尽力而为,链路将断时的拒绝不影响本地状态)。
  /// 模式覆写随解除死亡:软件态回拨杆真档 —— 拨杆在覆写期可能被拨过
  /// (读值被软件态遮蔽,我们看不见),不能凭旧态猜,释放后读回对表。
  Future<void> releaseTakeover() async {
    if (!_takeoverActive) return;
    final wasOverridden = _modeOverridden;
    _takeoverActive = false;
    _modeOverridden = false;
    engine.remoteHeld = false;
    notifyListeners();
    await _endRemoteModeQuietly();
    if (wasOverridden) await refreshCameraMode();
  }

  Future<void> _endRemoteModeQuietly() async {
    try {
      await session.changeCameraMode(0);
    } on Exception {
      // 尽力而为
    }
  }

  /// 无线取景失败占位的引导动作(2026-10-15 AP 三轮真机定案):开启
  /// 接管(0x90C2(1) 持有)后自动重试取景 —— AP 人设的取景门随接管
  /// 开(连接括号的 0x90C2(0) 退闩即关,未持有态 0x9201 回 OK 假成);
  /// 持有态起景为真。接管态机身停「已连接到计算机」屏 + 拨盘锁定,
  /// 解除即还(影控台同款);USB 不走此路(连接流已开闩,失败另有因)。
  /// 重试仍失败落既有占位(取景开启失败带梯),不吞错。
  /// 同日深夜起降为**兜底**:AP 连接沿已主动接管([_onConnectedChain]),
  /// 落到本引导 = 连接沿开闩被拒/总闸关,用户手动补一拍。
  Future<void> enableTakeoverAndRetryLiveView() async {
    if (!await enableTakeover()) return;
    await toggleLiveView();
  }

  // ---- AE/AWB 锁(0x9426,官方 §6.2.4.5)----

  bool get aeLocked => _aeLocked;

  /// 切换 AE/AWB 锁:应答 OK 先落乐观态,随即尽力读 AELockStatus
  /// (0xD105)对表 —— 读失败保持乐观态(不亮假态);断连沿清零
  /// (会话级状态,重连后未知)。
  Future<void> toggleAELock() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    final target = !_aeLocked;
    try {
      await session.changeAELock(lock: target, type: 2);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errAeLockFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
      );
      notifyListeners();
      return;
    } on Exception catch (e) {
      error = (key: 'remote.errAeLockFail', args: {'e': userFacingError(e)});
      notifyListeners();
      return;
    }
    _aeLocked = target;
    notifyListeners();
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.aeLockStatus);
      final actual = v.value == 1;
      if (actual != _aeLocked && !_disposed) {
        _aeLocked = actual;
        notifyListeners();
      }
    } on Exception {
      // 读回失败:保持乐观态
    }
  }

  // ---- 相机内屏强关(0x9422,官方 §6.2.2.17,B 组:线上未验)----

  bool get monitorOff => _monitorOff;

  /// 切换机背内屏强关:OK 先落乐观态,随即尽力读 MonitorOffStatus
  /// (0xD1BA)对表 —— 读失败保持乐观态;失败不动旗标。副作用未知
  /// (可能断取景流)由看门狗既有兜底,UI 标实验性。
  Future<void> toggleMonitorOff() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    final target = !_monitorOff;
    try {
      await session.changeMonitorOff(off: target);
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errMonitorOffFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
      );
      notifyListeners();
      return;
    } on Exception catch (e) {
      error = (key: 'remote.errMonitorOffFail', args: {'e': userFacingError(e)});
      notifyListeners();
      return;
    }
    _monitorOff = target;
    notifyListeners();
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.monitorOffStatus);
      final actual = v.value == 1;
      if (actual != _monitorOff && !_disposed) {
        _monitorOff = actual;
        notifyListeners();
      }
    } on Exception {
      // 读回失败:保持乐观态
    }
  }

  // ---- 曝光读数轮换轮询 ----

  static const _aePollProps = <int>[
    PtpDevicePropCode.fNumber,
    PtpDevicePropCode.exposureTime,
    PtpDevicePropCode.exposureIndex,
  ];

  @override
  void _syncAePolling() {
    // 页面不可见不轮询(取景引擎同款挂起;相机侧取景保持)。
    final shouldRun = _linkUp &&
        _viewerVisible &&
        engine.status.value == LiveViewStatus.running;
    if (shouldRun && !_aePolling) {
      _aePolling = true;
      unawaited(_aePollLoop(++_aeRun));
    } else if (!shouldRun && _aePolling) {
      _aePolling = false;
      _aeRun++;
    }
  }

  Future<void> _aePollLoop(int run) async {
    while (_aePolling && run == _aeRun) {
      await _aeDelay(_aePollInterval);
      if (!_aePolling || run != _aeRun || !_linkUp) return;
      if (capturing || writing) continue;
      for (final code in _aePollProps) {
        await _refreshProp(code);
      }
      if (_linkUp) notifyListeners();
    }
  }

  /// 取景开关:引擎启停(帧轮询/AE 轮询/对焦框状态都随引擎状态联动)。
  @override
  Future<void> refreshParams({bool joinInFlight = false}) {
    final inFlight = _paramSweepInFlight;
    if (joinInFlight && inFlight != null) return inFlight;
    final completer = Completer<void>();
    _paramSweepInFlight = completer.future;
    () async {
      try {
        await _refreshParamsSweep();
        completer.complete();
      } catch (error, stackTrace) {
        // 与直呼同形:错误经返回的 Future 交给各调用方(全链自身逐项
        // 兜底,走到这里只有意外形态)。
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_paramSweepInFlight, completer.future)) {
          _paramSweepInFlight = null;
        }
      }
    }();
    return completer.future;
  }

  Future<void> _refreshParamsSweep() async {
    // 张数读打头(2026-10-16):进页/拍摄沿的整条链 30+ 笔事务要跑几秒,
    // 排尾的话胶囊挂旧值几秒才对上;单笔裸读放链首,第二笔即对上。
    await _refreshShotsRemaining();
    for (final param in kShootingParams) {
      await _refreshProp(param.code);
    }
    if (_cameraMode == CaptureMode.video) {
      for (final param in kVideoShootingParams) {
        await _refreshProp(param.code);
      }
    }
    await _refreshIsoAuto();
    await _maybeFetchPicCtrlNames();
    _paramsRefreshedOnce = true;
    if (!_linkUp) return;
    notifyListeners();
  }

  /// 优化校准槽位真名拉取(0x90CC,每连接一次):对 FORM 枚举里静态表
  /// 未收录的槽位(自定义 201-209/云 301-309/表外新值)逐个读注册名;
  /// 内置(1-11)/创意(101-120)静态表已有真名,跳过。首异常即停
  /// (0x90CC 不通整组不试,机身名字显示回落静态占位)。digiCamControl
  /// InitPictControl 同款枚举循环;Zf 待真机核对。
  Future<void> _maybeFetchPicCtrlNames() async {
    if (_picCtrlNamesFetched || _picCtrlNamesBroken || !_linkUp) return;
    _picCtrlNamesFetched = true;
    final param = shootingParamByCode[PtpDevicePropCode.activePicCtrlItem];
    final staticLabels = param?.enumLabels ?? const <int, String>{};
    final values = paramProps[PtpDevicePropCode.activePicCtrlItem]
            ?.desc
            ?.enumValues
            ?.whereType<int>() ??
        const <int>[];
    var fetched = false;
    for (final slot in values) {
      if (staticLabels.containsKey(slot)) continue;
      String? name;
      try {
        name = await session.getPictureControlName(slot);
      } on Exception {
        if (!_linkUp) return;
        _picCtrlNamesBroken = true;
        break;
      }
      if (!_linkUp) return;
      if (name != null) {
        picCtrlNames[slot] = name;
        fetched = true;
      }
    }
    if (fetched && _linkUp) notifyListeners();
  }

  /// 参数值展示(页面统一入口):优化校准槽位真名优先(0x90CC 缓存),
  /// 其余走目录静态表(内置 1-11 + 创意 101-120 全员有键);返回键/
  /// 动态串由渲染端 t(key, args) 落地。null 值 = 「--」;段位键化分支
  /// (param.picCtrlCreative/Custom/Cloud 的 {n} 参)只兜表外值 ——
  /// 目录键外的 101-120 新值 / 201-209 / 301-309(静态表无占位的槽位)。
  L10nMessage displayParamValue(int code, int? value) {
    // 视频 ISO 复合值:设定(0xD1AA)与机身实际工作值(0xD0B5,视频
    // auto 增益)分叉时并列 —— 2026-10-26 真机:视频档 auto 拥有实际
    // 曝光,单值显示会被读成「改了没效果」。
    if (code == PtpDevicePropCode.movieExposureIndex) {
      final composite = isoWithActualValue(value, _actualIso);
      if (composite != null) return composite;
    }
    if (code == PtpDevicePropCode.activePicCtrlItem && value != null) {
      final name = picCtrlNames[value];
      if (name != null) return (key: name, args: null);
      final param = shootingParamByCode[code];
      final label = param?.enumLabels[value];
      if (label != null) return (key: label, args: null);
      if (value >= 101 && value <= 120) {
        return (key: 'param.picCtrlCreative', args: {'n': value - 100});
      }
      if (value >= 201 && value <= 209) {
        return (key: 'param.picCtrlCustom', args: {'n': value - 200});
      }
      if (value >= 301 && value <= 309) {
        return (key: 'param.picCtrlCloud', args: {'n': value - 300});
      }
    }
    return (
      key: shootingParamByCode[code]?.display(value) ?? '--',
      args: null,
    );
  }

  /// 剩余可拍张数(0xD1F1 裸读;拒答 null 不猜)。on Object 收口:
  /// 断链沿 transport 关闭抛的是 Error(StateError),会逃逸 on Exception
  /// (autoLiveViewOnConnect 同款「transport 已关」口径)。
  /// 静照自动 ISO 状态(0xD054,u8 裸读;拒答 null 不猜)。
  Future<void> _refreshIsoAuto() async {
    try {
      final v = await session
          .getDevicePropValue(PtpDevicePropCode.stillIsoAutoControl);
      if (!_linkUp) return;
      isoAuto = (v.value as int?) != 0;
    } on Exception {
      if (!_linkUp) return;
      isoAuto = null;
    }
  }

  Future<void> _refreshProp(int propCode) async {
    final param = shootingParamByCode[propCode];
    // 取值域来源:目录 pickValues 直供(快门 —— 0x500D 枚举单位存疑
    // 弃用)的参数不读标准码 PropDesc;其余读之(枚举/范围/可写性)。
    PtpDevicePropDesc? desc;
    if (param?.pickValues == null) {
      try {
        desc = await session.getDevicePropDesc(propCode);
        if (!_linkUp) return;
      } on Exception {
        // PropDesc 不给(方言/截断/不支持):值走裸读
      }
    }
    // 值回读路由:厂商写路由的参数标准码不跟写(真机「改了不同步」
    // 根因)—— 值读走目录 readCode(ISO 0xD0B5 有效 ISO / 快门 0xD100
    // 打包分数,OpenZCine 轮询同款);无路由且 PropDesc 在册时直接用
    // desc.currentValue。
    final readCode = param?.readCode ?? propCode;
    if (readCode != propCode || desc == null) {
      try {
        final v = await session.getDevicePropValue(readCode);
        if (!_linkUp) return;
        paramProps[propCode] = PropState(
            desc: desc, value: v.value as int? ?? desc?.currentValue as int?);
        return;
      } on Exception {
        if (!_linkUp) return;
        paramProps[propCode] =
            PropState(desc: desc, value: desc?.currentValue as int?);
        return;
      }
    }
    paramProps[propCode] =
        PropState(desc: desc, value: desc.currentValue as int?);
  }

  /// 拍摄参数调节(0x1016,数据入相)。
  ///
  /// 门禁:总开关、目录 readOnly(模式转盘)、**模式门**(曝光变量:
  /// A/P 下快门自动、S/P 下光圈自动 —— 本地拒绝零流量,不再撞 0x200F
  /// 报「启用接管」的误导)、相机 getSet(厂商路由跳过)、链路在。
  /// 写成功后按读码路由回读。拨盘拥有参数写被拒时,提示按接管状态分
  /// (接管已开 → 指向模式;未开 → 提示接管)。
  /// 拍摄参数调节(0x1016,数据入相)。
  ///
  /// 门禁:总开关、目录 readOnly(模式转盘)、**模式门**(曝光变量:
  /// A/P 下快门自动、S/P 下光圈自动 —— 本地拒绝零流量,不再撞 0x200F
  /// 报「启用接管」的误导)、相机 getSet(厂商路由跳过)、链路在。
  /// 写成功后按读码路由回读。拨盘拥有参数写被拒时,提示按接管状态分
  /// (接管已开 → 指向模式;未开 → 提示接管)。
  Future<void> setParam(int propCode, int value) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!_setPropEnabled()) {
      error = (key: 'remote.errWriteKilled', args: null);
      notifyListeners();
      return;
    }
    final param = shootingParamByCode[propCode];
    if (param?.readOnly ?? false) {
      error = (key: 'remote.errDialOwned', args: null);
      notifyListeners();
      return;
    }
    if (_autoControlled(propCode)) {
      final mode = _modeLabel ?? 'param.currentMode';
      switch (propCode) {
        case PtpDevicePropCode.exposureTime:
          error = (key: 'remote.errAutoShutter', args: {'m': mode});
        case PtpDevicePropCode.fNumber:
          error = (key: 'remote.errAutoAperture', args: {'m': mode});
        case PtpDevicePropCode.exposureIndex:
          error = (key: 'remote.errAutoIso', args: {'m': mode});
        default:
          error = (key: 'remote.errAutoControlled', args: null);
      }
      notifyListeners();
      return;
    }
    final desc = paramProps[propCode]?.desc;
    if (param?.writeCode == null &&
        param?.dialOwned != true &&
        desc != null &&
        !desc.getSet) {
      error = (key: 'remote.errReadOnly', args: null);
      notifyListeners();
      return;
    }
    // 写路径路由(目录 [ShootingParam.writeCode]):Z 系 ISO/快门的标准
    // 码只读,写走厂商码;值域仍取读码的相机自报枚举,换算失败不发
    // (宁失败不错值)。快门面板值已是 0xD100 打包分数,直写。
    var writeValue = value;
    final convert = param?.writeConvert;
    if (convert != null) {
      final packed = convert(value);
      if (packed == null) {
        error = (key: 'remote.errNotEncodable', args: null);
        notifyListeners();
        return;
      }
      writeValue = packed;
    }
    final writeCode = param?.writeCode ?? propCode;
    final dataType = param?.writeType ??
        desc?.dataType ??
        kStandardPropDataType[propCode] ??
        PtpDataType.uint16;
    writing = true;
    error = null;
    notice = null; // 新写动作清旧提示(上一写的横幅已属过去时)
    notifyListeners();
    // B 门/Time 哨兵写入:记写前值作收门还原目标(_closeBulbExposure
    // 步①,2026-10-15;官方 §2.8.4 收门序无还原步 —— N-link 模型的
    // 应用侧收口:相机不应被留在 Bulb 档)。
    final prevShutter = paramProps[propCode]?.value;
    final wroteOpenShutter = propCode == PtpDevicePropCode.exposureTime &&
        _isOpenShutterSentinel(writeValue);
    try {
      // 色温只在 WB=色温档(0x8012)生效:写入前自动切档(真机
      // 「改了没效果」根因 —— 机身语义,K 值跟随 WB 模式)。
      if (propCode == PtpDevicePropCode.wbColorTemp &&
          paramProps[PtpDevicePropCode.whiteBalance]?.value != 0x8012) {
        await session.setDevicePropValue(PtpDevicePropValue(
            code: PtpDevicePropCode.whiteBalance,
            dataType: PtpDataType.uint16,
            value: 0x8012));
      }
      await _writeWithTakeoverSelfHeal(
          param,
          PtpDevicePropValue(
              code: writeCode, dataType: dataType, value: writeValue));
      lockedProps.remove(propCode); // 写通:解除该参数的锁标
      if (wroteOpenShutter &&
          prevShutter != null &&
          !_isOpenShutterSentinel(prevShutter)) {
        // 写前值本身是哨兵(Bulb→Time)时保留更早记录。
        _bulbShutterRestore = prevShutter;
      }
      await _refreshProp(propCode);
      // 视频参数写后复读守卫(2026-10-13 USB 探针定案:Zf 视频曝光
      // 写 = 五态全试「0x2001 收下但弹回拨盘值」—— 协议成功 ≠ 生效,
      // 复读不一致就明说,不让用户以为改上了)。照片参数不设此守卫:
      // 回读差异有合法形态(如 Auto ISO 下 0xD0B5 回工作值)。
      if (param?.videoOnly == true) {
        final readBack = paramProps[propCode]?.value;
        if (readBack != null && readBack != value && !_disposed) {
          notice = (
            key: 'remote.errPropBounce',
            args: {
              'label': param!.label,
              'v': displayParamValue(propCode, readBack),
            },
          );
        }
      }
      // AF 区域切到宽C1/C2:饱和轴触屏移框不动属相机行为,切换沿
      // 浮一条提示(文案与 AF 面板常驻行同源)。
      if (propCode == PtpDevicePropCode.stillFocusMeteringMode) {
        final hint = afAreaAxisHint(value);
        if (hint != null) notice = hint;
      }
    } on Exception catch (e) {
      if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.deviceBusy) {
        error = (
          key: 'remote.errPropBusy',
          args: {'label': param?.label ?? '--'},
        );
        return;
      } else if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.sessionAlreadyOpen) {
        error = (key: 'remote.errPropSession', args: null);
        return;
      } else if (e is PtpResponseException &&
          e.responseCode == PtpResponseCode.accessDenied) {
        // 控制锁(OpenZCine lockedControls 口径):相机拒绝这个参数
        // 的遥控 → 读出条打锁标,直到写通或断连。
        lockedProps.add(propCode);
      }
      if (e is PtpResponseException && param?.dialOwned == true) {
        error = (
          key: 'remote.errPropWriteDial',
          args: {
            'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e),
            'tail': _takeoverActive
                ? 'remote.errPropWriteDialTakeover'
                : 'remote.errPropWriteDialLatch',
          },
        );
      } else if (e is PtpResponseException) {
        error = (
          key: 'remote.errPropWrite',
          args: {
            'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e),
            'tail': e.responseCode == PtpResponseCode.accessDenied
                ? 'remote.errPropWriteLatch'
                : '',
          },
        );
      } else {
        error = (
          key: 'remote.errPropWrite',
          args: {'e': userFacingError(e), 'tail': ''},
        );
      }
    } finally {
      writing = false;
      if (_linkUp) notifyListeners();
    }
  }

  /// 拨盘参数写入 + 授权失同步自愈(2026-10-26 真机口径):接管账面为开
  /// 时吃 0x200F = 相机侧授权已被收回 —— 写授权会话级(会话重建/机身
  /// 半按快门退闩都收;USB 探针实锤跨会话闩拒、重发 0x90C2(1) 幂等
  /// 恢复),且机身退闩无事件可对账 → 重打闩后静默重试一次,用户无感。
  /// 重打/重试仍拒 → 账面落闸(开着的面板沿 needTakeover 自动换出
  /// 接管门)原样上抛。非 dialOwned / 账面关:原样上抛走正常错误路径。
  Future<void> _writeWithTakeoverSelfHeal(
      ShootingParam? param, PtpDevicePropValue value) async {
    var busyAttempts = 0;
    var sessionRetried = false;
    while (true) {
      try {
        await session.setDevicePropValue(value);
        return;
      } on PtpResponseException catch (e, stack) {
        if (e.responseCode == PtpResponseCode.deviceBusy && busyAttempts < 2) {
          busyAttempts++;
          await _delay(Duration(milliseconds: 200 * busyAttempts));
          continue;
        }
        if (e.responseCode == PtpResponseCode.sessionAlreadyOpen &&
            !sessionRetried) {
          // 0x201E 表示相机侧会话账已丢/残留。重开会话会清掉 remote
          // 闩,持有接管时必须重打再写,不能把参数静默写进非接管态。
          sessionRetried = true;
          final restoreTakeover = _takeoverActive;
          try {
            await session.reopen();
            if (restoreTakeover) {
              await session.changeCameraMode(1);
            }
          } on Object {
            if (restoreTakeover) {
              _takeoverActive = false;
              engine.remoteHeld = false;
              if (!_disposed) notifyListeners();
            }
            // 对 UI 保留“会话失步且恢复失败”的原始 0x201E 语义;恢复动作
            // 自身的次级错误不覆盖用户下一步应做的“重新连接”判断。
            Error.throwWithStackTrace(e, stack);
          }
          continue;
        }
        if (e.responseCode != PtpResponseCode.accessDenied ||
            !(param?.dialOwned ?? false) ||
            !_takeoverActive) {
          rethrow;
        }
        try {
          await session.changeCameraMode(1); // 重打闩(幂等,0x2001)
        } on Object {
          // 重打失败:账面落闸,原 0x200F 照实上抛(响应码保留,文案/
          // 锁标判据不变)。
          _takeoverActive = false;
          engine.remoteHeld = false;
          if (!_disposed) notifyListeners();
          throw e;
        }
        await session.setDevicePropValue(value); // 重试;仍拒原样上抛
        return;
      }
    }
  }

  @override
  void _schedulePropRefresh(int propCode) {
    if (propCode == PtpDevicePropCode.exposureRemaining) {
      // 0xD1F1 不在参数目录(上面哨兵会丢),专路轻量刷张数
      _scheduleShotsRemainingRefresh();
      return;
    }
    if (!shootingParamByCode.containsKey(propCode)) return;
    _pendingPropRefreshes.add(propCode);
    if (_propRefreshScheduled) return;
    _propRefreshScheduled = true;
    unawaited(Future<void>.delayed(_propRefreshDebounce).then((_) async {
      _propRefreshScheduled = false;
      final codes = _pendingPropRefreshes.toList();
      _pendingPropRefreshes.clear();
      if (_disposed || !_linkUp) return;
      for (final code in codes) {
        await _refreshProp(code);
      }
      if (!_disposed && _linkUp) notifyListeners();
    }));
  }

  /// 断连/失败:停引擎、清状态;迟到的参数值/事件被门闩挡住。
}

/// 拍摄域:快门/连拍按住/B 门/录制/SDRAM 直拍/间隔/自拍。

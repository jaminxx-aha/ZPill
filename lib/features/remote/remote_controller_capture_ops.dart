part of 'remote_controller.dart';

mixin _RemoteCaptureOps on _RemoteCore {
  // ---- 自拍定时 ----

  /// 自拍倒计时剩余秒(null = 未在倒计时)。
  int? get selfTimerCountdown => _selfTimerLeft;

  /// 选自拍档位(0/2/5/10s;正在倒计时时切换即取消当前倒计时)。
  void setSelfTimer(int seconds) {
    if (seconds == selfTimerSeconds && !_selfTimerRunning) return;
    _cancelSelfTimer();
    selfTimerSeconds = seconds;
    notifyListeners();
  }

  @override
  void _cancelSelfTimer() {
    _selfTimerRunning = false;
    _selfTimerLeft = null;
  }

  /// 快门按下带自拍:倒计时(可取消)到点释放;档位 0 = 直接拍
  /// ([fire] 是异步动作,统一 await —— 按下的 Future 才真正盖住整段)。
  Future<void> _runSelfTimerThen(Future<void> Function() fire) async {
    if (selfTimerSeconds <= 0) {
      await fire();
      return;
    }
    if (_selfTimerRunning) return;
    _selfTimerRunning = true;
    _selfTimerLeft = selfTimerSeconds;
    notifyListeners();
    for (;;) {
      await _delay(_selfTimerTick);
      if (!_selfTimerRunning) return; // 被取消(切档/再点/断连)
      final left = _selfTimerLeft = _selfTimerLeft! - 1;
      if (left > 0) {
        notifyListeners();
        continue;
      }
      _selfTimerRunning = false;
      _selfTimerLeft = null;
      notifyListeners();
      await fire();
      return;
    }
  }

  // ---- 间隔拍摄(延时摄影)----

  IntervalometerStatus get intervalStatus => _interval.status;
  bool get intervalActive => _interval.active;
  int get intervalTaken => _interval.taken;
  int get intervalAttempted => _interval.attempted;
  int get intervalFailed => _interval.failed;
  int? get intervalShotCount => _interval.config?.shotCount;

  /// 调度器原句(测试拨小就绪预算/失败阈值用)。
  Intervalometer get intervalometer => _interval;

  /// 本轮收口 Future(测试 await 用)。
  Future<void> get intervalDone => _interval.done;

  /// 启动间隔拍摄。入口互锁(全部 notice 指路不炸):B 门/Time 曝光中
  /// (按住或定时)、录像中、SDRAM 直拍开(逐拍回传图库与紧间隔冲突)、
  /// 自拍倒计时中、单拍/连拍在途。间隔/张数域钳制见 [IntervalConfig]。
  void startInterval({required int intervalSeconds, int? shotCount}) {
    if (_interval.active) return;
    if (!_linkUp) {
      notice = (key: 'remote.ivNotConnected', args: null);
    } else if (_shutterIsOpenShutter ||
        _openShutterHeld ||
        _bulbExposureLeft != null) {
      notice = (key: 'remote.ivBulbOpen', args: null);
    } else if (recording) {
      notice = (key: 'remote.ivRecordingBusy', args: null);
    } else if (sdramCapture) {
      notice = (key: 'remote.ivSdramBusy', args: null);
    } else if (selfTimerCountdown != null) {
      notice = (key: 'remote.ivSelfTimerBusy', args: null);
    } else if (capturing) {
      notice = (key: 'remote.ivCapturingBusy', args: null);
    } else {
      _interval.start(IntervalConfig(
        interval: Duration(seconds: intervalSeconds),
        shotCount: shotCount,
      ));
      return; // start 已通知(_onIntervalChanged 转发)
    }
    notifyListeners();
  }

  void pauseInterval() => _interval.pause();
  void resumeInterval() => _interval.resume();
  void stopInterval() => _interval.stop();

  /// 间隔拍摄单拍执行器:UI 静默(错误只记账,跳拍策略;进度由状态行
  /// 透出),链路/B 门守卫复用 capture 口径。capturing 逐拍置位 —— 屏
  /// 上快门芯随拍闪忙,与手动单拍观感一致。
  @override
  Future<(bool, L10nMessage?)> _intervalShot() async {
    if (!_linkUp) return (false, (key: 'remote.notConnected', args: null));
    if (_shutterIsOpenShutter) {
      return (false, (key: 'remote.ivSkipBulb', args: null));
    }
    capturing = true;
    notifyListeners();
    try {
      return await _captureOnce();
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  /// 调度器状态/记账变化 → 转发刷新;一轮收口时把摘要上 notice
  /// (completed/autoStopped/stopped 三态文案)。断链沿的 stop 先于
  /// _invalidate 清 notice,不残留「已停止」横幅。
  @override
  void _onIntervalChanged() {
    if (_disposed) return;
    final iv = _interval;
    if (iv.status == IntervalometerStatus.stopped && iv.stopReason != null) {
      switch (iv.stopReason!) {
        case IntervalStopReason.completed:
          notice = iv.failed == 0
              ? (key: 'remote.ivDoneAll', args: {'n': iv.taken})
              : (key: 'remote.ivDone', args: {'n': iv.taken, 'f': iv.failed});
        case IntervalStopReason.autoStopped:
          notice = (
            key: 'remote.ivAutoStop',
            args: {'f': iv.consecutiveFailures, 'n': iv.taken},
          );
        case IntervalStopReason.stopped:
          notice = iv.failed == 0
              ? (key: 'remote.ivStoppedAll', args: {'n': iv.taken})
              : (
                  key: 'remote.ivStopped',
                  args: {'n': iv.taken, 'f': iv.failed}
                );
      }
    }
    notifyListeners();
  }

  // ---- SDRAM 直拍(0x90CB AF+SDRAM 一体拍,对象不入卡)----

  /// 对焦后拍:快门 0x9207 首参 CaptureSort —— true = 0xFFFFFFFE(先
  /// 驱动 AF 再释放,半按-全按;OpenZCine 默认形态),false = 0xFFFFFFFF
  /// (直接释放不动焦点,保留触控对焦/手动焦;OpenZCine preserveFocus
  /// 形态)。0x0000 旧实证形只作 0x201D 回退(见 [_captureSortCandidates])。
  bool get focusBeforeCapture => _focusBeforeCapture;
  set focusBeforeCapture(bool v) {
    if (_focusBeforeCapture == v) return;
    _focusBeforeCapture = v;
    notifyListeners();
  }

  /// 快门码回退信号集:相机明说「此码不对/不允许」的响应码 → 换另一
  /// 码重发。忙(0x2019)/会话/链路/参数域(0x201D,由 CaptureSort
  /// 换形处理)类错误不在其列。2026-10-06 真机补 0x2013 与 0x200F。
  static const _captureFallbackFrom = {
    PtpResponseCode.generalError,
    PtpResponseCode.operationNotSupported,
    PtpResponseCode.parameterNotSupported,
    PtpResponseCode.storeNotAvailable,
    PtpResponseCode.accessDenied,
  };

  /// 快门码选择:SDRAM 直拍开 = 0x90CB AF+SDRAM 一体(不入卡,收尾见
  /// [_collectSdramObject]);被拒(码级)自动回落常规码入卡 —— 照片不因
  /// 直拍拒而丢。返回 = (是否真发了 0x90CB, 回落提示):false 时拍照收尾
  /// 走常规卡拍流程,提示由 capture() 落收口后(防被 ObjectAdded 的
  /// 「已拍摄」冲掉)。否则首选码按相机 op 表(在册 0x9207 直用,
  /// OpenZCine 全系口径 —— Zf 在册;表拿不到退标准 0x100E)。0x9207 的
  /// CaptureSort 首参按 [_captureSortCandidates] 序换形(0x201D);被拒
  /// (码级)自动换另一码,成功后缓存。0x2013(存储不可用)转友好提示。
  Future<(bool, L10nMessage?)> _fireShutter() async {
    L10nMessage? fallbackNotice;
    if (sdramCapture && !_sdramCaptureDropped) {
      if (_shutterIsOpenShutter) {
        // B 门/Time 哨兵:直拍族(0x90C0/0x90CB)规格明文不支持长曝档
        //(0xA008 Shutter_Speed_Bulb / 0xA204 Shutter_Speed_Time,官方
        // §6.2.4.2/.3;2026-10-17 真机实证)—— 本地跳过零流量,直接走
        // 0x9207 按住/定时 B 门路,照片照旧入卡,如实提示。
        fallbackNotice = (key: 'remote.sdramBulbFallback', args: null);
      } else {
        try {
          await session.afAndCaptureRecInSdram();
          return (true, null);
        } on PtpResponseException catch (e) {
          if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
          // 0x90CB 码级被拒:记回落提示后**贯穿**到常规拍摄链(照片必须
          // 实拍入卡,这里只换机制)。模型级拒绝(0x2005)记本会话不再
          // 重试;状态类(0x200F/0x2013)逐拍回试 —— 拨杆拨回、卡归位后
          // 直拍仍可用。
          final dropped =
              e.responseCode == PtpResponseCode.operationNotSupported;
          if (dropped) _sdramCaptureDropped = true;
          final code = '0x${e.responseCode.toRadixString(16).toUpperCase()}';
          fallbackNotice = (
            key: 'remote.sdramRejected',
            args: {
              'c': code,
              'tail': dropped ? 'remote.sdramNoRetry' : '',
            },
          );
        }
      }
    }
    final pref = _captureOpPref;
    if (pref == PtpOperationCode.initiateCapture) {
      await session.initiateCapture();
      return (false, null);
    }
    final info = session.cachedDeviceInfo;
    final mediaFirst = pref == NikonOperationCode.initiateCaptureRecInMedia ||
        info == null ||
        info.supportsOperation(NikonOperationCode.initiateCaptureRecInMedia);
    if (mediaFirst) {
      try {
        await _fireMedia();
        return (false, fallbackNotice);
      } on PtpResponseException catch (e) {
        if (pref != null || !_captureFallbackFrom.contains(e.responseCode)) {
          rethrow; // 已缓存码/参数域类错误:换码解决不了
        }
        // 首选 0x9207 被拒(码级):标准码一试
        await session.initiateCapture();
        _captureOpPref = PtpOperationCode.initiateCapture;
        return (false, fallbackNotice);
      }
    }
    try {
      await session.initiateCapture();
      _captureOpPref = PtpOperationCode.initiateCapture;
    } on PtpResponseException catch (e) {
      if (!_captureFallbackFrom.contains(e.responseCode)) rethrow;
      await _fireMedia();
    }
    return (false, fallbackNotice);
  }

  /// 0x9207 落卡拍:CaptureSort 按候选序换形(0x201D 参数域拒时),
  /// 成功形缓存。对焦后拍开 = 固定 0xFFFFFFFE(显式意图,不缓存覆盖);
  /// 关 = 缓存形/0xFFFFFFFF 起。
  Future<void> _fireMedia() async {
    _captureOpPref = NikonOperationCode.initiateCaptureRecInMedia;
    final preferred =
        _focusBeforeCapture ? 0xFFFFFFFE : (_captureSortPref ?? 0xFFFFFFFF);
    final forms = <int>[
      preferred,
      ..._captureSortCandidates.where((f) => f != preferred),
    ];
    Object? lastError;
    for (final sort in forms) {
      try {
        await session.initiateCaptureRecInMedia(captureSort: sort);
        if (!_focusBeforeCapture) {
          _captureSortPref = sort; // 直接释放路径:记住成功形
        }
        return;
      } on PtpResponseException catch (e) {
        if (e.responseCode != PtpResponseCode.invalidParameter) rethrow;
        lastError = e; // 换下一形
      }
    }
    throw lastError!; // 全部形态皆被拒:抛最后一个(上层转提示)
  }

  // ---- 连拍按住(OpenZCine shutterPressLatchedBurst 同款)----

  /// 释放档当前值是否连续(高速连拍/低速连拍/C15-C120)。
  static const _continuousDriveValues = {
    2, // 高速连拍
    0x8010, // 低速连拍
    0x810F, // C15
    0x811E, // C30
    0x813C, // C60
    0x8178, // C120
  };

  bool get _driveContinuous => _continuousDriveValues
      .contains(paramProps[PtpDevicePropCode.stillCaptureMode]?.value);

  /// 0xD100 开门哨兵(Bulb 0xFFFFFFFF / Time 0xFFFFFFFD;X 同步
  /// 0xFFFFFFFE 非按住曝光态不列)。与 [_shutterIsOpenShutter] 同源。

  /// 快门当前值是否 Bulb/Time(0xD100 哨兵):**按住 = 开曝光,抬起
  /// 结束**(0x920C;OpenZCine pendingStillTerminate 同款语义)。
  bool get _shutterIsOpenShutter {
    final v = paramProps[PtpDevicePropCode.exposureTime]?.value;
    return v != null && _isOpenShutterSentinel(v);
  }

  /// 快门按钮**按下**(页面 onTapDown):
  /// - Bulb/Time:开曝光(按住中),[captureReleased] 抬起结束;自拍
  ///   档 > 0 时组合成**定时 B 门**(倒计时到点开门 → 同时长曝光倒计时
  ///   → 到点自动收门,见 [_openShutterPress]);
  /// - 连续释放档:连拍括持(0x90C2 remote + burstNumber 65535 —— 不
  ///   括持每次释放都会弹回单张,OpenZCine 同款)后释放,按住期间随
  ///   DeviceReady 就绪链发(上限 30 帧),抬起终止;
  /// - 普通档:自拍倒计时(档位 > 0)后一次 [capture]。
  Future<void> capturePressed() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      // 间隔拍摄运行中:屏上快门(含 B 门按住/连拍按住)全部让位,
      // 本地拒绝零流量 —— 停止间隔拍摄后再手动拍。
      notice = (key: 'remote.ivShutterYield', args: null);
      notifyListeners();
      return;
    }
    if (_bulbCloseFailed) {
      // 上次 B 门收门预算耗尽(曝光可能仍开着):这次按下不另开曝光,
      // 直接再试收门链 —— 「再点一次快门收门」的恢复路径。
      error = null;
      notice = null;
      notifyListeners();
      await _closeBulbExposure();
      return;
    }
    if (_shutterIsOpenShutter) {
      if (selfTimerSeconds > 0) {
        await _runSelfTimerThen(() => _openShutterPress(timed: true));
      } else {
        await _openShutterPress();
      }
      return;
    }
    if (!_driveContinuous) {
      await _runSelfTimerThen(capture); // 自拍档 > 0 时倒计时
      return;
    }
    if (capturing || _burstLatched) return;
    _burstLatched = true;
    _burstFrames = 0;
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      // 括持(尽力而为:失败不阻断 —— 释放档本身在机身上,可能仍连拍)
      try {
        await session.changeCameraMode(1);
        await session.setDevicePropValue(PtpDevicePropValue(
            code: PtpDevicePropCode.burstNumber,
            dataType: PtpDataType.uint16,
            value: 65535));
        _burstBracketHeld = true;
      } on Exception {
        // 括持失败:按单发链继续
      }
      final run = ++_burstRun;
      while (
          _burstLatched && run == _burstRun && _burstFrames < _burstFrameCap) {
        await _fireShutter();
        _burstFrames++;
        var ready = false;
        for (var i = 0;
            i < _capturePolls && _burstLatched && run == _burstRun && !ready;
            i++) {
          await _delay(_capturePollInterval);
          if (!_burstLatched || run != _burstRun) break;
          try {
            ready = await session.deviceReady();
          } on Exception {
            break; // DeviceReady 非忙错误:不再链发
          }
        }
        if (!ready) break; // 就绪超时:停链(用户可再按)
      }
    } on Exception catch (e) {
      error = (key: 'remote.errShutterFail', args: {'e': e.toString()});
    } finally {
      await _endBurstBracket();
      _burstLatched = false;
      _burstRun++;
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
  }

  // ---- B 门 / Time:按住开曝光 ----

  /// 定时 B 门曝光剩余秒(null = 未在定时曝光)。
  int? get bulbExposureCountdown => _bulbExposureLeft;

  /// Bulb/Time 按下:开曝光(0x9207 直发,不等待落地 —— 曝光持续到
  /// 抬起/定时到点)。[timed] = 定时 B 门(自拍定时 × B 门组合,
  /// 2026-10-15):开拍后同时长曝光倒计时,到点自动收门 —— 快拍一下
  /// = 延时 N 秒 + 定时 N 秒曝光,全程免按住;曝光中再点抬起 = 立即
  /// 手动收门。时长暂用自拍档位值(2/5/10s),更长档待后续。取景挂起
  /// 防事务挤占。
  Future<void> _openShutterPress({bool timed = false}) async {
    if (capturing || _openShutterHeld) return;
    _openShutterHeld = true;
    _bulbOpening = true;
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      final (_, sdramFallback) = await _fireShutter();
      if (sdramFallback != null) {
        // 直拍-B 门互斥改道等机制提示:曝光开始前如实带出(capture()
        // 路径的回落提示在收口带出,按住路径这里等效提前)。
        notice = sdramFallback;
        notifyListeners();
      }
      _bulbOpening = false;
      if (_bulbClosePending) {
        // 抬起先于开拍落地(极速点按):落地即收门,曝光开了就关。
        _bulbClosePending = false;
        await _closeBulbExposure();
        return;
      }
      if (timed) {
        _bulbExposureLeft = selfTimerSeconds;
        notifyListeners();
        while (_openShutterHeld && (_bulbExposureLeft ?? 0) > 0) {
          await _delay(_selfTimerTick);
          if (!_openShutterHeld) break; // 抬起已收门
          _bulbExposureLeft = _bulbExposureLeft! - 1;
          notifyListeners();
        }
        if (_openShutterHeld) {
          // 定时到点自动收门(检查-置位同步执行,与 captureReleased
          // 互斥,不会双收门)。
          _openShutterHeld = false;
          _bulbExposureLeft = null;
          notifyListeners();
          await _closeBulbExposure(autoClose: true);
        }
      } else {
        // 按住中:等抬起(不轮询 settle —— 曝光开着,DeviceReady 恒忙)
        while (_openShutterHeld) {
          await _delay(const Duration(seconds: 1));
        }
      }
    } on Exception catch (e) {
      error = (key: 'remote.errShutterFail', args: {'e': e.toString()});
    } finally {
      // 开拍失败也解锁:原实现失败路径漏置 false,后续按下被静默吞
      //(2026-10-15 收门鲁棒性收口)。
      _openShutterHeld = false;
      _bulbOpening = false;
      _bulbClosePending = false;
      _bulbExposureLeft = null;
      if (wasLive && _viewerVisible) engine.resume();
      capturing = false;
      notifyListeners();
    }
  }

  /// 快门按钮**抬起**:B 门结束曝光(收门链 [_closeBulbExposure]:
  /// 恢复原快门值 → 0x920C → 忙等码有界重试,2026-10-15)/ 终止进行
  /// 中的连拍(0x920C,已拍帧保留;运行已自行结束时相机会拒绝,容忍)。
  /// 普通档点按无副作用。
  Future<void> captureReleased() async {
    if (_openShutterHeld) {
      _openShutterHeld = false; // 等待环/倒计时环收口
      _bulbExposureLeft = null;
      notifyListeners();
      if (_bulbOpening) {
        // 开拍(0x9207)尚未落地:立刻 0x920C 会扑空 —— 记收门请求,
        // 开拍任务落地后立即收门。
        _bulbClosePending = true;
      } else {
        await _closeBulbExposure();
      }
      return;
    }
    if (!_burstLatched) return;
    _burstLatched = false;
    _burstRun++; // 打断链发循环
    await _terminateCaptureWithRetry(); // 忙等码有界重试;终态容忍(原口径)
  }

  /// B 门收门链(结构借 N-link BulbPolicy 步序,不采纳其与本仓已证
  /// 事实冲突的步骤,详见 [BulbClosePolicy] 头注):
  /// ① 恢复原快门值([_bulbShutterRestore] 有记录且当前仍是哨兵):
  ///    曝光中写被拒不阻断②,关门后相机闲态补试一次;
  /// ② 0x920C TerminateCapture(已证收门路径,官方 §2.8.4 步 6);
  /// ③ 忙等码(0x2019/0xA200/0xA201)按 [BulbClosePolicy] 短退避有界
  ///    重试,预算耗尽如实上报([autoClose] = 定时到点自动收门,文案
  ///    区分);失败后下一次按下转为收门重试([_bulbCloseFailed])。
  Future<void> _closeBulbExposure({bool autoClose = false}) async {
    if (!_linkUp) return;
    final restore = _bulbShutterRestore;
    if (restore != null && _shutterIsOpenShutter) {
      if (await _tryRestoreShutter(restore)) _bulbShutterRestore = null;
    }
    final closed = await _terminateCaptureWithRetry();
    _bulbCloseFailed = !closed;
    if (!closed) {
      error = autoClose
          ? (key: 'remote.errTimedBulbBusy', args: null)
          : (key: 'remote.errBulbCloseBusy', args: null);
      notifyListeners();
      return;
    }
    if (_bulbShutterRestore != null && _shutterIsOpenShutter) {
      // ① 中途失败(曝光中写被拒)的补试:曝光已终止,相机闲态写最稳。
      if (await _tryRestoreShutter(_bulbShutterRestore!)) {
        _bulbShutterRestore = null;
      } else {
        notice = (key: 'remote.errShutterRestore', args: null);
        notifyListeners();
      }
    }
  }

  /// 恢复快门值(0xD100 写,路由同 setParam):成功后乐观对表(该写
  /// 路径已证「面板值即写值」;0x4006 事件再校),失败返回 false 由
  /// 调用方决定补试。
  Future<bool> _tryRestoreShutter(int value) async {
    try {
      final param = shootingParamByCode[PtpDevicePropCode.exposureTime]!;
      await session.setDevicePropValue(PtpDevicePropValue(
          code: param.writeCode ?? PtpDevicePropCode.exposureTime,
          dataType: param.writeType ?? PtpDataType.uint32,
          value: value));
      paramProps[PtpDevicePropCode.exposureTime] = PropState(
          desc: paramProps[PtpDevicePropCode.exposureTime]?.desc, value: value);
      notifyListeners();
      return true;
    } on Exception {
      return false; // 曝光中写被拒(0x200F 等)等形态:不阻断收门
    }
  }

  /// 0x920C 终止(B 门收门/连拍终止共用):忙等码(0x2019/0xA200/
  /// 0xA201)按 [BulbClosePolicy] 有界退避重试;非忙码 = 运行已自行
  /// 结束的预期形态,容忍收口;链路级异常命令命运未知,交给断连路径。
  /// 返回是否真正终止成功(预算耗尽 = false)。
  Future<bool> _terminateCaptureWithRetry() async {
    final policy = BulbClosePolicy();
    for (;;) {
      try {
        await session.terminateCapture();
        return true;
      } on PtpResponseException catch (e) {
        if (!BulbClosePolicy.isBusyCode(e.responseCode)) return true;
        final d = policy.nextBusyDelay();
        if (d == null) return false; // 预算耗尽:如实上报由调用方
        await _delay(d);
      } on Exception {
        return true; // 链路级:命令命运未知,断连路径接管
      }
    }
  }

  Future<void> _endBurstBracket() async {
    if (!_burstBracketHeld) return;
    _burstBracketHeld = false;
    if (_takeoverActive) return; // 用户接管还持有:remote 模式保持
    try {
      await session.changeCameraMode(0);
    } on Exception {
      // 解除尽力而为
    }
  }

  // ---- 录制(0x920A/0x920B)+ MF 步进(0x9204)----

  /// 录制开关:取景开启为前置(机身口径)。录制中拍照会被机身拒,
  /// 先提示。事件 0xC10A/0xC108 到达时对齐状态(双保险)。间隔拍摄
  /// 运行中禁开录(对「录像中禁启间隔」的对称互锁 —— 录像会让每拍
  /// 静照落空,先停轮再录)。
  Future<void> toggleRecord() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errRecordNeedsViewfinder', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      notice = (key: 'remote.ivRecYield', args: null);
      notifyListeners();
      return;
    }
    if (capturing) return;
    error = null;
    notifyListeners();
    try {
      if (recording) {
        await session.endMovieRec();
        recording = false;
        recordingSince = null;
      } else {
        await session.startMovieRec();
        recording = true;
        recordingSince = DateTime.now();
      }
    } on PtpResponseException catch (e) {
      if (e.responseCode == NikonResponseCode.invalidStatus) {
        // 0xA004:机身不在可录制的状态 —— Zf 的机顶「照片/视频」切换
        // 拨杆在照片档时 0x920A 即被拒(OpenZCine 同码口径 invalidStatus)。
        error = (key: 'remote.errLeverVideo', args: null);
      } else {
        error = (
          key: 'remote.errRecFail',
          args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
        );
      }
    } on Exception catch (e) {
      error = (key: 'remote.errRecFail', args: {'e': e.toString()});
    }
    notifyListeners();
  }

  /// MF 步进(0x9204):向近/远驱动一步([pulses] 脉冲,默认 300)。
  /// 取景挂起防事务挤占;结果转提示(行程尽头/步进过小是结果非错误,
  /// OpenZCine 口径),并按方向归因进端点态([MfTravelEnds],步进/滚轮
  /// 两路共用 —— 提示行与轮压暗跟读)。
  /// 远程切换拍摄模式(模式条点按):接管持有下写 0xD1A6 + 重启取景。
  /// **两方向可切**(2026-10-11 Zf 实证:写被接受、拍照门跟软件态);
  /// 录像门跟物理拨杆 —— 照片档覆写视频后开录被拒,拨杆提示在开录时
  /// 弹出不预判。写被拒记 [modeWriteRejected](会话级,UI 灰显两方向)。
  /// 取景重启后必刷参(模式族属性连片变)。
  Future<bool> switchMode(CaptureMode target) async {
    if (_switchingMode || recording || capturing || focusing) return false;
    final current = _cameraMode;
    if (current == null || target == current) return false;
    if (_modeWriteRejected) {
      error = (key: 'remote.errModeSwitchRefused', args: null);
      notifyListeners();
      return false;
    }
    if (!_setPropEnabled()) {
      error = (key: 'remote.errWriteDisabledMode', args: null);
      notifyListeners();
      return false;
    }
    _switchingMode = true;
    error = null;
    notifyListeners();
    try {
      if (!takeoverActive && !await enableTakeover()) return false;
      // 探针实证序:0x90C2(1) → 0x9202 → 写 0xD1A6 → 0x9201(取景
      // 关着写,起景原生以新档起)。
      await engine.stop();
      try {
        await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.liveViewSelector,
          dataType: PtpDataType.uint8,
          value: target == CaptureMode.photo ? 0 : 1,
        ));
      } on PtpResponseException catch (e) {
        _modeWriteRejected = true;
        error = (
          key: 'remote.errModeSwitchFail',
          args: {'e': _nikonHint(e.responseCode)?.key ?? e.toString()},
        );
        unawaited(_recoverLiveViewAfterFailedSwitch());
        notifyListeners();
        return false;
      }
      _setCameraMode(target);
      // 写过即覆写期:拨杆真档被软件态遮蔽(哪怕切回 believed 拨杆档
      // —— 拨杆可能已被拨过,真相只在释放后的读回里)。
      _modeOverridden = true;
      notifyListeners();
      // 起景:接管已置 engine.remoteHeld,自愈梯自动转忙重试(模式
      // 写后的 0xA004 是瞬态,2026-10-11 实证)。
      await engine.start();
      if (!_viewerVisible) engine.pause();
      await refreshParams();
      return true;
    } finally {
      _switchingMode = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 切换链写失败后的取景回滚(停景已发生,尽力起回;接管保持不动
  /// —— 用户侧芯片仍如实显示)。
  /// 快门释放:op 表选码(在册 0x9207 直用,见 [_fireShutter]),被拒
  /// 自动换码重试(成功码缓存,后续直发)。SDRAM 直拍被拒(码级)自动
  /// 回落常规入卡拍并如实提示,照片不丢。
  ///
  /// 取景开着时挂起轮询,避免取帧事务挤占串行锁;完成信号 = 事件优先、
  /// DeviceReady 轮询兜底。0x2019 忙(半按对焦未就绪等)按失败提示。
  Future<void> capture() async {
    if (capturing) return;
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (intervalActive) {
      // 间隔拍摄运行中:屏上快门/音量键快门全部让位(快门由调度器按
      // 间隔驱动),如实提示 —— 用户要手动拍先停间隔轮。
      notice = (key: 'remote.ivShutterYield', args: null);
      notifyListeners();
      return;
    }
    if (_shutterIsOpenShutter) {
      // B 门/Time 经不起「点按即走」:曝光开了没人收门(音量键快门等
      // capture() 直呼路径)—— 本地拒绝零流量并指路;按住曝光走屏上
      // 快门钮([capturePressed]),或开自拍定时组合成定时 B 门。
      notice = (key: 'remote.errBulbShutter', args: null);
      notifyListeners();
      return;
    }
    capturing = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final (ok, message) = await _captureOnce();
      if (!ok) {
        error = message;
      } else if (message != null) {
        notice = message; // SDRAM 回落提示落收口后(「已拍摄」先到)
      }
    } finally {
      capturing = false;
      notifyListeners();
    }
  }

  /// 单张拍摄核心链(屏上快门 [capture] 与间隔拍摄单拍共用):挂起取景
  /// → 发码(含码回落/CaptureSort 换形/SDRAM 一体拍)→ 等落地
  /// (CaptureComplete 事件优先,DeviceReady 兜底)→ SDRAM 回传收尾。
  /// 只管相机事务,不碰 UI 状态(capturing/error/notice 由调用方按场景
  /// 收口)—— 间隔拍摄单拍失败只记账(跳拍策略),不走屏上错误横幅。
  /// 返回 (是否成功, 文案):失败文案 = 错误消息;成功文案 = SDRAM 回落
  /// 提示(仅回落发生时非 null)。
  Future<(bool, L10nMessage?)> _captureOnce() async {
    final wasLive = liveViewActive;
    if (wasLive) engine.pause();
    try {
      (bool, L10nMessage?) firedResult;
      try {
        firedResult = await _fireShutter();
      } on PtpResponseException catch (e) {
        return (false, await _captureErrorMessage(e));
      } on Exception catch (e) {
        return (
          false,
          (key: 'remote.errShutterFail', args: {'e': e.toString()})
        );
      }
      _captureDone = Completer<void>();
      final (sdramFired, sdramFallback) = firedResult;
      if (sdramFired) _sdramHandle = Completer<int>();
      await _awaitCaptureSettled();
      if (sdramFired && _linkUp) {
        await _collectSdramObject();
      }
      return (true, sdramFallback);
    } finally {
      _captureDone = null;
      _sdramHandle = null;
      if (wasLive && _viewerVisible) engine.resume();
    }
  }

  /// 快门释放被相机拒(码级)的用户提示(原 capture 内联映射抽出,语义
  /// 不变;尽力读 WarningStatus 0xD102 —— Bit0 序列错误 → 自愈指引)。
  Future<L10nMessage> _captureErrorMessage(PtpResponseException e) async {
    if (e.responseCode == PtpResponseCode.storeNotAvailable) {
      // 0x2013:标准义 = 存储不可用(无卡/卡错误);2026-10-11 真机
      // 另证:机身拨杆在视频档时远程拍照除 0x200F 外也会报此码
      //(存储卡在位,具体子态待核)—— 双因都指,别把用户支去翻卡槽。
      return (key: 'remote.errShutterStorage', args: null);
    }
    if (e.responseCode == PtpResponseCode.invalidParameter) {
      return (key: 'remote.errShutterParam', args: null);
    }
    if (e.responseCode == NikonResponseCode.movieFrameReleaseBusy) {
      // 0xA202:录像中的静照释放进行中(官方 §6.3.2.17)—— 录像
      // 期间拍静照连拍两下会撞上,等一拍再试。
      return (key: 'remote.errShutterDuringRec', args: null);
    }
    if (e.responseCode == PtpResponseCode.accessDenied) {
      // 0x200F:相机锁定拍照控制 —— Zf 机顶「照片/视频」切换拨杆在
      // 视频档时 0x9207 即被拒(2026-10-11 真机定案;对称于录像侧
      // 0xA004 的拨杆提示)。
      return (key: 'remote.errLeverPhoto', args: null);
    }
    // 码随文浮出:有提示语时附 〔0x????〕(同连接梯诊断风格);
    // 无提示语时异常文本自带码,不再重复。seq 参数 = WarningStatus
    // Bit0 序列错误自愈指引(键,渲染端 arg-t 落地;正常为空串)。
    final hint = _nikonHint(e.responseCode);
    var msg = hint == null
        ? (key: 'remote.errShutterFail', args: {'e': e.toString(), 'seq': ''})
        : (
            key: 'remote.errShutterFailCode',
            args: {
              'h': hint.key,
              'c': '0x${e.responseCode.toRadixString(16).toUpperCase()}',
              'seq': '',
            },
          );
    // 尽力读 WarningStatus(0xD102,官方 §6.5.6.24):Bit0 序列错误
    // → 自愈指引(官方 §11.7.5:下一次释放自清,非重启级故障)。
    try {
      final w =
          await session.getDevicePropValue(PtpDevicePropCode.warningStatus);
      final raw = w.value;
      if (raw is int && (raw & 0x1) != 0) {
        msg = (
          key: msg.key,
          args: {...msg.args, 'seq': 'remote.warnSeqRecover'},
        );
      }
    } on Exception {
      // 读不到就只报原错误
    }
    return msg;
  }

  /// 等拍照落地:CaptureComplete 事件先到即收口,否则 DeviceReady 兜底。
  /// DeviceReady 报非忙错误码(op 不支持等)时放弃兜底 —— 命令已被接受,
  /// 等事件即可。
  Future<void> _awaitCaptureSettled() async {
    final done = _captureDone!.future;
    for (var i = 0; i < _capturePolls; i++) {
      bool ready;
      try {
        ready = await Future.any([
          done.then((_) => true),
          _delay(_capturePollInterval).then((_) => session.deviceReady()),
        ]);
      } on Exception {
        return; // DeviceReady 非忙错误:命令已接受,不再兜底
      }
      if (ready) return;
    }
  }

  /// SDRAM 直拍收尾:取回相机内存对象并入图库(0x90CB → 0xC101 句柄 →
  /// GetObjectInfo → TransferEngine 图库目的地,水印/XMP/后台保活全链
  /// 共用)。句柄一律取 0xC101 事件参数(不硬编码,不跨会话);5s 无
  /// 事件如实提示不上 error(快门已实发)。
  Future<void> _collectSdramObject() async {
    // 压掉 2s 轮询延迟:手动拉一轮厂商事件队列(0xC101 经 _onEvent 补
    // 全 [_sdramHandle]);拉取失败不致命,异步通道/轮询器还有机会。
    try {
      session.emitPolledEvents(await session.getEventEx());
    } on Exception {
      // 下面的 5s 窗兜底
    }
    int? handle;
    try {
      handle = await _sdramHandle?.future.timeout(sdramHandleTimeout);
    } on TimeoutException {
      handle = null;
    }
    if (!_linkUp) return;
    if (handle == null || handle == 0) {
      notice = (key: 'remote.errNoSdramObject', args: null);
      notifyListeners();
      return;
    }
    final engine = transferEngine;
    try {
      final info = await session.getObjectInfo(handle);
      if (!_linkUp) return;
      final entry = ObjectRepository.toEntry(info);
      if (engine == null) {
        notice = (key: 'remote.sdramNoGallery', args: null);
        notifyListeners();
        return;
      }
      final state = await _awaitGalleryTerminal(engine, entry);
      if (!_linkUp) return;
      switch (state) {
        case TransferState.completed:
          notice = (key: 'remote.sdramSaved', args: null);
        case TransferState.failed:
          notice = (key: 'remote.sdramSaveFailed', args: null);
        default:
          notice = (key: 'remote.sdramSaving', args: null);
      }
      notifyListeners();
    } on Exception catch (e) {
      if (!_linkUp) return;
      notice = (key: 'remote.errSaveFail', args: {'e': e.toString()});
      notifyListeners();
    }
  }

  /// 入队图库目的地并等到终态(或超窗)。订阅先于入队(广播流不补发,
  /// 错过终态帧会白等);返回最后观测到的状态,null = 超窗未终态。
  Future<TransferState?> _awaitGalleryTerminal(
    TransferEngine engine,
    ObjectEntry entry,
  ) async {
    TransferState? finalState;
    final terminal = Completer<void>();
    final sub = engine.tasks.listen((ts) {
      for (final t in ts) {
        if (t.handle == entry.handle && t.isTerminal) finalState = t.state;
      }
      if (finalState != null && !terminal.isCompleted) terminal.complete();
    });
    try {
      await engine.enqueue([entry], destination: TransferDestination.gallery);
      await terminal.future.timeout(sdramTransferTimeout, onTimeout: () {});
      return finalState;
    } finally {
      await sub.cancel();
    }
  }

  /// 即拍即览:新照片到达 → GetThumb 缩略图小卡,几秒后自动撤
  /// (OpenZCine InstantReview 的轻量版;handle 缺失时跳过 ——
  /// SD 卡写完前事件可能先到,拿不到就等下一张)。
  @override
  Future<void> _showInstantReview(int? handle) async {
    if (handle == null || handle == 0) return;
    try {
      final thumb = await session.getThumb(handle);
      if (!_linkUp) return;
      reviewThumb = thumb;
      notifyListeners();
      _reviewTimer?.cancel();
      _reviewTimer = Timer(const Duration(seconds: 4), () {
        reviewThumb = null;
        if (!_disposed) notifyListeners();
      });
    } on Exception {
      // 缩略图拿不到:即拍即览静默跳过
    }
  }
}

/// 对焦域:触控对焦/AF 驱动/MF 拉焦轮/主体追踪。

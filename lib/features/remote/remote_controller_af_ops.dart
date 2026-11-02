part of 'remote_controller.dart';

mixin _RemoteAfOps on _RemoteCore {
  /// MF 步进(0x9204):向近/远驱动一步([pulses] 脉冲,默认 300)。
  /// 取景挂起防事务挤占;结果转提示(行程尽头/步进过小是结果非错误,
  /// OpenZCine 口径),并按方向归因进端点态([MfTravelEnds],步进/滚轮
  /// 两路共用 —— 提示行与轮压暗跟读)。
  Future<void> mfDriveStep({required bool towardNear, int pulses = 300}) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (focusing) return;
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程拉焦同样失效
    error = null;
    notifyListeners();
    engine.pause();
    try {
      _noteMfDrive(towardNear); // 反向请求即解锁(nico 语义)
      final outcome =
          await session.mfDrive(towardNear: towardNear, pulses: pulses);
      _applyMfOutcome(towardNear: towardNear, outcome: outcome);
      if (outcome == MfDriveOutcome.complete ||
          outcome == MfDriveOutcome.endOfTravel) {
        // 刻度鼓按实际驱动入账;步进过小(0xA00E 镜头未动)与拒答不入。
        dialNetPulses.value += towardNear ? pulses : -pulses;
      }
      switch (outcome) {
        case MfDriveOutcome.complete:
          break;
        case MfDriveOutcome.endOfTravel:
          notice = towardNear
              ? (key: 'remote.focusNearEnd', args: null)
              : (key: 'remote.focusFarEnd', args: null);
        case MfDriveOutcome.stepTooSmall:
          notice = (key: 'remote.stepTooSmall', args: null);
        case MfDriveOutcome.refused:
          error = (key: 'remote.errMfUnavailable', args: null);
      }
    } finally {
      if (_viewerVisible) engine.resume();
      if (_linkUp) notifyListeners();
    }
  }

  /// 对焦滚轮拖动增量(竖直像素,正 = 向近 / 负 = 向远):攒够一步
  /// [_dialStepPx] 发一次 0x9204([_dialStepPulses] 脉冲/步,不足一步的
  /// 余量保留)。单在途:驱动进行中再拖,像素攒着,完成后续发 —— 命令
  /// 通道上永远最多一个滚轮事务。**不挂起取景**(跟焦要在画面上看
  /// 焦点变化,与 [mfDriveStep] 的单发路径不同)。AF 驱动(点按对焦/
  /// 对焦按钮)抢占:代数自增,在途脉冲发完后不再续发。
  ///
  /// 端点锁(0xA00C 方向归因,见 [MfTravelEnds]):目标方向端点已到
  /// → 该增量静默丢弃(不发 0x9204,省流量防错;余量保留 —— 反向
  /// 增量照常攒步)。拖动方向反转后首步请求即解锁([_noteMfDrive]),
  /// 轮身压暗随 [_mfEnds] 翻转。
  ///
  /// 拒答(0x9204 refused)不弃单:脉冲原量归还,退避
  /// [_dialRetryBackoff] 静默续发(瞬时拒答 = AF 收敛/STM 镜头初始化/
  /// 激活瞬时忙,OpenZCine 重排队口径);同一拒答连跑超
  /// [_dialRefusalGrace] 墙钟才暂停出提示。
  void focusDialDrag(double dy) {
    if (dy == 0 || !_linkUp || capturing) return;
    if (focusModeIsMf) {
      // 机身 MF:拖动无效。静默丢弃(拖动事件高频,不刷横幅)+ 清
      // 余量,防锁定解除瞬间陈旧增量爆发成一次误驱动。
      _dialAccum = 0;
      return;
    }
    if ((dy > 0 && _mfEnds.nearEnd) || (dy < 0 && _mfEnds.farEnd)) {
      // 端点锁:该方向没有更多行程,静默丢增量(反向余量保留)。
      return;
    }
    _dialAccum += dy;
    _dialPump();
  }

  /// 滚轮重新启用(开关从关到开时页面调;清失败预算、拒答连跑戳与余量)。
  void resetFocusDial() {
    _dialFailures.clear();
    _dialSuspended = false;
    _dialRefusalSince = null;
    _dialAccum = 0;
    dialNetPulses.value = 0;
  }

  /// 近端已到(0xA00C 向近归因;反向驱动/驱动成功/AF 移焦即清)。
  bool get mfNearEnd => _mfEnds.nearEnd;

  /// 远端已到(0xA00C 向远归因;反向驱动/驱动成功/AF 移焦即清)。
  bool get mfFarEnd => _mfEnds.farEnd;

  /// 一次 0x9204 派出:反向端点旗作废 + 端点态变化才广播(轮压暗/
  /// 提示行跟随;高频拖动下不额外刷监听)。
  void _noteMfDrive(bool towardNear) {
    final before = _mfEnds.anyEnd;
    _mfEnds.noteDrive(towardNear);
    if (_mfEnds.anyEnd != before) notifyListeners();
  }

  /// 一次 0x9204 结果归因落账(端点态变化才广播,同 [_noteMfDrive])。
  /// 行程尽头落锁时滚轮余量一并清零 —— 步进路径落锁时滚轮可能正攒
  /// 着同向余量,不清会在解锁后陈旧爆发成一次误驱动。
  void _applyMfOutcome(
      {required bool towardNear, required MfDriveOutcome outcome}) {
    final before = _mfEnds.anyEnd;
    _mfEnds.apply(towardNear: towardNear, outcome: outcome);
    if (outcome == MfDriveOutcome.endOfTravel) _dialAccum = 0;
    if (_mfEnds.anyEnd != before) notifyListeners();
  }

  void _dialPump() {
    if (_dialDriving) return;
    if (!_linkUp || !liveViewActive) {
      _dialAccum = 0; // 无链路/无取景:余量无意义,清掉防陈旧爆发
      return;
    }
    // 暂停中先看窗口:失败都滑出窗即自动恢复。
    if (_dialSuspended) {
      _pruneDialFailures();
      if (_dialFailures.length >= _dialFailureLimit) return;
      _dialSuspended = false;
    }
    final steps = _dialAccum ~/ _dialStepPx; // 截断除法:正负对称攒步
    if (steps == 0) return;
    final sentPx = steps * _dialStepPx;
    _dialAccum -= sentPx;
    final gen = _dialGen;
    final towardNear = steps > 0;
    final pulses = steps.abs() * _dialStepPulses;
    _noteMfDrive(towardNear); // 反向请求即解锁(nico 语义,镜头正离开该端)
    // 刻度鼓派发即入账(乐观,跟手):拒答重排队脉冲未弃单,不回冲。
    dialNetPulses.value += towardNear ? pulses : -pulses;
    _dialDriving = true;
    unawaited(() async {
      var requeued = false;
      try {
        final outcome =
            await session.mfDrive(towardNear: towardNear, pulses: pulses);
        _applyMfOutcome(towardNear: towardNear, outcome: outcome);
        switch (outcome) {
          case MfDriveOutcome.complete:
          case MfDriveOutcome.stepTooSmall:
            _dialRefusalSince = null;
            break; // 过小是结果:不提示(拖快些即可),不挡续发
          case MfDriveOutcome.endOfTravel:
            _dialRefusalSince = null;
            notice = towardNear
                ? (key: 'remote.focusNearEnd', args: null)
                : (key: 'remote.focusFarEnd', args: null);
            notifyListeners();
          case MfDriveOutcome.refused:
            // 瞬时拒答是常态:脉冲重排队(原量归还)退避静默续发,
            // 不横幅不清账(OpenZCine 同款);连跑超宽限才暂停出提示,
            // 并入失败预算同走 8s 窗恢复门。
            _dialAccum += sentPx;
            requeued = true;
            _dialRefusalSince ??= DateTime.now();
            if (DateTime.now().difference(_dialRefusalSince!) >=
                _dialRefusalGrace) {
              requeued = false;
              _dialSuspended = true;
              _dialAccum = 0;
              _dialRefusalSince = null;
              _dialFailures.add(DateTime.now());
              notice = (key: 'remote.focusDialPaused', args: null);
              notifyListeners();
            }
        }
      } on Exception catch (e) {
        if (!_linkUp) return; // 断连收口已清状态,迟到异常不计数
        if (e is PtpResponseException &&
            e.responseCode == PtpResponseCode.deviceBusy) {
          // 机身忙(别的驱动在途):不算失败,余量丢弃不堆积
          _dialAccum = 0;
          return;
        }
        _dialFailures.add(DateTime.now());
        _pruneDialFailures();
        if (_dialFailures.length >= _dialFailureLimit) {
          _dialSuspended = true;
          _dialAccum = 0;
          notice = (key: 'remote.focusDialPaused', args: null);
          notifyListeners();
        }
      } finally {
        _dialDriving = false;
        // 在途期间又拖了(或没被抢占):续发攒下的余量;拒答重排队走
        // 退避续发(瞬时忙/AF 收敛给机身喘息窗),代数守卫防 AF 抢占
        // 后陈旧续发。
        if (!_dialSuspended && gen == _dialGen && _linkUp) {
          if (requeued) {
            unawaited(_delay(_dialRetryBackoff).then((_) {
              if (gen == _dialGen && !_dialSuspended && _linkUp) _dialPump();
            }));
          } else {
            _dialPump();
          }
        }
      }
    }());
  }

  void _pruneDialFailures() {
    final cutoff = DateTime.now().subtract(_dialFailureWindow);
    _dialFailures.removeWhere((t) => t.isBefore(cutoff));
  }

  /// AF 驱动(同点再点对焦/对焦按钮)抢占在途滚轮:代数自增即止续发,
  /// 余量清零(AF 改变了焦点位置,攒的像素是陈旧意图);端点态同样
  /// 作废(AF 移焦后镜头不再顶在已记端点,nico clearMfLimits 同款)。
  /// 挪框(0x9205)**不**走这里 —— 不动镜,端点/余量照旧有效。
  void _preemptFocusDial() {
    _dialGen++;
    _dialAccum = 0;
    _mfEnds.clear();
  }

  /// 录制时长(秒;未录制为 null)。
  int? get recordingSeconds => recordingSince == null
      ? null
      : DateTime.now().difference(recordingSince!).inSeconds;

  // ---- 对焦域:触控对焦 + 对焦驱动(候选码,待真机核对)----

  /// 机身对焦模式(0xD061)是否为 MF:是 → 远程对焦控制全部失效
  /// (机身 MF 下 AF 马达脱开,0x90C1/0x9205/0x9204 均无效,只有镜头
  /// 对焦环能动焦 —— libgphoto2/nico 实证口径,**3=MF(固定)/4=MF(选择)
  /// 两态同拦**:值 3 在 Zf 取值域外、其余 Z 机身可能回,按全方言集
  /// 判定)。值未知(desc 拒答/未读到)**不锁**:宁可按钮可按被机身拒,
  /// 也不把可用控制锁死。机身拨杆改动经 0x4006 事件定向刷新,门控实时
  /// 跟随。
  bool get focusModeIsMf => kStillFocusModeMfValues
      .contains(paramProps[PtpDevicePropCode.stillFocusMode]?.value);

  /// MF 门闩:锁定时设提示并返回 true,调用方即拦下本次操作。
  bool _rejectIfFocusModeMf() {
    if (!focusModeIsMf) return false;
    notice = _focusModeMfHint;
    notifyListeners();
    return true;
  }

  /// 触控对焦两手势(2026-10-17 用户定案:挪框不自动对焦 —— 省一趟
  /// 马达,对焦单独控):
  /// - 点按空白处 → 0x9205 移动对焦区域,框上屏红(未合焦);**不跟发
  ///   AF、不抢占滚轮**(0x9205 只挪框不动镜,端点态/攒余量仍有效)。
  /// - 点在上次框位([_afBoxTapRadius] 容差内)→ 不重发 0x9205,直接
  ///   0x90C1 驱动 AF 并抢占滚轮(点两下 = 移动 + 对焦;同点重发挪框
  ///   是纯冗余)。
  /// 坐标系:归一化 0..1 → **whole-size**(帧头 @16/18,如 6048×3400;
  /// OpenZCine 重置对焦用 coordinateWidth/2 实证 —— 0x9205 参数不在
  /// JPEG 像素空间)。头不可用回退链:当前头 → 最近头(OpenZCine 同款
  /// 缓存)→ SOF 帧尺寸(末级候选,比例同但缩尺不同,待真机核对)。
  /// 对焦框上屏直到下次点按/停取景;帧头 AF 框(真实尺寸)另行叠加。
  Future<void> touchFocus(double nx, double ny) async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive || focusing) return; // 无取景/对焦中:静默忽略
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    final h = engine.header.value;
    final size = h != null && h.coordinateWidth > 0 && h.coordinateHeight > 0
        ? (width: h.coordinateWidth, height: h.coordinateHeight)
        : _lastHeaderSpace ?? frameSize.value;
    if (size == null) {
      error = (key: 'remote.errNoFrameFocus', args: null);
      notifyListeners();
      return;
    }
    error = null;
    final box = afBox;
    final sameSpot = box != null &&
        (nx - box.nx).abs() < _afBoxTapRadius &&
        (ny - box.ny).abs() < _afBoxTapRadius;
    if (sameSpot) {
      _preemptFocusDial(); // AF 抢占在途滚轮驱动(焦点位置将改变)
      notifyListeners();
      await _driveAf();
      return;
    }
    final x = (nx * size.width).round().clamp(0, size.width);
    final y = (ny * size.height).round().clamp(0, size.height);
    // 框先上屏(未定红):忙窗重试可达秒级,无框点按形同「没反应」;
    // 失败留在点按处红框 + 报错(同 _driveAf 失败语义)。
    afBox = AfBox(nx: nx, ny: ny);
    notifyListeners();
    final busyDeadline = DateTime.now().add(_afBusyGrace);
    for (;;) {
      try {
        await session.changeAfArea(x, y);
        break;
      } on PtpResponseException catch (e) {
        if (e.responseCode != PtpResponseCode.deviceBusy ||
            DateTime.now().isAfter(busyDeadline)) {
          error = (
            key: 'remote.errAfAreaFail',
            args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
          );
          notifyListeners();
          return;
        }
        await _delay(_afBusyBackoff);
      } on Exception catch (e) {
        if (!_linkUp) return; // 断连收口已清状态,迟到异常不横幅
        error = (key: 'remote.errAfAreaFail', args: {'e': userFacingError(e)});
        notifyListeners();
        return;
      }
    }
  }

  /// 对焦按钮:独立驱动一次自动对焦(取景开启是前置条件 ——
  /// 0xA00B notLiveView 为未开取景的应答形态)。对焦中再点 = 如实
  /// 提示**不发包**(2026-10-17 真机定案):Zf 对 0x90C1 扣住应答直至
  /// AF 结束(0xA002 未合焦即从该应答带回,§6.2.5.1 的「开始即回 OK +
  /// 0x90C8 轮完成」两段流在 Zf 上不存在),AF 期间线路被在途事务
  /// 占死(PIMA 时序:应答未读走,下一发命令上不了线),排队 0x9206
  /// 只能到 AF 后空放一枪 —— 打断是假动作,撤包零流量。
  Future<void> afDriveNow() async {
    if (focusing) {
      notice = (key: 'remote.focusInProgress', args: null);
      notifyListeners();
      return;
    }
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (_rejectIfFocusModeMf()) return; // 机身 MF:远程对焦失效
    _preemptFocusDial(); // AF 抢占在途滚轮驱动(同点再点同此)
    error = null;
    notifyListeners();
    await _driveAf();
  }

  /// 驱动自动对焦(0x90C1):挂起取景轮询防事务挤占串行锁;厂商响应码
  /// (0xA002 未合焦 / 0xA004 状态不允许等)转友好提示。应答同时驱动
  /// [AfBox.focused](两色制:合焦绿 / 其余红,见类注;既有框在起步时
  /// 先回未定红 = 对焦中),对焦钮与触控对焦两条路都经此。
  Future<void> _driveAf() async {
    focusing = true;
    final box = afBox;
    if (box != null) {
      afBox = AfBox(nx: box.nx, ny: box.ny); // 回未定红 = 对焦中
    }
    notifyListeners();
    engine.pause();
    bool? focused;
    try {
      final busyDeadline = DateTime.now().add(_afBusyGrace);
      for (;;) {
        try {
          await session.afDrive();
          focused = true;
          break;
        } on PtpResponseException catch (e) {
          // 0x90C1 同吃忙窗:滚轮驱动/挪框在途时「同点再点对焦」第二拍
          // 必撞 0x2019 —— 宽限内静默续发(同 touchFocus 挪框口径)。
          if (e.responseCode != PtpResponseCode.deviceBusy ||
              DateTime.now().isAfter(busyDeadline)) {
            rethrow;
          }
          await _delay(_afBusyBackoff);
        }
      }
    } on PtpResponseException catch (e) {
      focused = e.responseCode == NikonResponseCode.outOfFocus ? false : null;
      error = (
        key: 'remote.errAfFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
      );
    } on Exception catch (e) {
      focused = null; // 链路/超时类失败:合焦与否未知,不冒充结论
      error = (key: 'remote.errAfFail', args: {'e': userFacingError(e)});
    } finally {
      final b = afBox;
      if (b != null && focused != null) {
        afBox = AfBox(nx: b.nx, ny: b.ny, focused: focused);
      }
      if (_viewerVisible) engine.resume();
      focusing = false;
      if (_linkUp) notifyListeners();
    }
  }

  /// 尼康厂商响应码 → 友好提示(候选语义,OpenZCine 口径);null =
  /// 无表项,调用方用原始异常。返回键由渲染端 arg-t 落地。
  static L10nMessage? _nikonHint(int code) {
    switch (code) {
      case NikonResponseCode.hardwareError:
        return (key: 'remote.hintHardwareError', args: null);
      case NikonResponseCode.outOfFocus:
        return (key: 'remote.hintOutOfFocus', args: null);
      case NikonResponseCode.changeCameraModeFailed:
        return (key: 'remote.hintModeSwitchFailed', args: null);
      case NikonResponseCode.cameraModeNotAdjustFnumber:
        return (key: 'remote.hintApertureLocked', args: null);
      case NikonResponseCode.invalidStatus:
        return (key: 'remote.hintInvalidStatus', args: null);
      case NikonResponseCode.notLiveView:
        return (key: 'remote.hintNotLiveView', args: null);
      case NikonResponseCode.movieFrameReleaseBusy:
        return (key: 'remote.hintRecStillBusy', args: null);
      default:
        return null;
    }
  }

  // ---- 主体追踪(0x9424/0x9425,官方 §6.2.6)----

  bool get tracking => _tracking;

  /// 主体追踪门控(官方 §6.2.6.7):AF 区域(0xD05D)须「自动」
  /// (0x8011)且取景开启。Zf FORM 七值无 3D 追踪档,单值判定;
  /// 值未知(拒答/未读到)不锁 —— 宁可按了被机身拒(focusModeIsMf
  /// 同口径)。
  bool get afAreaCanTrack =>
      paramProps[PtpDevicePropCode.stillFocusMeteringMode]?.value == 0x8011;

  /// 开启主体追踪:坐标 = 最近触控对焦点(无则 whole-size 中心),
  /// 坐标系同 0x9205(帧头 whole-size)。
  Future<void> startTracking() async {
    if (!_linkUp) {
      error = (key: 'remote.notConnected', args: null);
      notifyListeners();
      return;
    }
    if (!liveViewActive) {
      error = (key: 'remote.errViewfinderOff', args: null);
      notifyListeners();
      return;
    }
    if (_rejectIfFocusModeMf()) return;
    if (!afAreaCanTrack) {
      notice = (key: 'remote.errTrackingNeedsAuto', args: null);
      notifyListeners();
      return;
    }
    final box = afBox;
    final h = engine.header.value;
    final size = h != null && h.coordinateWidth > 0 && h.coordinateHeight > 0
        ? (width: h.coordinateWidth, height: h.coordinateHeight)
        : _lastHeaderSpace ?? frameSize.value;
    if (size == null) {
      error = (key: 'remote.errNoFrameTrack', args: null);
      notifyListeners();
      return;
    }
    final nx = box?.nx ?? 0.5;
    final ny = box?.ny ?? 0.5;
    error = null;
    notifyListeners();
    try {
      await session.startTracking(
        (nx * size.width).round().clamp(0, size.width),
        (ny * size.height).round().clamp(0, size.height),
      );
      _tracking = true;
    } on PtpResponseException catch (e) {
      error = (
        key: 'remote.errTrackingFail',
        args: {'e': _nikonHint(e.responseCode)?.key ?? userFacingError(e)},
      );
    } on Exception catch (e) {
      error = (key: 'remote.errTrackingFail', args: {'e': userFacingError(e)});
    }
    if (_linkUp) notifyListeners();
  }

  /// 停止主体追踪(0x9425 无参)。收尾失败不上 error(追踪随会话/
  /// 取景消亡,旗标照落)。
  Future<void> endTracking() async {
    if (!_tracking) return;
    _tracking = false;
    notifyListeners();
    try {
      await session.endTracking();
    } on Exception {
      // 状态已落,链路级失败由断链路径收口
    }
  }
}

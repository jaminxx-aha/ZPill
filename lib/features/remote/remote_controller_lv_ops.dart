part of 'remote_controller.dart';

mixin _RemoteLvOps on _RemoteCore {
  /// 取景开关:引擎启停(帧轮询/AE 轮询/对焦框状态都随引擎状态联动)。
  @override
  Future<void> toggleLiveView() async {
    error = null;
    notice = null;
    if (liveViewActive) {
      await engine.stop();
    } else {
      await engine.start();
    }
    notifyListeners();
  }

  /// 侧链放行门(见 [_startSettledGate])。消费方自带超时兜底 —— 门永不
  /// 落定也不押死侧链(理论不至:连接沿必经落定点)。
  Future<void> get connectedStartSettled => _startSettledGate.future;

  /// connected 沿串链:自动起景(0x9201 + 首帧入队)先行,再对表刷参
  /// —— 回台沿(41c6bba)同款序,请求序恒 [0x9201, 首帧, 参数…];两个
  /// 并发 unawaited 会让引擎帧请求穿插进刷参链。
  ///
  /// 起景驱动移到本控制器自己的 connected 沿,背景(2026-10-11 真机
  /// 修复):原先由 HomeShell 在 ConnectionController 的通知沿调用
  /// [autoLiveViewOnConnect],但 AppServices 装配序里 ConnectionController
  /// 先订阅 states 流(构造器先于本控制器),connected 事件派发时它先
  /// notifyListeners、HomeShell 的调用先到,而本控制器的 _linkUp 要在
  /// 自己的订阅(排在其后)里才置位 —— 首连靠 _linkUp 冷启乐观门闩
  /// (恒真起步)蒙混过关,重连沿 _invalidate 已把它压成 false,调用
  /// 全数早退:引擎停在 idle,画面冻结在断链前末帧、无「重试取景」、
  /// 录像被 liveViewActive 门拦住,唯退出拍摄页重进才恢复。由持有
  /// _linkUp 的本控制器自驱,顺序不再寄望装配序。
  /// 读 0xD1A6 刷 [cameraMode](连接沿初读、进页/回台沿对表、0x4006
  /// 事件跟随用)。读失败保持原状(null 仍 null → 页面回落;已知值
  /// 不因瞬态失败清掉)。**覆写回声护栏**:覆写期读值是软件态回声(与
  /// 拨杆真档不可分),与已知软件态相同即零动作 —— 拨杆真档的真相留给
  /// 释放接管后的读回([releaseTakeover]);读到不同值 = 覆写已被机身
  /// 顶掉/拨杆态盖过,按新真相全量对表。
  ///
  /// [triggerRefresh]:模式翻转沿是否补刷参数(视频参数族只视频档刷,
  /// 拨到视频档要拉整条链不然面板全「--」)。连接沿/进页沿的调用后都
  /// 紧跟显式 refreshParams,必须传 false 防双刷(双刷翻倍脚本序);
  /// 0x4006 事件路径用默认 true(那里没有后续刷参)。
  @override
  Future<void> refreshCameraMode({bool triggerRefresh = true}) async {
    if (!_linkUp) return;
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.liveViewSelector);
      final value = v.value;
      if (value is! int || (value != 0 && value != 1)) return; // 表外方言:宁缺不错
      final m = value == 1 ? CaptureMode.video : CaptureMode.photo;
      if (_modeOverridden && m == _cameraMode) return;
      final changed = m != _cameraMode;
      _setCameraMode(m);
      _dialMode = m;
      _modeOverridden = false;
      if (changed && !_disposed) {
        notifyListeners();
        // 模式翻转沿补刷参数(2026-10-12 视频参数族:拨到视频档要拉
        // 整条视频参数链,不然面板全「--」)。连接沿初读不触发(首刷
        // 由 _onConnectedChain 尾部统一做);切换链在途不触发(链尾
        // refreshParams 已定态)。
        if (_paramsRefreshedOnce && !_switchingMode && triggerRefresh) {
          unawaited(refreshParams());
        }
      }
    } on Object {
      // 旧机身无此属性/瞬态拒绝/链路已死(transport StateError):模式
      // 未知,页面走本地模式条
    }
  }

  /// 远程切换拍摄模式(模式条点按):接管持有下写 0xD1A6 + 重启取景。
  /// **两方向可切**(2026-10-11 Zf 实证:写被接受、拍照门跟软件态);
  /// 录像门跟物理拨杆 —— 照片档覆写视频后开录被拒,拨杆提示在开录时
  /// 弹出不预判。写被拒记 [modeWriteRejected](会话级,UI 灰显两方向)。
  /// 取景重启后必刷参(模式族属性连片变)。
  /// 切换链写失败后的取景回滚(停景已发生,尽力起回;接管保持不动
  /// —— 用户侧芯片仍如实显示)。
  @override
  Future<void> _recoverLiveViewAfterFailedSwitch() async {
    try {
      await engine.start();
      if (!_viewerVisible) engine.pause();
    } on Object {
      // 回滚失败:引擎自落 failed →「重试取景」兜底
    }
  }

  /// 连接即取景(OpenZCine 口径:连接成功直接驱动进监看,相机侧由此
  /// 进及时取景 —— 退出上传优先的收尾一步)。由本控制器的 connected
  /// 沿串链驱动([_onConnectedChain]),进页/回台沿(RemotePage)同款
  /// 幂等调用。拍摄页不在前台也无妨:0x9201 照发(相机进取景),帧轮询
  /// 挂起等页面可见([setViewerVisible])。闸门 [autoLiveViewEnabled]
  /// (十二轮持久化的取景总开关,AppServices 同步自设置):关 = 连接/
  /// 进页/回台沿都不自动起景;用户在浮层里显式开([toggleLiveView])
  /// 不经此闸,照常生效。
  ///
  /// 单飞:连接沿/进页沿/回台沿可能同拍到达(连接成功恰逢进页),
  /// 共享在途 Future —— 否则两个 start() 都过 status==running 门
  /// (running 要等 0x9201 应答才置),双发 0x9201、双起轮询循环。
  /// 连接即取景(OpenZCine 口径:连接成功直接驱动进监看,相机侧由此
  /// 进及时取景 —— 退出上传优先的收尾一步)。由本控制器的 connected
  /// 沿串链驱动([_onConnectedChain]),进页/回台沿(RemotePage)同款
  /// 幂等调用。拍摄页不在前台也无妨:0x9201 照发(相机进取景),帧轮询
  /// 挂起等页面可见([setViewerVisible])。闸门 [autoLiveViewEnabled]
  /// (十二轮持久化的取景总开关,AppServices 同步自设置):关 = 连接/
  /// 进页/回台沿都不自动起景;用户在浮层里显式开([toggleLiveView])
  /// 不经此闸,照常生效。
  ///
  /// 单飞:连接沿/进页沿/回台沿可能同拍到达(连接成功恰逢进页),
  /// 共享在途 Future —— 否则两个 start() 都过 status==running 门
  /// (running 要等 0x9201 应答才置),双发 0x9201、双起轮询循环。
  @override
  Future<void> autoLiveViewOnConnect() {
    final inFlight = _autoStartInFlight;
    if (inFlight != null) return inFlight;
    final completer = Completer<void>();
    _autoStartInFlight = completer.future;
    () async {
      try {
        if (!autoLiveViewEnabled) return;
        if (!_linkUp) return;
        if (engine.status.value == LiveViewStatus.running) return;
        await engine.start();
        if (!_viewerVisible) engine.pause();
      } on Object {
        // 引擎自身的失败已落在 status=failed/lastError(「重试取景」
        // 兜底);此处异常属意外(如 transport 已关),单飞共享面不上抛。
      } finally {
        _autoStartInFlight = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  /// 取景画质落定(设置浮层「监看」段):更新本地值;取景在跑即写相机
  /// (会话已开),否则留给连接沿(_onConnectedChain 起景前补写 ——
  /// 冷启乐观门闩期 _linkUp 恒真,不能拿它当会话已开的凭据)。
  void setLiveViewQuality({int? imageSize, int? compression}) {
    liveViewImageSize = imageSize;
    liveViewImageCompression = compression;
    if (_linkUp && liveViewActive) unawaited(_applyLiveViewQuality());
    notifyListeners();
  }

  /// 把当前画质档写入相机(0x1016,u8 显式;起景前后均合法 —— 尺寸
  /// 档决定 0x9428 帧分辨率)。尽力而为:拒答/断链/会话未开静默
  /// (`on Object` —— 未开会话的 StateError 是 Error 不是 Exception,
  /// 逃出去会炸 initState/连接链)。
  @override
  Future<void> _applyLiveViewQuality() async {
    for (final entry in <(int, int?)>[
      (PtpDevicePropCode.liveViewImageSize, liveViewImageSize),
      (PtpDevicePropCode.liveViewImageCompression, liveViewImageCompression),
    ]) {
      final code = entry.$1;
      final value = entry.$2;
      if (value == null) continue;
      try {
        await session.setDevicePropValue(PtpDevicePropValue(
            code: code, dataType: PtpDataType.uint8, value: value));
      } on Object {
        if (!_linkUp) return;
      }
    }
  }

  /// 拍摄页可见性汇报(离台/回台、退后台/回前台):不可见挂起帧轮询
  /// 与 AE 轮询(相机侧保持取景,不发 0x9202),可见恢复。拍照/对焦
  /// 操作前后的挂起不受影响(操作内 resume 会查本状态,页面不可见
  /// 不提前恢复轮询)。
  void setViewerVisible(bool visible) {
    if (_viewerVisible == visible) return;
    _viewerVisible = visible;
    if (visible) {
      engine.resume();
    } else {
      engine.pause();
    }
    _syncAePolling();
  }

  /// 快门释放:op 表选码(在册 0x9207 直用,见 [_fireShutter]),被拒
  /// 自动换码重试(成功码缓存,后续直发)。SDRAM 直拍被拒(码级)自动
  /// 回落常规入卡拍并如实提示,照片不丢。
  ///
  /// 取景开着时挂起轮询,避免取帧事务挤占串行锁;完成信号 = 事件优先、
  /// DeviceReady 轮询兜底。0x2019 忙(半按对焦未就绪等)按失败提示。
}

/// 参数域:读改写/刷参扫描/模式门/接管闩/AE 与内屏。

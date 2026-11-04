part of 'ptp_session.dart';

/// 会话核心:串行锁、状态字段、生命周期、事件流、配对、应答断言。
mixin _SessionCore {
  PtpTransport get transport;

  Future<void> _gate = Future<void>.value();

  /// 排队告警阈值:取景帧(50ms 一拍)等过这么久基本就是被大事务占着
  /// 锁(整档下载/页枚举)。日志里区分「排队慢」与「链路慢」。
  static const Duration queueWarnThreshold = Duration(milliseconds: 200);
  static DateTime _lastQueueWarnAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 把 [op] 排入全局串行队列;失败不断链(后续排队照常执行)。
  ///
  /// 排队时长在此计量(transport 的事务计时起点在锁内,看不出排队)——
  /// 「取景卡顿」到底是等锁还是等相机,靠这条日志分辨。告警限频 1s。
  Future<T> _serialized<T>(Future<T> Function() op) {
    final queuedAt = DateTime.now();
    final run = _gate.then((_) {
      final waited = DateTime.now().difference(queuedAt);
      if (waited >= queueWarnThreshold) {
        final now = DateTime.now();
        if (now.difference(_lastQueueWarnAt) >= const Duration(seconds: 1)) {
          _lastQueueWarnAt = now;
          AppLog.w(AppLog.protocol,
              '排队 ${waited.inMilliseconds}ms 才上链(锁被长事务占着?)');
        }
      }
      return op();
    });
    _gate = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  bool _sessionOpen = false;

  /// 会话是否已打开(OpenSession 成功且未 CloseSession)。
  bool get isSessionOpen => _sessionOpen;

  /// 0x90C2 remote 模式是否在持有(USB 连接流兜底进入,或用户接管/
  /// 连拍括持开启)。每次开新会话复位 —— 机身对每个连接自行重估模式,
  /// 旧链的持有态不得带到新链。
  bool _remoteModeActive = false;
  bool get remoteModeActive => _remoteModeActive;

  /// 请求取消当前在途事务(PTP-IP Cancel-Drain)。
  ///
  /// **必须绕过 [_serialized]**:调用窗口正是互斥锁被在途事务持有的
  /// 时候,排队等锁 = 等在途事务自己完成,取消就失去意义(死等退化)。
  /// 链路不支持(USB / 路由器未挂内层 / 未连接)或无在途事务 → false,
  /// 无害 no-op;调用方继续走「置旗标、等当前事务自然完成」的优雅降级。
  ///
  /// 返回 true = Cancel 已发出,在途 execute 随后以
  /// [PtpCancelledException] 完成(排水收口由传输层 dispatcher 异步驱动,
  /// 本方法不等它)。取消通道自身异常同样按 false 落回旧路径。
  /// **2026-10-16 真机定案:Zf 收 Cancel 直接掐链 —— 生产已无调用方**
  /// (分块下载软取消替代,见 ObjectDownloader);方法留档备将来
  /// Cancel 友好的机身。
  Future<bool> cancelInFlight() async {
    // 能力探测必须用 if-case 模式绑定:is 检查对「与声明类型无关的
    // 接口」不做类型提升(Dart 流分析只向下提升),裸 is 后调用会编译错。
    if (transport case final PtpCancelCapable capable) {
      try {
        return await capable.cancelInFlight();
      } on Exception {
        return false; // 排水通道异常:不放大成取消失败,旧路径兜底
      }
    }
    return false;
  }

  /// 连接梯诊断(2026-10-07 iPhone-USB 回归定案用):enableAppControl
  /// 与 LiveViewEngine 0xA004 自愈把每步「op:结果」记入;取景失败时随
  /// lastError 一并浮出到拍摄页,真机一眼读出哪一级被拒。open() 清零
  /// (一连接一账)。
  final List<String> connectLadder = [];

  /// 记一笔连接梯诊断(见 [connectLadder])。
  void noteLadder(String step) => connectLadder.add(step);

  PtpDeviceInfo? _deviceInfo;

  /// 上次 GetDeviceInfo 的缓存(纯读,不发事务;未取过为 null)——
  /// 快门码选择等只需 op 表的调用方用它,避免无谓往返。
  PtpDeviceInfo? get cachedDeviceInfo => _deviceInfo;

  /// GetDeviceInfo;会话内缓存([force] 强制刷新)。
  /// 唯一可在 OpenSession 之前调用的操作。
  Future<PtpDeviceInfo> getDeviceInfo({bool force = false, Duration? timeout}) async {
    if (_deviceInfo != null && !force) return _deviceInfo!;
    // 连接握手(会话未开)用短窗:首连/断开重连都尽快判楔死、进 USB
    // 端口复位;运行时 force 刷新(会话已开)仍走缺省 15s(写卡/清缓存
    // 可能慢)。**不能只看 _deviceInfo 缓存**:断开重连时缓存还在,
    // 按缓存判断会让重连退回 15s(2026-11-04 ohos 真机复报)。
    final connectProbe = !_sessionOpen;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getDeviceInfo,
          timeout: timeout ?? (connectProbe ? kConnectHandshakeTimeout : null),
        )));
    _ensureOk(result, PtpOperationCode.getDeviceInfo);
    _deviceInfo = PtpDeviceInfo.parse(_requireData(result, 'GetDeviceInfo'));
    return _deviceInfo!;
  }

  /// OpenSession(带 0x201E 自动恢复,照搬 probe ensure_session)。
  /// 恢复链(Close + 重开)整体持锁,避免与其他操作交错。
  Future<void> open() async {
    if (_sessionOpen) return;
    await _serialized(_openLocked);
  }

  /// 强制重建 PTP 会话(参数写入/快照恢复遇 0x201E 时用)。
  /// 相机可能实际已关会话而本地账仍为开;先置本地账为未开,再走
  /// [_openLocked] 的 0x201E Close+Open 自愈。
  Future<void> reopen() async {
    await _serialized(() async {
      _sessionOpen = false;
      await _openLocked();
    });
  }

  /// 保护态乐观覆盖(会话内,句柄 → 是否保护):0x1012 SetObjectProtection
  /// 无读回应答,查看器以本会话发出/读回的写为准;挂在会话上 —— 页
  /// State 每次进页重建,页面级缓存重开即清空(2026-10-16 真机复报
  /// 「加锁后重进显示未锁」根因)。基线真值 = ObjectInfo 的
  /// ProtectionStatus(相册列表自带,重列即新);本 Map 只记会话内的
  /// 写入增量(含解锁,故是 Map 非 Set),读回成功也覆写于此。
  /// open() 清空(新链重列,真值回基线)。
  final Map<int, bool> protectionOptimistic = {};

  Future<void> _openLocked() async {
    final result = await transport.execute(
      const PtpRequest(
        opcode: PtpOperationCode.openSession,
        params: [1],
        timeout: kConnectHandshakeTimeout,
      ),
    );
    if (result.responseCode == PtpResponseCode.sessionAlreadyOpen) {
      // 上次会话未关(拔线/崩溃残留):关掉重开。残留会话的
      // CloseSession 可能报错(会话号不属于本连接),响应码与异常都不阻断重开。
      try {
        await transport.execute(
          const PtpRequest(
            opcode: PtpOperationCode.closeSession,
            timeout: kConnectHandshakeTimeout,
          ),
        );
      } on Exception {
        // 尽力而为,见上
      }
      final retry = await transport.execute(
        const PtpRequest(
          opcode: PtpOperationCode.openSession,
          params: [1],
          timeout: kConnectHandshakeTimeout,
        ),
      );
      _ensureOk(retry, PtpOperationCode.openSession);
    } else {
      _ensureOk(result, PtpOperationCode.openSession);
    }
    _sessionOpen = true;
    _remoteModeActive = false; // 新链新账:旧链的 remote 模式持有态不带来
    _largeThumbDegraded = false; // 新链新账:0x90C4 重新探测
    _objectPropListDegraded = false; // 新链新账:0x9805 重新探测
    _objectsMetaDataDegraded = false; // 新链新账:0x9434 重新探测
    protectionOptimistic.clear(); // 新链新账:保护态乐观值不跨连接
    connectLadder.clear(); // 一连接一账:新连接的梯从零记
  }

  /// CloseSession(幂等、尽力而为):相机已拔出时不因清理报错。
  /// 设备级断开由连接层调 transport.close()。
  Future<void> close() async {
    _remoteModeActive = false; // 链将亡:remote 持有态一律作废(含未开会话的旁路持有)
    _largeThumbDegraded = false; // 链将亡:0x90C4 降级态作废,新链重探
    _objectPropListDegraded = false; // 链将亡:0x9805 降级态作废,新链重探
    _objectsMetaDataDegraded = false; // 链将亡:0x9434 降级态作废,新链重探
    if (!_sessionOpen) return;
    _sessionOpen = false;
    await _serialized(() async {
      try {
        await transport.execute(
          const PtpRequest(
            opcode: PtpOperationCode.closeSession,
            // 收会话**不能**用 5s 握手短窗:CloseSession 排在在途事务
            // 之后,短窗会提前放弃、把相机留在忙态,下一次重连的首笔
            // 读到晚到的旧响应(2026-11-04 ohos 真机 "V3.00" 流错位
            // 根因)。15s 缺省窗是相机响应上限,不是连接握手窗。
          ),
        );
      } on Exception {
        // 链路已断:本地状态已清,足够
      }
    });
  }

  /// 0x90C4 会话级降级旗标:本会话内 GetLargeThumb 已被真发证实不可用
  /// (错误应答/非 SOI/超时),缩略管线据此直走 0x100A。[open()] /
  /// [close()] 复位 —— 新连接重新探测。
  bool _largeThumbDegraded = false;

  /// 0x9805 会话级降级旗标(语义同 [_largeThumbDegraded]):本会话内
  /// GetObjectPropList 已被真发证实不可用(错误应答/数据集不可信/链路
  /// 异常),仓库层据此直走逐对象 GetObjectInfo。[open()] / [close()]
  /// 复位 —— 新连接重新探测;码表不在册不置位(不做 supportsOperation
  /// 门禁,STA 9-op 小表假门,直发纪律同 0x90C4/0x920F)。
  bool _objectPropListDegraded = false;

  /// 0x9434 会话级降级旗标(语义同 [_objectPropListDegraded]):本会话内
  /// GetObjectsMetaData 已超时/失败过,仓库层不再自动重试,直走逐张
  /// 评级补读。[open()] / [close()] 复位 —— 新连接重新探测。
  ///
  /// 动机(2026-11-04 真机):Zf/HarmonyOS USB 上 0x9434 生成整卡索引
  /// 超过 15s 缺省事务窗,重试会把整条链路拖死;降级后只损失「批量
  /// 星级位」,评级仍可由逐张 0xDC8A/XMP 补齐。
  bool _objectsMetaDataDegraded = false;

  /// 0x9434 是否已在本会话降级(见 [_objectsMetaDataDegraded])。
  bool get objectsMetaDataDegraded => _objectsMetaDataDegraded;

  /// 标记 0x9434 本会话不可用(仓库层失败沿调用;下一次 open/close 复位)。
  void noteObjectsMetaDataFailed() => _objectsMetaDataDegraded = true;

  /// 事件流 = 异步通道(USB interrupt / PTP-IP 事件 socket)+ 轮询注入
  /// ([emitPolledEvents],[NikonEventPoller] 用)的并流。尼康机身的重要
  /// 事件(ObjectAdded/CaptureComplete/0x4006)可能只走 GetEventEx
  /// 0x941C 轮询通道(OpenZCine/libgphoto2 实测口径),两路并存、
  /// 消费端幂等。
  late final Stream<PtpEvent> _events =
      _mergedStreams([transport.events, _eventInjections.stream]);
  final _eventInjections = StreamController<PtpEvent>.broadcast();

  Stream<PtpEvent> get events => _events;

  /// 轮询事件注入([NikonEventPoller] 调用)。
  void emitPolledEvents(Iterable<PtpEvent> polled) {
    for (final e in polled) {
      _eventInjections.add(e);
    }
  }

  /// 广播并流(单订阅源 → 广播聚合;单监听者模型,close 后不再复听)。
  static Stream<T> _mergedStreams<T>(List<Stream<T>> streams) {
    late StreamController<T> ctrl;
    final subs = <StreamSubscription<T>>[];
    var pending = streams.length;
    ctrl = StreamController<T>.broadcast(
      onListen: () {
        for (final s in streams) {
          subs.add(s.listen(ctrl.add, onError: ctrl.addError, onDone: () {
            if (--pending == 0) ctrl.close();
          }));
        }
      },
      onCancel: () {
        for (final s in subs) {
          s.cancel();
        }
        subs.clear();
      },
    );
    return ctrl.stream;
  }

  /// Nikon GetEventEx(0x941C,Gen-3 事件轮询):拉取并清空厂商事件队列。
  ///
  /// 布局(OpenZCine PTPNikonEventList):`u32 元素数 + N ×
  /// (u16 事件码 + u16 参数数 + 参数数 × u32)`;元素数上限 2048 防御。
  /// 相机不支持(旧机身回 0x2005)时上抛,由 [NikonEventPoller] 停轮询。
  Future<List<PtpEvent>> getEventEx() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.getEventEx,
        )));
    _ensureOk(result, NikonOperationCode.getEventEx);
    final data = result.data ?? Uint8List(0);
    if (data.length < 4) return const [];
    var count = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    if (count > 2048) count = 2048;
    final events = <PtpEvent>[];
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 4 > data.length) break;
      final code = data[offset] | (data[offset + 1] << 8);
      final paramCount = data[offset + 2] | (data[offset + 3] << 8);
      offset += 4;
      if (offset + paramCount * 4 > data.length) break;
      final params = <int>[
        for (var p = 0; p < paramCount; p++)
          data[offset + p * 4] |
              (data[offset + p * 4 + 1] << 8) |
              (data[offset + p * 4 + 2] << 16) |
              (data[offset + p * 4 + 3] << 24),
      ];
      offset += paramCount * 4;
      events
          .add(PtpEvent(code: code, transactionId: 0xFFFFFFFF, params: params));
    }
    return events;
  }

  /// Nikon GetPtpIpPairingCode(0x952B):智能设备模式的配对验证码。
  ///
  /// 数据集 = count(u32 LE)+ count 个字节,各字节的十进制值连成验证码
  /// (NiConn_DEMO 对 SnapBridge 抓包的语义;例:count=4,字节
  /// 05 00 07 07 → "5077")。**响应非 OK 时返回 null**(多半意味着本
  /// 客户端已配对或相机不要求配对,上层据此跳过配对相;具体语义待真机
  /// 核对);链路级异常照常抛出,不在此吞。
  Future<String?> getPairingCode() async {
    late final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getPtpIpPairingCode)));
      _ensureOk(result, NikonOperationCode.getPtpIpPairingCode);
    } on PtpResponseException {
      return null;
    }
    final data = result.data;
    if (data == null || data.length < 4) return null;
    final count = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    if (count <= 0 || count > data.length - 4) return null;
    return [for (var i = 0; i < count; i++) data[4 + i]].join();
  }

  /// Nikon CompletePairing(0x935A,param 0x2001):确认配对。
  ///
  /// 相机把本客户端(Init 载荷里的 16B UUID)记为已配对设备;Z50II 实测
  /// 配对完成后相机自行结束会话(Zf 待真机核对)—— 响应前链路被收线
  /// 属预期,上层按配对完成处理,不当作失败。
  Future<void> completePairing() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
        opcode: NikonOperationCode.completePairing, params: [0x2001])));
    _ensureOk(result, NikonOperationCode.completePairing);
  }

  void _ensureOk(PtpResult result, int opcode) {
    if (result.responseCode != PtpResponseCode.ok) {
      throw PtpResponseException(
        opcode: opcode,
        responseCode: result.responseCode,
        params: result.params,
      );
    }
  }
}

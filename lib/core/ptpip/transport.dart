/// PTP-IP 传输层实现(双 TCP 通道:command + event,均连相机 15740)。
///
/// 生命周期:[connect] 完成 MTP/IP 握手(command 通道 InitCommandRequest/
/// Response 取连接号 → event 通道 InitEventRequest/Response)后,两条通道
/// 各自进入**常驻 dispatcher**(frames 流生命周期内只 listen 一次);
/// [execute] 只负责取号、组包、挂 Completer,收包全靠 dispatcher 按
/// tid 路由。
///
/// 四条不变量(压测定案,缺一则 PtpSession 的串行 future-chain 会挂死):
/// 1. **毒化**:close()/断链/超时后,所有 in-flight 与后续 execute 以
///    [PtpLinkException](implements Exception)失败 —— Error 会逃过
///    session/browser/downloader 清理路径的 `on Exception` catch,把 UI
///    卡进无限转圈(iOS 通道字节陷阱同款教训)。
/// 2. **整事务超时**:每个在途事务挂看门狗,收到该 tid 的任意帧即重置;
///    超时 = fail + 毒化 + 广播 breakage(晚到帧不得污染下一事务 ——
///    USB responseBuffer 教训的无线版)。
/// 3. 通道 done/error → 同 2;两条通道任一死亡都按整链断裂处理
///    (Zf 真机:~180s 空闲杀 command 通道、event 通道存活 —— 保守先全断,
///    Phase 3 观测后再考虑降级)。
/// 4. StartData 的 u64 declared 与实收对账,不平即毒化。
///
/// 真机依据(Zf,2026-10-04 probe 13 步全过):tid 为 u32 宽度,
/// GetDeviceInfo 与 OpenSession 均用 0、其后自 1 递增(OpenSession 重置
/// 计数,适配 0x201E 自愈链的 Close+重开);相机**忽略**请求里的
/// DataPhaseInfo 值(仍按规范填表,便于抓包对拍);小数据集 StartData+
/// EndData 直接携带全部负载、零 Data 包;ProbeRequest 只在 event 通道回声。
library;

import 'dart:async';
import 'dart:typed_data';

import '../camera/keepalive.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_transport.dart';
import 'channels.dart';
import 'codec.dart';
import 'packet.dart';

/// 相机 PTP-IP 服务端口(command/event 通道同端口,两条独立 TCP 连接)。
const int kPtpIpPort = 15740;

/// 链路级故障(断链 / 超时 / 毒化后的 execute)。
///
/// implements Exception 是硬约束:上层清理路径全部 `on Exception` catch。
final class PtpLinkException implements Exception {
  const PtpLinkException(this.message);

  final String message;

  @override
  String toString() => 'PtpLinkException: $message';
}

/// 相机在 MTP/IP 握手期发回 InitFail 拒绝连接。
///
/// 2026-10-04 真机实证(STA 模式):reason=0x00000001 且完全可复现的场景是
/// **单连接槽位被占用** —— 已配对的 SnapBridge 抢先连上后,后来者 Init 即被
/// 拒;释放后同样的 Init 秒过(无配对门)。带上 reason 供 UI 区分指引。
final class PtpInitRejectException extends PtpLinkException {
  PtpInitRejectException(this.reason, String channel)
      : super('相机拒绝$channel(InitFail reason=0x${reason.toRadixString(16)})');

  /// InitFail 载荷里的 4 字节 reason(spec 未定义语义;0x1 = 占用,见类注)。
  final int reason;
}

/// DataPhaseInfo 私表:1=无数据相,2=数据出,3=数据入。
///
/// 放 core/ptpip(与链路强相关,不入链路无关的 operation_codes.dart)。
/// 真机已证相机忽略请求里的该值(Nikon 客户端恒发 1 亦通),仍按规范填。
/// 收录 = PtpSession 及近期规划(心跳/断点续传)实际用到的 data-in 操作;
/// 未收录码按 1 发,宽容度已证不影响正确性。
int _dataPhaseFor(int opcode, Uint8List? dataOut) {
  if (dataOut != null) return 2;
  const dataInOps = <int>{
    PtpOperationCode.getDeviceInfo,
    PtpOperationCode.getStorageIds,
    PtpOperationCode.getStorageInfo,
    PtpOperationCode.getObjectHandles,
    PtpOperationCode.getObjectInfo,
    PtpOperationCode.getObject,
    PtpOperationCode.getThumb,
    PtpOperationCode.getDevicePropDesc,
    PtpOperationCode.getDevicePropValue,
    PtpOperationCode.getPartialObject,
    NikonOperationCode.getLargeThumb,
    NikonOperationCode.getEvent,
    NikonOperationCode.getEventEx,
    NikonOperationCode.getObjectSize,
    NikonOperationCode.getPartialObjectEx,
    NikonOperationCode.getPtpIpPairingCode,
    NikonOperationCode.getLiveViewImage,
    NikonOperationCode.getLiveViewImageEx,
    NikonOperationCode.getDevicePropValueEx,
    NikonOperationCode.getDevicePropDescEx,
    NikonOperationCode.getPictCtrlData,
  };
  return dataInOps.contains(opcode) ? 3 : 1;
}

/// 一个在途事务的记账。
final class _Pending {
  _Pending({required this.transactionId, this.onData});

  final int transactionId;
  final void Function(Uint8List chunk)? onData;

  final completer = Completer<PtpResult>();
  Timer? watchdog;

  /// StartData 声明的总字节数;null = 纯响应事务(无数据相)。
  int? declaredLength;
  int receivedLength = 0;
  final _chunks = <Uint8List>[];

  bool get isStreaming => onData != null;

  /// 数据相分块(流式回调透传 / 非流式暂存,大文件不整体驻留内存)。
  void feed(Uint8List chunk) {
    receivedLength += chunk.length;
    final sink = onData;
    if (sink == null) {
      _chunks.add(chunk);
    } else {
      sink(chunk); // 回调抛异常(盘满等)由 dispatcher 兜住 → 毒化
    }
  }

  /// 非流式事务聚合出的数据相(流式返回 null,data 已随回调交出)。
  Uint8List takeData() {
    final out = Uint8List(receivedLength);
    var off = 0;
    for (final c in _chunks) {
      out.setAll(off, c);
      off += c.length;
    }
    return out;
  }
}

/// PTP-IP 传输层:握手、常驻 dispatcher、tid 路由、毒化语义。
///
/// 每次无线连接新建一个实例(close 后不可复用);USB 路径的
/// [PtpTransport] 另有实现,由连接层路由器选择挂载。
final class PtpIpTransport implements PtpTransport {
  PtpIpTransport({
    PtpIpChannel Function()? createChannel,
    Uint8List? clientGuid,
    this.hostname = 'Android Device',
    this.transactionTimeout = const Duration(seconds: 15),
    this.enableKeepalive = false,
    this.keepaliveInterval = const Duration(seconds: 15),
    this.keepaliveMaxMissed = 3,
    this.probeTimeout = const Duration(seconds: 10),
    Future<void> Function(Duration)? keepaliveDelay,
  })  : _createChannel = createChannel ?? TcpPtpIpChannel.new,
        _keepaliveDelay = keepaliveDelay ?? Future<void>.delayed,
        clientGuid = clientGuid ?? Uint8List.fromList(kNikonAndroidGuid);

  /// 通道工厂。null = 生产 TCP(5s 连接超时,见 [TcpPtpIpChannel]);
  /// 测试注入 Fake 回放脚本。**工厂被调两次:第一次 command、第二次
  /// event**,注入的队列必须按此顺序供通道。
  final PtpIpChannel Function() _createChannel;

  /// InitCommandRequest 的客户端 GUID(16B)。相机按它识别/记忆已配对
  /// 客户端:默认 [kNikonAndroidGuid](Camera_Bridge 固定值,全功能已证);
  /// 配对流程用 App 侧持久化的随机 GUID(见 data/client_identity_store),
  /// 换 GUID 即相机眼里的新客户端。
  final Uint8List clientGuid;

  /// InitCommandRequest 的主机名(尼康方言要求 NUL 终止 UTF-16LE,
  /// 相机仅按 GUID 识别客户端,主机名内容不敏感)。
  final String hostname;

  /// 整事务超时(发送 → 数据相 → 响应全程,每帧重置)。
  final Duration transactionTimeout;

  /// 心跳保活开关:握手完成后在 event 通道周期真发 ProbeRequest(13)、
  /// 等 ProbeResponse(14) 回声(2026-10-04 probe 13 步真机已证有回声;
  /// 只发不收等于定时断线)。默认关 —— 生产装配在创建处显式打开,
  /// 纯回放脚本的测试不受打扰。
  final bool enableKeepalive;

  /// 心跳周期间隔(默认 15s;真机 ~180s 空闲杀 command 通道,15s×3
  /// 的探测密度足够在之前判死)。
  final Duration keepaliveInterval;

  /// 连续无响应上限,达到即按断链收口。
  final int keepaliveMaxMissed;

  /// 单次心跳等回声的窗口;必须短于 [keepaliveInterval](串行循环,
  /// 挂满窗口会推迟下一拍,但不重叠)。
  final Duration probeTimeout;

  /// 心跳 delay 注入(测试驱动;生产恒真实挂钟)。
  final Future<void> Function(Duration) _keepaliveDelay;

  final _codec = PtpIpCodecImpl();

  PtpIpChannel? _command;
  PtpIpChannel? _event;
  bool _connecting = false;
  bool _connected = false;
  bool _closed = false;
  bool _poisoned = false;
  String? _deathReason;

  /// 握手期临时的包接收器;置 null 即 dispatcher 进入事务路由。
  /// (单订阅流终身只能 listen 一次 —— 握手与事务共用同一条订阅,
  /// 靠这两个字段区分阶段,而非先订阅再取消重订。)
  Completer<PtpIpPacket>? _cmdHandshake;
  Completer<PtpIpPacket>? _evtHandshake;

  int _nextTid = 0;
  final _pending = <int, _Pending>{};

  /// 运行期心跳(握手完成后创建;断链/主动关闭即停)。
  ProbeKeepalive? _keepalive;

  /// 在途心跳的回声 Completer:收到 ProbeResponse 即完成;超时/换代作废。
  Completer<void>? _probePong;

  final _eventsCtrl = StreamController<PtpEvent>.broadcast();

  /// 意外断链广播(文本描述,风格对齐 USB 看门狗 breakages,连接层据此
  /// 转 failed 并走 teardown)。**主动 close() 不广播。**
  Stream<String> get breakages => _breakagesCtrl.stream;
  final _breakagesCtrl = StreamController<String>.broadcast();

  @override
  Stream<PtpEvent> get events => _eventsCtrl.stream;

  /// 连接相机并完成双通道 MTP/IP 握手。
  ///
  /// 任一步失败:关闭两条通道、抛出原异常(SocketException → 上层转
  /// 本地网络/热点指引;TimeoutException → 握手超时;[PtpInitRejectException]
  /// → 相机 InitFail 拒绝,多为单连接槽位被占用)。
  Future<void> connect(String host, {int port = kPtpIpPort}) async {
    if (_closed || _poisoned || _connected || _connecting) {
      throw StateError(_closed
          ? 'transport 已关闭'
          : _poisoned
              ? 'transport 已毒化'
              : 'transport 已连接');
    }
    _connecting = true;
    final command = _createChannel();
    final event = _createChannel();
    try {
      await command.connect(host, port);
      // command 通道:先挂终身订阅再发 Init(无收包竞态);
      // 握手帧经 _cmdHandshake 接力,完成后同一条订阅转事务路由。
      final cmdHandshake = Completer<PtpIpPacket>();
      _cmdHandshake = cmdHandshake;
      _listenForever(command, isCommand: true);
      await _send(command, InitCommandRequestPacket(
            guid: clientGuid,
            hostname: hostname,
          ));
      final initResp = await cmdHandshake.future.timeout(transactionTimeout);
      if (initResp is InitFailPacket) {
        throw PtpInitRejectException(initResp.reason, '连接');
      }
      // 握手期只可能以目标类型或 InitFail 完成,转型安全
      final init = initResp as InitCommandResponsePacket;
      _cmdHandshake = null;

      await event.connect(host, port);
      final evtHandshake = Completer<PtpIpPacket>();
      _evtHandshake = evtHandshake;
      _listenForever(event, isCommand: false);
      await _send(event,
          InitEventRequestPacket(connectionNumber: init.connectionNumber));
      final evtResp = await evtHandshake.future.timeout(transactionTimeout);
      if (evtResp is InitFailPacket) {
        throw PtpInitRejectException(evtResp.reason, '事件通道');
      }
      _evtHandshake = null;

      _command = command;
      _event = event;
      _connected = true;
      if (enableKeepalive) {
        final keepalive = ProbeKeepalive(
          ping: _probe,
          interval: keepaliveInterval,
          maxMissed: keepaliveMaxMissed,
          delay: _keepaliveDelay,
          onDead: () => _onBreakage(
              '心跳丢失:$keepaliveMaxMissed 次连续 ProbeRequest 无回声,判定链路已断'),
        );
        _keepalive = keepalive;
        unawaited(keepalive.start());
      }
    } on Object {
      // 握手失败不留半开连接;transport 保持未连接态可由上层决定重试
      _cmdHandshake = null;
      _evtHandshake = null;
      await command.close();
      await event.close();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// 通道终身唯一订阅(单订阅流不可重订):握手期把 Init 系响应接力给
  /// 握手 Completer,之后按通道角色分派到事务/事件 dispatcher。
  void _listenForever(PtpIpChannel channel, {required bool isCommand}) {
    channel.frames.listen(
      (frame) {
        if (_poisoned) return; // 断链后的迟到帧直接丢弃
        final handshake = isCommand ? _cmdHandshake : _evtHandshake;
        if (handshake != null && !handshake.isCompleted) {
          _onHandshakeFrame(handshake, frame, isCommand: isCommand);
        } else if (isCommand) {
          _onCommandFrame(frame);
        } else {
          _onEventFrame(frame);
        }
      },
      onError: (Object e) {
        if (_poisoned) return;
        final handshake = isCommand ? _cmdHandshake : _evtHandshake;
        if (handshake != null && !handshake.isCompleted) {
          handshake.completeError(e);
        } else {
          _onBreakage(
              '${isCommand ? "command" : "event"} 通道错误: $e');
        }
      },
      onDone: () {
        if (_poisoned) return;
        final handshake = isCommand ? _cmdHandshake : _evtHandshake;
        if (handshake != null && !handshake.isCompleted) {
          handshake.completeError(
              const PtpLinkException('通道在握手完成前被关闭'));
        } else if (isCommand) {
          _onBreakage('command 通道被相机关闭(空闲超时或链路中断)');
        } else {
          _onBreakage('event 通道被相机关闭');
        }
      },
    );
  }

  void _onHandshakeFrame(
    Completer<PtpIpPacket> handshake,
    PtpIpFrame frame, {
    required bool isCommand,
  }) {
    final expected = isCommand
        ? PtpIpPacketType.initCommandResponse
        : PtpIpPacketType.initEventResponse;
    if (frame.type != expected && frame.type != PtpIpPacketType.initFail) {
      return; // 握手期的其他包(如迟到心跳)忽略
    }
    try {
      handshake.complete(_codec.decode(frame));
    } on Exception catch (e) {
      handshake.completeError(e);
    }
  }

  /// command 通道常驻 dispatcher:按包类型驱动事务状态机。
  void _onCommandFrame(PtpIpFrame frame) {
    if (_poisoned) return; // 断链后的迟到帧直接丢弃
    final PtpIpPacket packet;
    try {
      packet = _codec.decode(frame);
    } on Exception catch (e) {
      _onBreakage('command 通道帧解析失败: $e');
      return;
    }
    try {
      switch (packet) {
        case StartDataPacket p:
          _onStartData(p);
        case DataPacket(:final transactionId, :final payload):
          _onData(transactionId, payload);
        case EndDataPacket(:final transactionId, :final payload):
          // EndData 携带尾段(小数据集可能整个数据相都在这里)
          _onData(transactionId, payload);
        case OperationResponsePacket p:
          _onOperationResponse(p);
        case EventPacket ev:
          // 个别固件把事件发到 command 通道:转投广播
          _eventsCtrl.add(PtpEvent(
            code: ev.eventCode,
            transactionId: ev.transactionId,
            params: ev.params,
          ));
        case CancelPacket(:final transactionId):
          _onBreakage('相机主动发出 Cancel(tid=$transactionId)');
        case InitFailPacket(:final reason):
          _onBreakage(
              '相机在会话中发 InitFail(reason=0x${reason.toRadixString(16)})');
        case InitCommandRequestPacket():
        case InitEventRequestPacket():
        case OperationRequestPacket():
        case InitCommandResponsePacket():
        case InitEventResponsePacket():
        case ProbeRequestPacket():
        case ProbeResponsePacket():
          break; // 迟到的握手/心跳回声,无害忽略
      }
    } on Object catch (e) {
      // onData 回调抛异常(盘满)、对账失败以外的意外 —— 一律按断链处理
      _onBreakage('command 通道事务处理失败($e)');
    }
  }

  /// event 通道常驻 dispatcher:Event 包转广播,ProbeResponse 完成在途
  /// 心跳,其余(相机主动 ProbeRequest 等,真机已证无害)忽略。
  void _onEventFrame(PtpIpFrame frame) {
    if (_poisoned) return;
    try {
      final packet = _codec.decode(frame);
      switch (packet) {
        case EventPacket ev:
          _eventsCtrl.add(PtpEvent(
            code: ev.eventCode,
            transactionId: ev.transactionId,
            params: ev.params,
          ));
        case ProbeResponsePacket():
          // 心跳回声(真机实证:ProbeRequest 在 event 通道有回声)。
          // 迟到的前代回声可能误完成新一拍 —— 窗口内到得这么密,链路
          // 活着,误判方向无害。
          final pong = _probePong;
          if (pong != null && !pong.isCompleted) pong.complete();
        default:
          break;
      }
    } on Object catch (e) {
      _onBreakage('event 通道帧处理失败($e)');
    }
  }

  void _onStartData(StartDataPacket packet) {
    final pending = _pending[packet.transactionId];
    if (pending == null) {
      _onBreakage('StartData 事务号错位(tid=${packet.transactionId})');
      return;
    }
    pending.declaredLength = packet.totalLength;
    _armWatchdog(pending);
  }

  void _onData(int tid, Uint8List payload) {
    final pending = _pending[tid];
    if (pending == null) {
      _onBreakage('数据帧事务号错位(tid=$tid)');
      return;
    }
    if (payload.isNotEmpty) {
      // 空尾 EndData 不触发 onData / 不计入对账
      pending.feed(payload);
    }
    _armWatchdog(pending);
  }

  void _onOperationResponse(OperationResponsePacket packet) {
    final tid = packet.transactionId;
    final pending = _pending.remove(tid);
    if (pending == null) {
      _onBreakage('响应事务号错位(tid=$tid,无在途事务)');
      return;
    }
    pending.watchdog?.cancel();

    // 对账:声明过数据相就必须收满(StartData u64 vs 实收)
    final declared = pending.declaredLength;
    if (declared != null && pending.receivedLength != declared) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(PtpLinkException(
            'tid=$tid 数据不完整:声明 $declared B,实收 '
            '${pending.receivedLength} B'));
      }
      _onBreakage('数据相对账失败(tid=$tid)');
      return;
    }
    if (pending.completer.isCompleted) {
      _onBreakage('tid=$tid 收到重复响应');
      return;
    }
    pending.completer.complete(PtpResult(
      responseCode: packet.responseCode,
      params: packet.params,
      data: pending.isStreaming ? null : pending.takeData(),
    ));
  }

  /// (重)挂整事务看门狗:收到该事务任意帧即重置。
  void _armWatchdog(_Pending pending) {
    pending.watchdog?.cancel();
    pending.watchdog = Timer(transactionTimeout, () {
      _onBreakage('事务超时(tid=${pending.transactionId},'
          '${transactionTimeout.inSeconds}s 无新帧)');
    });
  }

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    if (_poisoned) {
      throw PtpLinkException(_deathReason ?? '链路已断');
    }
    final command = _command;
    if (command == null) {
      throw StateError('尚未连接:先 connect()');
    }
    // 尼康方言:GetDeviceInfo 与 OpenSession 均用 tid 0、其后自 1 递增;
    // OpenSession 重置计数,适配 PtpSession 0x201E 自愈链的 Close+重开。
    if (request.opcode == PtpOperationCode.openSession) {
      _nextTid = 0;
    }
    final tid = _nextTid++;
    final pending = _Pending(transactionId: tid, onData: onData);
    _pending[tid] = pending;
    _armWatchdog(pending);
    try {
      await _send(command, OperationRequestPacket(
            dataPhaseInfo: _dataPhaseFor(request.opcode, request.dataOut),
            opcode: request.opcode,
            transactionId: tid,
            params: request.params,
          ));
      final dataOut = request.dataOut;
      if (dataOut != null) {
        // 数据出相:StartData + EndData 携带全部负载。
        // 布局待真机核对(--setprop 未跑);需要分块发送时再加。
        await _send(command, StartDataPacket(
              transactionId: tid,
              totalLength: dataOut.length,
            ));
        await _send(
            command, EndDataPacket(transactionId: tid, payload: dataOut));
      }
    } on Object catch (e) {
      // 发送失败 = 链路已死(socket 断/通道关闭):毒化整链,
      // 本事务随 _failPending 一并失败
      final reason = '发送失败(tid=$tid): $e';
      if (!_poisoned) {
        _onBreakage(reason);
      }
      throw PtpLinkException(reason);
    }
    return pending.completer.future;
  }

  /// 意外断链统一入口:毒化 + fail 全部在途 + 广播 breakage + 关通道。
  /// 主动 close() 不走这里(不广播)。
  void _onBreakage(String reason) {
    if (_poisoned) return;
    _poisoned = true;
    _deathReason = reason;
    _keepalive?.stop();
    _keepalive = null;
    _failPending(PtpLinkException(reason));
    _breakagesCtrl.add(reason);
    unawaited(_eventsCtrl.close());
    unawaited(_command?.close());
    unawaited(_event?.close());
  }

  void _failPending(PtpLinkException error) {
    for (final pending in _pending.values) {
      pending.watchdog?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
  }

  /// 主动断开:立即毒化在途(与断链同语义,但不广播 breakage)。
  /// close 后本实例报废,无线重连 = 新建实例。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepalive?.stop();
    _keepalive = null;
    if (!_poisoned) {
      _poisoned = true;
      _deathReason = '链路已关闭';
      _failPending(const PtpLinkException('链路已关闭'));
    }
    final command = _command;
    final event = _event;
    _command = null;
    _event = null;
    await command?.close();
    await event?.close();
    await _eventsCtrl.close();
    await _breakagesCtrl.close();
  }

  Future<void> _send(PtpIpChannel channel, PtpIpPacket packet) async {
    final bytes = _codec.encode(packet);
    await channel.sendFrame(PtpIpFrame(
      type: packet.type,
      body: Uint8List.sublistView(bytes, kPtpIpHeaderLength),
    ));
  }

  /// 心跳一拍:向 event 通道真发 ProbeRequest,窗口内等到回声才算活。
  /// 链路已死/发送失败/超时 → false(由 keepalive 累计,达上限判死链)。
  Future<bool> _probe() async {
    final event = _event;
    if (event == null || _poisoned) return false;
    final pong = _probePong = Completer<void>();
    try {
      await _send(event, const ProbeRequestPacket());
    } on Object {
      return false; // 通道已死:breakage 广播由通道 done/error 负责
    }
    try {
      await pong.future.timeout(probeTimeout);
      return true;
    } on Object {
      return false; // 超时(或链路毒化后的异常):本拍无回声
    }
  }
}

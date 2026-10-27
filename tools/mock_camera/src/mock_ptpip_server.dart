/// 假相机 TCP 服务:PTP-IP 双通道(command + event)+ 尼康方言握手。
///
/// 握手严格按我方客户端(`lib/core/ptpip/transport.dart` 的 connect)逐包
/// 镜像 —— mock 是它的对端,对端按客户端实际会发的形状应答即正确:
///
/// 1. 客户端第 1 条 TCP 连上 15740,发 InitCommandRequest(尼康方言:
///    GUID 16B + 无长度前缀的 NUL 终止 UTF-16LE 主机名 + u32 版本)。
///    mock 回 InitCommandResponse(u32 连接号 + 16B 相机 GUID + NUL 终止
///    UTF-16LE 相机名 + u32 版本);占用拒绝(或 CLI `--init-fail`)回
///    InitFail(reason)。
/// 2. 客户端第 2 条 TCP 连同端口,发 InitEventRequest(连接号);mock 回
///    InitEventResponse(空负载)。
/// 3. 此后命令通道收 OperationRequest(数据出相 = DataPhaseInfo 2,随后
///    跟 StartData+EndData);mock 回 StartData → N×Data → EndData(小
///    数据集整只塞 EndData,与真机小数据集行为同款)→ OperationResponse。
///    事件通道收 ProbeRequest(心跳)回 ProbeResponse;拍摄事件由 mock
///    主动推 Event 包(0x4002/0x400D)。
///
/// 单连接语义(真机同款):命令通道在位时后来的 InitCommandRequest 回
/// InitFail(0x1)(槽位被占);任一通道断开 = 整会话亡,双侧收线、
/// 设备状态复位(重连即新会话)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:z_pill/core/ptpip/channels.dart';
import 'package:z_pill/core/ptpip/codec.dart';
import 'package:z_pill/core/ptpip/packet.dart';
import 'package:z_pill/core/utils/byte_reader.dart';

import 'mock_nikon_device.dart';

void _noopLog(String line) {}

enum _ConnRole { unknown, command, event }

final class _Conn {
  _Conn(this.socket);
  final Socket socket;
  final PtpIpFrameSplitter splitter = PtpIpFrameSplitter();
  _ConnRole role = _ConnRole.unknown;
  StreamSubscription<Uint8List>? sub;

  /// 数据出相暂存:DataPhaseInfo==2 的 op 先记账,EndData 到齐再执行。
  final Map<int, _DataOutGather> dataOut = {};
}

final class _DataOutGather {
  _DataOutGather(this.opcode, this.params);
  final int opcode;
  final List<int> params;
  final BytesBuilder bytes = BytesBuilder(copy: false);
}

/// PTP-IP 假相机服务(库形态;CLI 见 `bin/mock_camera.dart`)。
///
/// 零 Flutter 依赖,同一实现被 `test/e2e` 回环复用。留账:
/// - 真机 Zf 的拍摄事件可能只走 GetEventEx(0x941C)轮询队列而非事件
///   socket 推送(OpenZCine/libgphoto2 口径),本 mock 恒走事件 socket;
/// - 取消(Cancel 包)的数据相中断模拟未做 —— mock 的数据相在同轮
///   事件循环内同步发完,无「发一半被取消」窗口;
/// - USB 侧(PTP/USB 容器)不在本文件范围。
final class MockPtpIpCamera {
  MockPtpIpCamera({
    required this.device,
    this.host = '127.0.0.1',
    this.requestedPort = 0,
    this.initFailReason,
    this.dataChunkSize = 64 * 1024,
    this.connectionNumber = 1,
    this.cameraName = 'NIKON ZF',
    void Function(String line)? log,
  }) : _log = log ?? _noopLog;

  /// 设备人设(操作分发表 + 对象表 + 会话状态)。
  final MockNikonDevice device;

  final String host;

  /// 监听口;0 = 随机(e2e 用)。CLI 默认 15740(真机同款口)。
  final int requestedPort;

  /// 非空 = 对 InitCommandRequest 一律回 InitFail(此值)
  /// —— e2e 复现「槽位被 SnapBridge 占用」的拒绝路径。
  final int? initFailReason;

  /// 数据入相分块:超过一块的载荷拆 N×Data + EndData(尾块),
  /// 压出客户端的帧重组路径;缺省 64KB。
  final int dataChunkSize;

  /// InitCommandResponse 回给客户端的连接号(InitEventRequest 须带同值)。
  final int connectionNumber;

  /// 相机名(InitCommandResponse / DeviceInfo 展示用)。
  final String cameraName;

  /// 相机 GUID:ASCII 'ZPill-MOCK01' 恰 16 字节,一眼可辨。
  final Uint8List cameraGuid =
      Uint8List.fromList('ZPill-MOCK01'.codeUnits);

  final void Function(String line) _log;

  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSub;
  _Conn? _command;
  _Conn? _event;

  /// 握手观测(e2e 断言方言字节):InitCommandRequest 的 GUID/主机名/版本。
  Uint8List? lastClientGuid;
  String? lastClientHostname;
  int? lastClientProtocolVersion;

  /// ProbeRequest 收到的次数(event 通道心跳 + command 通道杂音合计)。
  int probeRequestCount = 0;

  /// 事件通道就绪前暂存的事件(正常时序用不上,防御性)。
  final List<MockPtpEvent> _eventBacklog = [];

  int? _boundPort;

  /// 实际监听口(start 后有效)。
  int get port {
    final p = _boundPort ?? _server?.port;
    if (p == null) {
      throw StateError('尚未 start()');
    }
    return p;
  }

  /// 单连接槽位是否被占(命令通道在位)。
  bool get isSlotOccupied => _command != null;

  /// 绑定并开始监听(幂等:重复调 no-op)。
  Future<void> start() async {
    if (_server != null) return;
    final address = InternetAddress.tryParse(host) ?? InternetAddress.loopbackIPv4;
    final server = await ServerSocket.bind(address, requestedPort);
    _server = server;
    _boundPort = server.port;
    _serverSub = server.listen(_onConnection,
        onError: (Object e) => _log('listen 错误: $e'),
        onDone: () => _log('server 关闭'));
    _log('监听 $host:${server.port}'
        '(相机名 $cameraName,${device.objects.length} 个对象)');
  }

  /// 收线:关 server、双侧连接、复位设备状态。幂等。
  Future<void> stop() async {
    await _serverSub?.cancel();
    _serverSub = null;
    final server = _server;
    _server = null;
    await server?.close();
    _teardownSession('stop()');
  }

  // ── 连接与握手 ──────────────────────────────────────────────

  void _onConnection(Socket socket) {
    final conn = _Conn(socket);
    _log('TCP 接入 ${socket.remoteAddress.address}:${socket.remotePort}');
    conn.sub = socket.listen(
      (chunk) {
        try {
          for (final frame in conn.splitter.feed(chunk)) {
            _handleFrame(conn, frame);
          }
        } on FormatException catch (e) {
          // 帧错位/巨值长度(大端包会以畸形长度现身):真机是静默丢弃,
          // mock 收线并留日志,便于定位。
          _log('帧解析失败,收线 ${socket.remotePort}: $e');
          _destroyConn(conn);
        }
      },
      onError: (Object e) {
        _log('连接错误 ${socket.remotePort}: $e');
        _onConnClosed(conn);
      },
      onDone: () => _onConnClosed(conn),
      cancelOnError: true,
    );
  }

  void _handleFrame(_Conn conn, PtpIpFrame frame) {
    switch (conn.role) {
      case _ConnRole.unknown:
        _handleFirstFrame(conn, frame);
      case _ConnRole.command:
        _handleCommandFrame(conn, frame);
      case _ConnRole.event:
        _handleEventFrame(conn, frame);
    }
  }

  /// 角色未定连接的首包:1 = InitCommandRequest、3 = InitEventRequest,
  /// 其余一律收线(真机对乱序 Init 亦不接)。
  void _handleFirstFrame(_Conn conn, PtpIpFrame frame) {
    switch (frame.type) {
      case PtpIpPacketType.initCommandRequest:
        _handleInitCommandRequest(conn, frame);
      case PtpIpPacketType.initEventRequest:
        _handleInitEventRequest(conn, frame);
      default:
        _log('首包非 Init(0x${frame.type.toRadixString(16)}),收线');
        _destroyConn(conn);
    }
  }

  void _handleInitCommandRequest(_Conn conn, PtpIpFrame frame) {
    // 单连接槽位:已有客户端在位 → InitFail(0x1)(真机「被 SnapBridge
    // 占用」同码,2026-10-04 真机实证)。
    if (_command != null) {
      _log('InitCommandRequest 被拒:槽位已被占用');
      _send(conn, const InitFailPacket(reason: 1));
      _destroyConn(conn);
      return;
    }
    if (initFailReason != null) {
      _log('InitCommandRequest 被拒:--init-fail $initFailReason');
      _send(conn, InitFailPacket(reason: initFailReason!));
      _destroyConn(conn);
      return;
    }
    // 尼康方言布局:GUID(16B)+ NUL 终止 UTF-16LE 主机名(无长度前缀)
    // + u32 版本。规范布局(u32 长度前缀)在这里会解出乱码主机名 ——
    // e2e 断言 lastClientHostname 即可钉住方言。
    final r = ByteReader(frame.body);
    final guid = r.raw(16);
    final hostname = r.utf16z();
    final version = r.eof ? null : r.u32();
    lastClientGuid = guid;
    lastClientHostname = hostname;
    lastClientProtocolVersion = version;
    conn.role = _ConnRole.command;
    _command = conn;
    _log('InitCommandRequest:主机名 "$hostname" '
        'GUID ${guid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} '
        '版本 0x${(version ?? 0).toRadixString(16)}');
    _send(
      conn,
      InitCommandResponsePacket(
        connectionNumber: connectionNumber,
        cameraGuid: cameraGuid,
        cameraName: cameraName,
        protocolVersion: kPtpIpProtocolVersion,
      ),
    );
  }

  void _handleInitEventRequest(_Conn conn, PtpIpFrame frame) {
    if (_event != null) {
      _log('InitEventRequest 被拒:事件通道已被占用');
      _send(conn, const InitFailPacket(reason: 1));
      _destroyConn(conn);
      return;
    }
    final command = _command;
    if (command == null) {
      _log('InitEventRequest 被拒:命令通道未建立');
      _send(conn, const InitFailPacket(reason: 1));
      _destroyConn(conn);
      return;
    }
    final r = ByteReader(frame.body);
    final requested = r.eof ? 0 : r.u32();
    if (requested != connectionNumber) {
      _log('InitEventRequest 被拒:连接号不符($requested != $connectionNumber)');
      _send(conn, const InitFailPacket(reason: 1));
      _destroyConn(conn);
      return;
    }
    conn.role = _ConnRole.event;
    _event = conn;
    _log('InitEventRequest:连接号 $requested,事件通道就绪');
    _send(conn, const InitEventResponsePacket());
    // 就绪前积压的事件(正常时序无)一次性放行。
    final backlog = List.of(_eventBacklog);
    _eventBacklog.clear();
    for (final ev in backlog) {
      _pushEvent(ev);
    }
  }

  // ── 命令通道:事务 ──────────────────────────────────────────

  final PtpIpCodecImpl _codec = PtpIpCodecImpl();

  void _handleCommandFrame(_Conn conn, PtpIpFrame frame) {
    final PtpIpPacket packet;
    try {
      packet = _codec.decode(frame);
    } on Exception catch (e) {
      _log('命令通道包解析失败: $e');
      _destroyConn(conn);
      return;
    }
    switch (packet) {
      case OperationRequestPacket(:final dataPhaseInfo, :final opcode,
            :final transactionId, :final params):
        if (dataPhaseInfo == 2) {
          // 数据出相:等 StartData/EndData 到齐再执行(客户端一发一收,
          // 帧紧随请求到达)。
          conn.dataOut[transactionId] = _DataOutGather(opcode, params);
          return;
        }
        _runTransaction(conn, transactionId, opcode, params, null);
      case StartDataPacket(:final transactionId):
        final gather = conn.dataOut[transactionId];
        if (gather == null) {
          _log('无数据出相事务却收到 StartData(tid=$transactionId)');
        }
      case DataPacket(:final transactionId, :final payload):
        conn.dataOut[transactionId]?.bytes.add(payload);
      case EndDataPacket(:final transactionId, :final payload):
        final gather = conn.dataOut.remove(transactionId);
        if (gather == null) {
          _log('无数据出相事务却收到 EndData(tid=$transactionId)');
          return;
        }
        gather.bytes.add(payload);
        _runTransaction(
            conn, transactionId, gather.opcode, gather.params, gather.bytes.takeBytes());
      case CancelPacket(:final transactionId):
        // 数据出相取消:按取消收口回 OK(会话不失步)。数据入相取消:
        // 本 mock 的数据相同步发完,无在途窗口,仅记账(见类注留账)。
        final gather = conn.dataOut.remove(transactionId);
        if (gather != null) {
          _log('Cancel(tid=$transactionId):丢弃数据出相,回 OK');
          _send(conn, OperationResponsePacket(
                responseCode: 0x2001,
                transactionId: transactionId,
              ));
        } else {
          _log('Cancel(tid=$transactionId):无在途数据出相,忽略');
        }
      case ProbeRequestPacket():
        probeRequestCount++;
        _send(conn, const ProbeResponsePacket());
      default:
        _log('命令通道收到 0x${frame.type.toRadixString(16)} 包,忽略');
    }
  }

  void _runTransaction(_Conn conn, int tid, int opcode, List<int> params,
      Uint8List? dataOut) {
    final reply = device.execute(opcode, params, dataOut);
    final data = reply.data;
    if (data != null) {
      _sendDataPhase(conn, tid, data);
    }
    _send(conn, OperationResponsePacket(
          responseCode: reply.code,
          transactionId: tid,
          params: reply.params,
        ));
    final events = reply.events;
    if (events != null) {
      for (final ev in events) {
        _pushEvent(ev);
      }
    }
  }

  /// 数据入相:StartData(u64 声明)→ N×Data → EndData(尾块)。
  /// 一块以内整只塞 EndData(真机小数据集同款,零 Data 包)。
  void _sendDataPhase(_Conn conn, int tid, Uint8List data) {
    _send(conn, StartDataPacket(transactionId: tid, totalLength: data.length));
    if (data.isEmpty) {
      _send(conn, EndDataPacket(transactionId: tid, payload: Uint8List(0)));
      return;
    }
    final chunkCount = (data.length + dataChunkSize - 1) ~/ dataChunkSize;
    for (var i = 0; i < chunkCount; i++) {
      final start = i * dataChunkSize;
      final end = (i + 1 == chunkCount) ? data.length : start + dataChunkSize;
      final slice = Uint8List.sublistView(data, start, end);
      if (i + 1 == chunkCount) {
        _send(conn, EndDataPacket(transactionId: tid, payload: slice));
      } else {
        _send(conn, DataPacket(transactionId: tid, payload: slice));
      }
    }
  }

  // ── 事件通道:心跳回声 + 事件推送 ──────────────────────────

  void _handleEventFrame(_Conn conn, PtpIpFrame frame) {
    switch (frame.type) {
      case PtpIpPacketType.probeRequest:
        // 心跳回声(生产装配 enableKeepalive: true,15s 一拍)。
        probeRequestCount++;
        _send(conn, const ProbeResponsePacket());
      case PtpIpPacketType.event:
        _log('事件通道收到客户端 Event 包(非常规),忽略');
      default:
        _log('事件通道收到 0x${frame.type.toRadixString(16)} 包,忽略');
    }
  }

  void _pushEvent(MockPtpEvent ev) {
    final event = _event;
    if (event == null) {
      _eventBacklog.add(ev);
      return;
    }
    _log('推事件 0x${ev.code.toRadixString(16)} params=${ev.params}');
    _send(event, EventPacket(
          eventCode: ev.code,
          transactionId: 0,
          params: ev.params,
        ));
  }

  // ── 收线 ────────────────────────────────────────────────────

  /// 任一通道断开 = 整会话亡(真机单连接语义):双侧收线、设备状态复位。
  void _onConnClosed(_Conn conn) {
    if (conn.role == _ConnRole.unknown) {
      _log('未握手连接关闭');
      return;
    }
    if (_command != conn && _event != conn) {
      return; // 已被 _teardownSession 收过线
    }
    _teardownSession('通道断开');
  }

  void _teardownSession(String reason) {
    final command = _command;
    final event = _event;
    _command = null;
    _event = null;
    _eventBacklog.clear();
    if (command != null || event != null) {
      _log('会话收线($reason):设备状态复位');
    }
    device.sessionOpen = false;
    device.cameraMode = 0;
    device.applicationMode = 0;
    device.recording = false;
    _destroyConn(command);
    _destroyConn(event);
  }

  void _destroyConn(_Conn? conn) {
    if (conn == null) return;
    unawaited(conn.sub?.cancel() ?? Future<void>.value());
    conn.sub = null;
    conn.socket.destroy();
  }

  void _send(_Conn conn, PtpIpPacket packet) {
    final bytes = _codec.encode(packet);
    conn.socket.add(bytes);
  }
}

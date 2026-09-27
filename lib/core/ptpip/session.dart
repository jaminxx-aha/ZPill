/// PTP-IP 会话:双 TCP 通道 + 事务状态机(TODO.md §一)。
///
/// 职责边界:
/// - 本层:协议事务(transactionId 分配、StartData/Data/EndData 循环、
///   响应配对、错误码上报)
/// - camera 层:连接状态机、心跳、WiFi 启发式
/// - browser/transfer 层:对象组合与业务队列
library;

import 'dart:typed_data';

import 'object_info.dart';
import 'operation_codes.dart';

enum PtpIpSessionState {
  disconnected,
  connecting,
  /// command + event 双通道均完成 Init 握手。
  channelsOpen,
  /// OpenSession(0x1002) 成功,可执行对象操作。
  sessionOpen,
}

abstract interface class PtpIpSession {
  PtpIpSessionState get state;
  Stream<PtpIpSessionState> get states;

  /// 建立双通道:command 与 event 各开一条连接,均连 [port](默认 15740);
  /// InitEventRequest 必须发在独立的 event socket 上(TODO.md §一)。
  Future<void> connect(String host, {int port = 15740});

  /// OpenSession(0x1002):任何对象操作前必须调用。
  Future<void> openSession();

  /// 对象 handle 列表;handle 只能来自本响应(TODO 注意事项 2)。
  Future<List<int>> getObjectHandles({
    int storage = GetObjectHandlesParams.storageAll,
    int parent = GetObjectHandlesParams.parentRoot,
  });

  Future<PtpObjectInfo> getObjectInfo(int handle);

  /// 流式取对象:内部重组 StartData/Data/EndData 循环,按块 yield,
  /// **禁止整文件驻留内存**(TODO.md §四)。
  Stream<Uint8List> getObject(int handle);

  /// GetThumb(0x100A):P2 缩略图,同样流式。
  Stream<Uint8List> getThumb(int handle);

  Future<void> close();
}

/// TODO(P0): 实现 —— 持有 command/event 两个 [PtpIpChannel]、
/// [PtpIpCodec]、transactionId 计数器与未决事务表;
/// 事件通道的 Event 包(ObjectAdded 等)经广播 Stream 上抛给 camera 层。
final class PtpIpSessionImpl implements PtpIpSession {
  @override
  PtpIpSessionState get state => throw UnimplementedError();

  @override
  Stream<PtpIpSessionState> get states => throw UnimplementedError();

  @override
  Future<void> connect(String host, {int port = 15740}) => throw UnimplementedError();

  @override
  Future<void> openSession() => throw UnimplementedError();

  @override
  Future<List<int>> getObjectHandles({
    int storage = GetObjectHandlesParams.storageAll,
    int parent = GetObjectHandlesParams.parentRoot,
  }) => throw UnimplementedError();

  @override
  Future<PtpObjectInfo> getObjectInfo(int handle) => throw UnimplementedError();

  @override
  Stream<Uint8List> getObject(int handle) => throw UnimplementedError();

  @override
  Stream<Uint8List> getThumb(int handle) => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();
}

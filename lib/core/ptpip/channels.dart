/// PTP-IP 传输通道:command 与 event 各一条 TCP 连接,均连 15740。
///
/// core 只依赖本接口 —— 状态机/会话逻辑的单测注入 Fake 即可覆盖,
/// 不需要真 socket(TODO.md §一「双 TCP 通道」)。
library;

import 'packet.dart';

abstract interface class PtpIpChannel {
  bool get isOpen;

  /// 已按包头(类型 u32 + 长度 u32)切好帧的输入流。
  Stream<PtpIpFrame> get frames;

  Future<void> connect(String host, int port);

  Future<void> sendFrame(PtpIpFrame frame);

  /// 断开清理:关 socket、复位状态(TODO.md §二)。
  Future<void> close();
}

/// 基于 dart:io Socket 的默认实现。
///
/// TODO(P1): 帧切分 —— 读满 8 字节头 → 按(长度-8)读满 body;
/// 半包/粘包必须处理,禁止假设一读一包。
final class TcpPtpIpChannel implements PtpIpChannel {
  @override
  bool get isOpen => throw UnimplementedError();

  @override
  Stream<PtpIpFrame> get frames => throw UnimplementedError();

  @override
  Future<void> connect(String host, int port) => throw UnimplementedError();

  @override
  Future<void> sendFrame(PtpIpFrame frame) => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();
}

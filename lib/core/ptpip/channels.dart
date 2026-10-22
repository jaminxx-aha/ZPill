/// PTP-IP 传输通道:command 与 event 各一条 TCP 连接,均连 15740。
///
/// core 只依赖 [PtpIpChannel] 接口 —— 状态机/会话逻辑的单测注入 Fake 即可
/// 覆盖,不需要真 socket。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'packet.dart';

/// 单帧长度上限(含 8B 包头)。相机侧分块 ≤8MB(Camera_Bridge 自适应
/// chunk 上限),16MB 整只下载存在;32MiB 为 2× 余量。
/// 超限几乎必然是流错位 —— 拒绝预分配,直接报错毒化链路。
const int kMaxPtpIpFrameLength = 32 * 1024 * 1024;

abstract interface class PtpIpChannel {
  bool get isOpen;

  /// 已按包头(长度 u32 在前 + 类型 u32)切好帧的输入流(单订阅)。
  Stream<PtpIpFrame> get frames;

  Future<void> connect(String host, int port);

  Future<void> sendFrame(PtpIpFrame frame);

  /// 断开清理:关 socket、复位状态;幂等。
  Future<void> close();
}

/// 字节流 → 帧的纯切分器:半包暂存、粘包拆分、逐字节喂入皆可。
///
/// 纯逻辑零 IO,单测即覆盖全部边界;[TcpPtpIpChannel] 内部使用。
/// 帧错误(长度 < 8 / 超上限)抛 [FormatException] —— 调用方据此毒化
/// 链路(晚到字节不得污染下一事务)。
///
/// 返回帧的 body 是**视图**:整帧随块到的常态直接切在来块上(零拷贝,
/// 取景帧流的常客),半包拼接才落内部缓冲;两类缓冲后续 feed 都不会
/// 使其失效(只读拼接,不复用来块内存),但调用方不得原地修改来块。
final class PtpIpFrameSplitter {
  Uint8List _pending = Uint8List(0);

  /// 喂入任意大小的字节块,返回其中完整的帧(可能为空)。
  List<PtpIpFrame> feed(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const [];
    }
    if (_pending.isEmpty) {
      // 常态:直接在来块上切,帧为来块视图(原路每轮把来块并进新
      // 缓冲 = 每帧一遍整帧拷贝喂 GC)。
      final (frames, off) = _parse(bytes, 0);
      if (off < bytes.length) {
        _pending = Uint8List.sublistView(bytes, off); // 半包尾巴
      }
      return frames;
    }
    final combined = Uint8List(_pending.length + bytes.length);
    combined.setAll(0, _pending);
    combined.setAll(_pending.length, bytes);
    final (frames, off) = _parse(combined, 0);
    _pending = Uint8List.sublistView(combined, off);
    return frames;
  }

  /// 自 [start] 起切分完整帧;返回(帧列表,消费截止偏移)。
  static (List<PtpIpFrame>, int) _parse(Uint8List buf, int start) {
    final frames = <PtpIpFrame>[];
    var off = start;
    while (buf.length - off >= kPtpIpHeaderLength) {
      final header = ByteData.sublistView(buf, off, off + kPtpIpHeaderLength);
      final length = header.getUint32(0, Endian.little);
      if (length < kPtpIpHeaderLength) {
        throw FormatException('PTP-IP 帧长度 $length < 8(流错位?)');
      }
      if (length > kMaxPtpIpFrameLength) {
        // 巨值保护:先校验再分配,拒绝按乱序长度预分配大缓冲。
        throw FormatException('PTP-IP 帧长度 $length 超上限(流错位?)');
      }
      if (buf.length - off < length) {
        break; // 半包,留待下一轮
      }
      final type = header.getUint32(4, Endian.little);
      frames.add(PtpIpFrame(
        type: type,
        body: Uint8List.sublistView(
            buf, off + kPtpIpHeaderLength, off + length),
      ));
      off += length;
    }
    return (frames, off);
  }
}

/// 基于 dart:io Socket 的默认实现(薄壳:连接、帧切分、收发、关断)。
///
/// 连接超时 3s —— IP 错/热点没开/相机停有线界面时 Darwin SYN 重试
/// ~75s,会把 UI 拖进「无限 connecting」;超时抛 [SocketException],
/// 由上层转成用户指引。健康局域网相机 TCP 握手远低于 1s(含首连 ARP、
/// Wi-Fi 省电唤醒),3s 已是 30 倍余量,只砍死地址(2026-10-08:原 5s
/// 是「上次」连死 IP 要干等 5s 才报「连不上」的主因)。
final class TcpPtpIpChannel implements PtpIpChannel {
  TcpPtpIpChannel({this.connectTimeout = const Duration(seconds: 3)});

  final Duration connectTimeout;
  Socket? _socket;
  bool _closed = false;
  final _frames = StreamController<PtpIpFrame>();
  final _splitter = PtpIpFrameSplitter();

  @override
  bool get isOpen => !_closed && _socket != null;

  @override
  Stream<PtpIpFrame> get frames => _frames.stream;

  @override
  Future<void> connect(String host, int port) async {
    if (_closed) {
      throw StateError('channel 已关闭');
    }
    if (_socket != null) {
      throw StateError('channel 已连接');
    }
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    // Nagle 必关:PTP-IP 每笔事务是「命令→数据起→数据→收尾→应答」一串
    // 小包逐个往返,Nagle 会把小包按住等前一包的 ACK,对端延迟 ACK 一等
    // 几十~几百 ms —— Wi-Fi 局域网纯 RTT 才几 ms,「每事务几百 ms」的
    // 主成分在此(libgphoto2 ptpip 同款先例)。大块数据传输不受影响。
    socket.setOption(SocketOption.tcpNoDelay, true);
    if (_closed) {
      // close() 与连接完成竞态:立刻回收刚建立的 socket
      socket.destroy();
      return;
    }
    _socket = socket;
    socket.listen(
      (chunk) {
        for (final frame in _splitter.feed(chunk)) {
          if (!_frames.isClosed) {
            _frames.add(frame);
          }
        }
      },
      onError: (Object e) {
        if (!_frames.isClosed) {
          _frames.addError(e);
        }
      },
      onDone: () {
        if (!_frames.isClosed) {
          _frames.close();
        }
      },
      cancelOnError: false,
    );
  }

  @override
  Future<void> sendFrame(PtpIpFrame frame) {
    final socket = _socket;
    if (socket == null || _closed) {
      throw StateError('channel 未连接');
    }
    final out = BytesBuilder(copy: false)
      ..add(_header(frame.type, frame.body.length));
    if (frame.body.isNotEmpty) {
      out.add(frame.body);
    }
    socket.add(out.takeBytes());
    return Future.value();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _socket?.destroy();
    _socket = null;
    if (!_frames.isClosed) {
      if (_frames.hasListener) {
        await _frames.close();
      } else {
        // 单订阅流无人监听时,close() 的 done future 永不完成 —— 不能 await
        unawaited(_frames.close());
      }
    }
  }

  /// 包头:长度(u32,含 8B)在前 + 类型(u32)在后,均小端。
  static Uint8List _header(int type, int bodyLength) {
    final h = Uint8List(kPtpIpHeaderLength);
    final bd = ByteData.sublistView(h);
    bd.setUint32(0, bodyLength + kPtpIpHeaderLength, Endian.little);
    bd.setUint32(4, type, Endian.little);
    return h;
  }
}

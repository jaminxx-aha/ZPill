/// PTP/USB 传输层(ISO 15740 / USB Still Image)。
///
/// 在 [UsbBytePipe](native 侧 bulk/interrupt 端点收口的最小字节管道,
/// platform/usb/usb_host.dart 的 UsbHostChannel 实现之)之上实现
/// [PtpTransport]:
/// - 命令/数据出相位 → bulk OUT;
/// - 数据入/响应相位 → bulk IN,**容器帧在本层组**:读 12 字节头、
///   按 u32 长度补齐;大数据容器(GetObject 的 25MB NEF 是单个容器!)
///   按 [kUsbStreamChunkBytes] 分块经 `onData` 流出,不整体驻留内存;
///   相位内异常中止 = 排空([UsbBytePipe.drainIn])后再抛,残余字节
///   不错位下一事务(nico 三件套之一;ZLP/清 halt 重试在 native);
/// - 事件 → interrupt IN(native 已组好完整事件容器)→ [decodeUsbEvent]。
///
/// 事务相位顺序(USB STI):命令 → [数据出] → [数据入] → 响应;
/// 相机出错时无数据入、直接收响应容器(响应码非 OK)。
///
/// 2026-09-27 事务模型对齐 tools/usb_probe 真机验证过的 xact() 流程。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ptp/ptp_transport.dart';
import '../utils/byte_reader.dart';
import 'containers.dart';

/// core 层可见的最小 USB 字节管道。
///
/// platform 层的 UsbHostChannel 实现本接口,并把设备生命周期方法
/// (listCameras/open/close)叠加其上 —— 本层不感知设备概念。
abstract interface class UsbBytePipe {
  /// bulk OUT:写整段字节(native 内部按平台上限分块循环)。
  Future<void> bulkOut(Uint8List bytes);

  /// bulk IN:单次读,返回至多 [maxLen] 字节(短读合法;native 内部可
  /// 按平台上限分块组装 —— 一次通道调用读满 maxLen,相机突发结束即返,
  /// 不为凑满而无限等待)。窗口内一个字节都没到则抛
  /// [TimeoutException]。STALL 的 CLEAR_HALT 重试在 native 内部消化。
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs});

  /// 中止后排空 bulk IN:事务异常收场后吸干残余字节(相机还在吐的
  /// 数据相位尾巴 + native 超读暂存),下一事务不从错位字节开始。
  /// native 有界(静默窗 + 轮数上限);无冲刷能力的实现(iOS 未实现
  /// 该通道方法)为 no-op 或抛错,调用方须 best-effort 静默。
  Future<void> drainIn();

  /// interrupt IN 事件流:每条为一个完整事件容器(native 组帧,≤64B)。
  Stream<Uint8List> get interruptEvents;
}

/// 流式回调的单块上限:1MB(通道往返从 64KB 一次降到 1MB 一次;Android
/// AOSP 有限超时 bulkTransfer 上限 16KB,native 内部分块循环组装;ohos
/// 单次 bulkTransfer 大缓冲真机恒 rc=-1、256KB 挂死(2026-10-25 定案),
/// native 按 64KB 起步自适应探大至 ≤128KB 的子块循环组装;iOS 容器缓冲
/// 天然支持任意 maxLen。三端一次通道调用均读满 maxLen,短读/ZLB 即返)。
const int kUsbStreamChunkBytes = 1024 * 1024;

/// 非流式数据容器必须整体驻留内存,单笔上限 64MiB。大对象必须由调用方
/// 提供 onData 走流式路径。
const int kMaxUsbBufferedDataBytes = 64 * 1024 * 1024;

/// bulk 读缺省超时:相机忙(写卡/连拍清缓存)可能拖长,放宽到 15s。
const int kUsbDefaultReadTimeoutMs = 15000;

/// 一次 bulk IN 收到的容器(未解码为公开容器类,保留内部表示)。
final class _Incoming {
  const _Incoming({
    required this.type,
    required this.code,
    required this.transactionId,
    this.payload,
    this.params = const [],
  });

  final int type; // UsbContainerType.data / response
  final int code;
  final int transactionId;

  /// DATA 容器且未走流式时的完整负载(小容器:DeviceInfo/ObjectHandles)。
  final Uint8List? payload;

  /// RESPONSE 容器的参数区(u32 列表)。
  final List<int> params;
}

/// PTP/USB 传输层实现:事务 ID 分配、容器组帧、流式数据入、事件解码。
///
/// 线程模型:一次只允许一个在途 execute()(相机侧事务严格串行;
/// 并发由上层会话/队列保证,本层不设锁)。
final class UsbPtpTransport implements PtpTransport {
  UsbPtpTransport(
      {required this.pipe, this.timeoutMs = kUsbDefaultReadTimeoutMs});

  final UsbBytePipe pipe;
  final int timeoutMs;

  int _txid = 0;
  bool _closed = false;

  @override
  Stream<PtpEvent> get events => pipe.interruptEvents.transform(
        StreamTransformer.fromHandlers(
          handleData: (bytes, sink) {
            try {
              final c = decodeUsbEvent(bytes);
              sink.add(PtpEvent(
                code: c.eventCode,
                transactionId: c.transactionId,
                params: c.params,
              ));
            } on FormatException {
              // 单个畸形事件丢弃,不断流(未知事件码不经过这里,
              // 走到这里说明字节布局坏了 —— 只能弃掉这一条)
            }
          },
        ),
      );

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    if (_closed) {
      throw StateError('UsbPtpTransport 已关闭');
    }
    final txid = _txid++;

    // 相位 1:命令容器
    await pipe.bulkOut(encodeUsbCommand(
      opcode: request.opcode,
      transactionId: txid,
      params: request.params,
    ));
    // 相位 2(可选):数据出容器
    if (request.dataOut != null) {
      await pipe.bulkOut(encodeUsbData(
        opcode: request.opcode,
        transactionId: txid,
        payload: request.dataOut!,
      ));
    }
    // 相位 3:数据入(可选)+ 响应。错误序:相机直接回响应、无数据入。
    // 本相位任何异常 = 事务中止:残余字节(相机还在吐的数据相位尾巴、
    // native 超读暂存)会错位下一事务 —— best-effort 排空后再抛
    // (nico PtpSession 中止收尾同款;排空自身失败不掩盖原始异常)。
    try {
      final first = await _readContainer(txid, onData: onData);
      if (first.type == UsbContainerType.data) {
        final resp = await _readContainer(txid);
        if (resp.type != UsbContainerType.response) {
          throw FormatException('数据容器之后应为响应容器,收到 type=${resp.type}');
        }
        return PtpResult(
          responseCode: resp.code,
          params: resp.params,
          data: onData != null ? null : first.payload,
        );
      }
      if (first.type != UsbContainerType.response) {
        throw FormatException('期待响应容器,收到 type=${first.type}');
      }
      return PtpResult(responseCode: first.code, params: first.params);
    } on Exception {
      await _drainAfterAbort();
      rethrow;
    }
  }

  /// 事务中止后的 best-effort 排空:吸干 bulk IN 残余,下一事务不从
  /// 错位字节开始。排空自身失败(平台未实现 → MissingPluginException、
  /// 链路已死)一律静默 —— 原始异常才是真相;残余未吸尽的极端由
  /// 上层断链重连兜底。
  Future<void> _drainAfterAbort() async {
    try {
      await pipe.drainIn();
    } on Exception {
      // best-effort:见上
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    // 设备生命周期(open/close 端点、release 接口)归 UsbHostChannel,
    // 由 camera 连接层管理;本层只拒绝后续事务。
  }

  // ── 容器组帧(短读跨包拼接在此消化) ─────────────────────────────

  /// 读一个容器。DATA 容器在 [onData] 提供时按块流出(payload 为 null),
  /// 否则整体收下(仅用于小容器 —— 上层约定大数据必须走 onData)。
  /// [expectedTxid] 为本事务 ID:bulk IN 上容器 txid 必须与命令一致,
  /// 不符即字节流错位,立即报错(异步事件 txid=0xFFFFFFFF 只走 interrupt)。
  Future<_Incoming> _readContainer(int expectedTxid,
      {void Function(Uint8List chunk)? onData}) async {
    final head = await _take(kUsbContainerHeaderLength);
    final r = ByteReader(head);
    final length = r.u32();
    final type = r.u16();
    final code = r.u16();
    final txid = r.u32();
    if (txid != expectedTxid) {
      // 头 12B 十六进制随报错浮出:txid 位是「旧容器头」还是「数据相位
      // 负载被当头解析」(如 XMP 文本的 '0\0\0\0' → txid=48)一眼可判,
      // 真机日志不再靠猜(2026-10-26 ohos 连接自锁死排查的教训)。
      final hex =
          head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      throw FormatException('容器 txid=$txid 与事务 $expectedTxid 不符(流错位?头:$hex)');
    }
    if (length < kUsbContainerHeaderLength) {
      throw FormatException('容器长度字段 $length 小于 12 字节头');
    }
    final bodyLen = length - kUsbContainerHeaderLength;

    switch (type) {
      case UsbContainerType.response:
        if (bodyLen % 4 != 0) {
          throw FormatException('响应参数区 $bodyLen 字节,不是 4 的倍数');
        }
        if (bodyLen > 5 * 4) {
          throw FormatException('响应参数 $bodyLen 字节,超过 5 个 u32');
        }
        final body = await _take(bodyLen);
        final br = ByteReader(body);
        return _Incoming(
          type: type,
          code: code,
          transactionId: txid,
          params: [for (var i = 0; i < bodyLen ~/ 4; i++) br.u32()],
        );

      case UsbContainerType.data:
        if (onData != null) {
          var remaining = bodyLen;
          while (remaining > 0) {
            final chunk =
                await _takeUpTo(math.min(remaining, kUsbStreamChunkBytes));
            remaining -= chunk.length;
            onData(chunk);
          }
          return _Incoming(type: type, code: code, transactionId: txid);
        }
        if (bodyLen > kMaxUsbBufferedDataBytes) {
          throw FormatException(
              'USB 非流式数据 $bodyLen B 超过 $kMaxUsbBufferedDataBytes B 上限');
        }
        final body = await _take(bodyLen);
        return _Incoming(
          type: type,
          code: code,
          transactionId: txid,
          payload: body,
        );

      default:
        // bulk 端点上不应出现命令/事件容器:多为字节流错位,显式报错
        throw FormatException('bulk IN 收到意外容器 type=$type(流错位?)');
    }
  }

  /// 精确读 [n] 字节:bulkRead 契约保证「至多 maxLen、≥1 或超时」,
  /// 故只按缺口循环(不存在超读余量)。
  Future<Uint8List> _take(int n) async {
    if (n == 0) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    while (out.length < n) {
      out.add(await pipe.bulkRead(n - out.length, timeoutMs: timeoutMs));
    }
    return out.toBytes();
  }

  /// 至多读 [maxLen] 字节(单次管道读;可能短读,流式回调容忍)。
  Future<Uint8List> _takeUpTo(int maxLen) async {
    if (maxLen <= 0) {
      throw ArgumentError.value(maxLen, 'maxLen', '必须为正');
    }
    final chunk = await pipe.bulkRead(maxLen, timeoutMs: timeoutMs);
    if (chunk.isEmpty) {
      // 契约上 bulkRead 要么 ≥1 字节要么抛超时;空返回按超时处理
      throw TimeoutException('bulkRead 窗口内未收到数据');
    }
    return chunk;
  }
}

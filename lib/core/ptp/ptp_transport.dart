/// 与链路无关的 PTP 传输层抽象(ISO 15740)。
///
/// 两条链路在此归一,P1 的会话层(openSession / 浏览 / 传输)只面对本接口:
/// - PTP-IP:TCP 封装(core/ptpip,P0 实现中);
/// - PTP/USB:USB Still Image 批量端点(core/ptpusb + platform/usb)。
///
/// 事务 ID 两条链路线上均为 uint32(PTP-IP tid 宽度经 Zf 真机回显验证,
/// 2026-10-04;此前头注记 uint16 系误记,已订正),共享层一律 int。
library;

import 'dart:typed_data';

/// 一次 PTP 操作请求。
final class PtpRequest {
  const PtpRequest({required this.opcode, this.params = const [], this.dataOut});

  /// 操作码,取值见 core/ptp/operation_codes.dart 的 PtpOperationCode。
  final int opcode;

  /// 操作参数(≤5 个 u32)。
  final List<int> params;

  /// 数据出相位(payload 由 initiator 发出,如 SetDevicePropValue);
  /// null 表示无数据出。
  final Uint8List? dataOut;
}

/// 操作结果:响应码 + 响应参数;数据入相位聚合在 [data]。
final class PtpResult {
  const PtpResult({required this.responseCode, this.params = const [], this.data});

  /// 响应码,取值见 core/ptp/operation_codes.dart 的 PtpResponseCode。
  final int responseCode;

  /// 响应参数(绝大多数操作为空)。
  final List<int> params;

  /// 数据入相位(GetObject 等);走流式回调(onData)时为 null。
  final Uint8List? data;
}

/// PTP 异步事件(USB interrupt IN / PTP-IP 事件通道各自解码为此结构)。
final class PtpEvent {
  const PtpEvent({required this.code, required this.transactionId, this.params = const []});

  /// 事件码,取值见 core/ptp/operation_codes.dart 的 PtpEventCode。
  final int code;

  final int transactionId;

  /// 事件参数(如 ObjectAdded 携带的对象 handle)。
  final List<int> params;
}

/// 在途事务被本端主动取消(Cancel-Drain 协议收口)。
///
/// 语义:发起方对在途事务发 PTP/IP Cancel 包(type 11)后,把该事务的
/// 数据相位**吸干**(只记账不交付)、一直读到它的 OperationResponse 才
/// 收场 —— 会话不脱同步,连接照常复用。execute 的 future 以本异常完成
/// = 干净取消,不是链路故障;上层(下载引擎)据此落「已取消」而非
/// 重试/失败。真机表现(相机是否提前掐数据相)待验证,见 transport 注释。
///
/// implements Exception 是硬约束(与 [PtpLinkException] 同款):上层清理
/// 路径全部 `on Exception` catch,StateError/Error 会逃逸卡死 UI。
final class PtpCancelledException implements Exception {
  const PtpCancelledException(this.transactionId);

  /// 被取消的事务号(诊断用)。
  final int transactionId;

  @override
  String toString() => 'PtpCancelledException: 事务 $transactionId 已取消';
}

/// 可选传输层能力:取消当前在途事务(PTP-IP Cancel-Drain)。
///
/// 只有 PTP-IP 实现了(USB 线零改动,不实现本接口 → 调用方按 false
/// 降级);[PtpLinkRouter] 也实现,负责向内层转发。调用方(PtpSession /
/// 下载管线)一律先 `is PtpCancelCapable` 探测,不支持 = 走「等当前
/// 事务自然完成」的旧路径。
abstract interface class PtpCancelCapable {
  /// 请求取消全部在途事务:发 Cancel 包并进入排水(吸干数据相直到该
  /// 事务的 OperationResponse,在途 execute 以 [PtpCancelledException]
  /// 完成)。
  ///
  /// 返回是否有事务**新进入**取消(无在途事务 / 已在排水 / 链路不支持
  /// = false,均为无害 no-op);返回不等排水结束 —— 排水由 dispatcher
  /// 异步收口。链路死亡(发送失败等)按既有断链路径处理。
  Future<bool> cancelInFlight();
}

/// PTP 传输层契约。
abstract interface class PtpTransport {
  /// 执行一次操作:发出命令(及可选数据出相位),收取数据入相位与响应。
  ///
  /// [onData] 提供时,数据入相位按链路分块回调 —— GetObject 大文件
  /// 流式落盘、不整体驻留内存;此时 [PtpResult.data] 为 null。
  Future<PtpResult> execute(PtpRequest request, {void Function(Uint8List chunk)? onData});

  /// 异步事件流(ObjectAdded / DevicePropChanged / CaptureComplete…)。
  Stream<PtpEvent> get events;

  Future<void> close();
}

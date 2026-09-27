/// PTP-IP 链路层专属常量。
///
/// 标准操作码/响应码/事件码是**链路无关**的 PTP 常量,已上移至
/// [core/ptp/operation_codes.dart](../ptp/operation_codes.dart)
/// (PTP/USB 共用);本文件转发导出并保留 PTP-IP 独有的
/// DataPhaseInfo 取值。
library;

export '../ptp/operation_codes.dart';

/// Operation Request 的 DataPhaseInfo 字段取值(PTP-IP 独有字段;
/// USB 容器无此字段,由"是否跟发数据容器"隐式表达)。
///
/// TODO(P0): 三种取值的具体语义以 USB-IF PTP-IP 规范 / libgphoto2
/// ptpip.c 为准,在 tools/ptpip_probe 真机验证时核对后固化文档;
/// 常量只在这一处定义,订正成本一行。
enum PtpDataPhase {
  /// 无数据阶段(纯命令,如 OpenSession)。
  noData(1),

  /// 数据由 initiator 发出(SetDevicePropValue 等)。
  dataOut(2),

  /// 数据由 responder 发出(GetObject 等)。
  dataIn(3);

  const PtpDataPhase(this.value);
  final int value;
}

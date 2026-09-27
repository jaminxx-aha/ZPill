/// PTP 标准操作码(ISO 15740 / PIMA 15740)与参数约定。
///
/// 值以 libgphoto2 ptp.h 与 TODO.md §一 为准;实现期如遇出入,
/// 以真机 GetDeviceInfo 响应为准并在本文件订正。
library;

/// 操作码(opcode 均为 uint16)。
abstract final class PtpOperationCode {
  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002; // 任何操作前必须建立会话
  static const int closeSession = 0x1003;
  static const int getStorageIds = 0x1004;
  static const int getStorageInfo = 0x1005;
  static const int getObjectHandles = 0x1007;
  static const int getObjectInfo = 0x1008;
  static const int getObject = 0x1009;
  static const int getThumb = 0x100A;
  static const int deleteObject = 0x100B;
  static const int initiateCapture = 0x100E; // P3 遥控
  static const int getDevicePropValue = 0x1015; // P3 曝光查询/设置
  static const int setDevicePropValue = 0x1016;
}

/// GetObjectHandles 参数约定(TODO.md §一)。
abstract final class GetObjectHandlesParams {
  /// storage 参数:0xFFFFFFFF 表示全部存储。
  static const int storageAll = 0xFFFFFFFF;

  /// objectFormat 参数:0 表示全部类型(配合浏览器端自行按格式过滤)。
  static const int formatAll = 0x00000000;

  /// parentHandle 参数:0x00000000 = 根目录,0xFFFFFFFF = 全部对象(递归)。
  static const int parentRoot = 0x00000000;
  static const int parentAll = 0xFFFFFFFF;
}

/// PTP 标准响应码(节选;非 OK 需上报 UI,见 TODO.md §一)。
abstract final class PtpResponseCode {
  static const int ok = 0x2001;
  static const int generalError = 0x2002;
  static const int sessionNotOpen = 0x2003;
  static const int invalidTransactionId = 0x2004;
  static const int operationNotSupported = 0x2005;
  static const int parameterNotSupported = 0x2006;

  // TODO(P1): 按需补充(存储不可用 / 对象不存在等),
  // 以 ISO 15740 §13.4 响应码表为准,禁止臆造。
}

/// Operation Request 的 DataPhaseInfo 字段取值。
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

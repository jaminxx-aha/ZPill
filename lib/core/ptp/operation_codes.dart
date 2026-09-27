/// PTP 标准操作码 / 响应码 / 事件码(ISO 15740 / PIMA 15740)。
///
/// 本文件是**链路无关**的常量家:PTP-IP(TCP 封装)与 PTP/USB
/// (USB Still Image 类)共用同一套码值,仅容器封装不同(见
/// core/ptpip/ 与 core/ptpusb/)。
///
/// 值以 libgphoto2 ptp.h 与 TODO.md §一 为准;实现期如遇出入,
/// 以真机 GetDeviceInfo 响应为准并在本文件订正
/// (tools/ptpip_probe 与 tools/usb_probe 都会 dump 该响应)。
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

/// PTP 标准事件码(节选;USB interrupt IN / PTP-IP 事件通道上报)。
///
/// 真机核对方式:tools/usb_probe 会 dump GetDeviceInfo 的
/// eventsSupported 数组 —— 以 Zf 实际上报的码表为准订正。
abstract final class PtpEventCode {
  static const int objectAdded = 0x4001;
  static const int objectRemoved = 0x4002;
  static const int storeAdded = 0x4003;
  static const int storeRemoved = 0x4004;
  static const int devicePropChanged = 0x4006;
  static const int captureComplete = 0x400D;

  // TODO(P1): deviceReset 等按需补充,以 ISO 15740 事件码表为准,禁止臆造。
}

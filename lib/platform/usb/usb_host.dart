/// USB 主机侧通道(TODO.md USB 主线,2026-09-27 定为优先连接方式)。
///
/// 把 native 的 USB 主机原语收口为 MethodChannel 契约;Dart 侧的
/// PTP/USB 容器(core/ptpusb/containers.dart)经由本通道收发字节:
///
/// | channel            | Android(Kotlin)   | iOS(Swift)                | ohos(ArkTS) |
/// |--------------------|--------------------|-----------------------------|---------------|
/// | `nikonbridge/usb`  | UsbManager bulk    | DriverKit dext + UserClient | @ohos.usb     |
///
/// iOS 前提(重要):DriverKit 自 iOS 26 起开放 iPhone(WWDC25),
/// 但**分发 dext 需向 Apple 申请 DriverKit entitlement**
/// (https://developer.apple.com/contact/request/driverkit/,审批周期不可控,
/// 应在开发早期提交;同类竞品「影控台」已获批,相机用途可批)。
/// dext 内实现 PTP 传输所必需的:接口 claim、bulk 双向、interrupt IN、
/// STALL 后的 CLEAR_HALT。
///
/// 铁律(TODO.md 实现注意事项):
/// - bulkIn 的**重组责任在 native**:先读 12 字节头、按长度字段补齐,
///   返回给 Dart 的永远是单个完整容器(见 containers.dart 契约)。
/// - 相机以 STALL 表达"暂无数据/忙"是正常流控,native 须 CLEAR_HALT
///   后重试,不得当作错误上抛。
library;

import 'package:flutter/services.dart';

/// 尼康 USB Vendor ID(USB-IF 分配,三端过滤都用它)。
const int kNikonUsbVendorId = 0x04B0;

/// 枚举出的 USB 设备。
final class UsbDeviceHandle {
  const UsbDeviceHandle({
    required this.vendorId,
    required this.productId,
    required this.identifier,
  });

  final int vendorId;
  final int productId;

  /// 端上唯一标识:Android 的 deviceName / iOS 的 registryID /
  /// ohos 的 busAddr —— 由 native 决定,Dart 只透传。
  final String identifier;
}

abstract interface class UsbHostChannel {
  /// 枚举相机(VID=0x04B0);未插入或无权限返回空表。
  /// Android 需先弹系统授权框,ohos 需 USB 声明权限。
  Future<List<UsbDeviceHandle>> listCameras();

  /// 打开并独占 Still Image 接口(claim bulk IN/OUT + interrupt IN)。
  Future<void> open(UsbDeviceHandle device);

  /// bulk OUT 写(命令容器 / 数据出容器)。
  Future<void> bulkOut(Uint8List bytes);

  /// bulk IN 读一个完整容器(native 负责按长度字段重组)。
  Future<Uint8List> bulkIn();

  /// interrupt IN 事件流,每条为一个完整事件容器字节
  /// (Dart 侧经 decodeUsbEvent 解析)。
  Stream<Uint8List> get interruptEvents;

  Future<void> close();
}

/// 经 `nikonbridge/usb` channel:方法 `listCameras`/`open`/`bulkOut`/
/// `bulkIn`/`close`;事件流走 EventChannel `nikonbridge/usb/events`。
///
/// TODO(P0-usb): native 实现。
/// - iOS:DriverKit dext(C++,IOUSBHostDevice/Interface)+ UserClient IPC,
///   模板对齐 Xcode 26 的 DriverKit USB 模板;entitlement 申请先行。
/// - Android:UsbManager + usb_device_filter.xml(VID 0x04B0),
///   bulkTransfer + UsbRequest(interrupt 轮询用独立线程)。
/// - ohos:usbManager(@ohos.usb)的 connectDevice/bulkTransfer。
final class MethodChannelUsbHost implements UsbHostChannel {
  static const MethodChannel channel = MethodChannel('nikonbridge/usb');

  @override
  Future<List<UsbDeviceHandle>> listCameras() => throw UnimplementedError();

  @override
  Future<void> open(UsbDeviceHandle device) => throw UnimplementedError();

  @override
  Future<void> bulkOut(Uint8List bytes) => throw UnimplementedError();

  @override
  Future<Uint8List> bulkIn() => throw UnimplementedError();

  @override
  Stream<Uint8List> get interruptEvents => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();
}

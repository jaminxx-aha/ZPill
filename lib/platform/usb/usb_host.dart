/// USB 主机侧通道(TODO.md USB 主线,2026-09-27 定为优先连接方式)。
///
/// 把 native 的 USB 主机原语收口为 MethodChannel 契约;本文件实现
/// core/ptpusb/usb_transport.dart 的 [UsbBytePipe](**字节管道**,v2 契约):
///
/// | channel            | Android(Kotlin)   | iOS(Swift)                | ohos(ArkTS) |
/// |--------------------|--------------------|-----------------------------|---------------|
/// | `nikonpill/usb`  | UsbManager bulk    | DriverKit dext + UserClient | @ohos.usb     |
///
/// iOS 前提(重要):DriverKit 自 iOS 26 起开放 iPhone(WWDC25),
/// 但**分发 dext 需向 Apple 申请 DriverKit entitlement**
/// (https://developer.apple.com/contact/request/driverkit/,审批周期不可控,
/// 应在开发早期提交;同类竞品「影控台」已获批,相机用途可批)。
/// dext 内实现 PTP 传输所必需的:接口 claim、bulk 双向、interrupt IN、
/// STALL 后的 CLEAR_HALT。
///
/// 铁律(TODO.md 实现注意事项):
/// - **native 不做容器重组**(v2 契约):bulkRead 是单次读、短读合法,
///   容器头解析/按长度补齐在 Dart 的 UsbPtpTransport;
///   为什么:GetObject 的 25.6MB NEF 是**单个数据容器**,native 整容器
///   重组 = 整文件过通道驻留内存,内存炸弹。
/// - 相机以 STALL 表达"暂无数据/忙"是正常流控,native 须 CLEAR_HALT
///   后重试,不得当作错误上抛。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/ptpusb/usb_transport.dart';

/// 尼康 USB Vendor ID(USB-IF 分配,三端过滤都用它)。
const int kNikonUsbVendorId = 0x04B0;

/// Nikon Zf 的 Product ID(2026-09-27 真机实测;USB 2.0 High-Speed 480Mbps,
/// STI 接口 0:bulk IN 0x81 / bulk OUT 0x02 / interrupt IN 0x83 —— 端点
/// 以描述符枚举为准,勿在 native 写死)。
const int kNikonZfUsbProductId = 0x0453;

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

/// USB 主机通道:UsbBytePipe(收发字节)+ 设备生命周期。
abstract interface class UsbHostChannel implements UsbBytePipe {
  /// 枚举相机(VID=0x04B0);未插入或无权限返回空表。
  /// Android 需先弹系统授权框,ohos 需 requestRight 授权。
  Future<List<UsbDeviceHandle>> listCameras();

  /// 打开并独占 Still Image 接口(claim bulk IN/OUT + interrupt IN)。
  Future<void> open(UsbDeviceHandle device);

  Future<void> close();

  /// 链路断开事件(原因文本,如「相机已断开(USB 连接消失)」)。
  /// 由看门狗装饰器(WatchdogUsbHostChannel)发出;无检测能力的实现
  /// 返回空流。连接层订阅它把 connected 转 failed(P1:相机拔出后
  /// 挂起的 bulk 读不会再有任何回调,只能靠主动检测发现断链)。
  Stream<String> get breakages;
}

/// 经 `nikonpill/usb` channel:方法 `listCameras`/`open`/`bulkOut`/
/// `bulkRead`/`close`;事件流走 EventChannel `nikonpill/usb/events`。
///
/// native 落地状态:
/// - ohos:✅ 真机闭环 —— @ohos.usbManager,ohos/entry/…/usbhost/UsbHostPlugin.ets。
/// - Android:✅ 已落地(编译过,真机待验证)—— UsbManager 应用内
///   requestPermission 授权(无 intent-filter),bulkTransfer + 独立
///   interrupt 轮询线程,android/…/usb/UsbHostPlugin.kt。
/// - iOS:✅ 真机闭环(ImageCaptureCore 免费路线,非 dext)。
final class MethodChannelUsbHost implements UsbHostChannel {
  MethodChannelUsbHost();

  static const MethodChannel channel = MethodChannel('nikonpill/usb');
  static const EventChannel _events = EventChannel('nikonpill/usb/events');

  Stream<Uint8List>? _eventStream;

  @override
  Future<List<UsbDeviceHandle>> listCameras() async {
    final raw = await channel.invokeListMethod<Map<dynamic, dynamic>>('listCameras');
    if (raw == null) return const [];
    return [
      for (final m in raw)
        UsbDeviceHandle(
          vendorId: m['vendorId'] as int,
          productId: m['productId'] as int,
          identifier: m['identifier'] as String,
        ),
    ];
  }

  @override
  Future<void> open(UsbDeviceHandle device) =>
      channel.invokeMethod('open', {'identifier': device.identifier});

  @override
  Future<void> bulkOut(Uint8List bytes) =>
      channel.invokeMethod('bulkOut', {'bytes': bytes});

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async {
    try {
      final bytes = await channel.invokeMethod<Uint8List>('bulkRead', {
        'maxLen': maxLen,
        'timeoutMs': timeoutMs,
      });
      return bytes ?? Uint8List(0);
    } on PlatformException catch (e) {
      // native 的窗口超时映射为 TimeoutException,对齐 UsbBytePipe 契约
      // (UsbPtpTransport 按超时向上传播,不做静默重试)
      if (e.code == 'usb_timeout') {
        throw TimeoutException('bulkRead ${timeoutMs}ms 内未收到数据: ${e.message}');
      }
      rethrow;
    }
  }

  @override
  Stream<Uint8List> get interruptEvents {
    // 惰性订阅:open() 之后 native 才开始转发 interrupt IN;
    // 多次取值共享同一条广播流(EventChannel 语义)。
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((dynamic b) => b as Uint8List);
  }

  @override
  Future<void> close() => channel.invokeMethod('close');

  /// 原生通道无断链检测(ohos 无热插拔事件 API);生产装配在
  /// AppServices 里用 WatchdogUsbHostChannel 包装后才有真实事件。
  @override
  Stream<String> get breakages => const Stream.empty();
}

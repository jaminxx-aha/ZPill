# core/ptpusb — PTP/USB 协议层

与 `core/ptpip`(PTP-IP over TCP)平行的另一条链路:USB Still Image 设备类
(ISO 15740 附录 D)。**纯 Dart、零 Flutter 依赖**;操作码/响应码/事件码
与 PTP-IP 共用 `core/ptp/operation_codes.dart`。

## 文件

| 文件 | 职责 |
|---|---|
| `containers.dart` | bulk/中断容器编解码(命令 1/数据 2/响应 3/事件 4) |
| `usb_transport.dart` | 实现 `core/ptp/ptp_transport.dart`:基于 `platform/usb` 通道的字节收发 |

字节收发本身(claim 接口、bulk 双向、interrupt IN、CLEAR_HALT)是平台能力,
收口在 `lib/platform/usb/usb_host.dart` 的 MethodChannel 契约里,不进 core。

## 与 PTP-IP 的差异备忘

1. **事件容器头是 10 字节、长度字段 u16**(bulk 容器是 12 字节头 + u32 长度)
2. 事务 ID 是 u32(PTP-IP 是 u16)
3. 无 DataPhaseInfo 字段:有无数据相位由"是否跟发数据容器"隐式表达
4. 流控不同:相机以 USB STALL 表达"忙",native 须 CLEAR_HALT 后重试
   (PTP-IP 用 Probe/Cancel 包)

## 现状

容器与传输均已落(字节级单测见 `test/core/ptpusb/`);native 三端:
iOS ImageCaptureCore / Android UsbManager / ohos @ohos.usb。
字节布局定案前身是 `tools/usb_probe`(Mac,pyusb)真机探针。

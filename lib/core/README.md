# core/ — 纯 Dart 业务核心(不 import 任何 Flutter 库)

三端 100% 共享的代码都在这里;禁止出现 `package:flutter/**`、`dart:io` 之外的
平台 API(dart:io 的 Socket 属于传输实现,允许在 ptpip/channels.dart 使用)。

## 分层与依赖方向(只允许向下)

```
core/ptp        PTP 标准层:操作/响应/事件码 + 链路无关传输抽象(USB 与 PTP-IP 共用)
core/ptpip      PTP-IP 链路:包模型/编解码/双通道/会话状态机(P0)
core/ptpusb     PTP/USB 链路:STI 容器编解码(P0;字节收发在 platform/usb)
core/camera     连接:WiFi 启发式/连接状态机/Probe 心跳(P1–P3)
core/browser    浏览:对象仓库/目录导航(P1–P2)
core/transfer   传输:队列引擎/任务模型/速度估算(P1–P2)
core/utils      小端字节读写器(TODO 注意事项 1 的防线)
```

- `ptpip`/`ptpusb` → `ptp`;`camera` → `ptp`;`browser`/`transfer` → `ptp` + 相互不依赖
- 所有对平台(WiFi 状态、相册、后台、BLE、USB)的需求经 `lib/platform/` 的接口注入,
  core 不感知三端差异

## 测试策略

- ptpip/ptpusb:字节级单测(小端、半包、大文件分包)
- camera/browser/transfer:注入 Fake(channel/repository)测状态机
- 真机验证统一走 `tools/ptpip_probe`(无线)与 `tools/usb_probe`(USB),通过后才移植进本层

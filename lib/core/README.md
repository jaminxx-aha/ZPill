# core/ — 业务核心(受控 Flutter 例外)

三端共享的协议、状态机和媒体管线都在这里。默认只写纯 Dart;仅 UI 相邻的
监听状态与 `dart:ui` 图像处理可按精确白名单例外,不得新增宽泛 Flutter 依赖。

## 分层与依赖方向(只允许向下)

```
core/ptp        PTP 标准层:操作/响应/事件码 + 链路无关传输抽象(USB 与 PTP-IP 共用)
core/ptpip      PTP-IP 链路:包模型/编解码/双通道/会话状态机(P0)
core/ptpusb     PTP/USB 链路:STI 容器编解码(P0;字节收发在 platform/usb)
core/camera     连接:WiFi 启发式/连接状态机/Probe 心跳(P1–P3)
core/browser    浏览:对象仓库/目录导航(P1–P2)
core/transfer   传输:队列引擎/任务模型/速度估算(P1–P2)
core/utils      小端字节读写器(字节序防线)
core/log        统一日志门面 AppLog:分级分域 + 环形缓冲 + 脱敏(纯 Dart 零 IO,控制台镜像/落盘经 configure 注入)
```

- `ptpip`/`ptpusb` → `ptp`;`camera` → `ptp`;`browser`/`transfer` → `ptp` + 相互不依赖
- BLE、USB、相册、RAW 解码只允许依赖 `lib/platform/` 中已登记的契约入口,
  不得依赖平台具体实现
- 禁止反向 import `features/`、`data/`、`app_*`、`design/`、`debug/`

## 架构与规模闸

```bash
dart run tools/check_architecture.dart
```

- Flutter / `dart:ui` 例外按文件与 import 精确登记在脚本内,新增依赖会失败
- 达到 2000 行的 Dart 文件必须登记行数预算;既有超大文件只能缩小或拆分
- CI 在 analyze 和 test 前执行该闸

## 测试策略

- ptpip/ptpusb:字节级单测(小端、半包、大文件分包)
- camera/browser/transfer:注入 Fake(channel/repository)测状态机
- 真机验证统一走 `tools/ptpip_probe`(无线)与 `tools/usb_probe`(USB),通过后才移植进本层

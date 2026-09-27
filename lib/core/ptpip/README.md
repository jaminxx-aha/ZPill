# core/ptpip — PTP-IP 协议层(P0)

一切功能的前提(TODO.md §一)。**纯 Dart、零 Flutter 依赖**,三端 100% 复用,必须可单测。

## 文件

| 文件 | 职责 |
|---|---|
| `packet.dart` | 包类型常量(1–14)、包头、包数据模型 |
| `operation_codes.dart` | PTP-IP 独有的 DataPhase 取值;标准操作/响应/事件码已上移至 `core/ptp/operation_codes.dart`(PTP/USB 共用),此处转发导出 |
| `object_format.dart` | ObjectFormatCode 节选 + `ObjectKind` 分类 + MIME 映射 |
| `object_info.dart` | GetObjectInfo 数据集模型 |
| `codec.dart` | 包 ↔ 字节编解码(**全部小端**)—— TODO(P0) |
| `channels.dart` | command/event 双 TCP 通道抽象 + socket 实现 —— TODO(P1) |
| `session.dart` | 会话状态机:OpenSession、对象操作、分包流式接收 —— TODO(P0) |

## 铁律(来自 TODO.md 实现注意事项)

1. 所有多字节字段小端;读写只经 `core/utils/byte_reader.dart` / `byte_writer.dart`
2. object handle 只能来自 GetObjectHandles 响应,禁止由文件路径推导
3. 大端包被相机**静默丢弃**(症状:"TCP 连上但无响应")—— 字节级单测必须覆盖

## 实现顺序

`tools/ptpip_probe`(Python CLI)对真机跑通握手 → 核对字节布局 → 落 `codec.dart` + 字节级单测 → `session.dart` 状态机 → `channels.dart` socket 帧切分。

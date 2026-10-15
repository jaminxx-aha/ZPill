# core/ptpip — PTP-IP 协议层(P0/P1)

无线传输的协议核心。**纯 Dart、零 Flutter 依赖**,三端 100% 复用,必须可单测。

## 尼康 Wi-Fi 方言(2026-10-04 定案)

Zf「网络 → 连接至智能设备」模式按 **SnapBridge 的 MTP/IP 方言**解析,
与规范 PTP/IP 有三处差异,错任何一处都会被相机在读完 Init 后直接 FIN:

1. **包头 = 长度(u32)在前 + 类型(u32)在后**(libgphoto2 同构;
   早期骨架曾写反成类型在前)
2. **InitCommandRequest = 固定 GUID `00112233…EEFF` + UTF-16LE 主机名
   (NUL 结尾,无长度前缀)+ u32 版本 0x00010000**(规范布局的
   u32 长度前缀主机名会被当乱码)
3. InitCommandResponse 相应多出相机 GUID / utf16z 相机名 / 版本三段

依据:[Camera_Bridge](https://github.com/HuiLiYiImpl/Camera_Bridge)
(小米 14 + Zf,Wireless 实测通过)+ 本仓 `tools/ptpip_probe` 复核。
「连接到计算机」模式(WTU/darktable 路线)说规范方言,本模块不针对它。

## 文件

| 文件 | 职责 |
|---|---|
| `packet.dart` | 包类型常量(1–14)、包头、包数据模型 |
| `codec.dart` | 包 ↔ 字节编解码(**全部小端,含尼康方言常量**) |
| `channels.dart` | 帧切分器(半包/粘包/巨值保护)+ `PtpIpChannel` 接口 + TCP 薄壳(5s 连接超时) |
| `operation_codes.dart` | PTP-IP 独有的 DataPhase 取值;标准操作/响应/事件码已上移至 `core/ptp/operation_codes.dart`(PTP/USB 共用),此处转发导出 |
| `object_format.dart` | ObjectFormatCode 节选 + `ObjectKind` 分类 + MIME 映射 |
| `object_info.dart` | GetObjectInfo 数据集模型 |
| `transport.dart` | `PtpIpTransport implements PtpTransport, PtpCancelCapable`:双通道握手、终身单订阅 dispatcher(握手与事务同一条订阅)、tid 表路由、整事务超时(每帧重置)、毒化(`PtpLinkException implements Exception`)、breakages 广播、DataPhaseInfo 私表、StartData u64 对账、取消-排水(`cancelInFlight`:Cancel 包 + 吸干数据相到 OperationResponse,`PtpCancelledException` 干净收口,墙钟+字节双阀) |

原骨架 `session.dart`(与 `core/ptp/PtpSession` 平行的旧接口,零引用)
已删 —— 无线复用既有 `PtpSession`,经 transport 级路由器切换链路。

## 实现状态(Phase 1 完)

probe(13 步,2026-10-04 Zf 真机)→ codec / channels / transport 全落,
单测 54 个(ptpip 目录)覆盖:字节 golden、半包粘包、回环 socket、
握手全流程、tid 方言、dp 私表清单、四条毒化不变量、事件转发。
数据出相布局(StartData+EndData)与 0x201E 自愈表现待下一轮真机核对。

## 铁律(来自 TODO.md 实现注意事项)

1. 所有多字节字段小端;读写只经 `core/utils/byte_reader.dart` / `byte_writer.dart`
2. object handle 只能来自 GetObjectHandles 响应,禁止由文件路径推导
3. 大端包被相机**静默丢弃**(症状:"TCP 连上但无响应")—— 字节级单测必须覆盖
4. GetStorageIDs 在 SnapBridge 会话被拒 —— 枚举一律用 storage=0xFFFFFFFF 哨兵
5. 勿发探测性连接:相机是单连接服务器,关闭后一段时间不接新 SYN

## 实现顺序

`tools/ptpip_probe`(Python CLI)对真机跑通握手 → 核对字节布局 →
`codec.dart` + `channels.dart` + `transport.dart`(均已落,单测见上)→
装配 `PtpLinkRouter` + 连接层双路径(见计划 vast-rolling-swing)。

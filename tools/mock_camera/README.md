# mock_camera —— 假尼康相机(PTP-IP 对端模拟器)

无相机环境下的回归工具:尼康 Wi-Fi 方言握手 → 相册 → 缩略/下载 → 拍摄事件
全链路。**同一份实现两条出口**:本目录 CLI(常驻,app 手动连)+ `test/e2e/`
回环测试(boot mock → 我方真 PtpIpTransport/PtpSession 走真 TCP → 断言)。

纯 Dart(`dart:io` ServerSocket),零 Flutter 依赖;协议字节复用仓内
`lib/core/ptpip/`(packet/codec/切帧器)+ `lib/core/utils/`(ByteReader/
ByteWriter),mock 即我方客户端的逐包镜像对端。

## CLI

```sh
# 仓根执行;缺省 15740(真机同款口)
dart run tools/mock_camera/bin/mock_camera.dart

# 真实文件当下载载荷(.jpg/.nef/.mov/.mp4 按扩展名入册)
dart run tools/mock_camera/bin/mock_camera.dart --objects-dir ~/Pictures/mock-card

# 复现「槽位被占用」的 InitFail 拒连(2026-10-04 真机 reason=0x1 场景)
dart run tools/mock_camera/bin/mock_camera.dart --init-fail 1
```

app 侧:连接页选无线 → 手动输入运行本 CLI 的机器 IP(同机即 127.0.0.1)。
日志 hilog 风格,Ctrl-C 退净。

## 握手镜像(两步方言,以我方客户端为镜像)

1. 第 1 条 TCP:InitCommandRequest(GUID 16B + 无长度前缀 NUL 终止
   UTF-16LE 主机名 + u32 版本)→ InitCommandResponse(u32 连接号 +
   16B 相机 GUID + NUL 终止 UTF-16LE 相机名 + u32 版本);槽位被占 /
   `--init-fail` 回 InitFail。
2. 第 2 条 TCP(GUI 事件 socket):InitEventRequest(连接号)→
   InitEventResponse。此后命令通道跑事务,事件通道回 ProbeRequest 心跳
   回声 + 推送拍摄事件。

## 支持面(= GetDeviceInfo 上报的操作码表)

| 操作 | 行为 |
|---|---|
| 0x1001 GetDeviceInfo / 0x1002 OpenSession / 0x1003 CloseSession | 标准语义;重复 OpenSession 回 0x201E |
| 0x1004/0x1005 StorageIDs/Info | 单卡 64GB/32GB 人设 |
| 0x1007 GetObjectHandles | Zf 方言:parent=0 全量、0xFFFFFFFF 只回根层 |
| 0x1008 GetObjectInfo | 52B 头 + 三串,布局同 `object_info.dart` |
| 0x1009 GetObject / 0x100A GetThumb | 正文 / 内嵌缩略(合成真 JPEG) |
| 0x101B GetPartialObject | 32 位偏移分块读,≥64KB 拆多 Data 包 |
| 0x90C2 / 0x9435 模式切换 | 记账 + OK |
| 0x90C4 GetLargeThumb | 合成大缩略 JPEG |
| 0x90C7/0x941C GetEvent(Ex) | 空队列(u32 计数 0) |
| 0x90C8 DeviceReady / 0x920A/0x920B/0x920C | OK |
| 0x9207 / 0x100E 拍摄 | OK 后推 0x4002 ObjectAdded + 0x400D CaptureComplete,新 JPEG 入对象表 |
| 其余 | OperationNotSupported(0x2005) |

## 留账

- 真机 Zf 拍摄事件可能只走 0x941C 轮询队列而非事件 socket(本 mock 走
  事件 socket);
- 属性族(0x1014/0x1015/0x1016 值)/ 0x9805 批量属性 / 取景族
  (0x9201/0x9428)未实现 —— app 连 mock 时取景页与信息卡按降级路径走;
- USB 侧(PTP/USB 容器)mock 不在本工具范围。

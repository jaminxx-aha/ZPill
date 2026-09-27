# ptpip_probe — PTP-IP 协议验证 CLI(P0)

在写任何 Dart 协议代码之前,先用这个脚本对**真机**跑通握手、核对字节布局
(TODO.md §一「协议验证脚本」;实现注意事项 6:常量不可臆造)。

## 用法

```bash
# 前置:手动连接相机 WiFi 热点
python3 tools/ptpip_probe/probe.py 192.168.1.1
python3 tools/ptpip_probe/probe.py --hostname MacBook 192.168.1.1
```

零依赖,仅标准库(Python 3.10+)。

## 当前覆盖

- [x] command 通道 TCP 连接 + InitCommandRequest/Response
- [ ] event 通道(独立 socket)InitEventRequest/Response
- [ ] OpenSession(0x1002)
- [ ] GetObjectHandles(0x1007)解析
- [ ] 结论回填:Dart 侧 `DataPhaseInfo` 取值语义、NEF 的 ObjectFormatCode

## 排障速查

| 症状 | 首要怀疑 |
|---|---|
| TCP 连上但无任何响应 | 字节序错误(必须小端)或包长度字段错(含 8B 头) |
| 连接被立即关闭 | 主机名编码/长度字段错(UTF-16LE + u32 长度) |
| InitFail | 看 reason 码;对照 libgphoto2 ptpip.c |
| 15740 拒绝连接 | 确认是否需要 BLE 激活相机 WiFi 服务(TODO §二 P3,待验证) |

# NikonPill

尼康相机无线传输工具(iOS / Android / HarmonyOS 三端)。
手动连接相机 WiFi 热点后,经 PTP-IP 协议(端口 15740)浏览与下载照片/视频。
目标机身:尼康 Z 系列及部分 DSLR。

> 状态:**工程骨架已就位** —— 分层、接口、协议常量、单测与真机验证 CLI;
> 协议实现按 [TODO.md](TODO.md) P0→P3 推进,架构详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 目录速览

```
lib/
├── core/          # 纯 Dart 业务核心(三端共享,零 Flutter 依赖)
│   ├── ptpip/     #   PTP-IP 协议:包模型/小端编解码/双通道/会话
│   ├── camera/    #   连接状态机/WiFi 启发式/Probe 心跳
│   ├── browser/   #   对象仓库/目录导航
│   ├── transfer/  #   传输引擎/速度估算
│   └── utils/     #   小端字节读写器
├── features/      # UI(MVVM):三 tab + 遥控/设置
├── platform/      # 三端差异收口:WiFi/相册/后台/BLE(MethodChannel)
└── data/          # 持久化(现为内存桩)
tools/ptpip_probe/ # PTP-IP 真机验证 CLI(Python,零依赖)
test/              # 字节级 + 状态机单测
docs/              # 架构文档
```

## 环境准备

| 目标平台 | 工具 |
|---|---|
| iOS / Android | [Flutter 官方 SDK](https://docs.flutter.dev/get-started/install)(stable) |
| HarmonyOS | OpenHarmony-SIG 的 [flutter_flutter fork](https://gitee.com/openharmony-sig/flutter_flutter) + DevEco Studio(见其仓库 README 配置 `PATH`) |

## 初始化(骨架期之后首次运行)

`android/`、`ios/`、`ohos/` 平台目录由工具链生成(勿手写),在仓库根执行:

```bash
# 官方 SDK(iOS/Android)
flutter create --project-name nikon_pill --platforms=android,ios .

# HarmonyOS:切换到 SIG fork 的 flutter 后
flutter create --project-name nikon_pill --platforms=ohos .
```

生成后:权限声明(蓝牙/位置/WiFi 状态)按 [TODO.md §七](TODO.md) 落入各平台清单,
`nikonpill/*` 四个 MethodChannel 的 native 实现按 [lib/platform/services.dart](lib/platform/services.dart)
契约表补齐。

## 常用命令

```bash
flutter pub get
flutter test                 # 运行单测
flutter run                  # 连接设备运行

# PTP-IP 真机验证(先手动连相机 WiFi)
python3 tools/ptpip_probe/probe.py 192.168.1.1
```

## 铁律(TODO.md 实现注意事项摘录)

1. PTP-IP 全字段**小端**;大端包被相机静默丢弃(症状:"TCP 连上但无响应")
2. object handle 只能来自 GetObjectHandles 响应,不可由路径推导
3. 心跳必须真实收发;只计数不清零的"心跳"等于定时断线
4. 功能就绪以"真实数据、端到端跑通"为准,禁止假数据标注完成

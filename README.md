# NikonPill

<img src="nikonpill.png" width="96" alt="NikonPill 图标" align="right" />

尼康相机无线遥控与传输工具:iOS / Android / HarmonyOS 三端共用一份 Flutter 代码库。

蓝牙配对唤醒相机 WiFi(或 USB 线直连),经 PTP 协议完成实时取景监看、遥控拍摄、
浏览下载与本地图库编辑。以尼康 **Zf** 为主要开发与真机验证机型。

## 功能

**连接**

- BLE 配对走 SnapBridge 方言:握手换身份、GATT 读出相机 WiFi 凭据、写开关直接唤醒相机的 WiFi 服务
- 三种接入:相机热点(AP)/ 相机入同一局域网(STA,mDNS 自动发现)/ USB 线连;Android / HarmonyOS 支持程序化加入热点,iOS 按手动指引降级
- USB 与无线双链路经 `PtpLinkRouter` 汇合同一会话,自动重连、心跳保活;解除配对有确认窗

**拍摄**

- 实时取景:XGA·Fine 默认画质,高质量档 Catmull-Rom fragment shader 上采样(`shaders/feed_quality.frag`)
- 监看辅助:直方图 / 斑马纹 / 伪色 / 峰值 / 构图框 / 示波器(波形 · RGB Parade · 矢量 · 红绿灯),共享一份帧分析,开关全部持久化
- 控制:拍照 / 录像 / B 门长曝、拍摄参数读写、手势拉焦(MF 驱动)、照片/视频模式切换、间隔拍摄;iOS 音量键可当快门

**浏览与下载**

- 相机存储浏览:目录导航、缩略图缓存(iOS 原生 NEF 解码,其余端回落内嵌缩略图)、存储卡用量总览
- 下载:单张 / 批量 / 自动传输,AIMD 自适应分块与速度估算,Android 经前台服务后台下载,入库系统相册

**图库与编辑**

- 本地图库(下载到应用的文件)、大图查看与视频播放、传输队列页
- 编辑:LUT 调色(内置胶片预设)、水印、变形宽银幕还原、照片信息(XMP / Motion Photo);LUT 可导出 `.cube`

**其他**

- GPS 注入:连接期间经 BLE 周期注入手机定位,照片 EXIF 原生带坐标(已真机闭环)
- 中英双语,文案全量键化,catalog 完整性由测试闸门把守
- 统一日志 AppLog(分级分域 + 环形缓冲 + 原生日志合流),设置页可查看

## 目录速览

```
lib/
├── core/          纯 Dart 业务核心,零 Flutter 依赖,三端 100% 共享
│   ├── ptp/       PTP 标准层:操作/事件码、会话、链路无关传输抽象
│   ├── ptpip/     PTP-IP 链路:尼康方言编解码、双 TCP 通道、事务路由
│   ├── ptpusb/    PTP/USB 链路:bulk 容器编解码、USB 传输
│   ├── ble/       SnapBridge BLE 方言:配对引擎、WiFi 凭据、GPS 注入载荷
│   ├── camera/    连接状态机、相机发现、保活、重连策略
│   ├── browser/   对象仓库、相册分组、存储信息、缩略图缓存
│   ├── transfer/  传输引擎:AIMD 分块、自动传输、速度估算
│   ├── remote/    取景引擎与 watchdog、帧分析、峰值/示波器、间隔拍摄
│   ├── media/     LUT、胶片预设、水印、XMP、Motion Photo
│   ├── log/       统一日志门面 AppLog
│   └── utils/     小端字节读写器
├── features/      UI(MVVM,Controller 驱动):connection / remote / browser
│                  / library / edit / transfers / settings / shell / common
├── platform/      三端差异唯一收口:MethodChannel 契约 + Dart 侧实现
├── data/          持久化:配对相机、身份凭据、设置、评分、配置快照
├── design/        设计 token(色彩 / 间距 / 主题)
├── l10n/          键化文案目录(zh / en)
└── debug/         PTP 诊断
android/ ios/ ohos/  三端 native:Kotlin / Swift / ArkTS 通道实现
tools/               真机探针与假相机(见下)
test/                字节级 / 状态机 / widget / golden / e2e
shaders/             取景上采样 fragment shader
docs/                架构文档
```

**依赖铁律**:core 不 import Flutter、不感知平台(平台需求一律经 platform/ 接口注入);UI 按钮必须绑 Controller,禁止直连协议层;依赖单向 `features → core / platform / data`,`ptpip / ptpusb / ble → ptp`;下游不感知链路切换。

## 平台通道

通道命名统一 `nikonpill/<service>`:`network / gallery / bg / ble / usb / nsd / motion / location / raw / video / log`。契约表与三端实现进度见 [lib/platform/services.dart](lib/platform/services.dart);能力缺失时上层按降级路径处理(iOS 拿不到 SSID → 网关直连等),详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境准备

| 目标平台 | 工具 |
|---|---|
| iOS / Android | [Flutter 官方 SDK](https://docs.flutter.dev/get-started/install)(stable) |
| HarmonyOS | OpenHarmony-SIG 的 [flutter_flutter fork](https://gitee.com/openharmony-sig/flutter_flutter) + DevEco Studio |

三端平台目录已入库,clone 即可构建,无需 `flutter create` 再生成。

## 常用命令

```bash
flutter pub get
dart run tools/check_architecture.dart  # core 依赖边界 + 大文件预算
flutter run                  # 连接设备运行
flutter test                 # 全量单测(2026-10-27 基线:1634 passed / 0 skipped)

# HarmonyOS(切到 SIG fork 的 flutter,备好 DevEco SDK / hvigor / ohpm 环境)
flutter build hap
```

发布版本号、Android 环境变量签名和 HarmonyOS 本地签名边界见
[docs/RELEASE.md](docs/RELEASE.md)。常规 CI 只产出无敏感密钥的 Debug APK。

## 测试与开发工具

| 工具 | 用途 |
|---|---|
| `tools/mock_camera` | 纯 Dart「假尼康相机」:CLI 常驻供 app 手动连接;同一实现驱动 `test/e2e` 回环用例,无相机也可回归 |
| `tools/check_architecture.dart` | core 框架/平台依赖白名单与 2000 行文件预算闸(CI 强制执行) |
| `tools/ptpip_probe` | Python PTP-IP 真机验证 CLI(零依赖) |
| `tools/usb_probe` | Python USB 探针(镜头 / 存储 / 模式族) |
| `tools/ble_pair` | macOS BLE GATT 只读发现 CLI(Swift) |
| `tools/make_icons.py` | 从源图生成三端应用图标与启动占位图(依赖 Pillow) |

无相机回归:`dart run tools/mock_camera/bin/mock_camera.dart` 起假相机 → app 连接页手动输入 `127.0.0.1`。

## 实现铁律

1. PTP-IP / PTP/USB 全字段**小端**,读写只经 `core/utils` 字节读写器;大端包被相机静默丢弃(症状:TCP 连上但无响应)
2. object handle 只能来自 GetObjectHandles 响应,禁止由文件路径推导
3. 心跳必须真实收发;只计数不清零的「保活」等于定时断线
4. 协议常量以真机响应为准,禁止臆造;功能就绪以真实数据端到端跑通为准
5. 勿发探测性连接:相机是单连接服务器,连接关闭后一段时间不接新 SYN

## 更多文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 总体分层、关键数据流、三端能力差异
- [docs/SECURITY.md](docs/SECURITY.md) — 协议、凭据、原生解析与发布安全边界
- [lib/core/README.md](lib/core/README.md) — core 分层与测试策略
- [lib/core/ptpip/README.md](lib/core/ptpip/README.md) — 尼康 Wi-Fi 方言定案
- [lib/core/ptpusb/README.md](lib/core/ptpusb/README.md) — PTP/USB 容器差异备忘
- [lib/platform/README.md](lib/platform/README.md) — 平台适配层现状

## 许可

MIT,全文见 [LICENSE](LICENSE)。

# platform/ — 平台适配层

三端差异的**唯一**收口:core 与 features 只依赖本层接口,
native(Android Kotlin / iOS Swift / ohos ArkTS)按 `services.dart` 里的
channel 契约表提供实现。

## 原则

1. 接口先行:core 层编译不依赖任何平台代码
2. channel 命名统一 `nikonpill/<service>`,方法/事件参数在各自文件注释里定义
3. 平台能力缺失时**降级**而不是崩溃(iOS 无 SSID → 网关直连;
   后台受限 → 前台传输提示)
4. BLE 方言常量全部先抓包后编码,来源必须可追溯

## 现状

- `network / gallery / bg / ble / usb / nsd / motion / location /
  location/stream / raw / video / video_lut / log` 三端均已有对应
  实现文件。
- iOS 真机闭环面最广,BLE→WiFi 凭据交接已端到端验收;Android 当前
  APK 可构建,平台服务仍待有设备时回归;ohos 已有多项真机验收记录,
  未统一复核的剩余项按项目本地待办账本分项记账。
- network join:Android 用 WifiNetworkSpecifier,ohos 用候选配置族;
  iOS 的 hotspot join 依赖 Network Extension entitlement,缺失时按
  手动入网指引降级。
- raw:Android 覆盖 HEIF,NEF 回落内嵌缩略图;iOS 走 ImageIO RAW;
  ohos 走 Image + LibRaw。video:三端均支持全屏,Android 当前没有
  内嵌平台视图,内嵌视图调用由上层回退。
- bg:Android 为 dataSync 前台服务,iOS 为 BGTaskScheduler,ohos 为
  backgroundTaskManager 长时任务。

`PlatformServices.bootstrap()` 在 main() 注入,测试可覆盖为 Fake;
各通道三端落地进度以 [services.dart](services.dart) 契约表内注释为准。

# platform/ — 平台适配层

三端差异的**唯一**收口:core 与 features 只依赖本层接口,
native(Android Kotlin / iOS Swift / ohos ArkTS)按 `services.dart` 里的
channel 契约表提供实现。

## 原则

1. 接口先行:core 层编译不依赖任何平台代码
2. channel 命名统一 `zpill/<service>`,方法/事件参数在各自文件注释里定义
3. 平台能力缺失时**降级**而不是崩溃(iOS 无 SSID → 网关直连;
   后台受限 → 前台传输提示)
4. BLE 方言常量全部先抓包后编码,来源必须可追溯

## 现状

- 三端均已实现:usb / nsd / gallery / bg / motion / location / log
  (iOS 真机闭环面最广;ohos USB/相册真机闭环,nsd 编译过待真机;
  Android 编译过待真机;Android bg = dataSync 前台服务)
- iOS 另有 ble / location/stream / raw / video;Android/ohos 缺这些通道,
  上层按 MissingPluginException 降级(raw → 内嵌缩略图回落,
  video → 平台不支持提示,ble → 按不可用降级)
- network join 仅 Android 可程序化加入热点;iOS/ohos 调用返回 unsupported,
  按手动指引降级(iOS 拿不到 SSID,一律网关直连)

`PlatformServices.bootstrap()` 在 main() 注入,测试可覆盖为 Fake;
各通道三端落地进度以 [services.dart](services.dart) 契约表内注释为准。

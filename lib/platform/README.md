# platform/ — 平台适配层

三端差异的**唯一**收口:core 与 features 只依赖本层接口,
native(Android Kotlin / iOS Swift / ohos ArkTS)按 `services.dart` 里的
channel 契约表提供实现。

## 原则

1. 接口先行:core 层编译不依赖任何平台代码
2. channel 命名统一 `nikonpill/<service>`,方法/事件参数在各自文件注释里定义
3. 平台能力缺失时**降级**而不是崩溃(iOS 无 SSID → 网关直连;
   后台受限 → 前台传输提示)
4. BLE(P3)全部先抓包后编码,常量来源必须可追溯

## 现状

usb / nsd / gallery 三通道三端均已实现 native(iOS 真机闭环;ohos USB/
相册真机闭环,nsd 编译过待真机;Android 三者编译过待真机)。
bg / motion / location 三端均已实现(iOS/ohos/Android 编译过,真机待验;
Android bg = dataSync 前台服务,motion/location 见各插件头注)。
network / ble 为纯契约通道(**三端均未实现**,
native 缺失时上层按 MissingPluginException 降级);
`PlatformServices.bootstrap()` 在 main() 注入,测试可覆盖为 Fake。

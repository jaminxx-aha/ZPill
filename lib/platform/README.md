# platform/ — 平台适配层

三端差异的**唯一**收口:core 与 features 只依赖本层接口,
native(Android Kotlin / iOS Swift / ohos ArkTS)按 `services.dart` 里的
channel 契约表提供实现。

## 原则

1. 接口先行:core 层编译不依赖任何平台代码
2. channel 命名统一 `nikonbridge/<service>`,方法/事件参数在各自文件注释里定义
3. 平台能力缺失时**降级**而不是崩溃(iOS 无 SSID → 网关直连;
   后台受限 → 前台传输提示)
4. BLE(P3)全部先抓包后编码,常量来源必须可追溯

## 现状

`MethodChannel*` 实现均为桩(native 侧尚未生成);`PlatformServices.bootstrap()`
在 main() 注入,测试可覆盖为 Fake。

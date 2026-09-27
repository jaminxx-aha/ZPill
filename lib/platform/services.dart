/// 平台服务注册表与 MethodChannel 契约。
///
/// 三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)全部抽象为接口,
/// native 侧按同一 channel 契约提供实现:
///
/// | channel                | Android(Kotlin)      | iOS(Swift)           | ohos(ArkTS)          |
/// |------------------------|------------------------|------------------------|-----------------------|
/// | `nikonbridge/network`  | WifiManager/Connectivity | NEHotspotNetwork*     | @ohos.wifiManager     |
/// | `nikonbridge/gallery`  | MediaStore             | PHPhotoLibrary         | photoAccessHelper     |
/// | `nikonbridge/bg`       | WorkManager+前台服务   | BGTaskScheduler        | 后台任务+通知         |
/// | `nikonbridge/ble`      | BluetoothLeScanner     | CoreBluetooth          | @ohos.bluetooth.ble   |
///
/// *iOS 普通应用拿不到当前 WiFi SSID(需 entitlement 且大多被拒),
/// 实际策略:直接尝试默认网关直连,详见 docs/ARCHITECTURE.md。
library;

import 'background_transfer.dart';
import 'ble_scanner.dart';
import 'gallery_saver.dart';
import 'network_monitor.dart';

final class PlatformServices {
  PlatformServices._();

  static late final NetworkMonitor network;
  static late final GallerySaver gallery;
  static late final BackgroundTransferScheduler background;
  static late final BleScanner ble;

  /// main() 中调用;测试时可覆盖为 Fake(集成测试注入点)。
  static void bootstrap() {
    network = MethodChannelNetworkMonitor();
    gallery = MethodChannelGallerySaver();
    background = MethodChannelBackgroundScheduler();
    ble = MethodChannelBleScanner();
  }
}

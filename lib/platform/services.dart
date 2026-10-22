/// 平台服务注册表与 MethodChannel 契约。
///
/// 三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)全部抽象为接口,
/// native 侧按同一 channel 契约提供实现:
///
/// | channel                | Android(Kotlin)      | iOS(Swift)             | ohos(ArkTS)          |
/// |------------------------|------------------------|------------------------|-----------------------|
/// | `zpill/network`  | WifiManager/Connectivity | NEHotspotNetwork*     | @ohos.wifiManager     |
/// |   (join/release)     | WifiNetworkSpecifier ✓ | NEHotspot 代码就位*** | (system_basic,待)  |
/// | `zpill/gallery`  | MediaStore             | PHPhotoLibrary         | photoAccessHelper     |
/// | `zpill/bg`       | WorkManager+前台服务   | BGTaskScheduler        | 后台任务+通知         |
/// | `zpill/ble`      | BluetoothLeScanner     | CoreBluetooth          | @ohos.bluetooth.ble   |
/// | `zpill/usb`      | UsbManager bulk        | ImageCaptureCore**     | @ohos.usb             |
/// | `zpill/nsd`      | NsdManager             | NetServiceBrowser      | @ohos.net.mdns        |
/// | `zpill/motion`   | SensorManager 重力     | CoreMotion             | @ohos.sensor          |
/// | `zpill/location` | LocationManager        | CoreLocation           | geoLocationManager    |
/// | `zpill/raw`      | (待补 libraw)         | ImageIO RAW            | (待补)               |
/// | `zpill/video`    | (待补 ExoPlayer)       | AVKit                  | (待补)               |
///
/// *iOS 普通应用拿不到当前 WiFi SSID(需 entitlement 且大多被拒),
/// 实际策略:直接尝试默认网关直连,详见 docs/ARCHITECTURE.md。
/// **iOS 的 USB 走 ImageCaptureCore 公开 API(免费个人团队可用,
/// DriverKit dext 需付费账号,2026-10-04 实证后弃用该路线),
/// 见 usb/usb_host.dart 头注释。
library;

import 'background_transfer.dart';
import 'ble_scanner.dart';
import 'gallery_saver.dart';
import 'location_host.dart';
import 'motion_host.dart';
import 'network_monitor.dart';
import 'nsd_scanner.dart';
import 'raw_decoder.dart';
import 'usb/usb_host.dart';
import 'video_player.dart';

final class PlatformServices {
  PlatformServices._();

  static late final NetworkMonitor network;

  /// 程序化加入热点(`zpill/network` join/release;Android 已实现,
  /// iOS/ohos 未落地,调用返回 unsupported 按手动指引降级)。
  /// BLE→WiFi 交接用,见 ConnectionController.joinCameraAp。
  static late final WifiJoiner wifiJoiner;
  static late final GallerySaver gallery;
  static late final BackgroundTransferScheduler background;
  /// BLE 宿主(`zpill/ble`:扫描/GATT 读写订阅;iOS 已实现,
  /// Android/ohos 待补,缺失时调用抛 MissingPluginException 按降级处理)。
  /// 协议层(配对/GEO/TIME)在 lib/core/ble/,本层零方言知识。
  static late final BleHost ble;
  static late final UsbHostChannel usb;

  /// mDNS/Bonjour 相机发现(`zpill/nsd`;三端已实现:ohos/Android
  /// 编译过待真机验证,iOS 真机闭环)。
  static late final NsdScanner nsd;

  /// 水平仪姿态(`zpill/motion`;三端已实现:iOS/ohos/Android 均
  /// 编译过待真机验证,native 缺失时 listen 报错按「不可用」降级)。
  static late final MotionHost motion;

  /// 位置采样(`zpill/location`;三端已实现:iOS/ohos/Android 均
  /// 编译过待真机验证,native 缺失时调用报错按「无位置」降级)。
  static late final LocationHost location;

  /// 定位流 + 后台授权(`zpill/location/stream`;iOS 已实现,
  /// Android/ohos 待补,缺失时订阅抛 MissingPluginException 降级)。
  static late final LocationStreamHost locationStream;

  /// RAW→JPEG 原生解码(`zpill/raw`;iOS 已实现,Android/ohos 待补,
  /// 缺失时 ThumbnailCache 回落 GetThumb 小图)。NEF 查看的数据源,
  /// 见 raw_decoder.dart 头注释。
  static late final RawDecoder rawDecoder;

  /// 视频播放(`zpill/video`:全屏 play + 内嵌平台视图两路;iOS
  /// 已实现,Android/ohos 待补,缺失时调用报错按「平台不支持」提示)。
  static late final VideoPlayer videoPlayer;

  static bool _bootstrapped = false;

  /// main() 中调用(幂等;测试直接 pumpWidget 时不经 main,由
  /// AppServices 兜底触发);测试时可覆盖为 Fake(集成测试注入点)。
  static void bootstrap() {
    if (_bootstrapped) {
      return;
    }
    _bootstrapped = true;
    network = MethodChannelNetworkMonitor();
    wifiJoiner = MethodChannelWifiJoiner();
    gallery = MethodChannelGallerySaver();
    background = MethodChannelBackgroundScheduler();
    ble = MethodChannelBleHost();
    usb = MethodChannelUsbHost();
    nsd = MethodChannelNsdScanner();
    motion = MethodChannelMotionHost();
    location = MethodChannelLocationHost();
    locationStream = MethodChannelLocationStream();
    rawDecoder = MethodChannelRawDecoder();
    videoPlayer = MethodChannelVideoPlayer();
  }
}

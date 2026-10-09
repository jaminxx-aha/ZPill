/// 平台服务注册表与 MethodChannel 契约。
///
/// 三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)全部抽象为接口,
/// native 侧按同一 channel 契约提供实现:
///
/// | channel                | Android(Kotlin)      | iOS(Swift)             | ohos(ArkTS)          |
/// |------------------------|------------------------|------------------------|-----------------------|
/// | `nikonpill/network`  | WifiManager/Connectivity | NEHotspotNetwork*     | @ohos.wifiManager     |
/// | `nikonpill/gallery`  | MediaStore             | PHPhotoLibrary         | photoAccessHelper     |
/// | `nikonpill/bg`       | WorkManager+前台服务   | BGTaskScheduler        | 后台任务+通知         |
/// | `nikonpill/ble`      | BluetoothLeScanner     | CoreBluetooth          | @ohos.bluetooth.ble   |
/// | `nikonpill/usb`      | UsbManager bulk        | ImageCaptureCore**     | @ohos.usb             |
/// | `nikonpill/nsd`      | NsdManager             | NetServiceBrowser      | @ohos.net.mdns        |
/// | `nikonpill/motion`   | SensorManager 重力     | CoreMotion             | @ohos.sensor          |
/// | `nikonpill/location` | LocationManager        | CoreLocation           | geoLocationManager    |
/// | `nikonpill/raw`      | (待补 libraw)         | ImageIO RAW            | (待补)               |
/// | `nikonpill/video`    | (待补 ExoPlayer)       | AVKit                  | (待补)               |
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
  static late final GallerySaver gallery;
  static late final BackgroundTransferScheduler background;
  static late final BleScanner ble;
  static late final UsbHostChannel usb;

  /// mDNS/Bonjour 相机发现(`nikonpill/nsd`;三端已实现:ohos/Android
  /// 编译过待真机验证,iOS 真机闭环)。
  static late final NsdScanner nsd;

  /// 水平仪姿态(`nikonpill/motion`;三端已实现:iOS/ohos/Android 均
  /// 编译过待真机验证,native 缺失时 listen 报错按「不可用」降级)。
  static late final MotionHost motion;

  /// 位置采样(`nikonpill/location`;三端已实现:iOS/ohos/Android 均
  /// 编译过待真机验证,native 缺失时调用报错按「无位置」降级)。
  static late final LocationHost location;

  /// RAW→JPEG 原生解码(`nikonpill/raw`;iOS 已实现,Android/ohos 待补,
  /// 缺失时 ThumbnailCache 回落 GetThumb 小图)。NEF 查看的数据源,
  /// 见 raw_decoder.dart 头注释。
  static late final RawDecoder rawDecoder;

  /// 视频全屏播放(`nikonpill/video`;iOS 已实现,Android/ohos 待补,
  /// 缺失时调用报错按「平台不支持」提示)。
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
    gallery = MethodChannelGallerySaver();
    background = MethodChannelBackgroundScheduler();
    ble = MethodChannelBleScanner();
    usb = MethodChannelUsbHost();
    nsd = MethodChannelNsdScanner();
    motion = MethodChannelMotionHost();
    location = MethodChannelLocationHost();
    rawDecoder = MethodChannelRawDecoder();
    videoPlayer = MethodChannelVideoPlayer();
  }
}

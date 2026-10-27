/// 平台服务注册表与 MethodChannel 契约。
///
/// 三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)全部抽象为接口,
/// native 侧按同一 channel 契约提供实现:
///
/// | channel                | Android(Kotlin)      | iOS(Swift)             | ohos(ArkTS)          |
/// |------------------------|------------------------|------------------------|-----------------------|
/// | `nikonpill/network`  | WifiManager/Connectivity | NEHotspotNetwork*     | @ohos.wifiManager     |
/// |   (join/release/scan)| WifiNetworkSpecifier   | NEHotspot 受 entitlement 限制 | 候选配置族       |
/// | `nikonpill/gallery`  | MediaStore             | PHPhotoLibrary         | photoAccessHelper     |
/// | `nikonpill/bg`       | 前台服务               | BGTaskScheduler        | backgroundTaskManager |
/// | `nikonpill/ble`      | BluetoothLeScanner     | CoreBluetooth          | @ohos.bluetooth.ble   |
/// | `nikonpill/usb`      | UsbManager bulk        | ImageCaptureCore**     | @ohos.usb             |
/// | `nikonpill/nsd`      | NsdManager             | NetServiceBrowser      | @ohos.net.mdns        |
/// | `nikonpill/motion`   | SensorManager 重力     | CoreMotion             | @ohos.sensor          |
/// | `nikonpill/location` | LocationManager        | CoreLocation           | geoLocationManager    |
/// | `nikonpill/raw`      | HEIF;真 RAW 回落缩略图 | ImageIO RAW            | image + LibRaw        |
/// | `nikonpill/video`    | MediaPlayer 全屏+抽帧  | AVKit+平台视图         | AVPlayer+平台视图     |
/// | `nikonpill/video_lut`| Media3 Transformer    | AVAssetExportSession   | LibRaw C++ 管线       |
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

  /// 程序化加入热点(`nikonpill/network` join/release;Android/ohos 已
  /// 实现,iOS 未落地 entitlement,调用返回 unsupported 按手动指引降级)。
  /// BLE→WiFi 交接用,见 ConnectionController.joinCameraAp。
  static late final WifiJoiner wifiJoiner;
  static late final GallerySaver gallery;
  static late final BackgroundTransferScheduler background;
  /// BLE 宿主(`nikonpill/ble`:扫描/GATT 读写订阅;三端已有实现,
  /// 真机状态见 platform/README.md)。
  /// 协议层(配对/GEO/TIME)在 lib/core/ble/,本层零方言知识。
  static late final BleHost ble;
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

  /// 定位流 + 后台授权(`nikonpill/location/stream`;三端已有实现,
  /// 系统后台权限差异由各平台 native 侧降级)。
  static late final LocationStreamHost locationStream;

  /// RAW/HEIF→JPEG 原生解码(`nikonpill/raw`;iOS/ohos 可解真 RAW,
  /// Android 覆盖 HEIF,NEF 回落 GetThumb/内嵌缩略图)。
  static late final RawDecoder rawDecoder;

  /// 视频播放(`nikonpill/video`:全屏 play + 内嵌平台视图两路;
  /// Android 当前为全屏/抽帧/帧率,内嵌视图由上层回退)。
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

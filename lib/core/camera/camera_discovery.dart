/// 相机 WiFi 检测启发式(TODO.md §二 P1)。
///
/// 纯函数,便于单测;真机校准后只改这里的常量。
library;

/// 尼康热点常见 SSID 片段(真机发现新前缀时在此追加)。
const List<String> kCameraSsidHints = ['NIKON', 'CCCC'];

/// 相机 WiFi 常见网段。192.168.1.x 为尼康默认,169.254.x 为链路本地。
bool isLikelyCameraGatewayIp(String ip) {
  return ip.startsWith('192.168.1.') || ip.startsWith('169.254.');
}

/// SSID 是否疑似相机热点(大小写不敏感,包含即命中)。
bool isLikelyCameraSsid(String? ssid) {
  if (ssid == null || ssid.isEmpty) return false;
  final upper = ssid.toUpperCase();
  return kCameraSsidHints.any(upper.contains);
}

/// 默认直连地址(尼康相机 WiFi 网关,TODO.md §二)。
const String kDefaultCameraIp = '192.168.1.1';
const int kPtpIpPort = 15740;

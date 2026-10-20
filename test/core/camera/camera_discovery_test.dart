import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/camera/camera_discovery.dart';

void main() {
  group('相机 WiFi 启发式', () {
    test('SSID 含 NIKON/CCCC 命中(大小写不敏感)', () {
      expect(isLikelyCameraSsid('NIKON-Z6_123456'), isTrue);
      expect(isLikelyCameraSsid('cccc901234'), isTrue);
      expect(isLikelyCameraSsid('My Home WiFi'), isFalse);
      expect(isLikelyCameraSsid(null), isFalse);
      expect(isLikelyCameraSsid(''), isFalse);
    });

    test('网关 IP 命中尼康默认网段与链路本地网段', () {
      expect(isLikelyCameraGatewayIp('192.168.1.1'), isTrue);
      expect(isLikelyCameraGatewayIp('192.168.1.42'), isTrue);
      expect(isLikelyCameraGatewayIp('169.254.1.1'), isTrue);
      expect(isLikelyCameraGatewayIp('192.168.0.1'), isFalse);
      expect(isLikelyCameraGatewayIp('10.0.0.1'), isFalse);
    });
  });
}

/// WifiJoiner 通道降级(iOS/ohos 未落地的如实回落;契约见
/// lib/platform/network_monitor.dart)。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/platform/network_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelWifiJoiner(nikonpill/network):', () {
    test('通道缺失:join 如实 unsupported,不抛', () async {
      // native 未注册该 channel(测试环境无任何 handler)→
      // invokeMethod 抛 MissingPluginException → 收敛为 unsupported。
      final joiner = MethodChannelWifiJoiner();
      final r = await joiner.join(
          ssid: 'Zf_80114411', password: 'wpa2pass99', security: 0x02);
      expect(r.ok, isFalse);
      expect(r.reason, 'unsupported');
    });

    test('通道缺失:release 静默(本就没持网络)', () async {
      final joiner = MethodChannelWifiJoiner();
      await joiner.release();
    });
  });
}

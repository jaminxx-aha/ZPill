/// WifiJoiner 通道降级(iOS/ohos 未落地的如实回落)+ join 结果 gateway
/// 透传(契约见 lib/platform/network_monitor.dart)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/platform/network_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelWifiJoiner(zpill/network):', () {
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

  group('join 结果 gateway 透传(native 在 onAvailable 沿读 DHCP 网关):',
      () {
    const channel = MethodChannel('zpill/network');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('join ok 带 gateway:点分串原样透传', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'join');
        return {'ok': true, 'gateway': '192.168.100.1'};
      });
      final r = await MethodChannelWifiJoiner().join(
          ssid: 'Zf_80114411', password: 'wpa2pass99', security: 0x02);
      expect(r.ok, isTrue);
      expect(r.reason, isNull);
      expect(r.gateway, '192.168.100.1');
    });

    test('join ok 拿不到网关:不带该键 → null(下游回落默认 IP)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return {'ok': true};
      });
      final r = await MethodChannelWifiJoiner().join(
          ssid: 'Zf_80114411', password: '', security: 0x01);
      expect(r.ok, isTrue);
      expect(r.gateway, isNull);
    });

    test('join 失败:reason 如实,gateway 不掺和', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return {'ok': false, 'reason': 'unavailable'};
      });
      final r = await MethodChannelWifiJoiner().join(
          ssid: 'Zf_80114411', password: 'wpa2pass99', security: 0x02);
      expect(r.ok, isFalse);
      expect(r.reason, 'unavailable');
      expect(r.gateway, isNull);
    });
  });
}

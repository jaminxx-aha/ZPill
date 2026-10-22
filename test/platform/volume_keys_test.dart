import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/platform/volume_keys.dart';

/// `zpill/volume` 通道件单测:mock 拦截 Dart→原生('setEnabled'),
/// handlePlatformMessage 反向推 'onVolumeKey' 模拟原生按键命中
/// (Android onKeyUp 拦截 / iOS 音量沿回推,载荷同契约)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zpill/volume');
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> outbound;

  setUp(() {
    outbound = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      outbound.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// 原生 → Dart:模拟 MainActivity onKeyUp 命中回推。
  Future<void> pushFromNative(MethodCall call) =>
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );

  test('setEnabled 推原生(载荷 = 布尔)', () async {
    final host = MethodChannelVolumeKeys.instance;
    await host.setEnabled(true);
    await host.setEnabled(false);
    // MethodCall 无结构性 ==,按 (method, arguments) 对比
    expect(outbound.map((c) => (c.method, c.arguments)), [
      ('setEnabled', true),
      ('setEnabled', false),
    ]);
  });

  test('onVolumeKey up/down → 流广播(上/下同效,均为有效事件)', () async {
    final host = MethodChannelVolumeKeys.instance;
    final events = <VolumeKey>[];
    final sub = host.keys.listen(events.add);
    await pushFromNative(
        const MethodCall('onVolumeKey', {'key': 'up'}));
    await pushFromNative(
        const MethodCall('onVolumeKey', {'key': 'down'}));
    await pumpEventQueue();
    expect(events, [VolumeKey.up, VolumeKey.down]);
    await sub.cancel();
  });

  test('未知方法/未知键名静默丢弃,不炸流', () async {
    final host = MethodChannelVolumeKeys.instance;
    final events = <VolumeKey>[];
    final sub = host.keys.listen(events.add);
    await pushFromNative(
        const MethodCall('onVolumeKey', {'key': 'bogus'}));
    await pushFromNative(const MethodCall('onVolumeKey', null));
    await pushFromNative(const MethodCall('somethingElse', null));
    await pumpEventQueue();
    expect(events, isEmpty);
    await sub.cancel();
  });

  test('setEnabled 无原生实现(异端/热重启)→ MissingPluginException 吞掉',
      () async {
    messenger.setMockMethodCallHandler(channel, null); // 撤 mock = 无实现
    final host = MethodChannelVolumeKeys.instance;
    // 不抛即过:静默降级,音量键本就归系统
    await host.setEnabled(true);
  });

  group('平台分派(2026-10-15 iOS 接入)', () {
    test('hostOn:Android/iOS 有原生实现 → 接线单例,其余 → null', () {
      final host = MethodChannelVolumeKeys.instance;
      expect(MethodChannelVolumeKeys.hostOn(android: true, ios: false),
          same(host));
      expect(MethodChannelVolumeKeys.hostOn(android: false, ios: true),
          same(host));
      expect(
          MethodChannelVolumeKeys.hostOn(android: false, ios: false), isNull);
    });

    test('platformHost:无实现平台(ohos/桌面)→ null 不接线', () {
      // Android/iOS 两分支由 hostOn 直测(测试宿主非移动端,Platform
      // 静态不可注);iOS 原生侧由 flutter build ios 编译闸兜底。
      expect(MethodChannelVolumeKeys.platformHost, isNull);
    });
  });
}

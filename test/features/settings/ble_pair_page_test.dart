import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app_services.dart';
import 'package:nikon_pill/core/ble/ble_camera_session.dart';
import 'package:nikon_pill/data/ble_identity_store.dart';
import 'package:nikon_pill/features/settings/ble_pair_page.dart';

/// 配对页 0x0399 冲突指引:有身份+异 ID → 行内提示;同 ID → 无;
/// 无身份 → 无;重连未命中(本页扫描结果里有别家相机)→ 日志复用
/// 同一条指引。
///
/// 基建(最小):AppServices 单例照常构建(bleGpsInject 默认关 → 零注入
/// 驱动 Timer),只 mock nikonpill/ble 的 scan/scanForDeviceId(喂设备
/// 列表/喂空)与 nikonpill/ble/events 的 listen(事件通道空挂)。身份
/// 不走真盘档 —— File IO 在 fake-async 里永不落地,经 [BlePairPage.
/// savedIdentity] 注入(生产不传,行为不变)。
///
/// 收尾纪律:addTearDown 晚于「树已拆仍有 Timer」不变量检查,拆页 +
/// 放掉 1s 状态行 Timer(与重连退避延迟)必须写在用例体内。
void main() {
  const ble = MethodChannel('nikonpill/ble');
  const bleEvents = MethodChannel('nikonpill/ble/events');
  // _loadSaved 会查定位授权:未 mock 的通道调用在 fake-async 里永不着地
  //(await 悬死),身份就永远进不了 _saved。
  const location = MethodChannel('nikonpill/location');

  Uint8List mfgOf(int deviceId) => Uint8List.fromList(<int>[
        0x99,
        0x03,
        deviceId & 0xFF,
        (deviceId >> 8) & 0xFF,
        (deviceId >> 16) & 0xFF,
        (deviceId >> 24) & 0xFF,
      ]);

  Map<String, Object?> deviceMap(Uint8List mfg) => <String, Object?>{
        'name': 'Z f_8014411',
        'uuid': 'P1',
        'rssi': -50,
        'mfg': mfg,
      };

  BlePairedIdentity identityOf(int deviceId) => BlePairedIdentity(
        peripheralUuid: 'P1',
        deviceId: deviceId,
        nonce: 0x70,
        serial: 'S',
        controllerName: 'NikonPill',
        pairedAt: DateTime(2026, 10, 15),
      );

  Future<void> boot(
    WidgetTester tester, {
    required List<Map<String, Object?>> scanResult,
    BlePairedIdentity? saved,
  }) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(bleEvents, (call) async => null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(bleEvents, null));
    messenger.setMockMethodCallHandler(
        location, (call) async => call.method == 'authStatus' ? 'always' : null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(location, null));
    messenger.setMockMethodCallHandler(
        ble, (call) async => call.method == 'scan' ? scanResult : null);
    addTearDown(() => messenger.setMockMethodCallHandler(ble, null));

    await tester
        .pumpWidget(MaterialApp(home: BlePairPage(savedIdentity: saved)));
    await tester.pump();
    await tester.tap(find.text('扫描(30s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 用例体收尾:拆页 + 放掉 1s 状态行周期 Timer(挂着的周期 Timer 按
  /// 「树已拆仍有 Timer」判失败)。[drain] 须盖过用例遗留的延时(重连
  /// 退避 2s → 3s 起步)。
  Future<void> disposePage(WidgetTester tester,
      {Duration drain = const Duration(seconds: 2)}) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(drain);
  }

  testWidgets('无注册身份:广播可解析也只做结构化展示,不判冲突(首次配对无从比较)', (tester) async {
    await boot(tester, scanResult: [deviceMap(mfgOf(0x56781234))]);

    expect(find.textContaining('设备ID 0x56781234'), findsOneWidget,
        reason: 'mfg 调试 hex 行换成 deviceId 数值展示');
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('有身份 + 异 ID:该行出「在等别的手机」指引(含别家 deviceId)', (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x11223301));

    expect(
        find.textContaining('此相机在等别的手机(设备ID 0x56781234)'),
        findsOneWidget);
    await disposePage(tester);
  });

  testWidgets('有身份 + 同 ID:相机在等我们自己,不出指引', (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x56781234));

    expect(find.textContaining('设备ID 0x56781234'), findsOneWidget);
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('重连未命中:本页扫描结果里有别家相机 → 日志复用同一条指引', (tester) async {
    // 会话身份一并注入:重连轮真实走到 scanForDeviceId(mock 喂空)。
    AppServices.instance.bleSession.identity = BleIdentity(
      peripheralUuid: 'P1',
      deviceId: 0x11223301,
      nonce: 0x70,
      serial: 'S',
      name: 'NikonPill',
    );
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x11223301));

    await tester.tap(find.text('重连(复用身份)'));
    await tester.pump();
    await tester.pump();

    // 行内提示 1 + 重连日志 1 = 同一条指引出现两处。
    expect(find.textContaining('此相机在等别的手机'), findsNWidgets(2));
    // 拆页 + 排干重连退避(失败 1 轮 → 退避 2s)与 1s 状态行 Timer。
    await disposePage(tester, drain: const Duration(seconds: 3));
  });
}

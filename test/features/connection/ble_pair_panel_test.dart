import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app_services.dart';
import 'package:nikon_pill/core/ble/ble_camera_session.dart';
import 'package:nikon_pill/core/log/app_log.dart';
import 'package:nikon_pill/data/ble_identity_store.dart';
import 'package:nikon_pill/features/connection/ble_pair_panel.dart';

/// 配对面板 0x0399 冲突指引 + 打开自动化 + 重连取消(2026-10-17 全自动
/// 重连定案):有身份+异 ID → 行内提示;同 ID → 无;无身份 → 无;弹层
/// 打开即自动扫(无身份)/自动重连(有身份);扫描/拆面板废在途重连。
///
/// 基建(最小):AppServices 单例照常构建(bleGpsInject 默认关 → 零注入
/// 驱动,面板打开即挂起),只 mock nikonpill/ble 的 scan/scanForDeviceId
/// (喂设备列表/喂空)与 nikonpill/ble/events 的 listen(事件通道空挂)。
/// 身份不走真盘档 —— File IO 在 fake-async 里永不落地,经 [BlePairPanel.
/// savedIdentity] 注入(生产不传,行为不变)。
///
/// 收尾纪律:驱动现在「认身份即臂」(全自动重连)—— 用例若给
/// AppServices 单例会话塞过身份,拆面板前必须清掉再刷([disposePage]
/// 已内置),否则拆面板沿 resumeBleDriver 起重试 Timer,「树已拆仍有
/// Timer」判死。
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
    addTearDown(() => messenger.setMockMethodCallHandler(bleEvents, null));
    messenger.setMockMethodCallHandler(location,
        (call) async => call.method == 'authStatus' ? 'always' : null);
    addTearDown(() => messenger.setMockMethodCallHandler(location, null));
    messenger.setMockMethodCallHandler(
        ble, (call) async => call.method == 'scan' ? scanResult : null);
    addTearDown(() => messenger.setMockMethodCallHandler(ble, null));

    // 面板自身无 Scaffold(嵌入连接页弹层):测试桩补 Material 祖先。
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: BlePairPanel(savedIdentity: saved))));
    await tester.pump();
    // 打开沿自动化已在此 pump 内落定:无身份 → 自动扫描填列表;
    // 有身份 → 自动重连进第 1 轮(退避等待中)。
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 用例体收尾:先清身份停驱动(认身份即臂 —— 不清则拆面板沿起重试
  /// Timer),再拆面板。重连退避可取消(世代号),无需长排水。
  Future<void> disposePage(WidgetTester tester,
      {Duration drain = const Duration(milliseconds: 100)}) async {
    AppServices.instance.bleSession.identity = null;
    AppServices.instance.refreshBleInjection();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(drain);
  }

  testWidgets('无注册身份:打开即自动扫描,广播可解析也只做结构化展示,不判冲突(首次配对无从比较)',
      (tester) async {
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

    // 有身份 → 打开沿走自动重连不出列表;点扫描填列表(顺带废在途重连)。
    await tester.tap(find.text('扫描(30s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('此相机在等别的手机(设备ID 0x56781234)'), findsOneWidget);
    await disposePage(tester);
  });

  testWidgets('有身份 + 同 ID:相机在等我们自己,不出指引', (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x56781234));

    await tester.tap(find.text('扫描(30s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('设备ID 0x56781234'), findsOneWidget);
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('重连未命中:面板扫描结果里有别家相机 → 日志复用同一条指引', (tester) async {
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

    // 打开沿自动重连已在跑:先扫描(废在途重连)填列表,再点重连。
    await tester.tap(find.text('扫描(30s)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('重连(复用身份)'));
    await tester.pump();
    await tester.pump();

    // 行内提示 1 处;重连日志并轨统一日志(AppLog ble 域),同一条指引
    // 落 AppLog 不再上墙。
    expect(find.textContaining('此相机在等别的手机'), findsOneWidget);
    expect(
        AppLog.entries
            .where((e) => e.domain == AppLog.ble)
            .map((e) => e.message),
        contains(contains('此相机在等别的手机')));
    await disposePage(tester);
  });

  testWidgets('拆面板废在途重连:退避即刻醒,退避到点也不续跑(取消语义)', (tester) async {
    await boot(tester, scanResult: [], saved: identityOf(0x11223301));
    // 首轮已在 boot 内发出(当时挂的是 boot mock,未计数);换计数 mock
    // 只盯后续:若无取消语义,2s 退避到点会发第 2 轮,计数必涨。
    var scanIdCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ble,
        (call) async {
      if (call.method == 'scanForDeviceId') {
        scanIdCalls++;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(ble, null));
    expect(scanIdCalls, 0, reason: '首轮在 boot 内已发,计数 mock 从此盯后续');
    await tester.pump(const Duration(milliseconds: 500));
    expect(scanIdCalls, 0, reason: '退避等待期不再扫');
    await disposePage(tester, drain: const Duration(seconds: 3));
    expect(scanIdCalls, 0, reason: '拆面板废在途重连,退避 2s 到点也不续跑');
  });
}

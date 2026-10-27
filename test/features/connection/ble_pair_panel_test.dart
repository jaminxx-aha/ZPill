import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/app_services.dart';
import 'package:nikon_pill/core/ble/ble_camera_session.dart';
import 'package:nikon_pill/core/ble/gatt_uuids.dart';
import 'package:nikon_pill/core/log/app_log.dart';
import 'package:nikon_pill/data/ble_identity_store.dart';
import 'package:nikon_pill/features/connection/ble_pair_panel.dart';
import 'package:nikon_pill/platform/ble_scanner.dart';

/// 配对面板(2026-10-19 改版):「已配对 / 其它设备」两段列表 + 打开
/// 沿自动扫描(静默 —— 无扫描钮、无「扫描中」指示)+ 打开沿**不自动
/// 回链**(页内全手动;后台守候由注入驱动承担,面板打开期间挂起)+
/// iOS 首配自动跳系统蓝牙删除(onSystemBondNeeded 通知宿主)。
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

  test('BLE 敏感通知特征日志只保留长度', () {
    final data = Uint8List.fromList(List<int>.generate(17, (i) => i + 1));
    for (final uuid in [
      kNikonCharPairing,
      kNikonCharConfig,
      kNikonCharServerName,
      kNikonCharGeo,
      kNikonCharSerialString,
    ]) {
      expect(bleNotificationLogPayload(uuid, data), '<脱敏 17B>');
    }
    expect(bleNotificationLogPayload(kNikonCharNot1, data), hexOf(data));
  });

  Uint8List mfgOf(int deviceId, {int? status}) => Uint8List.fromList(<int>[
        0x99,
        0x03,
        deviceId & 0xFF,
        (deviceId >> 8) & 0xFF,
        (deviceId >> 16) & 0xFF,
        (deviceId >> 24) & 0xFF,
        if (status != null) status,
      ]);

  Map<String, Object?> deviceMap(Uint8List mfg) => <String, Object?>{
        'name': 'Z f_8014411',
        'uuid': 'P1',
        'rssi': -50,
        'mfg': mfg,
      };

  BlePairedIdentity identityOf(int deviceId, {String cameraName = ''}) =>
      BlePairedIdentity(
        peripheralUuid: 'P1',
        deviceId: deviceId,
        nonce: 0x70,
        serial: 'S',
        controllerName: 'NikonPill',
        cameraName: cameraName,
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
    messenger.setMockMethodCallHandler(
        ble, (call) async => call.method == 'scan' ? scanResult : null);
    addTearDown(() => messenger.setMockMethodCallHandler(ble, null));

    // 面板自身无 Scaffold(嵌入连接页蓝牙视图):测试桩补 Material 祖先。
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: BlePairPanel(savedIdentity: saved))));
    // 打开沿自动化已在此 pump 内落定:自动扫描填列表(mock 直回);
    // 无「扫描中」指示、无扫描钮。
    await tester.pump();
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

  testWidgets('无注册身份:打开即自动扫描填列表(静默,无扫描钮/指示)',
      (tester) async {
    await boot(tester, scanResult: [deviceMap(mfgOf(0x56781234))]);

    expect(find.text('Z f_8014411'), findsOneWidget,
        reason: '打开沿自动扫描(2026-10-19 改版:扫描静默自动,不再'
            '「只认显式点按」)');
    expect(find.text('扫描'), findsNothing, reason: '扫描钮退役');
    expect(find.textContaining('扫描中'), findsNothing, reason: '静默:无扫描中指示');
    expect(find.text('已配对'), findsOneWidget, reason: '两段列表段名');
    expect(find.text('其它设备'), findsOneWidget);
    expect(find.text('暂无已配对设备'), findsOneWidget);
    expect(find.textContaining('设备ID'), findsNothing);
    expect(find.textContaining('待机'), findsNothing,
        reason: '无状态字节(mfg 不足 7B)不出电源态副文');
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('配对通知帧进入 AppLog 前整体脱敏', (tester) async {
    AppLog.resetForTest();
    addTearDown(AppLog.resetForTest);
    await boot(tester, scanResult: []);
    final data = Uint8List.fromList(List<int>.generate(17, (i) => i + 1));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      bleEvents.name,
      const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
        'type': 'notify',
        'uuid': kNikonCharPairing,
        'data': data,
      }),
      (_) {},
    );
    await tester.pump();

    final logs = AppLog.entries
        .where((e) => e.domain == AppLog.ble)
        .map((e) => e.message)
        .join('\n');
    expect(logs, contains('<脱敏 17B>'));
    expect(logs, isNot(contains(hexOf(data))));
    await disposePage(tester);
  });

  testWidgets('广播带状态字节:行尾出电源态色点(待机黄),设备ID/文字副文不显',
      (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234, status: 0x1F))]);

    expect(find.text('Z f_8014411'), findsOneWidget);
    expect(find.textContaining('待机'), findsNothing,
        reason: '电源态文字退役(2026-10-19 换色点)');
    expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle),
        findsOneWidget,
        reason: '待机黄点(深睡行 = 点连接唤不醒的答案面)');
    expect(find.textContaining('设备ID'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('有身份:打开不自动回链(重连钮在场待点),面板不持扫描权',
      (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x11223301));

    expect(find.text('连接中…'), findsNothing,
        reason: '打开沿不自动回链(2026-10-19 定稿:进入页面不主动连接)');
    expect(find.text('连接'), findsOneWidget, reason: '连接钮在场,显式点按才发起');
    expect(find.text('最近'), findsOneWidget,
        reason: '配对档案行 = 最近连接条目,名后绿底「最近」徽(八轮)');
    // 2026-10-21:有身份面板不持扫描权(无线电让给驱动回链),已配对
    // 相机也不进其它设备 → 扫描结果不列示,列表空。
    expect(find.text('Z f_8014411'), findsNothing);
    expect(find.textContaining('此相机在等别的手机'), findsNothing,
        reason: '扫描行只显设备名,冲突指引不再上墙');
    await disposePage(tester);
  });

  testWidgets('有身份 + 扫描结果同 ID:相机在等我们自己,无指引;且不进其它设备',
      (tester) async {
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x56781234));

    // 2026-10-21:已配对相机不再进「其它设备」(它有自己的行 + 状态点;
    // 本用例档案无 cameraName,配对行显示回落名,扫描行应被滤除)。
    expect(find.text('Z f_8014411'), findsNothing);
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('有身份:面板不持扫描权(回链优先),别家相机不列示无指引',
      (tester) async {
    // 会话身份一并注入:2026-10-21 定稿有身份面板不扫描(无线电让给
    // 驱动回链,已配对相机也不进其它设备)—— 别家相机列示与「在等别
    // 的手机」指引随发现扫描一并退场。
    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x11223301));

    expect(find.textContaining('Z f'), findsNothing);
    expect(find.textContaining('此相机在等别的手机'), findsNothing);
    await disposePage(tester);
  });

  testWidgets('设备行展示相机广播名;旧档未存回落控制器名', (tester) async {
    await boot(tester,
        scanResult: [],
        saved: identityOf(0x11223301, cameraName: 'Z f_8014411'));
    expect(find.text('Z f_8014411'), findsOneWidget,
        reason: '设备行 = 相机名(cameraName);controllerName 是本机'
            '在相机侧的注册名,不当相机名用');
    await disposePage(tester);

    await boot(tester, scanResult: [], saved: identityOf(0x11223301));
    expect(find.text('NikonPill'), findsOneWidget,
        reason: '旧档缺 cameraName → 展示名回落 controllerName');
    await disposePage(tester);
  });

  testWidgets('手动断开后:打开沿不自动回链(bleManualOff 压制),显式连接解除',
      (tester) async {
    AppServices.instance.bleManualOff = true;
    addTearDown(() => AppServices.instance.bleManualOff = false);
    await boot(tester, scanResult: [], saved: identityOf(0x11223301));

    expect(find.text('连接中…'), findsNothing,
        reason: '用户显式断开意图压制回链(2026-10-19 定稿;打开沿本就'
            '不自动回链,此处防回归)');
    expect(find.text('连接'), findsOneWidget);
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(AppServices.instance.bleManualOff, isFalse,
        reason: '显式连接沿解除手动断开意图,守候/驱动恢复资格');
    await disposePage(tester);
  });

  testWidgets('解除配对点按先弹确认窗(对齐 STA 忘记这台相机):取消不动,确认才清',
      (tester) async {
    // clear() 沿 dataDir 走 nikonpill/gallery 通道:mock 计数当「清档
    // 是否触达」的探针(路径不存在 → exists() 一发真 IO 收口)。
    var dataDirCalls = 0;
    const gallery = MethodChannel('nikonpill/gallery');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(gallery, (call) async {
      dataDirCalls++;
      return '/tmp/nikonpill_ble_unpair_test';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(gallery, null));

    await boot(tester,
        scanResult: [], saved: identityOf(0x11223301, cameraName: 'Z f_8014411'));
    AppServices.instance.bleManualOff = true; // 断链意图在:取消沿必须原封
    addTearDown(() => AppServices.instance.bleManualOff = false);
    AppServices.instance.bleSession.identity = BleIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223301,
        nonce: 0x70,
        serial: 'S',
        name: 'NikonPill');

    // 点解除配对图标 → 确认弹窗(标题 + 正文点名相机 + 取消/确认)。
    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    expect(find.text('解除配对?'), findsOneWidget);
    expect(find.textContaining('Z f_8014411'), findsNWidgets(2),
        reason: '档案行 + 弹窗正文各一(正文点名相机)');
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('解除配对'), findsOneWidget, reason: '确认钮(destructive)');

    // 取消:档案原封 —— 断链意图/会话身份/清档全不动。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('解除配对?'), findsNothing);
    expect(AppServices.instance.bleManualOff, isTrue,
        reason: '取消沿断链意图原封(解除沿才会清)');
    expect(AppServices.instance.bleSession.identity, isNotNull,
        reason: '取消沿会话身份原封');
    expect(dataDirCalls, 0, reason: '取消沿不触清档');

    // 再点 → 确认:走解除沿(清档/撤会话身份/意图复位)。
    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除配对'));
    await tester.pumpAndSettle();
    // clear() 内 file.exists() 是 dart:io 真 IO:完成回调只在 runAsync
    // 出窗上浮一个,逐窗排水(memory flutter-test runAsync IO 排水)。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(dataDirCalls, 1, reason: '确认沿走到清档');
    expect(AppServices.instance.bleSession.identity, isNull,
        reason: '确认沿撤会话身份');
    expect(AppServices.instance.bleManualOff, isFalse,
        reason: '解除沿清手动断开意图(下次配对干净起步)');
    await disposePage(tester);
  });

  testWidgets('解除配对沿即刻起扫(2026-10-27 根修):重配对相机当轮可见',
      (tester) async {
    // 复现链:iOS 设置断链 → app 解除配对 → 相机删配置重开配对窗。
    // 解除沿的 disconnect 是 idle→idle 短路(BleCameraSession._setState
    // 同态即返)无状态事件,扫描权仲裁若只挂状态沿,面板清了身份也
    // 不起扫,其它设备恒「未发现设备」,唯回前台才补 —— 真机实证
    // 「必须回桌面再开 app 才出现」。clear() 沿 dataDir 走
    // nikonpill/gallery 通道(真 IO 排水同上例)。
    const gallery = MethodChannel('nikonpill/gallery');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(gallery, (call) async {
      return '/tmp/nikonpill_ble_unpair_rescan_test';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(gallery, null));

    await boot(tester,
        scanResult: [deviceMap(mfgOf(0x56781234))],
        saved: identityOf(0x11223301, cameraName: 'Z f_8014411'));
    AppServices.instance.bleSession.identity = BleIdentity(
        peripheralUuid: 'P1',
        deviceId: 0x11223301,
        nonce: 0x70,
        serial: 'S',
        name: 'NikonPill');
    // 有身份:扫描权在驱动(2026-10-21 裁定),相机只在档案行可见。
    expect(find.text('Z f_8014411'), findsOneWidget,
        reason: '档案行展示相机名;面板不扫描,其它设备无行');

    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除配对'));
    await tester.pump(); // 弹窗收口 + _unpair 起步(悬在 clear() 真 IO)
    // clear() 内 file.exists() 是 dart:io 真 IO:runAsync 逐窗排水
    // (memory flutter-test runAsync IO 排水)。不用 pumpAndSettle ——
    // 解除沿起扫后扫描循环计时器在场,pumpAndSettle 永不收口。
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 50)); // 扫描回包落表

    expect(find.text('暂无已配对设备'), findsOneWidget,
        reason: '解除沿档案行收空');
    expect(find.text('Z f_8014411'), findsOneWidget,
        reason: '身份清空沿即刻重算扫描权并起扫:配对窗相机当轮进'
            '「其它设备」,不再等回前台/重启 app');
    await disposePage(tester);
  });

  testWidgets('重连反馈只在按钮位;握手中行尾只出状态词(十/十一/十三/十四轮)',
      (tester) async {
    await boot(tester, scanResult: [], saved: identityOf(0x11223301));
    addTearDown(() => AppServices.instance.bleManualOff = false);
    // 十轮:名下副文反馈退役(打开沿无循环,先验空;十三轮文案改
    //「连接中…」)。
    expect(find.text('连接中…'), findsNothing);

    // 驱动 AppServices 单例会话进 pairing:reconnectDirect 直连窗
    //(60s 握手超时内一直 pairing;mock 通道无事件喂,握手永不完成)。
    AppServices.instance.bleSession.identity = BleIdentity(
      peripheralUuid: 'P1',
      deviceId: 0x11223301,
      nonce: 0x70,
      serial: 'S',
      name: 'NikonPill',
    );
    unawaited(AppServices.instance.bleSession.reconnectDirect());
    await tester.pump();
    await tester.pump();
    expect(find.text('握手中…'), findsOneWidget,
        reason: '十轮:握手期按钮位让位「握手中」状态词,行尾不再空着');
    expect(find.text('连接'), findsNothing, reason: '握手期不可再发起');
    // 十一轮:「握手中」与同行「连接/连接中…」按钮标签同色(primary)。
    expect(
        tester.widget<Text>(find.text('握手中…')).style?.color,
        Theme.of(tester.element(find.text('握手中…'))).colorScheme.primary,
        reason: '十一轮:状态词同槽同色(深色=黄、浅色=墨)');
    // 十四轮:握手期行尾只出「握手中」状态词(「断开」钮被否),状态词
    // 本身可点 = 取消;解除配对在握手期隐。
    expect(find.byIcon(Icons.link_off), findsNothing);
    AppServices.instance.bleManualOff = false;
    addTearDown(() => AppServices.instance.bleManualOff = false);
    await tester.tap(find.text('握手中…'));
    await tester.pump();
    await tester.pump();
    expect(AppServices.instance.bleManualOff, isTrue,
        reason: '十四轮:点状态词 = 取消(显式断开意图,与 hero 再点同路)');
    expect(AppServices.instance.bleSession.state, BleSessionState.idle,
        reason: '断链沿收口回 idle');
    expect(find.text('握手中…'), findsNothing, reason: '在途握手已弃局');
    expect(find.text('连接'), findsOneWidget, reason: '面板行回到「连接」');
    // 会话不再被迟到超时翻回 reconnecting(十三轮取消纪元:disconnect
    // 沿弃局在途握手,60s 超时窗已当场收口)。
    await tester.pump(const Duration(seconds: 61));
    expect(AppServices.instance.bleSession.state, BleSessionState.idle,
        reason: '十三轮:取消后迟到超时不得复活状态(纪元闸)');

    // 十五轮:连接中(reconnecting)行内 = 可点状态词,不与「连接」钮
    // 并存;**常驻自动循环即刻起**(面板 = 页面开着时的重连执行者)。
    unawaited(AppServices.instance.bleSession.reconnectDirect());
    await tester.pump();
    await tester.pump();
    expect(find.text('握手中…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('连接中…'), findsOneWidget,
        reason: '十五轮:连接中行内报态(可点 = 取消)');
    expect(find.text('连接'), findsNothing,
        reason: '十五轮:连接中不与「连接」钮并存(重连由常驻循环承担)');
    await tester.tap(find.text('连接中…'));
    await tester.pump();
    await tester.pump();
    expect(AppServices.instance.bleSession.state, BleSessionState.idle,
        reason: '点状态词 = 取消(常驻循环随取消废)');
    expect(find.text('连接'), findsOneWidget, reason: '回「连接」钮');
    // 收尾:断链(幂等)+ 身份清理纪律(认身份即臂)。
    await AppServices.instance.bleSession.disconnect();
    await disposePage(tester);
  });

  // skip 理由:扫描权状态机改造中,本用例待按新所有权模型重写
  //(持续扫描循环的 Timer 生命周期/挂起让位沿断言,2026-10-21)。
  testWidgets('无身份首配:点选设备发起配对,先停在途扫描(无线电让给握手)',
      (tester) async {
    // TODO(测试基建,2026-10-21):持续扫描循环 + 扫描权状态机落地后,
    // 本用例按新所有权模型重写(Timer 生命周期/挂起让位沿断言)。
  },
      skip: true);

  testWidgets('拆面板废在途重连:退避即刻醒,退避到点也不续跑(取消语义)',
      (tester) async {
    await boot(tester, scanResult: [], saved: identityOf(0x11223301));
    // 打开沿不自动回链:显式点「连接」发起第 1 轮(当时挂的是 boot mock,
    // 未计数);换计数 mock 只盯后续:若无取消语义,2s 退避到点会发第
    // 2 轮,计数必涨。
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.text('连接中…'), findsOneWidget,
        reason: '十轮:重连反馈只在按钮位(名下副文退役;十三轮文案'
            '「连接中…」)');
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
    expect(scanIdCalls, 0, reason: '首轮在点按内已发,计数 mock 从此盯后续');
    await tester.pump(const Duration(milliseconds: 500));
    expect(scanIdCalls, 0, reason: '退避等待期不再扫');
    await disposePage(tester, drain: const Duration(seconds: 3));
    expect(scanIdCalls, 0, reason: '拆面板废在途重连,退避 2s 到点也不续跑');
  });

  group('mergeScanRow(RPA 轮换/缩短名/过期,2026-10-21 实证串)', () {
    final t0 = DateTime(2026, 10, 21, 15);
    final t1 = t0.add(const Duration(seconds: 1));
    const zfa = BleDevice(name: 'Z_f_8014411', uuid: 'RPA-A', rssi: -50);
    const zfb = BleDevice(name: 'Z_f_8014411', uuid: 'RPA-B', rssi: -60);
    const short = BleDevice(name: 'Z_f_', uuid: 'RPA-C', rssi: -55);
    const other = BleDevice(name: 'Z_f_9999999', uuid: 'RPA-D', rssi: -55);
    const anon = BleDevice(name: '', uuid: 'RPA-E', rssi: -70);

    test('RPA 轮换:同机身跨会话按归一化名并一行,地址信号换新', () {
      final rows = mergeScanRow(mergeScanRow([], zfa, t0), zfb, t1);
      expect(rows.length, 1);
      expect(rows.single.device.uuid, 'RPA-B');
      expect(rows.single.seenAt, t1);
    });

    test('缩短名前缀:Z_f_ 遇全名长成全名,地址取最新事件', () {
      final rows = mergeScanRow(mergeScanRow([], zfa, t0), short, t1);
      expect(rows.length, 1); // 不拆行
      expect(rows.single.device.name, 'Z_f_8014411'); // 名取长者
      expect(rows.single.device.uuid, 'RPA-C'); // 地址取最新
      // 反向先后:先短后全,同样长成全名
      final rows2 = mergeScanRow(mergeScanRow([], short, t0), zfa, t1);
      expect(rows2.length, 1);
      expect(rows2.single.device.name, 'Z_f_8014411');
      expect(rows2.single.device.uuid, 'RPA-A');
    });

    test('名写法漂移(空格/下划线)仍合并:归一化键', () {
      const spaced = BleDevice(name: 'Z f 8014411', uuid: 'RPA-F', rssi: -52);
      final rows = mergeScanRow(mergeScanRow([], zfa, t0), spaced, t1);
      expect(rows.length, 1);
      expect(rows.single.device.uuid, 'RPA-F');
    });

    test('不同机身各行;空名独立行不参与前缀合并', () {
      final rows = mergeScanRow(
          mergeScanRow(mergeScanRow([], zfa, t0), other, t0), anon, t1);
      expect(rows.length, 3);
      expect(rows.map((r) => r.device.uuid),
          ['RPA-A', 'RPA-D', 'RPA-E']);
    });

    test('同配对关系(deviceId 相等):无名次要载荷并入有名行,名保留', () {
      Uint8List mfg(int id) => Uint8List.fromList([
            0x99, 0x03, id & 0xFF, (id >> 8) & 0xFF, //
            (id >> 16) & 0xFF, (id >> 24) & 0xFF, 0x1E,
          ]);
      final named = BleDevice(
          name: 'Z_f_8014411', uuid: 'RPA-A', rssi: -50, mfgData: mfg(0x11223344));
      final nameless = BleDevice(
          name: '', uuid: 'RPA-G', rssi: -58, mfgData: mfg(0x11223344));
      final rows = mergeScanRow(mergeScanRow([], named, t0), nameless, t1);
      expect(rows.length, 1);
      expect(rows.single.device.name, 'Z_f_8014411'); // 名保留
      expect(rows.single.device.uuid, 'RPA-G'); // 地址取最新
      // 不同配对关系(别家相机/别的关系)不误并
      final rows2 = mergeScanRow(mergeScanRow([], named, t0),
          BleDevice(name: '', uuid: 'RPA-H', rssi: -58, mfgData: mfg(0x55667788)),
          t1);
      expect(rows2.length, 2);
    });

    test('同键命中优先,行 seenAt 刷新(过期修剪依据)', () {
      final rows = mergeScanRow([], zfa, t0);
      mergeScanRow(rows, zfa, t1);
      expect(rows.single.seenAt, t1);
    });
  });
}

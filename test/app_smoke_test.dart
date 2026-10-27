import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/app.dart';
import 'package:z_pill/app_services.dart';
import 'package:z_pill/platform/gallery_saver.dart';

/// 整棵 UI 树冒烟:真机上"屏幕只打一堆文字"疑似渲染异常,
/// 此处先在本地复现/排除 Widget 层异常。
void main() {
  // 图库 tab 随首屏预建:首次目录扫描走真单例 + 真 dart:IO(2026-10-22
  // refreshAppFiles 异步化)。mock 给真实临时目录(空),扫描链可在
  // runAsync 排水窗内收口(通道错误不落进窗,local_library_page_test
  // 同款)。
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zpill_smoke');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel,
            (call) async => switch (call.method) {
                  'dataDir' || 'previewsDir' || 'downloadsDir' => dir.path,
                  _ => null,
                });
    // 同因:AppServices 装配即 ConnectionController 起 BLE/NSD 两个扫描
    // 事件流,listen 无 mock 即 MissingPluginException,异步错在哪个用例
    // 的排水窗上浮看运气 —— mock 成空应答(冒烟只验渲染,不发事件)
    // 钉死顺序无关(local_library_page_test 同款)。
    for (final name in const ['zpill/ble/events', 'zpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name),
              (call) async => call.method == 'listen' ? '' : null);
    }
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel, null);
    for (final name in const ['zpill/ble/events', 'zpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  // 加高视口:ListView 懒构建,默认 600 逻辑高把页面尾部/设置项
  // 挡在折线下(未 build 即不可断言)。
  Future<void> boot(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ZPillApp());
    // 首扫排水:扫描未收口前图库 tab 在转圈,pumpAndSettle 会挂在动画
    // 帧上 —— 逐窗排水到收口(单例跨用例保值,首用例排水后续直通)。
    final transfers = AppServices.instance.transfersController;
    for (var i = 0; i < 20 && !transfers.appFilesScanned; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('应用骨架整体可渲染(相机 tab 未连接主视图)', (tester) async {
    await boot(tester);

    expect(find.text('相机'), findsWidgets); // AppBar 标题 + 底部 tab
    // 状态行常驻(2026-10-19 改版):圆点+状态词;「当前方式」字样
    // 整删,说明藏方式行 ⓘ 后;方式入口收进右上角弹层。
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('有线'), findsOneWidget); // 方式行(五轮;默认方式 = 有线)
    expect(find.text('连接相机'), findsNothing); // 中央连接钮退役(五轮:点图标连接)
    expect(find.text('当前方式:有线'), findsNothing);
    expect(find.text('扫描相机'), findsNothing); // 扫描钮退役(STA 自动扫)
  });

  // 拍摄页冒烟不在此列:2026-10-08 起拍摄页由相机页已连接视图
  // 「进入拍摄」push 进入,真机无连接不可达;页面级渲染/控件就位
  // 由 remote_page_test 直挂 RemotePage 覆盖。

  testWidgets('图库 tab:空态(非 ohos 环境静默)', (tester) async {
    await boot(tester);

    await tester.tap(find.text('图库'));
    await tester.pumpAndSettle();
    expect(find.text('图库'), findsWidgets); // AppBar + tab
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'),
        findsOneWidget);
  });

  testWidgets('设置 tab:配置项在场', (tester) async {
    await boot(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets); // AppBar + tab
    expect(find.text('自动传输(速传)'), findsOneWidget);
    expect(find.text('水印'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget); // i18n 第一期(2026-10-14)
  });
}

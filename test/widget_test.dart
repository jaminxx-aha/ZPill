import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/app.dart';
import 'package:z_pill/app_services.dart';
import 'package:z_pill/platform/gallery_saver.dart';

void main() {
  // 图库 tab 随首屏预建:首次目录扫描走真单例 + 真 dart:IO(2026-10-22
  // refreshAppFiles 异步化)。mock 给真实临时目录(空),扫描链可在
  // runAsync 排水窗内收口(与 app_smoke_test 同款)。
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zpill_widget');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel,
            (call) async => switch (call.method) {
                  'dataDir' || 'previewsDir' || 'downloadsDir' => dir.path,
                  _ => null,
                });
    // 同因:AppServices 装配即 ConnectionController 起 BLE/NSD 两个扫描
    // 事件流,listen 无 mock 即 MissingPluginException,异步错在哪个用例
    // 的排水窗上浮看运气 —— mock 成空应答(事件流本就不该在壳冒烟里
    // 发事件)钉死顺序无关(local_library_page_test 同款)。
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

  testWidgets('应用启动并渲染底部三 tab', (WidgetTester tester) async {
    // 加高视口:ListView 懒构建,折线下内容未 build 即不可断言。
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ZPillApp());
    // 首扫排水:扫描未收口前图库 tab 在转圈,pumpAndSettle 会挂在动画
    // 帧上 —— 逐窗排水到收口。
    final transfers = AppServices.instance.transfersController;
    for (var i = 0; i < 20 && !transfers.appFilesScanned; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // 底部导航三 tab(拍摄页 2026-10-08 改由相机页「进入拍摄」push
    // 进入):标签文本与页内 AppBar 标题可能重名,故断言 NavigationBar
    // 的目的地而非全局唯一文本。
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final labels = nav.destinations
        .map((d) => (d as NavigationDestination).label)
        .toList();
    expect(labels, ['相机', '图库', '设置']);
    // 初始 tab = 相机:方式行(五轮)+ 状态行 + hero(点按即连接);说明
    // 藏方式行 ⓘ 后;其余方式入口收进右上角弹层不占屏。
    expect(find.text('未连接'), findsOneWidget, reason: '状态行常驻(灰点)');
    expect(find.text('有线'), findsOneWidget, reason: '方式行标题(五轮)');
    expect(find.text('连接相机'), findsNothing,
        reason: '中央连接钮退役(五轮:点图标连接)');
    expect(find.text('当前方式:有线'), findsNothing, reason: '「当前方式」字样整删');
    expect(find.textContaining('C-to-C 数据线直连'), findsNothing,
        reason: '说明藏方式行 ⓘ 后(点 ⓘ 弹窗)');

    // 右上角弹层:方式条目与收放(选中仅切换,真连接冒烟归
    // connection_page_test 假连接;壳冒烟只验条目)。
    await tester.tap(find.byTooltip('选择连接方式'));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsOneWidget);
    expect(find.text('AP 模式'), findsOneWidget);
    expect(find.text('STA 模式'), findsOneWidget);
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('选择连接方式'), findsNothing);

    // 切 STA 模式:原地替换两段列表,进页自动扫描(静默 —— 主机无
    // 插件,扫描失败静默收口;无扫描钮、无「扫描中」指示)。
    await tester.tap(find.byTooltip('选择连接方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STA 模式'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已配对'), findsOneWidget, reason: '两段列表段名');
    expect(find.text('其它设备'), findsOneWidget);
    expect(find.text('扫描相机'), findsNothing, reason: '扫描钮退役');
    expect(find.textContaining('扫描中'), findsNothing, reason: '扫描静默');
  });
}

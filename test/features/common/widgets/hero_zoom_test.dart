import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image/image.dart' as img;

import 'package:nikon_pill/features/common/widgets/hero_zoom.dart';

/// 1×1 PNG(解码必成):梭子层无底,盘档须真图防错误道上翻红屏。
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// 航班配对页:格侧(小)与查看器侧(大)同 tag 同图源。
Widget _page(String label, String thumbPath, double size) => Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(
        child: HeroZoom(
          tag: 't1',
          thumbPath: thumbPath,
          child: FlutterLogo(size: size),
        ),
      ),
    );

/// 梭子 cover 图层(航班在场的标志;格页自身图已被 Hero 占位隐藏,
/// 不计入默认 find)。
Finder shuttleLayers() => find.byWidgetPredicate(
    (w) => w is Image && w.fit == BoxFit.cover);

void main() {
  late Directory tmp;
  late String thumbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nikonpill_hero_zoom');
    thumbPath = '${tmp.path}/thumb.png';
    File(thumbPath).writeAsBytesSync(_tinyPng);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// 泵出「格 → 查看器」推入沿:两次零时程泵(第一帧后航班启动,第二
  /// 帧梭子上屏),动画值仍 0。不预解码 —— 航班用例只断言梭子在场(与
  /// 图比无关);且 runAsync(precache) 会与 pumpWidget 沿 HeroZoom 已
  /// 挂起的解码共用 completer,FakeAsync 队列事件不出窗 = 死锁。
  Future<void> pumpPush(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: _page('grid', thumbPath, 80),
    ));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(
              builder: (_) => _page('viewer', thumbPath, 240)),
        );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('图源提供器与 Image.file(cacheWidth: 300) 同键(航班零重解)',
      (tester) async {
    expect(
      gridThumbImageProvider('/a/b.jpg'),
      ResizeImage(FileImage(File('/a/b.jpg')), width: 300),
    );
  });

  testWidgets('推程:梭子(双 cover 层)在场,落定撤场配对件两枚', (tester) async {
    await pumpPush(tester);
    expect(shuttleLayers(), findsNWidgets(2));

    await tester.pumpAndSettle();
    // 落定:航班梭子撤场,格页与查看器页 HeroZoom 原位(配对件两枚;
    // 下方网格路由 offstage,计数需显式含)。
    expect(shuttleLayers(), findsNothing);
    expect(find.byType(HeroZoom, skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('回程:梭子再入场,落定格页配对件在位', (tester) async {
    await pumpPush(tester);
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump();
    expect(shuttleLayers(), findsNWidgets(2));

    await tester.pumpAndSettle();
    // 落回:查看器出栈,格页配对件在位(航班终点 = 格位)。
    expect(shuttleLayers(), findsNothing);
    expect(find.byType(HeroZoom), findsOneWidget);
  });

  testWidgets('无配对(查看器侧不挂 HeroZoom):推入无航班,原样转场',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: _page('grid', thumbPath, 80),
    ));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('plain')),
                    body: const Center(child: FlutterLogo(size: 240)),
                  )),
        );
    await tester.pump();
    await tester.pump();
    // 无同 tag 配对 → 无梭子。
    expect(shuttleLayers(), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('plain'), findsOneWidget);
  });

  testWidgets('对位回归:推程落点与收程起点 == 图片 contain 显示位(横图)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    // 3:2 横图真档(图比驱显示盒;setUp 共享档是 1×1,比 1 测不出盒)。
    final landPath = '${tmp.path}/land.png';
    File(landPath).writeAsBytesSync(img.encodePng(img.Image(width: 100, height: 60)));

    // 先开窗预解码 300px 档(HeroZoom 图比沿缓存命中同步回),再建真页
    // —— 顺序反了会与 initState 挂起的解码共用 completer 死锁。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final ctx = tester.element(find.byType(SizedBox).first);
    await tester.runAsync(
        () => precacheImage(gridThumbImageProvider(landPath), ctx));

    // 结构同查看器:格页 80² 盒;查看器 aspectBox 定显示盒(100×60 图,
    // 3:2 横)。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('grid')),
        body: Center(
          child: HeroZoom(
            tag: 't',
            thumbPath: landPath,
            child: SizedBox(
              width: 80,
              height: 80,
              child:
                  Image(image: FileImage(File(landPath)), fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).push(
          ZoomPageRoute<void>(
            pageBuilder: (_, __, ___) => Scaffold(
              appBar: AppBar(title: const Text('viewer')),
              body: InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: HeroZoom(
                    tag: 't',
                    thumbPath: landPath,
                    aspectBox: true,
                    child: SizedBox.expand(
                      child: Image(
                          image: FileImage(File(landPath)),
                          fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pump();
    await tester.pump();

    // 推程近端(ZoomPageRoute 无页面变换):时长-20ms 处 ≈ 终点,
    // 终点 = 图片 contain 显示位(字体盒:全屏体宽铺满、垂直居中)。
    await tester.pump(kHeroZoomDuration - const Duration(milliseconds: 20));
    final nearEnd = tester.getRect(shuttleLayers().first);
    await tester.pumpAndSettle();
    final viewerHero =
        find.byWidgetPredicate((w) => w is Hero && w.tag == 't').last;
    final bodyRect = tester.getRect(viewerHero);
    final expected = Rect.fromCenter(
      center: bodyRect.center,
      width: bodyRect.width,
      height: bodyRect.width / (100 / 60),
    );
    debugPrint('[对位回归] body=$bodyRect 终点=$expected 推程近端=$nearEnd');
    expect((nearEnd.top - expected.top).abs() < 2.0, isTrue,
        reason: '推程落点 top:${nearEnd.top} vs ${expected.top}');
    expect((nearEnd.height - expected.height).abs() < 2.0, isTrue,
        reason: '推程落点高:${nearEnd.height} vs ${expected.height}');

    // 收程:起步梭子必须已在显示位(否则「最后再移动一下」)。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump();
    final startRect = tester.getRect(shuttleLayers().first);
    debugPrint('[对位回归] 收程起步=$startRect');
    expect((startRect.top - expected.top).abs() < 2.0, isTrue,
        reason: '收程起点 top:${startRect.top} vs ${expected.top}');
    expect((startRect.height - expected.height).abs() < 2.0, isTrue,
        reason: '收程起点高:${startRect.height} vs ${expected.height}');
    await tester.pumpAndSettle();
  });

  testWidgets('对位回归:角格航班尺寸先行(锚在格位就地放大,中心后到)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final landPath = '${tmp.path}/corner.png';
    File(landPath).writeAsBytesSync(img.encodePng(img.Image(width: 100, height: 60)));

    // 预解码(死锁教训:先开窗,再建真页)。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final ctx = tester.element(find.byType(SizedBox).first);
    await tester.runAsync(
        () => precacheImage(gridThumbImageProvider(landPath), ctx));

    // 格页:左上角格(Align topLeft);查看器同对位回归结构。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('grid')),
        body: Align(
          alignment: Alignment.topLeft,
          child: HeroZoom(
            tag: 'c',
            thumbPath: landPath,
            child: SizedBox(
              width: 80,
              height: 80,
              child:
                  Image(image: FileImage(File(landPath)), fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    tester.state<NavigatorState>(find.byType(Navigator)).push(
          ZoomPageRoute<void>(
            pageBuilder: (_, __, ___) => Scaffold(
              appBar: AppBar(title: const Text('viewer')),
              body: InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: HeroZoom(
                    tag: 'c',
                    thumbPath: landPath,
                    aspectBox: true,
                    child: SizedBox.expand(
                      child: Image(
                          image: FileImage(File(landPath)),
                          fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pump();
    await tester.pump();

    // 25% 行程采样:尺寸进度须显著领先中心进度(锚定 = 就地放大)。
    await tester.pump(kHeroZoomDuration * 0.25);
    final rect = tester.getRect(shuttleLayers().first);
    final sizeP = (rect.width - 80) / (400 - 80);
    final beginCenter = const Offset(40, 96); // 左上格中心(56+80/2)
    final endCenter = const Offset(200, 328); // 显示盒中心(56+(600-56)/2? 见下)
    // 显示盒 = (0,208)-(400,448),中心 (200,328)。
    final centerP =
        ((rect.center - beginCenter).distance) / ((endCenter - beginCenter).distance);
    debugPrint('[对位回归] 角格25% rect=$rect sizeP=$sizeP centerP=$centerP');
    expect(sizeP, greaterThan(centerP + 0.15),
        reason: '尺寸须先行于中心(锚定读感);sizeP=$sizeP centerP=$centerP');
    // 起点仍在格位(两线都从 0 起)。
    expect(sizeP, greaterThan(0.4));
    expect(centerP, lessThan(0.5));
    await tester.pumpAndSettle();
  });
}

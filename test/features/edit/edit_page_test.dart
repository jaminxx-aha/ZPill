import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/ptpip/object_format.dart' show ObjectKind;
import 'package:nikon_pill/features/common/widgets/states.dart';
import 'package:nikon_pill/features/edit/edit_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver()
      : root = Directory.systemTemp.createTempSync('nikonpill_edit_test');

  final Directory root;
  final List<List<GalleryImportRequest>> importCalls = [];
  final List<Uint8List> importedBytes = [];
  List<Uri> importResult = const [];

  @override
  Future<String> dataDir() async => _ensure('${root.path}/data');

  @override
  Future<String> tempDir() async => _ensure('${root.path}/temp');

  @override
  Future<String> thumbsDir() async => _ensure('${root.path}/thumbs');

  @override
  Future<String> previewsDir() async => _ensure('${root.path}/previews');

  @override
  Future<String> downloadsDir() async => _ensure('${root.path}/downloads');

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async {
    importCalls.add(List.of(requests));
    // 临时文件在导入返回后即被页面删除,断言输出内容须当场抓字节。
    importedBytes
        .addAll([for (final r in requests) File(r.path).readAsBytesSync()]);
    return importResult;
  }

  static Future<String> _ensure(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return path;
  }
}

Uint8List _jpeg({int w = 80, int h = 60}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1), 128, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 纯色图:保存产物走 JPEG 往返,纯色压缩噪声最小、期望值可手算。
Uint8List _solidJpeg(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

IconButton _iconButton(WidgetTester tester, IconData icon) =>
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

bool _saveEnabled(WidgetTester tester) =>
    _iconButton(tester, Icons.save_outlined).onPressed != null;

bool _resetEnabled(WidgetTester tester) =>
    _iconButton(tester, Icons.restart_alt).onPressed != null;

Future<void> _pumpPage(
  WidgetTester tester, {
  required FakeGallerySaver gallery,
  Uint8List? jpeg,
  String filename = 'DSC_1234.jpg',
  Finder? bootTerminus,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: EditPage(
      jpeg: jpeg ?? _jpeg(),
      filename: filename,
      gallery: gallery,
    ),
  ));
  await tester.pump();
  await _drainBoot(tester, bootTerminus ?? find.byType(Image));
}

/// 引导/渲染完成回调只在 runAsync 窗口上浮(真异步出窗,见 _drainSave
/// 注),逐窗循环到终态出现为止;50 窗预算防意外挂死。
Future<void> _drainBoot(WidgetTester tester, Finder terminus) async {
  for (var i = 0; i < 50; i++) {
    if (terminus.evaluate().isNotEmpty) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump();
  }
  fail('编辑页引导未在窗口预算内落定: $terminus');
}

/// 返回保护用例的落地:根页 + push 编辑页(编辑页实际总是被 push 进
/// 栈,顶栏返回钮才在场;MaterialApp home 单路由无返回钮)。
Future<void> _pumpPushed(WidgetTester tester,
    {required FakeGallerySaver gallery}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EditPage(
                jpeg: _jpeg(),
                filename: 'DSC_1234.jpg',
                gallery: gallery,
              ),
            )),
            child: const Text('打开编辑'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开编辑'));
  // 引导期页面驻留 LoadingState(spinner 常动),pumpAndSettle 永不结算:
  // 定帧过完页面过渡 + 排水等引导落定。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await _drainBoot(tester, find.byType(Image));
}

/// compute 隔离 + 真实文件 IO 都挂在真实事件循环上,而 fake zone 的
/// 微任务只在 pump 时刷 —— 每个真实落点都要「runAsync 窗口 + pump」
/// 一轮。循环推进到相册导入落地且保存转圈消失;末尾不能用
/// pumpAndSettle(SnackBar 入场后无动画,但若链路意外卡死会撞上
/// 转圈动画的无限帧)。
Future<void> _drainSave(WidgetTester tester, FakeGallerySaver gallery) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    if (gallery.importCalls.isNotEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场
}

void main() {
  testWidgets('初始:标题为文件名,预览渲染,保存/重置禁用', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery, filename: 'DSC_0001.jpg');
    expect(find.text('DSC_0001.jpg'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // 预览在构造器里同步烘出:就绪即无空态/加载态闪现。
    expect(find.byType(EmptyState), findsNothing);
    expect(find.byType(LoadingState), findsNothing);
    expect(_saveEnabled(tester), isFalse);
    expect(_resetEnabled(tester), isFalse);
  });

  testWidgets('非 JPEG:统一空态提示不可编辑,无预览', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester,
        gallery: gallery,
        jpeg: Uint8List.fromList([1, 2, 3, 4, 5]),
        bootTerminus: find.byType(EmptyState));
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('无法编辑此文件(仅支持 JPEG)'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('旋转:右转使能保存,重置回中性再禁用', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.text('右转 90°'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);
    expect(_resetEnabled(tester), isTrue);

    await tester.tap(find.byTooltip('重置'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('调节:滑条拖动松手才生效', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('调节'));
    await tester.pump();

    // 拖动亮度滑条(第一行)到右端。
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    final rect = tester.getRect(find.byType(Slider).first);
    expect(_saveEnabled(tester), isFalse);
    await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
    await tester.pump();
    // onChangeEnd 在 tap 手势结束后触发。
    expect(slider, isNotNull);
    expect(_saveEnabled(tester), isTrue);
  });

  testWidgets('LUT:内置风格使能保存;选「无」回到禁用', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('LUT'));
    await tester.pump();
    expect(find.text('青橙'), findsOneWidget);

    await tester.tap(find.text('青橙'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);

    await tester.tap(find.widgetWithText(ChoiceChip, '无'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('LUT:剪贴板导入成功加芯片;坏文本给失败提示', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('LUT'));
    await tester.pump();

    const cube = 'TITLE "pos"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n'
        '0 0 1\n1 0 1\n0 1 1\n1 1 1\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': cube} : null,
    );
    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pump();
    expect(find.text('已导入「pos」(2³)'), findsOneWidget);
    expect(find.text('pos'), findsOneWidget);
    expect(_saveEnabled(tester), isTrue);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': '垃圾'} : null,
    );
    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pump();
    expect(find.textContaining('导入失败'), findsOneWidget);
  });

  testWidgets('LUT:XMP 剪贴板导入走 RGBTable 链;坏 XMP 给失败提示', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('LUT'));
    await tester.pump();

    // 属性式 XMP + 一条 N=2 全零增量表(向量语义见
    // test/core/media/xmp_rgb_table_test.dart,此处只验挂点接线)。
    const xmp = '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n'
        '          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">\n'
        '  <rdf:Description rdf:about="" crs:RGBTable="t"'
        ' crs:Table_t=":0000OcImwM!emwO1/)wKOJQvZ2100H6SM2"/>\n'
        ' </rdf:RDF>\n'
        '</x:xmpmeta>\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': xmp} : null,
    );
    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pump();
    expect(find.text('已导入「XMP LUT」(2³)'), findsOneWidget);
    expect(find.text('XMP LUT'), findsOneWidget);
    expect(_saveEnabled(tester), isTrue);

    // 有 XMP 标记但表数据是垃圾:走 XMP 分支照样 FormatException。
    const badXmp =
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n <rdf:RDF xmlns:rdf="r">\n'
        '  <rdf:Description rdf:about="" crs:Table_x=",;;,"/>\n'
        ' </rdf:RDF>\n</x:xmpmeta>\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': badXmp} : null,
    );
    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pump();
    expect(find.textContaining('导入失败'), findsOneWidget);
  });

  testWidgets('裁剪:进入模式 → 应用落参数;取消不落', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);

    await tester.tap(find.byTooltip('裁剪'));
    await tester.pump();
    expect(find.text('应用'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse); // 取消:无参数落下

    await tester.tap(find.byTooltip('裁剪'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue); // 0.05..0.95 非全幅

    await tester.tap(find.byTooltip('重置'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('保存:渲染落盘 → 相册导入 → 清临时 → 成功提示', (tester) async {
    final gallery = FakeGallerySaver()
      ..importResult = [Uri.parse('file:///saved/1.jpg')];
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.text('右转 90°'));
    await tester.pump();

    await tester.tap(find.byTooltip('保存到相册'));
    await tester.pump(); // 转圈
    await _drainSave(tester, gallery);

    expect(gallery.importCalls.length, 1);
    final req = gallery.importCalls.single.single;
    expect(req.filename, 'DSC_1234_edit.jpg');
    expect(req.kind, ObjectKind.image);
    // 临时文件导入后即删
    final temp = Directory('${gallery.root.path}/temp');
    expect(temp.listSync().whereType<File>(), isEmpty);
    expect(find.text('已保存到相册'), findsOneWidget);
  });

  testWidgets('保存取消(相册返回空):提示未保存', (tester) async {
    final gallery = FakeGallerySaver(); // importResult = []
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.text('左转 90°'));
    await tester.pump();

    await tester.tap(find.byTooltip('保存到相册'));
    await tester.pump();
    await _drainSave(tester, gallery);

    expect(gallery.importCalls.length, 1);
    expect(find.text('未保存(已取消)'), findsOneWidget);
  });

  group('返回保护', () {
    testWidgets('脏态:返回被拦,弹丢弃确认', (tester) async {
      final gallery = FakeGallerySaver();
      await _pumpPushed(tester, gallery: gallery);
      await tester.tap(find.text('右转 90°'));
      await tester.pump();
      expect(_saveEnabled(tester), isTrue); // 脏

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byType(EditPage), findsOneWidget); // 被拦未退
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('放弃修改?'), findsOneWidget);
      expect(find.text('未保存的修改将会丢失'), findsOneWidget);
    });

    testWidgets('确认丢弃:直接退出回根页', (tester) async {
      final gallery = FakeGallerySaver();
      await _pumpPushed(tester, gallery: gallery);
      await tester.tap(find.text('右转 90°'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();

      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(EditPage), findsNothing);
      expect(find.text('打开编辑'), findsOneWidget); // 回到根页
    });

    testWidgets('取消:留在编辑页,参数不丢', (tester) async {
      final gallery = FakeGallerySaver();
      await _pumpPushed(tester, gallery: gallery);
      await tester.tap(find.text('右转 90°'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(EditPage), findsOneWidget);
      expect(_saveEnabled(tester), isTrue); // 旋转参数仍在
    });

    testWidgets('保存成功:复位不脏,退出不再弹确认', (tester) async {
      final gallery = FakeGallerySaver()
        ..importResult = [Uri.parse('file:///saved/1.jpg')];
      await _pumpPushed(tester, gallery: gallery);
      await tester.tap(find.text('右转 90°'));
      await tester.pump();
      await tester.tap(find.byTooltip('保存到相册'));
      await tester.pump(); // 转圈
      await _drainSave(tester, gallery);
      expect(_saveEnabled(tester), isFalse); // 保存成功沿复位

      // await 落点后先泵一帧再交互(工程规律:直接 tap 会静默丢)。
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing); // 不弹确认
      expect(find.byType(EditPage), findsNothing); // 直接退出
    });
  });

  testWidgets('保存:所选 LUT 烘焙进输出文件(剪贴板导入反色表)', (tester) async {
    final gallery = FakeGallerySaver()
      ..importResult = [Uri.parse('file:///saved/1.jpg')];
    // 纯色 (200,100,50) → 反色 (55,155,205)。
    await _pumpPage(tester,
        gallery: gallery, jpeg: _solidJpeg(80, 60, 200, 100, 50));

    await tester.tap(find.byTooltip('LUT'));
    await tester.pump();
    const invCube = 'TITLE "inv"\nLUT_3D_SIZE 2\n'
        '1 1 1\n0 1 1\n1 0 1\n0 0 1\n1 1 0\n0 1 0\n1 0 0\n0 0 0\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': invCube} : null,
    );
    await tester.tap(find.text('从剪贴板导入 .cube/.xmp'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue); // 导入即选中

    await tester.tap(find.byTooltip('保存到相册'));
    await tester.pump();
    await _drainSave(tester, gallery);

    expect(gallery.importCalls.length, 1);
    final decoded = img.decodeJpg(gallery.importedBytes.single)!;
    expect(decoded.width, 80); // 原分辨率保存(预览档是缩小图)
    expect(decoded.height, 60);
    final p = decoded.getPixel(0, 0);
    expect(p.r, inInclusiveRange(40, 70));
    expect(p.g, inInclusiveRange(140, 170));
    expect(p.b, inInclusiveRange(190, 220));
  });

  testWidgets('胶片:分组筛选换芯片集,选中使能保存,「无」回禁用', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('胶片'));
    await tester.pump();

    // 默认组=富士胶片;芯片行横向懒加载,只断言视口内已构建的芯片。
    expect(find.text('PROVIA 标准'), findsOneWidget);
    expect(find.text('GR 正片'), findsNothing); // 理光组,不在默认组

    await tester.tap(find.text('经典正片'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);

    // 切组:富士芯片换理光芯片,已选预设保留(保存仍使能)。
    await tester.tap(find.text('理光人文'));
    await tester.pump();
    expect(find.text('GR 正片'), findsOneWidget);
    expect(find.text('经典正片'), findsNothing);
    expect(_saveEnabled(tester), isTrue);

    await tester.tap(find.widgetWithText(ChoiceChip, '无'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('胶片:重置收走预设(保存回禁用)', (tester) async {
    final gallery = FakeGallerySaver();
    await _pumpPage(tester, gallery: gallery);
    await tester.tap(find.byTooltip('胶片'));
    await tester.pump();
    await tester.tap(find.text('PROVIA 标准'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);

    await tester.tap(find.byTooltip('重置'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('保存:所选胶片矩阵烘焙进输出文件(经典正片手调矩阵)', (tester) async {
    final gallery = FakeGallerySaver()
      ..importResult = [Uri.parse('file:///saved/1.jpg')];
    // 纯色 (200,100,50) → classicChrome 手调矩阵 → (208,96,48)。
    await _pumpPage(tester,
        gallery: gallery, jpeg: _solidJpeg(80, 60, 200, 100, 50));

    await tester.tap(find.byTooltip('胶片'));
    await tester.pump();
    await tester.tap(find.text('经典正片'));
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);

    await tester.tap(find.byTooltip('保存到相册'));
    await tester.pump(); // 转圈
    await _drainSave(tester, gallery);

    expect(gallery.importCalls.length, 1);
    final decoded = img.decodeJpg(gallery.importedBytes.single)!;
    expect(decoded.width, 80); // 原分辨率保存(预览档是缩小图)
    expect(decoded.height, 60);
    final p = decoded.getPixel(0, 0);
    // r'=1.08*200-0.05*100-0.03*50-2=207.5→208;两轮 JPEG 往返,容差 ±15。
    expect(p.r, inInclusiveRange(193, 223));
    expect(p.g, inInclusiveRange(81, 111));
    expect(p.b, inInclusiveRange(33, 63));
  });
}

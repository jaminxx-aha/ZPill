import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/library/local_library_page.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/raw_decoder.dart';
import 'package:nikon_pill/platform/video_player.dart';

/// 伪相册服务:downloadsDir 指向临时目录,importFiles 落账可断言;
/// thumbsDir 用独立子目录(NEF 网格缩略落盘,不污染 downloadsDir 清单)。
final class _FakeGallery implements GallerySaver {
  _FakeGallery(this.dir);

  final Directory dir;
  late final Directory thumbs = Directory('${dir.path}/_thumbs')
    ..createSync();
  final importCalls = <List<GalleryImportRequest>>[];
  List<Uri> importResult = [Uri.parse('content://media/1')];

  @override
  Future<String> downloadsDir() async => dir.path;

  @override
  Future<String> tempDir() async => dir.path;

  @override
  Future<String> thumbsDir() async => thumbs.path;

  @override
  Future<String> previewsDir() async => dir.path;

  @override
  Future<String> dataDir() async => dir.path;

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async {
    importCalls.add(requests);
    return importResult;
  }
}

/// 伪 RAW 解码器:记录 (路径, 长边上限) 调用;fail = 模拟无解码器/失败。
final class _FakeRawDecoder implements RawDecoder {
  _FakeRawDecoder({this.fail = false});

  final bool fail;
  final calls = <(String, int)>[];

  @override
  Future<Uint8List> decodeJpeg(String path, {required int maxPixelSize}) async {
    calls.add((path, maxPixelSize));
    if (fail) {
      throw const FormatException('无解码器');
    }
    // 假 JPEG(SOI+EOI):Image 解码失败走 errorBuilder,但组件与
    // 落盘路径可断言。
    return Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]);
  }
}

/// 伪播放器:记录播放路径与速率;抽帧 [failThumbs] 默认失败(= 无抽帧回落
/// 图标格,与生产 Android/ohos 无通道同形),海报帧用例置 false;
/// [frameRateOf] 供顺帧用例注入帧率。
final class _FakeVideoPlayer implements VideoPlayer {
  _FakeVideoPlayer({this.failThumbs = true, this.frameRateOf});

  final bool failThumbs;
  final double? Function(String path)? frameRateOf;
  final played = <(String, double)>[];
  final thumbs = <(String, int)>[];

  @override
  Future<void> play(String path, {double rate = 1.0}) async {
    played.add((path, rate));
  }

  @override
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize}) async {
    thumbs.add((path, maxPixelSize));
    if (failThumbs) {
      throw const FormatException('无抽帧');
    }
    return Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]);
  }

  @override
  Future<double?> frameRate(String path) async =>
      frameRateOf == null ? null : frameRateOf!(path);
}

/// 任务流由测试驱动的伪引擎(sync 广播:事件在 add 时刻同步送达,
/// 不错过首帧 —— 同 photo_grid 测试的 _FakeRepo 约定)。
final class _FakeEngine implements TransferEngine {
  final tasksCtrl = StreamController<List<TransferTask>>.broadcast(sync: true);

  @override
  Stream<List<TransferTask>> get tasks => tasksCtrl.stream;

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {}

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nikonpill_library');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  File writeFile(String name, {DateTime? modified}) {
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync([1, 2, 3]);
    if (modified != null) {
      f.setLastModifiedSync(modified);
    }
    return f;
  }

  Widget host(_FakeGallery gallery, TransfersController controller,
          {RawDecoder? rawDecoder, VideoPlayer? videoPlayer}) =>
      MaterialApp(
          home: LocalLibraryPage(
        controller: controller,
        gallery: gallery,
        rawDecoder: rawDecoder ?? _FakeRawDecoder(fail: true),
        videoPlayer: videoPlayer ?? _FakeVideoPlayer(),
      ));

  testWidgets('空态:应用内还没有文件', (tester) async {
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    expect(find.text('图库'), findsOneWidget); // AppBar
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'), findsOneWidget);
  });

  testWidgets('网格:修改时间倒序;可解码图片铺格,NEF 落图标格', (tester) async {
    // a.jpg(最旧)/ b.jpg / c.nef(最新)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.nef', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    // 两张可解码图片(Image.file;内容非图走 errorBuilder,组件仍在)
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('NEF'), findsOneWidget); // 原生格式落图标格

    // 点最新图片进查看器(倒序:图片格里第一张是 b.jpg)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsWidgets); // 查看器 AppBar 标题
  });

  testWidgets('格式过滤:RAW/JPG/视频 chips 按扩展名收窄网格', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.nef', modified: DateTime(2026, 10, 2));
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    // 全部:一张可解码图 + NEF 图标格 + MOV 图标格(摄像机图标)
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

    await tester.tap(find.text('RAW'));
    await tester.pumpAndSettle();
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });

  testWidgets('过滤无匹配:提示该格式暂无,切回全部即恢复', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.text('没有视频格式的文件'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('查看器:导入系统相册(kind 按扩展名)→ 相册服务落账', (tester) async {
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导入系统相册'));
    await tester.pumpAndSettle();

    final calls = gallery.importCalls;
    expect(calls, hasLength(1));
    expect(calls.single.single.filename, 'b.jpg');
    expect(calls.single.single.kind, ObjectKind.image);
    expect(find.text('已导入系统相册(应用内文件保留)'), findsOneWidget);
    // 文件本体保留(导入是复制不是移动)
    expect(File('${dir.path}/b.jpg').existsSync(), isTrue);

    // 冲掉 snackbar 的自动消失 timer(不能留 pending 到测试末)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('长按删除:确认对话框把关,删后网格收缩', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));

    await tester.longPress(find.byType(Image).first); // b.jpg(最新在前)
    await tester.pumpAndSettle();
    expect(find.text('删除应用内文件?'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(File('${dir.path}/b.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/a.jpg').existsSync(), isTrue); // 相邻不受牵连
    // file.delete() 是真异步 I/O:FakeAsync 域里完成回调不上浮(文件已
    // 删但 refreshAppFiles 不会跑),runAsync 放行真实事件循环后网格才收。
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('传输徽标:进行中任务数角标;点击进传输页', (tester) async {
    final gallery = _FakeGallery(dir);
    final engine = _FakeEngine();
    final controller = TransfersController(engine: engine, gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing); // 无任务无角标

    engine.tasksCtrl.add([
      const TransferTask(
          id: 't1',
          handle: 1,
          filename: 'DSC_0001.JPG',
          totalBytes: 100,
          destination: TransferDestination.app,
          state: TransferState.running,
          receivedBytes: 10),
    ]);
    await tester.pump();
    expect(find.text('1'), findsOneWidget); // 徽标亮起

    await tester.tap(find.byIcon(Icons.swap_vert));
    await tester.pumpAndSettle();
    // 传输页(真单例控制器,任务列表空态)
    expect(find.text('传输'), findsOneWidget);
    expect(find.text('暂无传输任务\n(在相机相册里多选或大图页单张下载)'), findsOneWidget);
  });

  // ── NEF/视频可看可点(2026-10-09 补齐:原生格式不再只落图标格) ──

  testWidgets('NEF:网格缩略解码落盘,点进查看器解码大图', (tester) async {
    writeFile('c.nef', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final decoder = _FakeRawDecoder();
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await tester.pumpAndSettle();

    // 网格缩略:512px 解码一次(会话内合并),落盘 thumbsDir
    // (内容键 + lib_ 前缀,不与相机侧缩略键串台)。
    expect(decoder.calls, [('${dir.path}/c.nef', 512)]);
    expect(
        File('${gallery.thumbs.path}/lib_c.nef_3.jpg').existsSync(), isTrue);

    // 点 NEF 格进查看器:标题 + 2560px 全尺寸解码(假 JPEG 解不开走
    // errorBuilder,Image 组件在即可)。格键 = 文件名(缩略解码后
    // 图标格文案不再保证在场,按格点)。
    await tester.tap(find.byKey(const ValueKey('c.nef')));
    await tester.pumpAndSettle();
    expect(find.text('c.nef'), findsWidgets); // 查看器 AppBar
    expect(decoder.calls.last, ('${dir.path}/c.nef', 2560));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('NEF 无解码器:网格图标格顶位,查看器报错占位', (tester) async {
    writeFile('c.nef', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    // host 缺省注入 failing 解码器。
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    expect(find.text('NEF'), findsOneWidget); // 图标格
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('NEF'));
    await tester.pumpAndSettle();
    expect(find.text('RAW 解码失败(该平台可能不支持)'), findsOneWidget);
  });

  testWidgets('MOV:查看器播放钮 → 原生播放,应用内档保留', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer();
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.videocam_outlined));
    await tester.pumpAndSettle();
    expect(find.text('c.mov'), findsWidgets); // 查看器 AppBar
    expect(find.byIcon(Icons.play_arrow), findsOneWidget); // 播放钮

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.played, [('${dir.path}/c.mov', 1.0)]);
    // 应用内常驻档:播完不删(与相机相册临时下载播放不同)
    expect(File('${dir.path}/c.mov').existsSync(), isTrue);
  });

  testWidgets('MOV:高帧率先问顺帧,24fps 档按 0.4 播', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(frameRateOf: (_) => 60);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.videocam_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 顺帧门:未选不起播
    expect(find.text('高帧率素材'), findsOneWidget);
    expect(player.played, isEmpty);

    await tester.tap(find.text('24fps 顺帧 · 40%'));
    await tester.pumpAndSettle();
    expect(player.played, [('${dir.path}/c.mov', 0.4)]);
    // 常驻档保留
    expect(File('${dir.path}/c.mov').existsSync(), isTrue);
  });

  testWidgets('MOV:网格海报帧抽帧落盘,查看器共用缓存不重复抽', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(failThumbs: false);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await tester.pumpAndSettle();

    // 抽帧一次(会话内合并),落盘 thumbsDir(lib_ 前缀内容键,与
    // NEF 同管线)。假 JPEG 解不开走 errorBuilder,按格键点进。
    expect(player.thumbs, [('${dir.path}/c.mov', 512)]);
    expect(
        File('${gallery.thumbs.path}/lib_c.mov_3.jpg').existsSync(), isTrue);

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    // 查看器海报帧走页面级缓存:不重复抽帧,播放钮在场。
    expect(player.thumbs, hasLength(1));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.played, [('${dir.path}/c.mov', 1.0)]);
  });
}

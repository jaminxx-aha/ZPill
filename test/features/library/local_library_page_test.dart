import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/library/local_library_page.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

/// 伪相册服务:downloadsDir 指向临时目录,importFiles 落账可断言。
final class _FakeGallery implements GallerySaver {
  _FakeGallery(this.dir);

  final Directory dir;
  final importCalls = <List<GalleryImportRequest>>[];
  List<Uri> importResult = [Uri.parse('content://media/1')];

  @override
  Future<String> downloadsDir() async => dir.path;

  @override
  Future<String> tempDir() async => dir.path;

  @override
  Future<String> thumbsDir() async => dir.path;

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

  Widget host(_FakeGallery gallery, TransfersController controller) =>
      MaterialApp(
          home: LocalLibraryPage(controller: controller, gallery: gallery));

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
}

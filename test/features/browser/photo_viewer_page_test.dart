import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/browser/photo_viewer_page.dart';
import 'package:nikon_pill/features/common/widgets/embedded_video_player.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/video_player.dart';

/// 假缩略图:即时返回路径(文件不存在 → Image.file 走占位,无动画挂起)。
final class _FakeThumbs implements ThumbnailCache {
  final warmed = <ObjectEntry>[];

  @override
  int get previewMaxPixelSize => 2560;

  @override
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) async =>
      '/tmp/nikonpill_test_preview_${entry.handle}.jpg';

  @override
  void reset() {}

  @override
  Stream<PreviewUpgrade> get previewUpgrades => const Stream.empty();

  @override
  Future<void> warmPreview(ObjectEntry entry) async {
    warmed.add(entry);
  }

  @override
  int get gridLimitBytes => 0;

  @override
  int get previewLimitBytes => 0;
}

/// 记录入队调用的假引擎。
final class _FakeEngine implements TransferEngine {
  final List<(List<ObjectEntry>, TransferDestination)> calls = [];

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {
    calls.add((entries.toList(growable: false), destination));
  }

  @override
  Stream<List<TransferTask>> get tasks => const Stream.empty();

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

/// 假下载器:真实落一个临时文件(视频页 keep-alive 存活期要持有它);
/// [gate] 挂住进度供取消路径摆拍;取消位照 [DownloadCancelledException]
/// 语义抛。
final class _FakeDownloader implements ObjectDownloader {
  final List<(ObjectEntry, String)> calls = [];
  bool failNext = false;
  Completer<void>? gate;

  @override
  int? get partialChunkBytes => null;

  @override
  Future<ObjectDownload> download(
    ObjectEntry entry, {
    required String targetDir,
    void Function(int receivedBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls.add((entry, targetDir));
    if (gate != null) {
      await gate!.future;
    }
    if (isCancelled != null && isCancelled()) {
      throw const DownloadCancelledException();
    }
    if (failNext) {
      failNext = false;
      throw const FormatException('假下载失败');
    }
    final path = '$targetDir/${entry.name}';
    File(path).writeAsBytesSync(List.filled(8, 1));
    onProgress?.call(entry.sizeInBytes);
    return ObjectDownload(
        path: path,
        bytes: entry.sizeInBytes,
        elapsed: Duration.zero,
        averageBytesPerSecond: 1);
  }
}

/// 伪播放器(内嵌人设 = iOS):load/viewControl 落账,viewStatus 由
/// viewControl 驱动像真播放器 —— 值不变才不重绘,FakeAsync 里
/// pumpAndSettle 才能收。play 老路留落账(新实现不应再调)。
final class _FakeVideoPlayer implements VideoPlayer {
  _FakeVideoPlayer({this.frameRateOf, this.embedded = true});

  /// 帧率探测(按路径;null = 探测不到)。
  final double? Function(String path)? frameRateOf;
  final bool embedded;

  final played = <(String, double)>[];
  final loads = <(int, String)>[];
  final viewControls = <(int, bool, double)>[];
  final viewStates =
      <int, ({double position, double duration, bool playing})>{};

  @override
  bool get supportsEmbeddedView => embedded;

  @override
  Future<void> play(String path, {double rate = 1.0}) async {
    played.add((path, rate));
  }

  @override
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize}) async {
    throw UnimplementedError();
  }

  @override
  Future<double?> frameRate(String path) async =>
      frameRateOf == null ? null : frameRateOf!(path);

  @override
  Future<void> loadEmbeddedView(int viewId, String path) async {
    loads.add((viewId, path));
  }

  @override
  Future<void> controlEmbeddedView(int viewId,
      {required bool playing, required double rate}) async {
    viewControls.add((viewId, playing, rate));
    final s = viewStates[viewId];
    viewStates[viewId] = (
      position: s?.position ?? 0.0,
      duration: s?.duration ?? 60.0,
      playing: playing,
    );
  }

  @override
  Future<({double position, double duration, bool playing})>
      embeddedViewStatus(int viewId) async =>
          viewStates[viewId] ??
          (position: 0.0, duration: 60.0, playing: false);

  @override
  Future<void> seekEmbeddedView(int viewId, {required double position}) async {}
}

/// 假内嵌视频视图:占位盒 + 微任务里回 onCreated(固定 viewId 7)。
/// 不建真平台视图(Widget 测试环境造不出;生产行为装机验)。
final class _StubVideoView extends StatefulWidget {
  const _StubVideoView({required this.onCreated});

  final void Function(int viewId) onCreated;

  @override
  State<_StubVideoView> createState() => _StubVideoViewState();
}

final class _StubVideoViewState extends State<_StubVideoView> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() => widget.onCreated(7));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// 假相册:视频播放只用到 tempDir,其余照抛。
final class _FakeGallery implements GallerySaver {
  final Directory temp = Directory.systemTemp.createTempSync('nikonpill_test_viewer');

  @override
  Future<String> tempDir() async => temp.path;

  @override
  Future<String> dataDir() async => throw UnimplementedError();

  @override
  Future<String> thumbsDir() async => throw UnimplementedError();

  @override
  Future<String> previewsDir() async => throw UnimplementedError();

  @override
  Future<String> downloadsDir() async => throw UnimplementedError();

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async =>
      throw UnimplementedError();
}

ObjectEntry _file(int handle, String name,
        {int format = 0x3801, ObjectKind kind = ObjectKind.image}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 8,
      kind: kind,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 1, 12),
      formatCode: format,
    );

PhotoGroup _videoGroup() => PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);

/// 推入查看器路由(home 直挂是栈底路由没有返回钮,pageBack 无从收)。
/// 路由动画收口后返回。
Future<void> _openViewer(WidgetTester tester, PhotoViewerPage page) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => page)),
        child: const Text('打开查看器'),
      ),
    ),
  ));
  await tester.tap(find.text('打开查看器'));
  await tester.pumpAndSettle();
}

/// 内嵌人设的视图构建(假视图回 viewId 7)。
EmbeddedVideoViewBuilder get _stubView =>
    (path, onCreated) => _StubVideoView(onCreated: onCreated);

/// 结束前冲掉 snackbar 的 4s 自动消失 timer(不能留 pending 到测试末)。
Future<void> _drainSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// 等真 IO(临时档删除)落地:pumpAndSettle 无帧可泵会提前返回,
/// runAsync 里轮询。
Future<void> _waitFileGone(WidgetTester tester, String path) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 100 && File(path).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
}

/// 真机手指式拖动翻页:多帧小步位移(单步大位移会先触发
/// InteractiveViewer 的 36px pan slop 被缩放认领,翻页不动;且
/// PageScrollPhysics 须拖距过半屏 + slop,800px 视口须 600px)。
Future<void> _dragLikeFinger(WidgetTester tester, Offset offset) async {
  final gesture =
      await tester.startGesture(tester.getCenter(find.byType(PageView)));
  final steps = (offset.distance / 10).ceil();
  final step = offset / steps.toDouble();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step);
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 播放中控制浮层 3s 自动隐:先把隐藏计时走完(pumpAndSettle 只推进
/// 有帧的时钟,纯 timer 不动),浮层隐掉后点画面唤回,再点浮层上的
/// 控件 —— 直接点会砸在中键播放钮上变成暂停。
/// (调用前提:视频在播 —— 隐藏计时只有播放中才会武装。)
Future<void> _revealControls(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4)); // 3s 隐藏计时落地
  await tester.tapAt(tester.getCenter(find.byType(PageView)));
  await tester.pump(const Duration(milliseconds: 250)); // 180ms 淡入
}

void main() {
  testWidgets('双格式组:下载前弹格式选择,仅 RAW 只入队 NEF', (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.JPG'),
      _file(102, 'DSC_0001.NEF', format: 0x3000),
    ]);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: engine,
        ));

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsOneWidget);
    expect(find.text('这张照片有 JPG 和 RAW 两份文件'), findsOneWidget);

    await tester.tap(find.text('仅 RAW'));
    await tester.pumpAndSettle();

    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'DSC_0001.NEF');
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('已开始下载到相册(RAW)'), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('单格式组:不弹面板直接整组入队', (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([_file(101, 'IMG_0101.JPG')]);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: engine,
        ));

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing);
    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'IMG_0101.JPG');
    expect(destination, TransferDestination.gallery);

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:点播放 → 准备播放进度 → 下载完成页内起播(装载即播,'
      '不再推全屏播放器)', (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer();
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    // 海报 + 播放钮(不自动播:未点播放前无内嵌装载)
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(player.loads, isEmpty);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 拉取完成:进度对话框已收,内嵌播放器页内起播(点播放已是意图)
    expect(find.text('准备播放'), findsNothing);
    final (entry, dir) = downloader.calls.single;
    expect(entry.name, 'DSC_0001.MOV');
    expect(dir, gallery.temp.path);
    expect(player.loads, [(7, '${gallery.temp.path}/DSC_0001.MOV')]);
    expect(player.viewControls, isNotEmpty);
    expect(player.viewControls.last, (7, true, 1.0)); // autoplay + 实时
    expect(player.played, isEmpty); // 旧全屏播放路不再走
    // 播放中:临时档还在(keep-alive 页持有)
    expect(File(player.loads.single.$2).existsSync(), isTrue);

    // 收查看器 → 临时档删
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _waitFileGone(tester, player.loads.single.$2);
    expect(File(player.loads.single.$2).existsSync(), isFalse);
  });

  testWidgets('视频组:高帧率浮顺帧开关(非阻塞,点了才变速静音)',
      (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer(frameRateOf: (_) => 60);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 不再弹「实时/顺帧」二选一:直接实时起播,开关浮在底行上方
    expect(find.text('高帧率素材'), findsNothing);
    expect(player.viewControls.last, (7, true, 1.0));
    expect(find.text('24fps 顺帧'), findsOneWidget);

    // 播放中浮层 3s 自动隐:点画面唤回,再点顺帧开关 → 变速到 24/60
    await _revealControls(tester);
    await tester.tap(find.text('24fps 顺帧'));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, true, 0.4)); // 24/60
  });

  testWidgets('视频组:取消拉取 → 弹「已取消」,回播放钮不装载',
      (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader()..gate = Completer<void>();
    final player = _FakeVideoPlayer();
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    // 拉取中(不确定态菊花在转):只定长 pump,不 settle
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('准备播放'), findsOneWidget); // 进度对话框在

    await tester.tap(find.text('取消'));
    await tester.pump(); // 置位取消位
    downloader.gate!.complete();
    await tester.pumpAndSettle(); // 异常路径收口:菊花复位成播放钮

    expect(find.text('准备播放'), findsNothing); // 对话框收口
    expect(find.text('已取消'), findsOneWidget);
    expect(player.loads, isEmpty); // 未进播放
    expect(gallery.temp.listSync(), isEmpty); // 无半成品残留
    // 回到播放钮态:可再点
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:拉取失败 → 弹「加载视频失败」,回播放钮',
      (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader()..failNext = true;
    final player = _FakeVideoPlayer();
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(find.text('加载视频失败,请检查连接后重试'), findsOneWidget);
    expect(player.loads, isEmpty);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:无内嵌视图平台(Android/ohos)点播放直接提示,不拉整档',
      (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer(embedded: false);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
        ));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(downloader.calls, isEmpty); // 不拉整档再报错
    expect(player.loads, isEmpty);
    expect(find.text('该平台暂不支持视频播放'), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:滑走翻回不重拉(keep-alive 持临时档),收查看器才删',
      (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer();
    final items = [_videoGroup(), PhotoGroup([_file(201, 'IMG_0201.JPG')])];
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: items,
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    final tempPath = player.loads.single.$2;
    expect(File(tempPath).existsSync(), isTrue);

    // 滑到照片页(多帧小步,InteractiveViewer 不抢):视频页 keep-alive
    // 存活(keepAlive 桶里算 offstage,默认 finder 跳过 → 显式关掉),
    // 临时档不删、内嵌播放器不拆
    await _dragLikeFinger(tester, const Offset(-600, 0));
    expect(find.text('2 / 2'), findsOneWidget);
    expect(File(tempPath).existsSync(), isTrue);
    expect(find.byType(EmbeddedVideoPlayer, skipOffstage: false),
        findsOneWidget);

    // 翻回:不重拉不重装(同一视图)
    await _dragLikeFinger(tester, const Offset(600, 0));
    expect(downloader.calls, hasLength(1));
    expect(player.loads, hasLength(1));

    // 收查看器 → 删档
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _waitFileGone(tester, tempPath);
    expect(File(tempPath).existsSync(), isFalse);
  });

  testWidgets('视频组:全屏原地旋转(锁横屏 + 沉浸,同一播放器不新增视图);'
      '滑到照片页自动退出全屏', (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer();
    final items = [_videoGroup(), PhotoGroup([_file(201, 'IMG_0201.JPG')])];
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: items,
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: downloader,
          gallery: gallery,
          videoPlayer: player,
          embeddedVideoView: _stubView,
        ));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 记录 SystemChrome 通道指令(方向锁/沉浸是全屏的本体动作)
    final chromeCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      chromeCalls.add(call);
      return null;
    });
    List<List<String>> orientationCalls() => chromeCalls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .map((c) => List<String>.from(c.arguments as List))
        .toList();

    // 全屏:锁横屏 + 沉浸,顶栏/底栏收起(浮层自动隐了,先点画面唤回)
    await _revealControls(tester);
    await tester.tap(find.byTooltip('全屏播放'));
    await tester.pumpAndSettle();
    expect(orientationCalls().first, const [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(chromeCalls.any((c) => c.method.contains('SystemUIMode')), isTrue);
    expect(find.text('1 / 2'), findsNothing); // AppBar 收
    expect(find.text('下载到相册'), findsNothing); // 底栏收
    // 同一播放器:无二次装载
    expect(player.loads, hasLength(1));
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    // 滑到照片页:自动退出全屏(还原方向三态 + 顶栏回)
    await _dragLikeFinger(tester, const Offset(-600, 0));
    expect(orientationCalls().last, const [
      'DeviceOrientation.portraitUp',
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(find.text('2 / 2'), findsOneWidget); // AppBar 回

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, null);
  });

  testWidgets('视频组:点按唤回层盖在平台视图之上(父级包装的 tap 在'
      '抬手结算时输给原生视图 —— 真机唤不回的结构根因)', (tester) async {
    final gallery = _FakeGallery();
    addTearDown(() => gallery.temp.deleteSync(recursive: true));
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          downloader: _FakeDownloader(),
          gallery: gallery,
          videoPlayer: _FakeVideoPlayer(),
          embeddedVideoView: _stubView,
        ));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 沿内嵌视图向上第一层 Stack = 播放页本体:平台视图必须是首子
    // (底层),点按层(GestureDetector)其后(盖上)—— 引擎的同步
    // 命中拦截只认「盖在上面的 Flutter 件」,父级包装不在此列。
    Stack? playerStack;
    tester
        .element(find.byType(_StubVideoView))
        .visitAncestorElements((element) {
      if (element.widget is Stack) {
        playerStack = element.widget as Stack;
        return false;
      }
      return true;
    });
    expect(playerStack, isNotNull);
    final children = playerStack!.children;
    expect(children, hasLength(3));
    expect(children[0], isA<_StubVideoView>()); // 平台视图打底
    expect(children[1], isA<GestureDetector>()); // 点按层盖上
  });
}

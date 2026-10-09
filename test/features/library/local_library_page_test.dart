import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// [frameRateOf] 供顺帧用例注入帧率;[embedded] = 内嵌播放视图可用
/// (iOS 人设;load/viewControl/viewSeek 落账,viewStatus 由
/// viewControl 驱动像真播放器 —— 位置不前进,值不变才不重绘,
/// FakeAsync 里 pumpAndSettle 才能收)。
final class _FakeVideoPlayer implements VideoPlayer {
  _FakeVideoPlayer({this.failThumbs = true, this.frameRateOf, this.embedded = false});

  final bool failThumbs;
  final double? Function(String path)? frameRateOf;
  final bool embedded;

  final played = <(String, double)>[];
  final thumbs = <(String, int)>[];

  /// viewControl 指令流:(viewId, playing, rate)。
  final viewControls = <(int, bool, double)>[];
  final loads = <(int, String)>[];
  final seeks = <(int, double)>[];
  final viewStates =
      <int, ({double position, double duration, bool playing})>{};

  @override
  bool get supportsEmbeddedView => embedded;

  @override
  Future<void> play(String path, {double rate = 1.0}) async {
    played.add((path, rate));
  }

  @override
  Future<void> loadEmbeddedView(int viewId, String path) async {
    loads.add((viewId, path));
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
  Future<void> seekEmbeddedView(int viewId, {required double position}) async {
    seeks.add((viewId, position));
    final s = viewStates[viewId];
    if (s != null) {
      viewStates[viewId] =
          (position: position, duration: s.duration, playing: s.playing);
    }
  }
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
          {RawDecoder? rawDecoder,
          VideoPlayer? videoPlayer,
          EmbeddedVideoViewBuilder? embeddedView}) =>
      MaterialApp(
          home: LocalLibraryPage(
        controller: controller,
        gallery: gallery,
        rawDecoder: rawDecoder ?? _FakeRawDecoder(fail: true),
        videoPlayer: videoPlayer ?? _FakeVideoPlayer(),
        embeddedVideoView: embeddedView,
      ));

  /// 内嵌播放人设:embedded 播放器 + 假视图(onCreated 回固定 viewId 7)。
  Widget embeddedHost(_FakeGallery gallery, TransfersController controller,
          _FakeVideoPlayer player) =>
      host(gallery, controller,
          videoPlayer: player,
          embeddedView: (path, onCreated) =>
              _StubVideoView(onCreated: onCreated));

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

  // ── 视频页内播放(2026-10-09 再改:点开**不自动播**,首帧 + 播放钮
  // 常驻,点了才起播;全屏改查看器原地旋转,同一播放器零跳变)──

  testWidgets('MOV:点开不自动播放(装载即暂停,点播放才起播)', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();

    expect(find.text('c.mov'), findsWidgets); // 查看器 AppBar
    // 视图就位 → 通道装载档案 → 按意图暂停(装载先于控制,同通道 FIFO)
    expect(player.loads, [(7, '${dir.path}/c.mov')]);
    expect(player.viewControls, isNotEmpty);
    expect(player.viewControls.first, (7, false, 1.0)); // 不自动起播
    expect(find.byIcon(Icons.play_arrow), findsOneWidget); // 中键 = 播放
    // 不走全屏 play 通道;应用内常驻档播完不删
    expect(player.played, isEmpty);
    expect(File('${dir.path}/c.mov').existsSync(), isTrue);

    // 点播放才起播
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, true, 1.0));

    // 播放中退出查看器(左上返回)= 立即停播(显式暂停兜底,不靠
    // 平台视图销毁时序 —— 2026-10-09 退出后声音未停复报)
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, false, 1.0));
  });

  testWidgets('MOV:高帧率浮顺帧开关(非阻塞),点了才变速静音', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true, frameRateOf: (_) => 60);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();

    // 暂停待播,顺帧开关照样在场(不拦起播,非门)
    expect(player.viewControls.first, (7, false, 1.0));
    expect(find.text('24fps 顺帧'), findsOneWidget);

    await tester.tap(find.text('24fps 顺帧'));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, false, 0.4));
    expect(find.text('顺帧 24fps · 40%'), findsOneWidget);

    // 再点回实时
    await tester.tap(find.text('顺帧 24fps · 40%'));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, false, 1.0));
  });

  testWidgets('MOV:播放控制 —— 暂停/续播/拖进度条', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();

    // 待播:中键是播放图样;点它起播
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, true, 1.0));
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // 播放中点中键暂停
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, false, 1.0));

    // 续播
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.viewControls.last, (7, true, 1.0));

    // 拖进度条 → seek(左拖出进度值)
    await tester.drag(find.byType(Slider), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(player.seeks, isNotEmpty);
    expect(player.seeks.single.$1, 7);
  });

  /// 浮层当前透明度配置(淡入淡出由 AnimatedOpacity 内部驱动)。
  /// 经 Slider 定位:视频页浮层是它唯一的 AnimatedOpacity 祖先。
  double overlayOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.ancestor(
          of: find.byType(Slider), matching: find.byType(AnimatedOpacity)))
      .opacity;

  testWidgets('MOV:播放中控制浮层 3s 自动隐,点按唤回;暂停常驻', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    // 待播浮层常驻;点播放起播(此后浮层要自动隐)
    expect(overlayOpacity(tester), 1.0);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 播放中 3s 后自动隐(此前常驻不消 —— 用户复报点)
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle(); // 180ms 淡出收尾
    expect(overlayOpacity(tester), 0.0);

    // 点按画面(避开中键/角钮的空档)唤回,播放中再计 3s
    await tester.tapAt(const Offset(400, 150));
    await tester.pumpAndSettle();
    expect(overlayOpacity(tester), 1.0);

    // 暂停后浮层常驻:过了 3s 也不隐(不然没法点续播)
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(overlayOpacity(tester), 1.0);
    expect(player.viewControls.last, (7, false, 1.0));
  });

  testWidgets('MOV:全屏 —— 原地旋转(同一播放器,不新增视图)', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    // 记录 SystemChrome 通道指令(方向锁/沉浸是全屏的本体动作)
    final chromeCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      chromeCalls.add(call);
      return null;
    });
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    expect(find.text('c.mov'), findsWidgets); // 顶栏标题在

    // 进全屏:顶栏收起 + 锁横屏 + 沉浸,角钮翻成退出
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(find.text('c.mov'), findsNothing); // AppBar 随全屏收起
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    // 同一播放器:没有第二次装载,也没有暂停/续播翻动
    expect(player.loads, hasLength(1));
    expect(player.viewControls, hasLength(1));
    List<List<String>> orientationCalls() => chromeCalls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .map((c) => List<String>.from(c.arguments as List))
        .toList();
    expect(orientationCalls().first, ['DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight']); // 锁横屏
    expect(chromeCalls.any((c) => c.method.contains('SystemUIMode')),
        isTrue); // 沉浸

    // 退全屏:顶栏回来,方向还原成应用方向集
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(find.text('c.mov'), findsWidgets);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(orientationCalls().last, ['DeviceOrientation.portraitUp',
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight']);
  });

  testWidgets('MOV:无内嵌视图平台(Android/ohos)回落海报帧 + 说明文案',
      (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(failThumbs: false);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await tester.pumpAndSettle();

    // 抽帧一次(会话内合并),落盘 thumbsDir(lib_ 前缀内容键,与
    // NEF 同管线)。
    expect(player.thumbs, [('${dir.path}/c.mov', 512)]);
    expect(
        File('${gallery.thumbs.path}/lib_c.mov_3.jpg').existsSync(), isTrue);

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    // 查看器海报帧走页面级缓存:不重复抽帧;说明文案在场,无播放钮。
    expect(player.thumbs, hasLength(1));
    expect(find.text('该平台暂不支持视频播放'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  /// 真机手指式拖动:多帧小步位移。单步大位移(tester.drag)会一步
  /// 跨过 InteractiveViewer Scale 手势的 36px pan slop 被它先认领,
  /// 翻页不动;真机多帧小位移下 PageView 的 18px touch slop 先到。
  Future<void> dragLikeFinger(
      WidgetTester tester, Finder finder, Offset offset) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    final steps = (offset.distance / 10).ceil();
    final step = offset / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(step);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // ── 查看器翻页(2026-10-09:PageView 左右滑)──

  testWidgets('查看器:左右滑翻页,标题跟随网格过滤序', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    // 倒序 c,b,a;打开第一张(c)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('c.jpg'), findsWidgets);

    // 左滑 → 下一张(b)
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('b.jpg'), findsWidgets);
    expect(find.text('c.jpg'), findsNothing);

    // 右滑 → 回到 c
    await dragLikeFinger(tester, find.byType(PageView), const Offset(600, 0));
    expect(find.text('c.jpg'), findsWidgets);
    expect(find.text('b.jpg'), findsNothing);
  });

  testWidgets('查看器:图片滑到视频不自动播放(装载即暂停)', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 2));
    writeFile('b.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await tester.pumpAndSettle();

    // 倒序 b.mov, a.jpg;开在图片(a)上,右滑到视频(b)
    await tester.tap(find.byKey(const ValueKey('a.jpg')));
    await tester.pumpAndSettle();
    await dragLikeFinger(tester, find.byType(PageView), const Offset(600, 0));
    expect(find.text('b.mov'), findsWidgets);

    // 视频页就位:装载了档案,但控制指令是暂停(不自动播)
    expect(player.loads, [(7, '${dir.path}/b.mov')]);
    expect(player.viewControls.first, (7, false, 1.0));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('查看器删除:当前页删除下一张滑入;删尾页翻回前一页',
      (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    // 倒序 c,b,a;打开 c
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();

    // 删当前页 c → b 滑入(页位不变,下一张补上)
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(File('${dir.path}/c.jpg').existsSync(), isFalse);
    expect(find.text('b.jpg'), findsWidgets);

    // 滑到尾页 a,删除 → 翻回前一页 b(不白屏)
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('a.jpg'), findsWidgets);
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(File('${dir.path}/a.jpg').existsSync(), isFalse);
    expect(find.text('b.jpg'), findsWidgets); // 尾页删除后落回 b
    expect(find.byType(PageView), findsOneWidget); // 查看器还在
  });
}

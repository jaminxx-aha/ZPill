import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/media/watermark.dart' show ExifCardData;
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/browser/photo_viewer_page.dart';
import 'package:nikon_pill/features/common/widgets/embedded_video_player.dart';
import 'package:nikon_pill/features/common/widgets/photo_info_sheet.dart';
import 'package:nikon_pill/l10n/l10n.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/video_player.dart';

/// 假缩略图:即时返回路径(文件不存在 → Image.file 走占位,无动画挂起)。
final class _FakeThumbs implements ThumbnailCache {
  final warmed = <ObjectEntry>[];

  /// 信息底单的 EXIF 桩:handle → 卡;未脚本 = null(无 EXIF)。
  final Map<int, ExifCardData> exifByHandle = {};

  @override
  int get previewMaxPixelSize => 2560;

  @override
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) async =>
      '/tmp/nikonpill_test_preview_${entry.handle}.jpg';

  @override
  Future<ExifCardData?> exifCardOf(ObjectEntry entry) async =>
      exifByHandle[entry.handle];

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

/// 伪播放器:load/viewControl 落账,viewStatus 由
/// viewControl 驱动像真播放器 —— 值不变才不重绘,FakeAsync 里
/// pumpAndSettle 才能收。play 落账 = 原生全屏路(embedded: false 人设)。
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
  Future<double?> play(String path,
      {double rate = 1.0, double? position}) async {
    played.add((path, rate));
    return null;
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
        {int format = 0x3801,
        ObjectKind kind = ObjectKind.image,
        int protectionStatus = 0}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 8,
      kind: kind,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 1, 12),
      formatCode: format,
      protectionStatus: protectionStatus,
    );

/// GetObjectInfo 数据集(开页保护态读回 0x1008 用):52B 定长头 + 文件
/// 名/拍摄/修改三串([protection] = ProtectionStatus u16)。
Uint8List _objectInfoDataset({int protection = 0}) {
  final w = ByteWriter()
    ..u32(1) // storageId
    ..u16(0x3801) // format JPG
    ..u16(protection)
    ..u32(8) // size(与 _file 一致)
    ..u16(0)..u32(0)..u32(0)..u32(0) // 缩略图四件
    ..u32(0)..u32(0)..u32(0) // 图像宽/高/位深
    ..u32(0x11) // parentObject
    ..u16(0)..u32(0)..u32(0); // assocType/assocDesc/sequence
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str('DSC_0001.JPG');
  str('20261016T120000.0');
  str('20261016T120000.0');
  return w.takeBytes();
}

PhotoGroup _videoGroup() => PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);

/// 推入查看器路由(home 直挂是栈底路由没有返回钮,pageBack 无从收)。
/// 路由动画收口后返回。入口页带 Scaffold:与生产一致(否则 pop 后
/// ScaffoldMessenger 的在显 SnackBar 无处挂载,下载提示回归用例测不出
/// 「挂到上一页」的真实行为)。
Future<void> _openViewer(WidgetTester tester, PhotoViewerPage page) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => page)),
            child: const Text('打开查看器'),
          ),
        ),
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

/// 记录请求的假传输(保护标记用;按序回放预置结果/异常)。
final class _FakePtpTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 ${request.opcode.toRadixString(16)}');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('双格式组:筛选未预定(全部)整组直接入队,不弹面板',
      (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.JPG'),
      _file(102, 'DSC_0001.NEF', format: 0x3000),
    ]);
    var transfersTapped = false;
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: engine,
          onOpenTransfers: () => transfersTapped = true,
        ));

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('下载到相册'), findsNothing); // 两段式:默认单「下载」钮
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsNothing,
        reason: '全部 = 整组直接下,不弹格式面板');

    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['DSC_0001.JPG', 'DSC_0001.NEF']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('已开始下载到相册'), findsOneWidget);

    // SnackBar「查看进度」动作 → 传输页入口
    await tester.tap(find.text('查看进度'));
    await tester.pump();
    expect(transfersTapped, isTrue, reason: 'SnackBar 动作直通传输页');

    await _drainSnackBar(tester);
  });

  testWidgets('下载后立即返回:「查看进度」仍可跳传输页,提示自动消失',
      (tester) async {
    // 网格页同款回归(2026-10-17 真机):pop 后动作闭包沿 State.context
    // 找 Navigator 抛 defunct;SDK #173084 起带 action 默认 persist=true
    // 永不消失。生产默认路径(不注入 onOpenTransfers)。
    final engine = _FakeEngine();
    final group = PhotoGroup([_file(101, 'DSC_0001.JPG')]);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: engine,
        ));

    // 两段式:先点「下载」换出目的地,再点「下载到相册」。
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已开始下载到相册'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开查看器'), findsOneWidget);
    expect(find.textContaining('已开始下载'), findsOneWidget,
        reason: 'dismiss 窗口内提示随 messenger 挂在上一页');

    await tester.tap(find.text('查看进度'));
    await tester.pumpAndSettle();
    expect(find.byType(TransfersPage), findsOneWidget,
        reason: '展示时刻捕获的 Navigator 跨 pop 存活');

    await _drainSnackBar(tester);
    expect(find.textContaining('已开始下载'), findsNothing,
        reason: 'persist=false 恢复自动消失,不永久滞留');
  });

  testWidgets('信息底单:照片组 EXIF 头读出机身/镜头/参数/拍摄时间,'
      '双格式组两份文件名', (tester) async {
    final thumbs = _FakeThumbs()
      ..exifByHandle[101] = ExifCardData(
          make: 'NIKON CORPORATION',
          model: 'NIKON Z f',
          lens: 'NIKKOR Z 40mm f/2',
          focalLengthMm: 40,
          fNumber: 2,
          exposureSec: 1 / 250,
          iso: 100,
          takenAt: DateTime(2026, 10, 1, 12));
    final group = PhotoGroup([
      _file(101, 'DSC_0001.JPG'),
      _file(102, 'DSC_0001.NEF', format: 0x3000),
    ]);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: thumbs,
          engine: _FakeEngine(),
        ));

    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();

    expect(find.text('照片信息'), findsOneWidget);
    expect(find.text('DSC_0001.JPG + DSC_0001.NEF'), findsOneWidget);
    expect(find.text('NIKON Z f'), findsOneWidget, reason: '机身(titleLine 去厂牌)');
    expect(find.text('NIKKOR Z 40mm f/2'), findsOneWidget);
    expect(find.text('40mm ƒ/2 · 1/250s · ISO 100'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('2026-10-01 12:00')),
        findsOneWidget,
        reason: '拍摄时间(EXIF 本地时间;底栏的 UTC 换算时间在底单外)');

    await tester.tapAt(const Offset(10, 10)); // 点外关闭底单
    await tester.pumpAndSettle();
    expect(find.text('照片信息'), findsNothing);
  });

  testWidgets('信息跟随被点格口径:JPG 格只显 JPG 名与体量,NEF 格同'
      '(不再双格式名拼接/合计)', (tester) async {
    final thumbs = _FakeThumbs()
      ..exifByHandle[102] = ExifCardData(
          make: 'NIKON CORPORATION',
          model: 'NIKON Z f',
          lens: 'NIKKOR Z 40mm f/2',
          focalLengthMm: 40,
          fNumber: 2,
          exposureSec: 1 / 250,
          iso: 100,
          takenAt: DateTime(2026, 10, 1, 12));
    final group = PhotoGroup([
      _file(101, 'DSC_0001.JPG'),
      _file(102, 'DSC_0001.NEF', format: 0x3000),
    ]);

    // JPG 格进入(相册页拆格传 {jpg}):信息行与底单都只 JPG 一份
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: thumbs,
          engine: _FakeEngine(),
          formats: {MediaFormat.jpg},
        ));
    expect(find.textContaining('DSC_0001.JPG · 8B'), findsOneWidget,
        reason: '信息行:单文件名 + 单文件体量(条目各 8 字节)');
    expect(find.textContaining('+'), findsNothing,
        reason: '不再拼接两格式名');

    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();
    expect(find.text('DSC_0001.JPG'), findsOneWidget);
    expect(find.text('8B'), findsOneWidget);
    expect(find.text('16B'), findsNothing, reason: '不再双文件合计');

    await tester.tapAt(const Offset(10, 10)); // 点外关闭底单
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // NEF 格进入:名字/体量随 NEF,EXIF 也改锚 NEF 件(头 102)
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: thumbs,
          engine: _FakeEngine(),
          formats: {MediaFormat.nef},
        ));
    expect(find.textContaining('DSC_0001.NEF · 8B'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);

    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();
    expect(find.text('DSC_0001.NEF'), findsOneWidget);
    expect(find.text('8B'), findsOneWidget);
    expect(find.text('NIKON Z f'), findsOneWidget,
        reason: 'EXIF 锚随口径走 NEF 件(TIFF 头路)');

    await tester.tapAt(const Offset(10, 10)); // 点外关闭底单
    await tester.pumpAndSettle();
    expect(find.text('照片信息'), findsNothing);
  });

  testWidgets('信息底单:视频组只走文件级信息(无 EXIF 段无转圈)',
      (tester) async {
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [_videoGroup()],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: _FakeEngine(),
        ));

    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();

    expect(find.text('照片信息'), findsOneWidget);
    expect(find.text('DSC_0001.MOV'), findsOneWidget);
    expect(find.text('机身'), findsNothing);
    expect(find.text('参数'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('信息底单(EN):标签列自适应,Captured/Exposure 不截断;'
      '标签色 token 化 onSurfaceVariant', (tester) async {
    // 直呼底单(不走查看器):聚焦标签列本身。EN 最长标签 Captured/
    // Exposure 在旧 64 钉宽下贴边/截断,自适应后单行全显。
    await tester.pumpWidget(L10nScope(
      code: 'en',
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPhotoInfoSheet(
                  context,
                  filename: 'DSC_0001.JPG',
                  sizeBytes: 12345678,
                  fallbackTime: '2026-10-01 12:00',
                  loadExif: () async => ExifCardData(
                      make: 'NIKON CORPORATION',
                      model: 'NIKON Z f',
                      lens: 'NIKKOR Z 40mm f/2',
                      focalLengthMm: 40,
                      fNumber: 2,
                      exposureSec: 1 / 250,
                      iso: 100,
                      takenAt: DateTime(2026, 10, 1, 12)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final label in const ['Captured', 'Exposure']) {
      final finder = find.text(label);
      final element = tester.element(finder);
      final natural = TextPainter(
        text: TextSpan(text: label, style: tester.widget<Text>(finder).style),
        textScaler: MediaQuery.textScalerOf(element),
        textDirection: TextDirection.ltr,
      )..layout();
      final naturalWidth = natural.width;
      natural.dispose();
      expect(tester.getSize(finder).width, greaterThanOrEqualTo(naturalWidth),
          reason: '$label 单行全显(标签列按最长标签放行,不折行不省略)');
    }
    // 两段行(文件级 + EXIF)共用一宽:列起点对齐。
    expect(tester.getSize(find.text('File')).width,
        tester.getSize(find.text('Captured')).width);
    // 标签色 token 化:onSurfaceVariant(原 Colors.grey 退役)。
    expect(
        tester.widget<Text>(find.text('Captured')).style?.color,
        Theme.of(tester.element(find.text('Captured')))
            .colorScheme
            .onSurfaceVariant);
  });

  testWidgets('单格式组:「下载」展开目的地后不弹面板直接整组入队',
      (tester) async {
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

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing);
    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'IMG_0101.JPG');
    expect(destination, TransferDestination.gallery);

    await _drainSnackBar(tester);
  });

  testWidgets('筛选预定格式(仅 RAW):跳过面板直接入队 NEF,入队后复位「下载」',
      (tester) async {
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
          formats: {MediaFormat.nef},
        ));

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing,
        reason: '相册页筛选已定格式:不再弹格式面板');
    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'DSC_0001.NEF');
    expect(destination, TransferDestination.gallery);
    expect(find.text('下载到相册'), findsNothing,
        reason: '入队完成:两段式复位回单「下载」钮');

    await _drainSnackBar(tester);
  });

  testWidgets('筛选预定格式但组内缺该格式(纯 JPG × 仅 RAW):提示不下',
      (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([_file(101, 'IMG_0101.JPG')]);
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [group],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
          engine: engine,
          formats: {MediaFormat.nef},
        ));

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(engine.calls, isEmpty);
    expect(find.text('没有符合「NEF」的文件,未开始下载'), findsOneWidget);

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
    expect(player.played, isEmpty); // 内嵌路不调 play(那是无内嵌视图平台的路)
    // 播放中:临时档还在(keep-alive 页持有)
    expect(File(player.loads.single.$2).existsSync(), isTrue);

    // 收查看器 → 临时档由会话缓存持有不删(2026-10-16 起:重开秒开);
    // 重开查看器再点播放:不重拉,同一临时档直接装载
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(File(player.loads.single.$2).existsSync(), isTrue,
        reason: '临时档由 _PlayedVideoCache 会话持有,收看器不删');
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
    expect(downloader.calls, hasLength(1), reason: '缓存命中:不重拉');
    expect(player.loads, hasLength(2));
    expect(player.loads.last.$2, player.loads.first.$2,
        reason: '同一临时档复用');
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

  testWidgets('视频组:无内嵌视图平台(Android)拉整档后原生全屏播放'
      '(不装内嵌视图,海报留守,重播走会话缓存)', (tester) async {
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

    expect(player.played, hasLength(1)); // 原生全屏播放路
    expect(player.played.single.$2, 1.0); // 常速
    expect(player.loads, isEmpty); // 不装内嵌视图
    expect(find.byIcon(Icons.play_arrow), findsOneWidget); // 海报留守

    // 再点:临时档在会话缓存,秒重播不重拉
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.played, hasLength(2));
    expect(downloader.calls, hasLength(1));
  });

  testWidgets('视频组:滑走翻回不重拉(keep-alive 持临时档),收看视器档留会话缓存',
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

    // 收看视器 → 档由会话缓存持有(重开秒开语义,详见「点播放」例)
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(File(tempPath).existsSync(), isTrue);
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
    expect(find.text('下载'), findsNothing); // 底栏收
    // 同一播放器:无二次装载
    expect(player.loads, hasLength(1));
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    // 滑到照片页:自动退出全屏(**钉回竖屏** + 顶栏回;交还传感器集
    // 会在设备横放时滞留横屏 —— 2026-10-24 真机复报)
    await _dragLikeFinger(tester, const Offset(-600, 0));
    expect(orientationCalls().last, const [
      'DeviceOrientation.portraitUp',
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

    // 沿内嵌视图向上第一层 Stack = 播放页本体:海报垫底,平台视图
    // 其次(ohos 懒挂载未播时顶黑面;iOS 被首帧盖住无感),点按层
    // (GestureDetector)再盖上 —— 引擎的同步命中拦截只认「盖在上面
    // 的 Flutter 件」,父级包装不在此列。
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
    expect(children, hasLength(4));
    expect(children[0], isNotNull); // 海报垫底
    expect(children[1], isA<_StubVideoView>()); // 平台视图
    expect(children[2], isA<GestureDetector>()); // 点按层盖上
  });

  testWidgets('评分设置闸:顶栏无打星钮,信息/编辑钮照常(守 kRatingUiEnabled)',
      (tester) async {
    await _openViewer(
        tester,
        PhotoViewerPage(
          items: [PhotoGroup([_file(0x1234, 'DSC_0001.JPG')])],
          initialIndex: 0,
          thumbnails: _FakeThumbs(),
        ));
    // 闸翻回 true 时,下面 findsNothing 全部改回 findsOneWidget
    expect(find.byTooltip('评分'), findsNothing,
        reason: 'kRatingUiEnabled=false 藏唯一设评沿');
    expect(find.byIcon(Icons.star), findsNothing);
    expect(find.byIcon(Icons.star_border), findsNothing);
    expect(find.byTooltip('照片信息'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget); // 组内有 JPG 才有调参钮
  });

  group('相机内保护(SetObjectProtection 0x1012,2026-10-12 官方 §6.2.1.14)',
      () {
    testWidgets('开页读回真值:GetObjectInfo ProtectionStatus=1 → 图标直亮锁',
        (tester) async {
      final t = _FakePtpTransport();
      // 0x1008 定长头 @6 = 1(只读);列表条目不带保护字段(0x9805 路)
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _objectInfoDataset(protection: 1)));
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [PhotoGroup([_file(0x1234, 'DSC_0001.JPG')])],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: PtpSession(transport: t),
          ));
      expect(t.requests.single.opcode, PtpOperationCode.getObjectInfo);
      expect(t.requests.single.params, [0x1234]);
      expect(find.byIcon(Icons.lock), findsOneWidget,
          reason: '0x1008 是唯一在册真值源(0x9803 不在册/0x9805 不带字段)');
    });

    testWidgets('锁钮点按发 [句柄, 0x0001],再点发解除;失败走 SnackBar',
        (tester) async {
      final t = _FakePtpTransport();
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _objectInfoDataset(protection: 0))); // 开页读回:未保护
      final group = PhotoGroup([_file(0x1234, 'DSC_0001.JPG')]);
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [group],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: PtpSession(transport: t),
          ));

      // 上保护
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pumpAndSettle();
      expect(
          t.requests
              .where((r) => r.opcode == PtpOperationCode.setObjectProtection)
              .single
              .params,
          [0x1234, 0x0001]);
      expect(find.text('已设为相机内保护(只读)'), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsOneWidget, reason: '乐观态跟本地写');
      await _drainSnackBar(tester);

      // 解除
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await tester.tap(find.byIcon(Icons.lock));
      await tester.pumpAndSettle();
      expect(t.requests.last.params, [0x1234, 0x0000]);
      expect(find.text('已解除相机内保护'), findsOneWidget);
      await _drainSnackBar(tester);
    });

    testWidgets('写被拒(断链/卡写保护):图标不动,SnackBar 指路', (tester) async {
      final t = _FakePtpTransport();
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _objectInfoDataset(protection: 0))); // 开页读回:未保护
      final group = PhotoGroup([_file(0x1234, 'DSC_0001.JPG')]);
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [group],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: PtpSession(transport: t),
          ));

      t.fail(const PtpResponseException(
          opcode: PtpOperationCode.setObjectProtection,
          responseCode: PtpResponseCode.storeNotAvailable));
      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pumpAndSettle();
      expect(find.textContaining('保护标记失败'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget,
          reason: '失败不落乐观态');
      await _drainSnackBar(tester);
    });

    testWidgets('重开页面:乐观态挂会话保值(0x9803 废弃,乐观 Map 不随页清)',
        (tester) async {
      // 2026-10-16 真机复报「加锁后重进显示未锁」回归:页 State 每次进页
      // 重建,页面级缓存重开即清空;乐观增量挂 session 后跨页保值。
      final t = _FakePtpTransport();
      final group = PhotoGroup([_file(0x1234, 'DSC_0001.JPG')]);
      final session = PtpSession(transport: t);
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [group],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: session,
          ));

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 上保护
      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock), findsOneWidget);
      await _drainSnackBar(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // 重开:会话乐观 Map 保住锁态(真机形态:重读 0x1008 已回 1)
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _objectInfoDataset(protection: 1)));
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [group],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: session,
          ));
      expect(find.byIcon(Icons.lock), findsOneWidget,
          reason: '乐观态挂会话:重开不回落未锁假态');
    });

    testWidgets('断开重连:会话清账 + 重列新真值(ProtectionStatus=1)→ 锁态如显',
        (tester) async {
      // 真机原始复报路径:加锁 → 断开重连(open() 清乐观账)→ 重进照片
      // 仍须显锁 —— 重列的 ObjectInfo ProtectionStatus 带回真值 1。
      final t = _FakePtpTransport();
      final session = PtpSession(transport: t);
      final group = PhotoGroup([_file(0x1234, 'DSC_0001.JPG')]);
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [group],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: session,
          ));
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 上保护
      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pumpAndSettle();
      await _drainSnackBar(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      session.protectionOptimistic.clear(); // open():新链新账
      // 重列:0x9805 批量路不带保护字段(Zf 实测),条目基线 0
      final relisted = PhotoGroup([_file(0x1234, 'DSC_0001.JPG')]);
      // 开页读回 0x1008:真值 1(相机侧已锁)
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: _objectInfoDataset(protection: 1)));
      await _openViewer(
          tester,
          PhotoViewerPage(
            items: [relisted],
            initialIndex: 0,
            thumbnails: _FakeThumbs(),
            session: session,
          ));
      expect(find.byIcon(Icons.lock), findsOneWidget,
          reason: '开页 0x1008 读回真值接管显示,不再回落未锁假态');
    });
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart' show baseNameOf;
import 'package:nikon_pill/core/media/cube_lut.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/ratings_store.dart';
import 'package:nikon_pill/features/common/trash_rating_icon.dart';
import 'package:nikon_pill/features/common/sort_bars_icon.dart';
import 'package:nikon_pill/features/common/widgets/hero_zoom.dart';
import 'package:nikon_pill/data/ui_prefs_store.dart';
import 'package:nikon_pill/features/library/library_ratings.dart';
import 'package:nikon_pill/features/library/local_library_page.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/raw_decoder.dart';
import 'package:nikon_pill/platform/video_lut_export.dart';
import 'package:nikon_pill/platform/video_player.dart';

/// 伪相册服务:downloadsDir 指向临时目录,importFiles 落账可断言;
/// thumbsDir 用独立子目录(NEF 网格缩略落盘,不污染 downloadsDir 清单)。
final class _FakeGallery implements GallerySaver {
  _FakeGallery(this.dir);

  final Directory dir;
  late final Directory thumbs = Directory('${dir.path}/_thumbs')..createSync();
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
  _FakeVideoPlayer(
      {this.failThumbs = true, this.frameRateOf, this.embedded = false});

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
  Future<double?> play(String path,
      {double rate = 1.0, double? position}) async {
    played.add((path, rate));
    return null;
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
  Future<({double position, double duration, bool playing})> embeddedViewStatus(
          int viewId) async =>
      viewStates[viewId] ?? (position: 0.0, duration: 60.0, playing: false);

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

/// 假 LUT 导出宿主:isSupported 恒真;export 记账并回固定产物路径
/// (预置的临时 MP4,落库后由查看器删)。
final class _FakeVideoLut implements VideoLutExportHost {
  _FakeVideoLut(this.outPath);

  final String outPath;
  final exportCalls = <String>[];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<String> export(String path, CubeLut lut,
      {void Function(int progress)? onProgress}) async {
    exportCalls.add(path);
    onProgress?.call(50);
    onProgress?.call(100);
    return outPath;
  }

  @override
  Future<void> cancel() async {}
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
  Future<void> removeRecord(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

/// 带 EXIF 的「JPG」字节(SOI + APP1 Exif + EOI,无图像数据):IFD0
/// Make/Model + Exif 子表 光圈/快门/ISO/焦距,无 takenAt(时间行走
/// mtime 兜底的用例语义)。布局:头 8 + IFD0 42(8..49,3 条目)+
/// Exif 54(50..103)+ 数据区(104..)。Make/Model 用真实长度(>4B)
/// —— EXIF 规则:值 ≤4 字节内联存储,短串会踩中内联路径测不到偏移。
Uint8List _jpgExifBytes() {
  const ascii = 2, short = 3, long = 4, rational = 5;
  const makeOff = 104,
      modelOff = 122,
      fNumOff = 131,
      expOff = 139,
      focalOff = 147;
  final w = ByteWriter()
    ..u16(0x4949)
    ..u16(42)
    ..u32(8)
    // IFD0:Make / Model / Exif 指针(count 含结尾 NUL:17 字符 → 18)
    ..u16(3)
    ..u16(0x010F)
    ..u16(ascii)
    ..u32(18)
    ..u32(makeOff)
    ..u16(0x0110)
    ..u16(ascii)
    ..u32(9)
    ..u32(modelOff)
    ..u16(0x8769)
    ..u16(long)
    ..u32(1)
    ..u32(50)
    ..u32(0)
    // Exif 子表:光圈 / 快门 / ISO / 焦距
    ..u16(4)
    ..u16(0x829D)
    ..u16(rational)
    ..u32(1)
    ..u32(fNumOff)
    ..u16(0x829A)
    ..u16(rational)
    ..u32(1)
    ..u32(expOff)
    ..u16(0x8827)
    ..u16(short)
    ..u32(1)
    ..u16(100)
    ..u16(0)
    ..u16(0x920A)
    ..u16(rational)
    ..u32(1)
    ..u32(focalOff)
    ..u32(0)
    // 数据区
    ..raw('NIKON CORPORATION'.codeUnits)
    ..u8(0)
    ..raw('NIKON Zf'.codeUnits)
    ..u8(0)
    ..u32(2)
    ..u32(1) // ƒ/2
    ..u32(1)
    ..u32(250) // 1/250s
    ..u32(40)
    ..u32(1); // 40mm
  final payload = w.takeBytes();
  final segLen = 2 + 6 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...'Exif'.codeUnits, 0, 0, //
    ...payload, //
    0xFF, 0xD9, //
  ]);
}

/// 打开筛选弹层(右上 tune 按钮,tooltip 定位;点任意行即收,换档每步重开)。
Future<void> openFilterMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('筛选'));
  await tester.pumpAndSettle();
}

/// 选一个格式档(共享级联子面板:开筛选 → 进格式 → 点档 → 点外收层;
/// [formatName] ∈ all/nef/jpg/mov/mp4/hif)。
Future<void> pickFormat(WidgetTester tester, String formatName) async {
  await openFilterMenu(tester);
  await tester.tap(find.byKey(const ValueKey('formatFilter-entry')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('formatFilter-$formatName')));
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(30, 10)); // 点外收层(选档行不收)
  await tester.pumpAndSettle();
}

/// 开弹层点一行并等收场。弹层行文案页面唯一(旧双行 chips 的
/// 「全部/视频」重名问题随弹层化消失,直接按文案点)。
Future<void> pickFilter(WidgetTester tester, String label) async {
  await openFilterMenu(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 点一次「时间」排序行(直切:当前键翻方向,他键切键;行不收层,
/// 点外收)。
Future<void> tapSortTime(WidgetTester tester) async {
  await openFilterMenu(tester);
  await tester.tap(find.byKey(const ValueKey('sort-time')));
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(30, 10)); // 点外收层
  await tester.pumpAndSettle();
}

/// 排序行行尾示排序图标(自绘 SortBarsIcon;方向断言看排序结果)。
bool sortIconShown(WidgetTester tester) => find
    .descendant(
        of: find.ancestor(
            of: find.text('时间'), matching: find.byType(MenuItemButton)),
        matching: find.byType(SortBarsIcon))
    .evaluate()
    .isNotEmpty;

/// 最小 NEF 合成(II 小端,IFD0@8 条目升序):宽/高/方向/JPEG 偏移/
/// 长度 + 填充 + [thumb] 内嵌缩略。结构对齐 Zf NEF(nef_thumb.dart
/// 提取器口径),专供「无原生 RAW 解码器 → 内嵌缩略兜底」用例。
Uint8List _nefWithEmbeddedThumb(Uint8List thumb, {int orientation = 1}) {
  final entries = <(int, int, int)>[
    (0x0100, 4, 160), // width
    (0x0101, 4, 120), // height
    (0x0112, 3, orientation), // Orientation(SHORT)
    (0x0201, 4, 0), // JPEGInterchangeFormat(合成时回填)
    (0x0202, 4, thumb.length),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  const ifdOffset = 8;
  final ifdSize = 2 + entries.length * 12 + 4;
  final thumbOffset = ifdOffset + ifdSize + 64;
  final out = Uint8List(thumbOffset + thumb.length);
  final d = ByteData.view(out.buffer);
  out.setAll(0, [0x49, 0x49, 0x2A, 0x00]); // II*\0
  d.setUint32(4, ifdOffset, Endian.little);
  d.setUint16(ifdOffset, entries.length, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final e = ifdOffset + 2 + i * 12;
    final (tag, type, value) = entries[i];
    d.setUint16(e, tag, Endian.little);
    d.setUint16(e + 2, type, Endian.little);
    d.setUint32(e + 4, 1, Endian.little); // count
    d.setUint32(e + 8, tag == 0x0201 ? thumbOffset : value, Endian.little);
  }
  d.setUint32(ifdOffset + 2 + entries.length * 12, 0, Endian.little);
  out.setRange(thumbOffset, thumbOffset + thumb.length, thumb);
  return out;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nikonpill_library');
    // AppServices 惰性装配(查看器 DeSqueezedImage 首触)会起 BLE 身份
    // 装载、传输页真单例会列下载目录,都走本通道:三个目录方法给个
    // 无害默认(临时目录),通道错误不落进任何用例的 runAsync 排水窗。
    Future<Object?> galleryHandler(MethodCall call) async =>
        switch (call.method) {
          'dataDir' || 'previewsDir' || 'downloadsDir' => dir.path,
          _ => null,
        };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            MethodChannelGallerySaver.channel, galleryHandler);
    // 同因:AppServices 装配即 ConnectionController 起两个事件流
    // (BLE/NSD 扫描),listen 回 null 是 MissingPluginException ——
    // 异步错在哪个用例的排水窗上浮看运气(单跑/全跑不同),mock 成
    // 空应答(事件流本就不该在图库用例里发事件)钉死顺序无关。
    for (final name in const ['nikonpill/ble/events', 'nikonpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name),
              (call) async => call.method == 'listen' ? '' : null);
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel, null);
    for (final name in const ['nikonpill/ble/events', 'nikonpill/nsd/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
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

  /// 网格类测试用高视口:日期分段后各日纵向堆叠(每段 = 段头 + 行),
  /// 默认 600 逻辑高装不下多段,尾部格不进 cacheExtent 不构建。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(_FakeGallery gallery, TransfersController controller,
          {RawDecoder? rawDecoder,
          VideoPlayer? videoPlayer,
          EmbeddedVideoViewBuilder? embeddedView,
          VideoLutExportHost? videoLut,
          LibraryRatings? ratings}) =>
      MaterialApp(
          home: LocalLibraryPage(
            uiPrefs: InMemoryUiPrefsStore(),
        controller: controller,
        gallery: gallery,
        rawDecoder: rawDecoder ?? _FakeRawDecoder(fail: true),
        videoPlayer: videoPlayer ?? _FakeVideoPlayer(),
        embeddedVideoView: embeddedView,
        videoLutExport: videoLut,
        ratings: ratings,
      ));

  /// 内嵌播放人设:embedded 播放器 + 假视图(onCreated 回固定 viewId 7)。
  Widget embeddedHost(_FakeGallery gallery, TransfersController controller,
          _FakeVideoPlayer player, {VideoLutExportHost? videoLut}) =>
      host(gallery, controller,
          videoPlayer: player,
          embeddedView: (path, onCreated) =>
              _StubVideoView(onCreated: onCreated),
          videoLut: videoLut);

  /// refreshAppFiles 异步列目录(2026-10-22 改制)后的首屏排水:目录
  /// 枚举是 dart:io 真异步,FakeAsync 域里完成回调只在 runAsync 出窗
  /// 上浮(每窗约一个,工程既证规律 —— 删除用例同款),逐窗排水到首扫
  /// 收口且文件列表达预期数(上限兜底防死循环)。期间页面在扫描转圈
  /// (动画帧不停),循环内 pump() 单帧推进即可,收口后才 pumpAndSettle
  /// (旧版 pumpWidget 后直接 pumpAndSettle 依赖的是同步列目录时序)。
  Future<void> drainAppFiles(WidgetTester tester, TransfersController c,
      [int? expectCount]) async {
    for (var i = 0;
        i < 20 &&
            (!c.appFilesScanned ||
                (expectCount != null && c.appFiles.length != expectCount));
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(c.appFilesScanned, isTrue, reason: '首扫收口(排水窗内目录枚举完成)');
    if (expectCount != null) {
      expect(c.appFiles.length, expectCount, reason: '文件列表就位');
    }
    await tester.pumpAndSettle();
  }

  testWidgets('空态:应用内还没有文件', (tester) async {
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    expect(find.text('图库'), findsOneWidget); // AppBar
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'), findsOneWidget);
  });

  // ── 首扫扫描态/筛后空态(2026-10-22:refreshAppFiles 异步化 + 状态分流)──

  testWidgets('首扫扫描态:未收口转圈,收口后落空态(与真空库可分)', (tester) async {
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    // 目录枚举是真 dart:IO:未开窗前扫描未回 —— 扫描态在场,空态文案
    // 不出现(旧版 files.isEmpty 直接落空态,扫描中/真空库不可分)。
    await tester.pump();
    expect(controller.appFilesScanned, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在扫描文件…'), findsOneWidget);
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'), findsNothing);

    await drainAppFiles(tester, controller);
    expect(controller.appFilesScanned, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('应用内还没有文件\n(在相机相册里选择「下载到应用」)'), findsOneWidget);
    // 真空库(未筛过)不出「清除筛选」:那是筛后空的专属动作。
    expect(find.text('清除筛选'), findsNothing);
  });

  testWidgets('筛后空态:带「清除筛选」动作,点按回全部恢复网格', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller, 1);

    await pickFormat(tester, 'mov');
    // 筛后空:文案 + 「清除筛选」动作(EmptyState 动作位),不再是裸 Text。
    expect(find.text('没有MOV格式的文件'), findsOneWidget);
    final clear = find.widgetWithText(FilledButton, '清除筛选');
    expect(clear, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget); // 回「全部」:网格恢复
    expect(find.text('清除筛选'), findsNothing);
  });

  testWidgets('网格:修改时间倒序;可解码图片铺格,NEF 落图标格', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    // a.jpg(最旧)/ b.jpg / c.nef(最新)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.nef', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 两张可解码图片(Image.file;内容非图走 errorBuilder,组件仍在)
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('NEF'), findsOneWidget); // 原生格式落图标格

    // 点最新图片进查看器(倒序:图片格里第一张是 b.jpg)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsWidgets); // 查看器 AppBar 标题
  });

  testWidgets('格式过滤:弹层 RAW/JPG/视频按扩展名收窄网格', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.nef', modified: DateTime(2026, 10, 2));
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 全部:一张可解码图 + NEF 图标格 + MOV 图标格(摄像机图标)
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

    await pickFormat(tester, 'nef');
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    // 多选并集:切档前先回「全部」清空(与旧单选流等价)。
    await pickFormat(tester, 'all');
    await pickFormat(tester, 'mov');
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byType(Image), findsNothing);

    await pickFormat(tester, 'all');
    await pickFormat(tester, 'jpg');
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    await pickFormat(tester, 'all');
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });

  testWidgets('视频格:摄像机角标退场,时长胶囊上屏(mvhd 本地读)', (tester) async {
    useTallSurface(tester);
    // 最小容器:ftyp(16B)+ moov[mvhd v0](48B)= 64B,时长 150s。
    final mov = Uint8List.fromList([
      0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, ...List.filled(8, 0x20),
      0, 0, 0, 48, 0x6d, 0x6f, 0x6f, 0x76,
      0, 0, 0, 40, 0x6d, 0x76, 0x68, 0x64,
      0x00, 0x00, 0x00, 0x00,
      0, 0, 0, 1, 0, 0, 0, 2,
      0, 0, 2, 88, // timescale 600
      0, 0, 1, 95, // duration 419 → 419/600 ≈ 0.698s → 0:00?毫秒取整
      0, 0, 0, 1, 1, 0, 0, 0,
    ]);
    // 重写 timescale(物理 44-47)/duration(48-51)= 150s:
    final ts = 1000, dur = 150000; // 150s
    mov[44] = (ts >> 24) & 0xff; mov[45] = (ts >> 16) & 0xff;
    mov[46] = (ts >> 8) & 0xff; mov[47] = ts & 0xff;
    mov[48] = (dur >> 24) & 0xff; mov[49] = (dur >> 16) & 0xff;
    mov[50] = (dur >> 8) & 0xff; mov[51] = dur & 0xff;
    final f = File('${dir.path}/c.mov');
    f.writeAsBytesSync(mov);
    f.setLastModifiedSync(DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(failThumbs: false);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await drainAppFiles(tester, controller);

    // 摄像机角标退场;时长胶囊上屏(150s → 2:30)。
    expect(find.byIcon(Icons.videocam), findsNothing);
    // 时长探测是真 IO:逐窗排水等 mvhd 读取收口再断言(一窗只上浮
    // 一个回调,open/setPosition/read/close 链多窗才走完)。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }
    expect(find.text('2:30'), findsOneWidget);
  });

  testWidgets('过滤无匹配:提示该格式暂无,切回全部即恢复', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await pickFormat(tester, 'mov');
    expect(find.text('没有MOV格式的文件'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await pickFormat(tester, 'all');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('评级:徽标上屏;评级档(快照装载后)收窄网格,筛空走专用文案', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    // a.jpg ★3(3 字节档,见 writeFile)/ b.jpg 未评。
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    final store = InMemoryRatingsStore();
    await store.set(fileRatingKey('a.jpg', 3), 3);
    final ratings = LibraryRatings(store: store);
    addTearDown(ratings.dispose);
    await tester.pumpWidget(host(gallery, controller, ratings: ratings));
    // refreshAppFiles 异步列目录(9a66323 改制):runAsync 排水窗等首扫
    // 收口(不 await 则与 pumpAndSettle 的假时钟泵赛跑,IO 上浮晚于断言)。
    await drainAppFiles(tester, controller, 2);
    await tester.pumpAndSettle();

    // 显示.评级:勾上后评级图标上格(默认净格)。
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('show-rating')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();

    // 徽标:a.jpg 左下胶囊内 ★3;两格照常。
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget);

    // 主面板:评级分区收成单行入口(7 档收进级联子面板;图库无垃圾星/
    // 未知档,星档键 = 4-8)。
    await openFilterMenu(tester);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);
    expect(find.text('无评级'), findsNothing);

    // 点开子面板:与父面板共存(排序区仍在),全部 + 5 分类。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-entry')));
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsOneWidget); // 父面板保持
    expect(find.byKey(const ValueKey('ratingFilter-0')), findsOneWidget);
    expect(find.text('无评级'), findsNothing); // 无评级亦仅图标
    expect(find.byKey(const ValueKey('ratingFilter-1')), findsOneWidget);
    expect(find.text('已评级'), findsNothing);

    // ★3:只剩 a.jpg;弹层不收(选档不收层,点外才收)。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-6')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);

    // 接着勾无评级:多选并集 = a + b。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-1')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget); // a.jpg 星标仍在

    // 勾「全部」:互斥清空,网格复原。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-0')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget);

    // 点弹层外:整体收起。
    await tester.tapAt(const Offset(30, 10)); // AppBar 空区(高视口下 400 落格,穿透)
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsNothing);

    // ★4 筛空:单勾 ★4 → 专用文案(格式档不背锅)。
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('ratingFilter-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ratingFilter-7')));
    await tester.pumpAndSettle();
    expect(find.text('没有该评级的文件'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);
    await tester.tapAt(const Offset(30, 10)); // AppBar 空区(高视口下 400 落格,穿透)
    await tester.pumpAndSettle();
  });

  testWidgets('分区折叠:一级头点按收展,行随头隐现', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await openFilterMenu(tester);
    // 折叠排序区:三行消失,头行在;展开复原。
    await tester.tap(find.byKey(const ValueKey('section-sort')));
    await tester.pumpAndSettle();
    expect(find.text('时间'), findsNothing);
    expect(find.text('排序'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('section-sort')));
    await tester.pumpAndSettle();
    expect(find.text('时间'), findsOneWidget);

    // 折叠筛选区:格式/评级入口行消失;展开复原。
    await tester.tap(find.byKey(const ValueKey('section-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('section-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsOneWidget);
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('删除候选:值 -1 不显星标;筛选行(仅图标)收窄网格', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    final store = InMemoryRatingsStore();
    await store.set(fileRatingKey('a.jpg', 3), 3);
    await store.set(fileRatingKey('c.jpg', 3), -1); // 下载沿垃圾桶档
    final ratings = LibraryRatings(store: store);
    addTearDown(ratings.dispose);
    await tester.pumpWidget(host(gallery, controller, ratings: ratings));
    await drainAppFiles(tester, controller, 2);
    await tester.pumpAndSettle();

    // 显示.评级:勾上后评级图标上格。
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('show-rating')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();

    // 徽标:a.jpg ★3;c.jpg 删除候选不显星标(值 -1 归零)。
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget);

    // 筛选:删除候选行(仅图标)→ 只剩 c.jpg;勾「全部」复原。
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('ratingFilter-entry')));
    await tester.pumpAndSettle();
    // 菜单行 + c.jpg 格上删除候选徽标(格上也有角标,与相机相册一致)
    expect(find.byType(TrashRatingIcon), findsNWidgets(2));
    expect(find.text('删除候选'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ratingFilter-2')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('3'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ratingFilter-0')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    await tester
        .tapAt(const Offset(30, 10)); // AppBar 空区(高视口下 400 落格,穿透) // 点外收层
    await tester.pumpAndSettle();
  });

  testWidgets('查看器:导入系统相册(kind 按扩展名)→ 相册服务落账', (tester) async {
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

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

  testWidgets(
      '视频 LUT 导出:视频页入口 → 选表 → 导出落库(_LUT.mp4 改名,'
      '临时档用完即删)', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    final outPath = '${dir.path}/_out.mp4';
    File(outPath).writeAsBytesSync([9, 9, 9]);
    final lut = _FakeVideoLut(outPath);
    await tester
        .pumpWidget(embeddedHost(gallery, controller, player, videoLut: lut));
    // 扫描转圈期 pumpAndSettle 挂帧:先排水到首扫收口(其余用例同款)。
    await drainAppFiles(tester, controller);

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    // 视频页有 LUT 入口(照片页由 isVideoFilename 门自然不出现)
    expect(find.byTooltip('LUT 导出'), findsOneWidget);

    await tester.tap(find.byTooltip('LUT 导出'));
    await tester.pumpAndSettle();
    expect(find.text('LUT 风格'), findsOneWidget);

    await tester.tap(find.text('青橙'));
    await tester.pumpAndSettle();

    expect(lut.exportCalls, ['${dir.path}/c.mov']);
    final call = gallery.importCalls.single.single;
    expect(call.filename, 'c_LUT.mp4');
    expect(call.kind, ObjectKind.video);
    expect(find.text('已保存到系统相册'), findsOneWidget);
    expect(File(outPath).existsSync(), isFalse); // 临时档用完即删

    // 冲掉 snackbar 的自动消失 timer(不能留 pending 到测试末)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets(
      '信息底单:本地 JPG 头读 EXIF(机身/参数/兜底时间),'
      'MOV 只走文件级信息', (tester) async {
    // 带 EXIF 的「JPG」(SOI+APP1+EOI,无图像数据:网格解码走占位,
    // 头读只认头部)。无 takenAt → 时间行回落文件 mtime(「时间」非
    // 「拍摄时间」)。
    File('${dir.path}/exif.jpg').writeAsBytesSync(_jpgExifBytes());
    writeFile('v.mov', modified: DateTime(2026, 10, 4));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // JPG 页(修改时间倒序,exif.jpg 最新在前)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();
    Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet), matching: find.text(text));
    expect(inSheet('exif.jpg'), findsOneWidget);
    expect(inSheet('NIKON Zf'), findsOneWidget, reason: '机身(titleLine)');
    expect(inSheet('40mm ƒ/2 · 1/250s · ISO 100'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(BottomSheet), matching: find.text('拍摄时间')),
        findsNothing,
        reason: 'EXIF 无时间 → 不出「拍摄时间」行');

    await tester.tapAt(const Offset(10, 10)); // 关底单
    await tester.pumpAndSettle();

    // 翻到视频页:文件级信息在场,EXIF 段不出(负 x = 下一页)
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();
    expect(inSheet('v.mov'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(BottomSheet), matching: find.text('机身')),
        findsNothing);
    expect(
        find.descendant(
            of: find.byType(BottomSheet),
            matching: find.textContaining('2026-10-04')),
        findsOneWidget,
        reason: '时间行(mtime 兜底)');
  });

  testWidgets('长按进多选:预选该格,批量删除确认把关,删后网格收缩', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    expect(find.byType(Image), findsNWidgets(2));

    await tester.longPress(find.byType(Image).first); // b.jpg(最新在前)
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget); // AppBar 计数
    // 格上勾 + 段头「该日已全选」勾(共享段头多选沿)
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byType(BottomAppBar), findsOneWidget); // 操作栏常驻

    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除应用内文件?'), findsOneWidget);
    expect(find.textContaining('将删除 1 个文件'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(File('${dir.path}/b.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/a.jpg').existsSync(), isTrue); // 相邻不受牵连
    // 删除与 refreshAppFiles 的目录枚举都是真异步 I/O:FakeAsync 域里
    // 完成回调不上浮(文件已删但 Dart 侧刷新链没跑),开窗排水到网格
    // 收缩(旧版单窗够 —— 刷新链里只有同步列目录;异步化后 exists+list
    // 各占窗,须逐窗排水)。
    await drainAppFiles(tester, controller, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('图库'), findsOneWidget); // 删后退出多选,标题复原

    // 冲掉 snackbar 的自动消失 timer(不能留 pending 到测试末)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── 筛选弹层/多选(2026-10-16:iPhone 图库式收口,筛选进弹层,
  // 长按格进多选,操作栏批量删/导出)──

  testWidgets('筛选弹层:分区头在场,当前项打勾,换档勾随迁、点行即收', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await openFilterMenu(tester);
    // 排序区(共享):三行平铺,当前键(时间)行尾示排序图标。
    // 筛选区 = 共享两级联子面板入口(格式 + 评级;评级未建立仅格式)。
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('时间'), findsOneWidget);
    expect(find.text('文件名'), findsOneWidget);
    expect(find.text('文件大小'), findsOneWidget);
    expect(sortIconShown(tester), isTrue);
    expect(find.text('筛选'), findsOneWidget);
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsOneWidget);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsNothing);
    expect(find.text('视图选项'), findsOneWidget);
    expect(find.text('连拍聚合'), findsOneWidget);
    // 排序行无勾(勾位语言专属格式/评级多选)
    Finder checkBeside(String label) => find.descendant(
        of: find.ancestor(
            of: find.text(label), matching: find.byType(MenuItemButton)),
        matching: find.byIcon(Icons.check));
    expect(checkBeside('时间'), findsNothing);

    // 点时间行:直切翻向(不收层,无二级面板)。
    await tester.tap(find.byKey(const ValueKey('sort-time')));
    await tester.pumpAndSettle();
    expect(sortIconShown(tester), isTrue); // 图标同码,方向看排序结果
    expect(find.byType(MenuItemButton), findsWidgets); // 弹层保持(行仍在)

    // 点外收层;再点翻回。
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('sort-time')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
    await openFilterMenu(tester);
    await tester.tap(find.byKey(const ValueKey('formatFilter-entry')));
    await tester.pumpAndSettle();
    expect(checkBeside('全部'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('formatFilter-nef')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing); // 只剩?—— 本例无 NEF:筛空
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('长按进多选:勾选启用操作栏,空选禁用,退出复原', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await tester.longPress(find.byType(Image).first); // b(最新在前)预选
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('取消选择'), findsOneWidget);
    FilledButton exportBtn() => tester.widget<FilledButton>(find.ancestor(
        of: find.text('导出到系统相册'), matching: find.byType(FilledButton)));
    expect(exportBtn().onPressed, isNotNull); // 勾选即启用

    await tester.tap(find.byType(Image).first); // b 再点 = 取消
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(exportBtn().onPressed, isNull); // 空选禁用

    await tester.tap(find.byType(Image).at(1)); // a 勾上
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(exportBtn().onPressed, isNotNull); // 勾选即启用

    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('图库'), findsOneWidget);
    expect(find.byType(BottomAppBar), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('多选增删与全选:点格勾/取消,全选收齐', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await tester.longPress(find.byType(Image).first); // b(最新在前)预选
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).at(1)); // a 勾上
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.byType(Image).first); // b 再点 = 取消
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    // b 格未选圈 + b 段头「未全选」圈(共享段头多选沿)
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));

    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    // 两格勾 + 两段头「已全选」勾
    expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('批量删除取消:确认框点取消,文件与选中态不动', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.text('将删除 1 个文件。\n此操作不可恢复(相机上的原件不受影响)。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(File('${dir.path}/a.jpg').existsSync(), isTrue);
    expect(find.text('已选 1 项'), findsOneWidget); // 选中态保留
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  testWidgets('批量导出:一次批量落账(kind 按扩展名),应用内文件保留', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('v.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await tester.longPress(find.byType(Image).first); // v.mov(最新在前)预选
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('导出到系统相册'));
    await tester.pumpAndSettle();

    expect(gallery.importCalls, hasLength(1)); // 一次批量调用,不逐格拆单
    final call = gallery.importCalls.single;
    expect(call, hasLength(2));
    expect(
        call.map((r) => r.kind).toSet(), {ObjectKind.image, ObjectKind.video});
    expect(call.map((r) => r.filename).toSet(), {'a.jpg', 'v.mov'});
    expect(find.text('已导出 2 项到系统相册(应用内文件保留)'), findsOneWidget);
    // 复制不是移动:两文件原位保留
    expect(File('${dir.path}/a.jpg').existsSync(), isTrue);
    expect(File('${dir.path}/v.mov').existsSync(), isTrue);
    expect(find.text('图库'), findsOneWidget); // 导出后退出多选

    // 冲掉 snackbar 的自动消失 timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('批量导出取消:空回列表 → 未导入文案,退出多选,文件原位', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir)..importResult = const [];
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出到系统相册'));
    await tester.pumpAndSettle();

    expect(gallery.importCalls, hasLength(1));
    expect(find.text('未导入(已取消或失败)'), findsOneWidget);
    expect(File('${dir.path}/a.jpg').existsSync(), isTrue);
    expect(find.text('图库'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('传输徽标:进行中任务数角标;点击进传输页', (tester) async {
    final gallery = _FakeGallery(dir);
    final engine = _FakeEngine();
    final controller = TransfersController(engine: engine, gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
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
    await drainAppFiles(tester, controller);

    // 网格缩略:512px 解码一次(会话内合并),落盘 thumbsDir
    // (内容键 + libv4_ 前缀,不与相机侧缩略键串台;键全量升版 = 黑边裁剪放开到全部缩略)。
    expect(decoder.calls, [('${dir.path}/c.nef', 512)]);
    expect(File('${gallery.thumbs.path}/libv4_c.nef_3.jpg').existsSync(), isTrue);

    // 点 NEF 格进查看器:标题 + 2560px 全尺寸解码(假 JPEG 解不开走
    // errorBuilder,Image 组件在即可)。格键 = 文件名(缩略解码后
    // 图标格文案不再保证在场,按格点)。查看器两枚 Image = 300px 防黑闪
    // 垫底(ResizeImage contain,缓存命中即显)+ 解码大图(MemoryImage)。
    await tester.tap(find.byKey(const ValueKey('c.nef')));
    await tester.pumpAndSettle();
    expect(find.text('c.nef'), findsWidgets); // 查看器 AppBar
    expect(decoder.calls.last, ('${dir.path}/c.nef', 2560));
    expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is Image && w.image is ResizeImage),
        findsOneWidget);
  });

  testWidgets('NEF 无解码器:网格图标格顶位,查看器报错占位', (tester) async {
    writeFile('c.nef', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    // host 缺省注入 failing 解码器。
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    expect(find.text('NEF'), findsOneWidget); // 图标格
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('NEF'));
    // 兜底探路(内嵌缩略提取)是真 IO,FakeAsync 域完成回调只在 runAsync
    // 出窗上浮:逐窗排水至失败落位(无内嵌缩略 → 报错占位)。
    var failed = false;
    for (var i = 0; i < 40 && !failed; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      failed = find.text('解码失败(该平台可能不支持)').evaluate().isNotEmpty;
    }
    expect(failed, isTrue);
  });

  // ── HIF 可看可点(2026-10-24:与 NEF 同族走原生解码通道,不再
  // 图标格 + 不可点;真机语境 iOS CGImageSource 直解 HEIF)──

  testWidgets('HIF:网格缩略解码落盘,点进查看器解码大图', (tester) async {
    writeFile('c.hif', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final decoder = _FakeRawDecoder();
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await drainAppFiles(tester, controller);

    // 与 NEF 同管线:格缩略 512px 解码一次,落盘 thumbsDir(libv3 键)。
    expect(decoder.calls, [('${dir.path}/c.hif', 512)]);
    expect(File('${gallery.thumbs.path}/libv4_c.hif_3.jpg').existsSync(), isTrue);

    // 点 HIF 格进查看器:标题 + 2560px 全尺寸解码(假 JPEG 解不开走
    // errorBuilder,Image 组件在即可)。两枚 Image = 300px 防黑闪垫底 +
    // 解码大图(同 NEF 口径)。
    await tester.tap(find.byKey(const ValueKey('c.hif')));
    await tester.pumpAndSettle();
    expect(find.text('c.hif'), findsWidgets); // 查看器 AppBar
    expect(decoder.calls.last, ('${dir.path}/c.hif', 2560));
    expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is Image && w.image is ResizeImage),
        findsOneWidget);
  });

  testWidgets('HIF 无解码器:网格图标格顶位,查看器报错占位', (tester) async {
    writeFile('c.hif', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    // host 缺省注入 failing 解码器。
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    expect(find.text('HIF'), findsOneWidget); // 图标格
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('HIF'));
    await tester.pumpAndSettle();
    expect(find.text('解码失败(该平台可能不支持)'), findsOneWidget);
  });

  // ── NEF 内嵌缩略兜底(2026-10-24 ohos 缩略缺口:无原生 RAW 解码器
  // 平台的网格真身)──

  testWidgets('NEF 无解码器:内嵌缩略兜底铺格(方向注入落盘)', (tester) async {
    // 内嵌缩略给真 JPEG(引擎可解),方向 8(竖拍横置):提取 → 注入
    // EXIF → 引擎解码转正,格出图不落图标格(ohos/Android 无原生 RAW
    // 解码器时网格缩略的真身,与相机相册 GetThumb 同质)。
    final jpeg =
        Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));
    final nef = _nefWithEmbeddedThumb(jpeg, orientation: 8);
    File('${dir.path}/c.nef').writeAsBytesSync(nef);
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    final cache =
        File('${gallery.thumbs.path}/libv4_c.nef_${nef.length}.jpg');
    // 缩略串行链内嵌缩略提取是真 IO(RandomAccessFile 头读/段读):
    // FakeAsync 域完成回调只在 runAsync 出窗上浮,逐窗排水至小档落盘。
    var written = false;
    for (var i = 0; i < 40 && !written; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      written = cache.existsSync();
      await tester.pump();
    }
    expect(written, isTrue, reason: '内嵌缩略兜底落盘');
    await tester.pumpAndSettle();
    final cached = cache.readAsBytesSync();
    expect(cached.length, greaterThan(jpeg.length)); // 注入 APP1 变长
    expect(String.fromCharCodes(cached.sublist(0, 24)), contains('Exif'));
    expect(find.text('NEF'), findsNothing); // 不再图标格
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('NEF 无解码器:查看器回内嵌缩略兜底(不再报错占位)', (tester) async {
    // 原生解码缺席(缺省 failing 解码器 = ohos/Android 无通道人设)时
    // 查看器大图回内嵌缩略(方向注入 + 黑边裁剪装配,nefEmbeddedJpeg)
    // —— 不再死在「解码失败」。HIF 解码失败不走此兜底(见上一组)。
    final jpeg =
        Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));
    final nef = _nefWithEmbeddedThumb(jpeg, orientation: 8);
    File('${dir.path}/c.nef').writeAsBytesSync(nef);
    final gallery = _FakeGallery(dir);
    final decoder = _FakeRawDecoder(fail: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await drainAppFiles(tester, controller);

    // 网格先行:格缩略兜底同链,排完才可按格键点进查看器。
    final thumbCache =
        File('${gallery.thumbs.path}/libv4_c.nef_${nef.length}.jpg');
    var written = false;
    for (var i = 0; i < 40 && !written; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      written = thumbCache.existsSync();
      await tester.pump();
    }
    expect(written, isTrue, reason: '网格缩略兜底先行落盘');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('c.nef')));
    await tester.pump(); // 查看器进场(解码在途,菊花在屏不能 settle)
    // 查看器兜底同链真 IO:逐窗排水至大图上屏(512 与 2560 各解码一次)。
    var shown = false;
    for (var i = 0; i < 40 && !shown; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      shown = find.byType(Image).evaluate().isNotEmpty;
    }
    expect(shown, isTrue, reason: '查看器回内嵌缩略兜底出图');
    expect(decoder.calls.last, ('${dir.path}/c.nef', 2560)); // 原生先试
    expect(find.text('解码失败(该平台可能不支持)'), findsNothing);
    expect(find.text('c.nef'), findsWidgets); // 查看器 AppBar
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
    await drainAppFiles(tester, controller);

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
    await drainAppFiles(tester, controller);

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
    await drainAppFiles(tester, controller);

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
    await drainAppFiles(tester, controller);

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
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      chromeCalls.add(call);
      return null;
    });
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await drainAppFiles(tester, controller);

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
    expect(orientationCalls().first, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight'
    ]); // 锁横屏
    expect(chromeCalls.any((c) => c.method.contains('SystemUIMode')),
        isTrue); // 沉浸

    // 退全屏:顶栏回来,方向**钉回竖屏**(查看器竖排 UI,交还传感器
    // 集会在设备横放时滞留横屏 —— 2026-10-24 真机复报)
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(find.text('c.mov'), findsWidgets);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(orientationCalls().last, ['DeviceOrientation.portraitUp']);
  });

  testWidgets('MOV:无内嵌视图平台(Android)回落海报帧 + 播放钮'
      '(点了走原生全屏播放)', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(failThumbs: false);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await drainAppFiles(tester, controller);

    // 抽帧一次(会话内合并),落盘 thumbsDir(libv4_ 前缀内容键,与
    // NEF 同管线)。
    expect(player.thumbs, [('${dir.path}/c.mov', 512)]);
    // 键全量升版(libv4_):黑边裁剪放开到全部缩略。
    expect(
        File('${gallery.thumbs.path}/libv4_c.mov_3.jpg').existsSync(), isTrue);

    await tester.tap(find.byKey(const ValueKey('c.mov')));
    await tester.pumpAndSettle();
    // 查看器海报帧走页面级缓存:不重复抽帧;播放钮在场(原生全屏路)。
    expect(player.thumbs, hasLength(1));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(player.played, [('${dir.path}/c.mov', 1.0)]); // 原生全屏播放
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
    await drainAppFiles(tester, controller);

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

  testWidgets(
      '查看器预热:邻页预解码进缓存 + 缓存预算随查看器开收'
      '(2026-10-20 翻页黑闪根修)', (tester) async {
    // 真字节(可解码):预热命中才能从 imageCache 断言;假字节走
    // precache 静默失败,测不出命中。
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    final a = writeReal('a.jpg', DateTime(2026, 10, 1));
    writeReal('b.jpg', DateTime(2026, 10, 2));
    final c = writeReal('c.jpg', DateTime(2026, 10, 3));
    final cache = PaintingBinding.instance.imageCache;
    final budgetBefore = cache.maximumSizeBytes;
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 倒序 c,b,a;开在中间张(b):两侧邻居都在预热射程
    await tester.tap(find.byKey(const ValueKey('b.jpg')));
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsWidgets);
    expect(cache.maximumSizeBytes, 512 << 20); // 查看器语境临时预算

    // 预热解码(dart:io 读档 + 引擎解码):runAsync 逐窗排水到命中。
    // 当前页 b 自己解是常驻行为,不算预热;只认两侧邻居 a/c。
    bool bothWarmed() =>
        cache.containsKey(FileImage(a)) && cache.containsKey(FileImage(c));
    for (var i = 0; i < 10 && !bothWarmed(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(bothWarmed(), isTrue);

    // 收查看器:预算还原(高预算只随查看器存续,不动全局默认)
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(cache.maximumSizeBytes, budgetBefore);
  });

  testWidgets(
      'JPG 网格格走小档管线:落盘 + 换小档源 + gapless'
      '(2026-10-20 缩略重刷根治)', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final decoder = _FakeRawDecoder(); // 成功人设
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await drainAppFiles(tester, controller);

    // 小档解码一次、落盘 thumbsDir(与 NEF/MOV 同管线同键式)
    expect(decoder.calls, [('${dir.path}/a.jpg', 512)]);
    expect(File('${gallery.thumbs.path}/libv4_a.jpg_3.jpg').existsSync(), isTrue);

    // 格已换小档源:provider 指向小档文件,gapless 换源保帧不闪
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.gaplessPlayback, isTrue);
    final inner = (image.image as ResizeImage).imageProvider as FileImage;
    expect(inner.file.path, '${gallery.thumbs.path}/libv4_a.jpg_3.jpg');
  });

  testWidgets('查看器:图片滑到视频不自动播放(装载即暂停)', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 2));
    writeFile('b.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(embeddedHost(gallery, controller, player));
    await drainAppFiles(tester, controller);

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

  testWidgets('查看器删除:当前页删除下一张滑入;删尾页翻回前一页', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 倒序 c,b,a;打开 c
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    // 删除前把在途图片 IO 全部出窗(drainAppFiles 同机制:dart:io 完成回调
    // 只在 runAsync 窗上浮,一窗一个)—— 格/页对 c 的在途读若拖到删除后
    // 才出窗,撞「档已无」且 listener 已卸,由 ImageCache 报 image
    // resource service 翻测试;文件还在时出窗只会 codec 失败,走
    // errorBuilder/precache onError 静默口,不外冒。
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // 删当前页 c → b 滑入(页位不变,下一张补上)。删除+异步列目录刷新
    // 链逐窗排水(见 drainAppFiles 注)。
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await drainAppFiles(tester, controller, 2);
    expect(File('${dir.path}/c.jpg').existsSync(), isFalse);
    expect(find.text('b.jpg'), findsWidgets);

    // 滑到尾页 a,删除 → 翻回前一页 b(不白屏)
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('a.jpg'), findsWidgets);
    // 同上:a 页在途读删除前出窗,不外冒(第二次删除前)。
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await drainAppFiles(tester, controller, 1);
    expect(File('${dir.path}/a.jpg').existsSync(), isFalse);
    expect(find.text('b.jpg'), findsWidgets); // 尾页删除后落回 b
    expect(find.byType(PageView), findsOneWidget); // 查看器还在
  });

  // ── 排序(时间两向,弹层切换)──

  testWidgets('排序:默认新→旧不动;「旧→新」翻向,查看器随排序翻页', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 默认新→旧:首格 c(既有默认,行为不变)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('c.jpg'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 旧→新(点时间行直切翻向):首格 a,翻页序随排序(a → b)
    await tapSortTime(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsWidgets);
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('b.jpg'), findsWidgets);

    // 回新→旧(再点翻向):首格回到 c
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tapSortTime(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('c.jpg'), findsWidgets);
  });

  // ── 连拍聚合(2026-10-14:相邻拍摄时刻成段合为一格,与相机相册
  // buildPhotoGroups 第三遍同参;mtime = 拍摄时刻由下载引擎回写)──

  test('连拍聚合:散时刻全单段(每文件独立)', () {
    final files = [
      writeFile('a.jpg', modified: DateTime(2026, 10, 1, 10, 0, 0)),
      writeFile('b.jpg', modified: DateTime(2026, 10, 1, 10, 5, 0)),
      writeFile('c.jpg', modified: DateTime(2026, 10, 1, 10, 40, 0)),
    ];
    expect(groupLocalBurstRuns(files), [
      [files[0]],
      [files[1]],
      [files[2]],
    ]);
  });

  test('连拍聚合:3 张 100ms 间隔聚为一段', () {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final files = [
      writeFile('a.jpg', modified: base),
      writeFile('b.jpg', modified: base.add(const Duration(milliseconds: 100))),
      writeFile('c.jpg', modified: base.add(const Duration(milliseconds: 200))),
    ];
    expect(groupLocalBurstRuns(files), [files]);
  });

  test('连拍聚合:相邻差 600ms 超窗断段,窗内段照聚', () {
    // setLastModifiedSync 秒级取整(dart:io 限制,宿主机实证:设
    // .600ms 读回 .000),毫秒窗边界走注入时刻(见 groupLocalBurstRuns
    // 库注);真机 mtime 同为秒级粒度,窗语义不变(同秒内聚、跨秒断)。
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final a = writeFile('a.jpg');
    final b = writeFile('b.jpg');
    final c = writeFile('c.jpg');
    final d = writeFile('d.jpg');
    final times = {
      a: base,
      b: base.add(const Duration(milliseconds: 600)),
      c: base.add(const Duration(milliseconds: 700)),
      d: base.add(const Duration(milliseconds: 800)),
    };
    // a |600ms 超窗| b,c,d(各 100ms)→ a 单段 + bcd 一段
    expect(groupLocalBurstRuns([a, b, c, d], modifiedOf: (f) => times[f]!), [
      [a],
      [b, c, d],
    ]);
  });

  test('连拍聚合:同基名 JPG+NEF 孪生同刻不聚(1 基名)', () {
    final t = DateTime(2026, 10, 1, 10, 0, 0);
    final jpg = writeFile('DSC_0001.JPG', modified: t);
    final nef = writeFile('DSC_0001.NEF', modified: t);
    expect(groupLocalBurstRuns([jpg, nef]), [
      [jpg],
      [nef],
    ]);
  });

  test('连拍聚合:3 张 × 双格式 6 文件聚一段(不同基名数 = 3)', () {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final files = <File>[];
    var i = 0;
    for (final name in ['DSC_0001', 'DSC_0002', 'DSC_0003']) {
      final t = base.add(Duration(milliseconds: 150 * i++));
      files.add(writeFile('$name.JPG', modified: t));
      files.add(writeFile('$name.NEF', modified: t));
    }
    final runs = groupLocalBurstRuns(files);
    expect(runs, hasLength(1));
    expect(runs.single, hasLength(6));
    expect(runs.single.map((f) => baseNameOf(f.uri.pathSegments.last)).toSet(),
        hasLength(3));
  });

  test('连拍聚合:段内 2 基名不足成段(边界不聚)', () {
    final t = DateTime(2026, 10, 1, 10, 0, 0);
    final aj = writeFile('a.jpg', modified: t);
    final an = writeFile('a.nef', modified: t);
    final bj = writeFile('b.jpg', modified: t);
    final bn = writeFile('b.nef', modified: t);
    expect(groupLocalBurstRuns([aj, an, bj, bn]), [
      [aj],
      [an],
      [bj],
      [bn],
    ]);
  });

  test('连拍聚合:升序输入同样生效(对方向不敏感)', () {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final old =
        writeFile('z.jpg', modified: base.subtract(const Duration(hours: 1)));
    final c = writeFile('c.jpg', modified: base);
    final b = writeFile('b.jpg',
        modified: base.add(const Duration(milliseconds: 100)));
    final a = writeFile('a.jpg',
        modified: base.add(const Duration(milliseconds: 200)));
    // 旧→新输入:old 单段 + c,b,a(倒着相邻差 100ms)聚一段
    expect(groupLocalBurstRuns([old, c, b, a]), [
      [old],
      [c, b, a],
    ]);
  });

  testWidgets('连拍聚合弹层开关:成段合为一格带 ×N 角标,点开段内翻张,关掉恢复平铺', (tester) async {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    // 三连拍(mtime = 拍摄时刻)+ 一张散拍
    writeFile('b1.jpg', modified: base);
    writeFile('b2.jpg', modified: base.add(const Duration(milliseconds: 100)));
    writeFile('b3.jpg', modified: base.add(const Duration(milliseconds: 200)));
    writeFile('solo.jpg', modified: base.subtract(const Duration(minutes: 10)));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 默认平铺:4 格,无角标
    expect(find.byType(Image), findsNWidgets(4));
    expect(find.text('×3'), findsNothing);

    // 开连拍:倒序 [b3,b2,b1] 聚一段(封面 b3)+ solo 独立格 → 2 格
    await pickFilter(tester, '连拍聚合');
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('×3'), findsOneWidget);

    // 点连拍格:查看器初始页 = 封面,peers = 段内 3 张可翻张
    await tester.tap(find.byKey(const ValueKey('b3.jpg')));
    await tester.pumpAndSettle();
    expect(find.text('b3.jpg'), findsWidgets);
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('b2.jpg'), findsWidgets);
    // 段外文件(solo)不在查看器翻页集里
    expect(find.text('solo.jpg'), findsNothing);

    // 关连拍:恢复平铺 4 格
    await tester.pageBack();
    await tester.pumpAndSettle();
    await pickFilter(tester, '连拍聚合');
    expect(find.byType(Image), findsNWidgets(4));
    expect(find.text('×3'), findsNothing);
  });

  testWidgets('连拍格长按:整段成员一次全选,批量删除整段', (tester) async {
    useTallSurface(tester); // 日期分段后各日纵向堆叠,600 高视口装不下(尾部格不进 cacheExtent)
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    writeFile('b1.jpg', modified: base);
    writeFile('b2.jpg', modified: base.add(const Duration(milliseconds: 100)));
    writeFile('b3.jpg', modified: base.add(const Duration(milliseconds: 200)));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    await pickFilter(tester, '连拍聚合');
    expect(find.text('×3'), findsOneWidget);

    // 长按连拍格:进多选,整段 3 成员(3 基名)原子勾上
    await tester.longPress(find.byKey(const ValueKey('b3.jpg')));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    // 段内唯一连拍格勾 + 其段头「已全选」勾
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));

    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除 3 个文件'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 真异步 IO 的完成回调在 runAsync 出窗时才上浮(单删一个窗够,
    // 批量要逐窗排水):开窗直到三文件全消失 + 异步列目录刷新链收口
    // (refreshAppFiles 异步化后 exists+list 再各占窗)。整段全删,
    // 列表归零(expectCount = 0)。
    await drainAppFiles(tester, controller, 0);
    await tester.pumpAndSettle();

    // 整段删除:三文件全消失
    expect(File('${dir.path}/b1.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/b2.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/b3.jpg').existsSync(), isFalse);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── NEF 解码缓存 LRU 封顶(2026-10-22:16 张上限,访问即提升)──
  // 查看器序 = 网格倒序(新→旧):p0 = f16(最新)… p16 = f0(最旧)。
  // 大图解码(maxPixelSize 2560)与网格缩略(512)共用假解码器,计数
  // 只认 2560 档(查看器会话缓存 _decodes 的进出)。

  testWidgets('NEF 解码缓存 LRU:塞 17 张最旧被逐(首开张翻回须重解)', (tester) async {
    for (var i = 0; i <= 16; i++) {
      writeFile('f$i.nef', modified: DateTime(2026, 10, 1, 0, i));
    }
    final gallery = _FakeGallery(dir);
    final decoder = _FakeRawDecoder();
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await drainAppFiles(tester, controller, 17);

    int bigDecodes(String name) => decoder.calls
        .where((c) => c.$1 == '${dir.path}/$name' && c.$2 == 2560)
        .length;

    // 开最新张 f16(p0),正向翻到尾 f00(p16):17 张全进缓存,第 17 张
    // 落位时逐最久未访问的 f16(首开张,之后只被 p1 预热碰过一次)。
    await tester.tap(find.byKey(const ValueKey('f16.nef')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 16; i++) {
      await dragLikeFinger(
          tester, find.byType(PageView), const Offset(-600, 0));
    }
    expect(decoder.calls.where((c) => c.$2 == 2560).length, 17,
        reason: '全程恰 17 次大图解码(每张一次)');
    expect(bigDecodes('f16.nef'), 1);

    // 翻回首张:f16 被逐过,重解(其余 16 张都还驻留,不重解)。
    for (var i = 0; i < 16; i++) {
      await dragLikeFinger(tester, find.byType(PageView), const Offset(600, 0));
    }
    expect(bigDecodes('f16.nef'), 2, reason: '最旧被逐:翻回须重解');
    for (var i = 0; i <= 15; i++) {
      expect(bigDecodes('f$i.nef'), 1, reason: 'f$i 全程驻留不该重解');
    }
  });

  testWidgets('NEF 解码缓存 LRU:访问即提升(逐访问最旧,不按插入序)', (tester) async {
    for (var i = 0; i <= 16; i++) {
      writeFile('f$i.nef', modified: DateTime(2026, 10, 1, 0, i));
    }
    final gallery = _FakeGallery(dir);
    final decoder = _FakeRawDecoder();
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await drainAppFiles(tester, controller, 17);

    int bigDecodes(String name) => decoder.calls
        .where((c) => c.$1 == '${dir.path}/$name' && c.$2 == 2560)
        .length;

    await tester.tap(find.byKey(const ValueKey('f16.nef')));
    await tester.pumpAndSettle();
    // ① 正向到尾(p16=f0):f16(插入最旧)被逐。
    for (var i = 0; i < 16; i++) {
      await dragLikeFinger(
          tester, find.byType(PageView), const Offset(-600, 0));
    }
    // ② 翻回首张(p0=f16):f16 重解回缓存。回程把 f15…f01 全部重新
    // 访问过 —— f16 落位时按访问序逐的是 f00(回程第一触、之后不再
    // 碰),而不是插入序最旧的 f15:提升语义的判别点。
    for (var i = 0; i < 16; i++) {
      await dragLikeFinger(tester, find.byType(PageView), const Offset(600, 0));
    }
    // ③ 再正向到尾:f00 被逐过须重解;f15(插入次旧)两段回看都在访
    // 问,驻留不重解 —— 若无访问提升(FIFO),②里被逐的会是 f15。
    for (var i = 0; i < 16; i++) {
      await dragLikeFinger(
          tester, find.byType(PageView), const Offset(-600, 0));
    }
    expect(bigDecodes('f0.nef'), 2, reason: '访问最旧:②被逐③重解');
    expect(bigDecodes('f16.nef'), 2, reason: '插入最旧:①被逐②重解');
    expect(bigDecodes('f15.nef'), 1, reason: '插入次旧但访问新:提升驻留');
    for (var i = 1; i <= 14; i++) {
      expect(bigDecodes('f$i.nef'), 1, reason: 'f$i 全程驻留');
    }
  });

  testWidgets('渐进放大动效:格缩略挂 HeroZoom,点格查看器初始页同 tag 配对+缩略垫底',
      (tester) async {
    useTallSurface(tester);
    // 真字节(可解码):查看器缩略垫底层无 errorBuilder 语义外另有
    // 断言(提供器同源),假字节走错误道测不出。
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    final a = writeReal('a.jpg', DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);

    // 格缩略挂动效锚(HeroZoom 包 Image,tag = 图库侧配对键)。
    expect(find.byType(HeroZoom), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Hero && w.tag == 'lib-grid-${a.path}'),
        findsOneWidget);

    // 点格进查看器:初始页挂同 tag 配对件(PageView 只建初始页,恰一枚;
    // 下方网格 tab offstage 不计)+ 同源缩略垫底(contain)。
    await tester.tap(find.byType(HeroZoom));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsWidgets); // 查看器 AppBar 标题
    expect(find.byWidgetPredicate((w) => w is Hero && w.tag == 'lib-grid-${a.path}'),
        findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is Image &&
            w.fit == BoxFit.contain &&
            w.image == gridThumbImageProvider(a.path)),
        findsOneWidget);

    // 收查看器:配对件回格位(回程航班终点)。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HeroZoom), findsOneWidget);
  });

  testWidgets('动效锚:NEF/MOV 缩略上格挂 HeroZoom,点格查看器同 tag 配对',
      (tester) async {
    useTallSurface(tester);
    // 假件回真路径(libv4 落盘),字节假 → 格/查看器 Image 走 errorBuilder,
    // 但 HeroZoom/锚组件在场 —— 显档记账与配对链正是本用例断言面。
    final nef = writeFile('a.nef', modified: DateTime(2026, 10, 1));
    final mov = writeFile('b.mov', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(
      gallery,
      controller,
      rawDecoder: _FakeRawDecoder(fail: false),
      videoPlayer: _FakeVideoPlayer(failThumbs: false),
    ));
    await drainAppFiles(tester, controller);

    // 两格都挂动效锚(NEF 原生缩略 + MOV 抽帧)。
    expect(find.byType(HeroZoom), findsNWidgets(2));
    expect(find.byWidgetPredicate(
        (w) => w is Hero && w.tag == 'lib-grid-${mov.path}'), findsOneWidget);

    // 点 NEF 格进查看器:初始页同 tag 配对(_nativeBody aspectBox)。
    await tester.tap(find.byKey(const ValueKey('a.nef')));
    await tester.pumpAndSettle();
    expect(find.text('a.nef'), findsWidgets); // 查看器 AppBar 标题
    expect(find.byWidgetPredicate(
        (w) => w is Hero && w.tag == 'lib-grid-${nef.path}'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 点 MOV 格进查看器:_VideoPlayPage 海报显示位锚。
    await tester.tap(find.byKey(const ValueKey('b.mov')));
    await tester.pumpAndSettle();
    expect(find.text('b.mov'), findsWidgets);
    expect(find.byWidgetPredicate(
        (w) => w is Hero && w.tag == 'lib-grid-${mov.path}'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('下拉跟手:过阈值松手收查看器回网格', (tester) async {
    useTallSurface(tester);
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    writeReal('a.jpg', DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    await tester.tap(find.byType(HeroZoom));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsWidgets); // 查看器在场

    // 垂直拖 150px(>110 阈值)松手 → 提交返回,网格回位。
    await tester.drag(find.byType(PageView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsNothing); // 查看器已收
    expect(find.byType(HeroZoom), findsOneWidget); // 网格回位
  });

  testWidgets('下拉跟手:短拖弹回,查看器不收', (tester) async {
    useTallSurface(tester);
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    writeReal('a.jpg', DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    await tester.tap(find.byType(HeroZoom));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsWidgets); // 仍在查看器(弹回)
  });

  testWidgets('下拉跟手:拖拽中图片跟手(下移+缩小)、chrome 渐隐,松手弹回复位',
      (tester) async {
    useTallSurface(tester);
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    writeReal('a.jpg', DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    await tester.tap(find.byType(HeroZoom));
    await tester.pumpAndSettle();

    final hero = find
        .byWidgetPredicate(
            (w) => w is Hero && w.tag == 'lib-grid-${dir.path}/a.jpg')
        .last;
    final rest = tester.getRect(hero);

    debugPrint('[跟手探针] === 纵拖 ===');
    // 持续拖拽 80px(不过阈值):图片跟手下移 + 缩小;chrome 渐隐。
    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    final during = tester.getRect(hero);
    expect(during.top, greaterThan(rest.top), reason: '跟手下移');
    expect(during.height, lessThan(rest.height), reason: '轻微缩小');
    expect(
        find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
        findsWidgets,
        reason: 'chrome 渐隐');

    // 松手(80 < 110 阈值)→ 弹回复位,查看器不收。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(hero), rest, reason: '弹回复位');
    expect(find.text('a.jpg'), findsWidgets);
  });

  testWidgets('下拉跟手:视频页不启用(纵向拖不收)', (tester) async {
    useTallSurface(tester);
    writeFile('b.mov', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(
      gallery,
      controller,
      videoPlayer: _FakeVideoPlayer(failThumbs: false),
    ));
    await drainAppFiles(tester, controller);
    await tester.tap(find.byKey(const ValueKey('b.mov')));
    await tester.pumpAndSettle();
    expect(find.text('b.mov'), findsWidgets);

    await tester.drag(find.byType(PageView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.text('b.mov'), findsWidgets); // 视频页闸关:不收
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('下拉跟手:横翻页之后的纵拉仍生效(竞技场序列)', (tester) async {
    useTallSurface(tester);
    File writeReal(String name, DateTime modified) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      f.setLastModifiedSync(modified);
      return f;
    }

    writeReal('a.jpg', DateTime(2026, 10, 1));
    writeReal('b.jpg', DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await drainAppFiles(tester, controller);
    await tester.tap(find.byKey(const ValueKey('a.jpg')));
    await tester.pumpAndSettle();
    // 先横翻页(网格倒序:b 在前;查看器开在 a,正向翻到 b),再纵拉:
    // 下拉跟手必须仍然生效。
    await dragLikeFinger(tester, find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsWidgets);

    await tester.drag(find.byType(PageView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.text('b.jpg'), findsNothing); // 纵拉提交返回
    expect(find.byType(HeroZoom), findsNWidgets(2)); // 网格回位(两格锚)
  });
}

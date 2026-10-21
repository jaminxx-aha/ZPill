import 'dart:async';
import 'dart:io';

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
  Future<void> clearHistory() async {}
}

/// 带 EXIF 的「JPG」字节(SOI + APP1 Exif + EOI,无图像数据):IFD0
/// Make/Model + Exif 子表 光圈/快门/ISO/焦距,无 takenAt(时间行走
/// mtime 兜底的用例语义)。布局:头 8 + IFD0 42(8..49,3 条目)+
/// Exif 54(50..103)+ 数据区(104..)。Make/Model 用真实长度(>4B)
/// —— EXIF 规则:值 ≤4 字节内联存储,短串会踩中内联路径测不到偏移。
Uint8List _jpgExifBytes() {
  const ascii = 2, short = 3, long = 4, rational = 5;
  const makeOff = 104, modelOff = 122, fNumOff = 131, expOff = 139,
      focalOff = 147;
  final w = ByteWriter()
    ..u16(0x4949)
    ..u16(42)
    ..u32(8)
    // IFD0:Make / Model / Exif 指针(count 含结尾 NUL:17 字符 → 18)
    ..u16(3)
    ..u16(0x010F)..u16(ascii)..u32(18)..u32(makeOff)
    ..u16(0x0110)..u16(ascii)..u32(9)..u32(modelOff)
    ..u16(0x8769)..u16(long)..u32(1)..u32(50)
    ..u32(0)
    // Exif 子表:光圈 / 快门 / ISO / 焦距
    ..u16(4)
    ..u16(0x829D)..u16(rational)..u32(1)..u32(fNumOff)
    ..u16(0x829A)..u16(rational)..u32(1)..u32(expOff)
    ..u16(0x8827)..u16(short)..u32(1)..u16(100)..u16(0)
    ..u16(0x920A)..u16(rational)..u32(1)..u32(focalOff)
    ..u32(0)
    // 数据区
    ..raw('NIKON CORPORATION'.codeUnits)..u8(0)
    ..raw('NIKON Zf'.codeUnits)..u8(0)
    ..u32(2)..u32(1) // ƒ/2
    ..u32(1)..u32(250) // 1/250s
    ..u32(40)..u32(1); // 40mm
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

/// 开弹层点一行并等收场。弹层行文案页面唯一(旧双行 chips 的
/// 「全部/视频」重名问题随弹层化消失,直接按文案点)。
Future<void> pickFilter(WidgetTester tester, String label) async {
  await openFilterMenu(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 开弹层点排序行(单行「时间+方向箭头」,点按翻向并收层)。
/// 排序行没有方向文案,翻向断言看行尾箭头图标(见箭头约定:↓ = 新→旧)。
Future<void> toggleSort(WidgetTester tester) async {
  await openFilterMenu(tester);
  await tester.tap(find.text('时间'));
  await tester.pumpAndSettle();
}

/// 排序行行尾方向箭头(默认 ↓ = 新→旧,翻向 ↑ = 旧→新)。
IconData? sortArrow(WidgetTester tester) =>
    tester.widget<Icon>(find.descendant(
        of: find.ancestor(
            of: find.text('时间'), matching: find.byType(MenuItemButton)),
        matching: find.byType(Icon))).icon;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nikonpill_library');
    // AppServices 惰性装配(查看器 DeSqueezedImage 首触)会起 BLE 身份
    // 装载、传输页真单例会列下载目录,都走本通道:三个目录方法给个
    // 无害默认(临时目录),通道错误不落进任何用例的 runAsync 排水窗。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel,
            (call) async => switch (call.method) {
                  'dataDir' || 'previewsDir' || 'downloadsDir' => dir.path,
                  _ => null,
                });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGallerySaver.channel, null);
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
          EmbeddedVideoViewBuilder? embeddedView,
          VideoLutExportHost? videoLut}) =>
      MaterialApp(
          home: LocalLibraryPage(
        controller: controller,
        gallery: gallery,
        rawDecoder: rawDecoder ?? _FakeRawDecoder(fail: true),
        videoPlayer: videoPlayer ?? _FakeVideoPlayer(),
        embeddedVideoView: embeddedView,
        videoLutExport: videoLut,
      ));

  /// 内嵌播放人设:embedded 播放器 + 假视图(onCreated 回固定 viewId 7)。
  Widget embeddedHost(_FakeGallery gallery, TransfersController controller,
          _FakeVideoPlayer player,
          {VideoLutExportHost? videoLut}) =>
      host(gallery, controller,
          videoPlayer: player,
          embeddedView: (path, onCreated) =>
              _StubVideoView(onCreated: onCreated),
          videoLut: videoLut);

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

  testWidgets('格式过滤:弹层 RAW/JPG/视频按扩展名收窄网格', (tester) async {
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

    await pickFilter(tester, 'RAW');
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    await pickFilter(tester, '视频');
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byType(Image), findsNothing);

    await pickFilter(tester, 'JPG');
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    await pickFilter(tester, '全部');
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });

  testWidgets('视频缩略格角标带底色:黑半透明圆角小底,亮帧上可辨',
      (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(failThumbs: false); // 抽帧出小档路径
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, videoPlayer: player));
    await tester.pumpAndSettle();

    // 抽帧小档就位:缩略铺图格 + 摄像机角标(非图标格的 outlined)。
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);

    // 角标图标最近的 DecoratedBox 祖先 = 底:黑 0.55 圆角矩形(与
    // 相机相册网格同款视觉语言)。
    final iconEl = tester.element(find.byIcon(Icons.videocam));
    late final Element badgeBase;
    iconEl.visitAncestorElements((e) {
      if (e.widget is DecoratedBox) {
        badgeBase = e;
        return false;
      }
      return true;
    });
    final deco = (badgeBase.widget as DecoratedBox).decoration as BoxDecoration;
    expect(deco.color, Colors.black.withValues(alpha: 0.55));
    expect(deco.borderRadius, BorderRadius.circular(4));
  });

  testWidgets('过滤无匹配:提示该格式暂无,切回全部即恢复', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await pickFilter(tester, '视频');
    expect(find.text('没有视频格式的文件'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await pickFilter(tester, '全部');
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

  testWidgets('视频 LUT 导出:视频页入口 → 选表 → 导出落库(_LUT.mp4 改名,'
      '临时档用完即删)', (tester) async {
    writeFile('c.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final player = _FakeVideoPlayer(embedded: true);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    final outPath = '${dir.path}/_out.mp4';
    File(outPath).writeAsBytesSync([9, 9, 9]);
    final lut = _FakeVideoLut(outPath);
    await tester.pumpWidget(
        embeddedHost(gallery, controller, player, videoLut: lut));
    await tester.pumpAndSettle();

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

  testWidgets('信息底单:本地 JPG 头读 EXIF(机身/参数/兜底时间),'
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
    await tester.pumpAndSettle();

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
    expect(find.descendant(
        of: find.byType(BottomSheet), matching: find.text('拍摄时间')),
        findsNothing, reason: 'EXIF 无时间 → 不出「拍摄时间」行');

    await tester.tapAt(const Offset(10, 10)); // 关底单
    await tester.pumpAndSettle();

    // 翻到视频页:文件级信息在场,EXIF 段不出(负 x = 下一页)
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('照片信息'));
    await tester.pumpAndSettle();
    expect(inSheet('v.mov'), findsOneWidget);
    expect(find.descendant(
        of: find.byType(BottomSheet), matching: find.text('机身')),
        findsNothing);
    expect(
        find.descendant(
            of: find.byType(BottomSheet),
            matching: find.textContaining('2026-10-04')),
        findsOneWidget,
        reason: '时间行(mtime 兜底)');
  });

  testWidgets('长按进多选:预选该格,批量删除确认把关,删后网格收缩',
      (tester) async {
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
    expect(find.text('已选 1 项'), findsOneWidget); // AppBar 计数
    expect(find.byIcon(Icons.check_circle), findsOneWidget); // 格上勾
    expect(find.byType(BottomAppBar), findsOneWidget); // 操作栏常驻

    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除应用内文件?'), findsOneWidget);
    expect(find.textContaining('将删除 1 个文件'), findsOneWidget);
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
    expect(find.text('图库'), findsOneWidget); // 删后退出多选,标题复原

    // 冲掉 snackbar 的自动消失 timer(不能留 pending 到测试末)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  // ── 筛选弹层/多选(2026-10-16:iPhone 图库式收口,筛选进弹层,
  // 长按格进多选,操作栏批量删/导出)──

  testWidgets('筛选弹层:分区头在场,当前项打勾,换档勾随迁、点行即收',
      (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await openFilterMenu(tester);
    // 排序分区头在场;排序 = 单行「时间+方向箭头」(默认 ↓ 新→旧)
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('时间'), findsOneWidget);
    expect(sortArrow(tester), Icons.arrow_downward);
    expect(find.text('筛选:'), findsOneWidget);
    expect(find.text('视图选项'), findsOneWidget);
    expect(find.text('连拍聚合'), findsOneWidget);
    // 当前档(全部)行尾打勾;排序行以箭头示向,无勾
    Finder checkBeside(String label) => find.descendant(
        of: find.ancestor(
            of: find.text(label), matching: find.byType(MenuItemButton)),
        matching: find.byIcon(Icons.check));
    expect(checkBeside('全部'), findsOneWidget);
    expect(checkBeside('时间'), findsNothing);

    await tester.tap(find.text('时间')); // 点排序行:翻向 + 收层
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing); // 点行即收

    await openFilterMenu(tester);
    expect(sortArrow(tester), Icons.arrow_upward); // 已翻旧→新
    await tester.tap(find.text('时间'));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);

    await openFilterMenu(tester);
    expect(sortArrow(tester), Icons.arrow_downward); // 再翻回新→旧
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('长按进多选:勾选启用操作栏,空选禁用,退出复原', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

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
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(Image).first); // b(最新在前)预选
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).at(1)); // a 勾上
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.byType(Image).first); // b 再点 = 取消
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('批量删除取消:确认框点取消,文件与选中态不动', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(
        find.text('将删除 1 个文件。\n此操作不可恢复(相机上的原件不受影响)。'),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(File('${dir.path}/a.jpg').existsSync(), isTrue);
    expect(find.text('已选 1 项'), findsOneWidget); // 选中态保留
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  testWidgets('批量导出:一次批量落账(kind 按扩展名),应用内文件保留',
      (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('v.mov', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

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
    expect(call.map((r) => r.kind).toSet(),
        {ObjectKind.image, ObjectKind.video});
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

  testWidgets('批量导出取消:空回列表 → 未导入文案,退出多选,文件原位',
      (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final gallery = _FakeGallery(dir)..importResult = const [];
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

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

  testWidgets('查看器预热:邻页预解码进缓存 + 缓存预算随查看器开收'
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
    await tester.pumpAndSettle();

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

  testWidgets('JPG 网格格走小档管线:落盘 + 换小档源 + gapless'
      '(2026-10-20 缩略重刷根治)', (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    final decoder = _FakeRawDecoder(); // 成功人设
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller, rawDecoder: decoder));
    await tester.pumpAndSettle();

    // 小档解码一次、落盘 thumbsDir(与 NEF/MOV 同管线同键式)
    expect(decoder.calls, [('${dir.path}/a.jpg', 512)]);
    expect(
        File('${gallery.thumbs.path}/lib_a.jpg_3.jpg').existsSync(), isTrue);

    // 格已换小档源:provider 指向小档文件,gapless 换源保帧不闪
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.gaplessPlayback, isTrue);
    final inner =
        (image.image as ResizeImage).imageProvider as FileImage;
    expect(inner.file.path, '${gallery.thumbs.path}/lib_a.jpg_3.jpg');
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

  // ── 排序(时间两向,弹层切换)──

  testWidgets('排序:默认新→旧不动;「旧→新」翻向,查看器随排序翻页',
      (tester) async {
    writeFile('a.jpg', modified: DateTime(2026, 10, 1));
    writeFile('b.jpg', modified: DateTime(2026, 10, 2));
    writeFile('c.jpg', modified: DateTime(2026, 10, 3));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

    // 默认新→旧:首格 c(既有默认,行为不变)
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('c.jpg'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 旧→新(点排序行翻向):首格 a,翻页序随排序(a → b)
    await toggleSort(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsWidgets);
    await dragLikeFinger(tester, find.byType(PageView), const Offset(-600, 0));
    expect(find.text('b.jpg'), findsWidgets);

    // 回新→旧(再翻向):首格回到 c
    await tester.pageBack();
    await tester.pumpAndSettle();
    await toggleSort(tester);
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
      writeFile('b.jpg',
          modified: base.add(const Duration(milliseconds: 100))),
      writeFile('c.jpg',
          modified: base.add(const Duration(milliseconds: 200))),
    ];
    expect(groupLocalBurstRuns(files), [files]);
  });

  test('连拍聚合:相邻差 600ms 超窗断段,窗内段照聚', () {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final a = writeFile('a.jpg', modified: base);
    final b = writeFile('b.jpg',
        modified: base.add(const Duration(milliseconds: 600)));
    final c = writeFile('c.jpg',
        modified: base.add(const Duration(milliseconds: 700)));
    final d = writeFile('d.jpg',
        modified: base.add(const Duration(milliseconds: 800)));
    // a |600ms 超窗| b,c,d(各 100ms)→ a 单段 + bcd 一段
    expect(groupLocalBurstRuns([a, b, c, d]), [
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
    expect(
        runs.single
            .map((f) => baseNameOf(f.uri.pathSegments.last))
            .toSet(),
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

  testWidgets('连拍聚合弹层开关:成段合为一格带 ×N 角标,点开段内翻张,关掉恢复平铺',
      (tester) async {
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    // 三连拍(mtime = 拍摄时刻)+ 一张散拍
    writeFile('b1.jpg', modified: base);
    writeFile('b2.jpg', modified: base.add(const Duration(milliseconds: 100)));
    writeFile('b3.jpg', modified: base.add(const Duration(milliseconds: 200)));
    writeFile('solo.jpg',
        modified: base.subtract(const Duration(minutes: 10)));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();

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
    await dragLikeFinger(
        tester, find.byType(PageView), const Offset(-600, 0));
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
    final base = DateTime(2026, 10, 1, 10, 0, 0);
    final b1 = writeFile('b1.jpg', modified: base);
    final b2 =
        writeFile('b2.jpg', modified: base.add(const Duration(milliseconds: 100)));
    final b3 =
        writeFile('b3.jpg', modified: base.add(const Duration(milliseconds: 200)));
    final gallery = _FakeGallery(dir);
    final controller =
        TransfersController(engine: _FakeEngine(), gallery: gallery);
    await tester.pumpWidget(host(gallery, controller));
    await tester.pumpAndSettle();
    await pickFilter(tester, '连拍聚合');
    expect(find.text('×3'), findsOneWidget);

    // 长按连拍格:进多选,整段 3 成员(3 基名)原子勾上
    await tester.longPress(find.byKey(const ValueKey('b3.jpg')));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.byTooltip('批量删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除 3 个文件'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 真异步 IO 的完成回调在 runAsync 出窗时才上浮(单删一个窗够,
    // 批量要逐窗排水):开窗直到三文件全消失(上限兜底防死循环)。
    for (var i = 0; i < 5; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      if ([b1, b2, b3].every((f) => !f.existsSync())) {
        break;
      }
    }
    await tester.pumpAndSettle();

    // 整段删除:三文件全消失
    expect(File('${dir.path}/b1.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/b2.jpg').existsSync(), isFalse);
    expect(File('${dir.path}/b3.jpg').existsSync(), isFalse);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

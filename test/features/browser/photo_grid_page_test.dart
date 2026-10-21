import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/media/watermark.dart' show ExifCardData;
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/browser/browser_controller.dart';
import 'package:nikon_pill/features/browser/photo_grid_page.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/l10n/message.dart';

/// 手动驱动的伪仓库(同 browser_controller_test:块事件逐个发,
/// loadAlbums 挂在 Completer 上由测试择机完成)。
final class _FakeRepo implements ObjectRepository {
  final updatesCtrl = StreamController<AlbumsUpdate>.broadcast(sync: true);
  Completer<List<CameraAlbum>>? _pending;
  int resetCalls = 0;

  void completeLoad(List<CameraAlbum> albums) => _fresh().complete(albums);

  Completer<List<CameraAlbum>> _fresh() {
    if (_pending == null || _pending!.isCompleted) {
      _pending = Completer<List<CameraAlbum>>();
    }
    return _pending!;
  }

  @override
  Future<List<CameraAlbum>> loadAlbums() => _fresh().future;

  @override
  Stream<AlbumsUpdate> get updates => updatesCtrl.stream;

  @override
  Future<ObjectEntry> entryFor(int handle) async => throw UnimplementedError();

  @override
  void reset() => resetCalls++;

  final List<int> removedHandles = [];

  @override
  void removeHandles(Iterable<int> handles) =>
      removedHandles.addAll(handles);
}

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  L10nMessage? get error => null;

  @override
  String? get deviceName => null;

  @override
  String? get deviceModel => null;

  @override
  bool get isWireless => false;

  @override
  String? get pairingCode => null;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {}

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}

  @override
  Future<void> disconnect() async {}
}

/// 1×1 PNG(解码必成):缩略出图路径的真档替身。
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// 假缩略图:落盘真字节(存在文件 → Image.file 可解码);[failHandles]
/// = 取数抛错;[calls] 记取数账。
final class _FakeThumbs implements ThumbnailCache {
  final Set<int> failHandles;
  final calls = <int>[];

  _FakeThumbs({this.failHandles = const {}});

  @override
  int get previewMaxPixelSize => 2560;

  @override
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) async {
    calls.add(entry.handle);
    if (failHandles.contains(entry.handle)) {
      throw Exception('假失败:${entry.name}');
    }
    final path = '/tmp/nikonpill_test_thumb_${entry.handle}.jpg';
    File(path).writeAsBytesSync(_tinyPng);
    return path;
  }

  @override
  Future<ExifCardData?> exifCardOf(ObjectEntry entry) async => null;

  @override
  void reset() {}

  @override
  Stream<PreviewUpgrade> get previewUpgrades => const Stream.empty();

  @override
  Future<void> warmPreview(ObjectEntry entry) async {}

  @override
  int get gridLimitBytes => 0;

  @override
  int get previewLimitBytes => 0;
}

ObjectEntry _entry(int handle) => ObjectEntry(
      handle: handle,
      name: 'IMG_$handle.JPG',
      sizeInBytes: 1,
      kind: ObjectKind.image,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 1, 12, handle),
      formatCode: 0x3801,
    );

/// 单文件组(独立 JPG)。
PhotoGroup _photo(int handle) => PhotoGroup([_entry(handle)]);

/// 同一快门的 RAW+JPG 双文件组(基名/时刻一致,直接构造)。
PhotoGroup _pair(int jpgHandle, int rawHandle) => PhotoGroup([
      ObjectEntry(
        handle: jpgHandle,
        name: 'DSC_0001.JPG',
        sizeInBytes: 8,
        kind: ObjectKind.image,
        parentHandle: 0x11,
        capturedAt: DateTime.utc(2026, 10, 1, 12),
        formatCode: 0x3801,
      ),
      ObjectEntry(
        handle: rawHandle,
        name: 'DSC_0001.NEF',
        sizeInBytes: 26,
        kind: ObjectKind.image,
        parentHandle: 0x11,
        capturedAt: DateTime.utc(2026, 10, 1, 12),
        formatCode: 0x3000,
      ),
    ]);

/// 纯 RAW 单文件组。
PhotoGroup _rawPhoto(int handle) => PhotoGroup([
      ObjectEntry(
        handle: handle,
        name: 'DSC_0002.NEF',
        sizeInBytes: 26,
        kind: ObjectKind.image,
        parentHandle: 0x11,
        capturedAt: DateTime.utc(2026, 10, 1, 12),
        formatCode: 0x3000,
      ),
    ]);

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

Widget _host(PhotoGridPage page) => MaterialApp(home: page);

/// 结束前冲掉 snackbar 的 4s 自动消失 timer(不能留 pending 到测试末)。
Future<void> _drainSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渐进增长:新块追加 cell,key 按 handle 复用不漂移', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    // 块 1:两个对象。
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([_photo(1), _photo(2)])],
        loaded: 2,
        total: 4,
        complete: false));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(2)), findsOneWidget);
    expect(find.byKey(ValueKey(3)), findsNothing);

    // 块 2:增长到四个 —— 新 cell 尾部追加,首格原位复用不漂移。
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3), _photo(4)])],
        loaded: 4,
        total: 4,
        complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(3)), findsOneWidget);
    expect(find.byKey(ValueKey(4)), findsOneWidget);

    repo.completeLoad(
        [CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3), _photo(4)])]);
    await loading;
  });

  testWidgets('首块前骨架:枚举在途显网格形占位,首块到达切真网格',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
    )));
    await tester.pump(); // initState 懒枚举已发起,块未到:骨架态

    // 骨架占位 + 编目文案;旧空心转圈退役,「在动」反馈只留 AppBar 细条。
    expect(find.byKey(const ValueKey('gridSkeleton')), findsOneWidget);
    expect(find.text('正在连接相机读取对象…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 首块到达:骨架退场,真网格上屏。
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([_photo(1)])],
        loaded: 1,
        total: 2,
        complete: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('gridSkeleton')), findsNothing);
    expect(find.byKey(ValueKey(1)), findsOneWidget);

    repo.completeLoad([CameraAlbum.allPhotos([_photo(1)])]);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('缩略取数失败:断图占位,3s 后限次自动重试(失败 future 不驻留)',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    final thumbs = _FakeThumbs(failHandles: {1});
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: thumbs,
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([_photo(1), _photo(2)])],
        loaded: 2,
        total: 2,
        complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    await tester.pump(); // 取数失败的错误沿下一帧上屏(微任务 → setState → 帧)
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget,
        reason: '句柄 1 取数失败:断图占位');

    // 3s 后自动重试(失败 future 已从缓存移除;假失败解除 → 第二次取数)
    thumbs.failHandles.clear();
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    await tester.pump();
    expect(thumbs.calls.where((h) => h == 1), hasLength(2),
        reason: '自动重试发出第二次取数(失败 future 不驻留)');

    repo.completeLoad([CameraAlbum.allPhotos([_photo(1), _photo(2)])]);
    await loading;
  });

  testWidgets('图档级失败:2s 去抖删坏档 + future 失效重取(死路径自愈)',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    final thumbs = _FakeThumbs();
    final group = _photo(1);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: thumbs,
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([group, _photo(2)])],
        loaded: 2,
        total: 2,
        complete: true));
    await tester.pump();
    await tester.pump();
    expect(thumbs.calls.where((h) => h == 1), hasLength(1));

    // 模拟 Image.file errorBuilder 沿(fake-async 里引擎解码失败沿落不
    // 地,直调同款入口):future 已完成、盘档被驱逐删档 → 2s 后删档 +
    // future 失效 + 重取
    (tester.state(find.byType(PhotoGridPage)) as dynamic)
        .debugRetryThumbAfterFileError(group);
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    await tester.pump();
    expect(thumbs.calls.where((h) => h == 1), hasLength(2),
        reason: '图档级失败触发重取(死路径 future 不驻留)');

    repo.completeLoad([CameraAlbum.allPhotos([group, _photo(2)])]);
    await loading;
  });

  testWidgets('前瞻预取:构建沿窗外一窗先取(滚到即现,可视请求先入队)',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    final thumbs = _FakeThumbs();
    final groups = [for (var i = 1; i <= 24; i++) _photo(i)];
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: thumbs,
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos(groups)],
        loaded: 24,
        total: 24,
        complete: true));
    await tester.pump();
    // 一帧:可视 cell 构建(取数)+ post-frame 预取窗(24 张窗越过屏外)
    await tester.pumpAndSettle();

    // 假视口只能容纳前十几格,窗后段(>可视)也已被预取 = 全部 24 张入账
    expect(thumbs.calls.toSet(), containsAll([for (var i = 1; i <= 24; i++) i]),
        reason: '预取窗越过可视下界:滚到即现,不排队等待');

    repo.completeLoad([CameraAlbum.allPhotos(groups)]);
    await loading;
  });

  testWidgets('断连:网格保留最后快照,标题取兜底名', (tester) async {
    final repo = _FakeRepo();
    final conn = _FakeConnection();
    final controller = BrowserController(repository: repo, connection: conn);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    final album = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(2)), findsOneWidget);

    conn.statesCtrl.add(CameraLinkState.disconnected); // albums 被清空
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1)); // 异步广播微任务送达

    // 控制器已清空,但网格保持最后快照(页面级 _lastAlbum 兜底)。
    expect(controller.albums, isEmpty);
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(2)), findsOneWidget);
    expect(find.text('全部照片'), findsOneWidget);

    repo.completeLoad([album]);
    await loading;
  });

  testWidgets('文件夹相册:按 folderHandle 解析活相册,不串台', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: 0x11,
      fallbackName: '文件夹',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    final folder =
        CameraAlbum(name: '100NIKON', folderHandle: 0x11, items: [_photo(5)]);
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1)]),
      folder,
    ], loaded: 2, total: 2, complete: true));
    await tester.pump();

    // 只渲染 0x11 相册的内容;标题用兜底名,相册名收在筛选弹层。
    expect(find.byKey(ValueKey(5)), findsOneWidget);
    expect(find.byKey(ValueKey(1)), findsNothing);
    expect(find.text('文件夹'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('100NIKON'), findsOneWidget);
    expect(find.text('全部照片'), findsOneWidget);

    repo.completeLoad([folder]);
    await loading;
  });

  testWidgets('类型角标:合并组 jpg+raw / 纯 raw / 纯 jpg 各自落格', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [
          CameraAlbum.allPhotos([
            _pair(101, 102), // DSC_0001 双格式
            _photo(2), // IMG_2.JPG 独立 JPG
            _photo(3),
          ]),
        ],
        loaded: 4,
        total: 4,
        complete: true));
    await tester.pump();

    // RAW+JPG 合并:一个 cell、角标 jpg+raw;两份文件不再各占一格。
    expect(find.text('jpg+raw'), findsOneWidget);
    expect(find.byKey(ValueKey(102)), findsOneWidget); // 组键 = 最大句柄
    expect(find.byKey(ValueKey(101)), findsNothing);
    // 独立 JPG(两张):角标 jpg 各一格。
    expect(find.text('jpg'), findsNWidgets(2));

    repo.completeLoad([CameraAlbum.allPhotos([_pair(101, 102)])]);
    await loading;
  });

  // ── 多选批量下载:格式按筛选预定档收集 ─────────────────────────

  /// 装载网格并选中指定组(长按第一项进入多选);返回控制器与假引擎供断言。
  Future<(BrowserController, _FakeEngine)> selectGroups(
      WidgetTester tester, List<PhotoGroup> groups,
      {VoidCallback? onOpenTransfers}) async {
    final repo = _FakeRepo();
    final engine = _FakeEngine();
    final controller = BrowserController(repository: repo);
    final loading = controller.load();
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      engine: engine,
      onOpenTransfers: onOpenTransfers,
    )));
    final album = CameraAlbum.allPhotos(groups);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [album],
        loaded: groups.length,
        total: groups.length,
        complete: true));
    await tester.pump();
    repo.completeLoad([album]);
    await loading;

    await tester.longPress(find.byKey(ValueKey(groups.first.key)));
    await tester.pump();
    for (final group in groups.skip(1)) {
      await tester.tap(find.byKey(ValueKey(group.key)));
      await tester.pump();
    }
    expect(find.text('已选 ${groups.length} 项'), findsOneWidget);
    return (controller, engine);
  }

  testWidgets('多选含双格式组:筛选「全部」整组全量直接入队,不弹面板',
      (tester) async {
    final (_, engine) =
        await selectGroups(tester, [_pair(101, 102), _rawPhoto(201)]);

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsNothing,
        reason: '全部 = 整组全量直接下,不弹格式面板');

    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name),
        ['DSC_0001.JPG', 'DSC_0001.NEF', 'DSC_0002.NEF']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('跳过'), findsNothing);
    expect(find.text('已选 2 项'), findsNothing); // 下载后清空选择

    await _drainSnackBar(tester);
  });

  testWidgets('多选全单一格式:不弹面板,整组直接入队(行为同旧版)', (tester) async {
    var transfersTapped = false;
    final (_, engine) = await selectGroups(
        tester, [_photo(1), _rawPhoto(201), _photo(3)],
        onOpenTransfers: () => transfersTapped = true);

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing);
    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name),
        ['IMG_1.JPG', 'DSC_0002.NEF', 'IMG_3.JPG']);
    expect(destination, TransferDestination.app);

    // SnackBar「查看进度」动作 → 传输页入口
    await tester.tap(find.text('查看进度'));
    await tester.pump();
    expect(transfersTapped, isTrue, reason: 'SnackBar 动作直通传输页');

    await _drainSnackBar(tester);
  });

  testWidgets('底栏两段式下载:默认单「下载」钮,点按换出双目的地;'
      '下载完成清空选择复位', (tester) async {
    final (_, engine) = await selectGroups(tester, [_photo(1)]);

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('下载到相册'), findsNothing);
    expect(find.text('下载到应用'), findsNothing);

    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('下载到相册'), findsOneWidget);
    expect(find.text('下载到应用'), findsOneWidget);

    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();
    final (_, destination) = engine.calls.single;
    expect(destination, TransferDestination.app);
    expect(find.text('已选 1 项'), findsNothing); // 下载后清空选择
    expect(find.byType(BottomAppBar), findsNothing); // 底栏随选择收起

    await _drainSnackBar(tester);
  });

  testWidgets('两段式展开后改选/全选:回落单「下载」钮重新起段', (tester) async {
    final (_, engine) = await selectGroups(tester, [_photo(1), _photo(2)]);

    // 先取消一项再展开:1 项选中,底栏显单「下载」。
    await tester.tap(find.byKey(ValueKey(2)));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('下载到应用'), findsOneWidget);

    // 全选:选择集一变即复位,不得直显双目的地(旧 UI 观感,
    // 2026-10-17 真机反馈)。
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('下载到相册'), findsNothing);
    expect(find.text('下载到应用'), findsNothing);

    // 复位后两段照常走完。
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();
    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['IMG_1.JPG', 'IMG_2.JPG']);
    expect(destination, TransferDestination.app);

    await _drainSnackBar(tester);
  });

  testWidgets('筛选定格式仅 JPG:下载跳过面板直接收集,缺格式组跳过',
      (tester) async {
    final repo = _FakeRepo();
    final engine = _FakeEngine();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      engine: engine,
    )));
    final loading = controller.load();
    final album = CameraAlbum.allPhotos([_pair(101, 102), _rawPhoto(201)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    repo.completeLoad([album]);
    await loading;
    await tester.pump(); // await loading 留下脏树:交互前先落一帧

    // 先在筛选弹层定格式(多选中弹层不可达,须先设后选)
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅 JPG'));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey(102)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(201)));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing,
        reason: '筛选已定格式:不再弹格式面板');
    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['DSC_0001.JPG']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('跳过 1 项无 JPG'), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('下载后立即返回:提示自动消失,「查看进度」仍可跳传输页',
      (tester) async {
    // 真实导航栈(入口页 push 相册页)+ 生产默认跳转路径(不注入
    // onOpenTransfers)。复现盘:2026-10-17 真机 —— SDK #173084 起带
    // action 的 SnackBar 默认 persist=true 永不消失,且 pop 后动作闭包
    // 沿 State.context 找 Navigator 抛 defunct。
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    final engine = _FakeEngine();
    final g1 = _photo(1);
    final g2 = _photo(2);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PhotoGridPage(
                    controller: controller,
                    folderHandle: CameraAlbum.allPhotosHandle,
                    fallbackName: '相机相册',
                    thumbnails: _FakeThumbs(),
                    engine: engine,
                  ),
                ),
              ),
              child: const Text('打开相册'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开相册'));
    await tester.pump();

    // 懒枚举(2026-10-17):initState 已发起 load,块到达前 syncing 转圈,
    // 须先喂完仓库再 pumpAndSettle;手动 load() 在途去重,不再单发。
    final album = CameraAlbum.allPhotos([g1, g2]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    repo.completeLoad([album]);
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey(g1.key)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(g2.key)));
    await tester.pump();
    // 两段式:先点「下载」换出目的地,再点「下载到应用」。
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已开始下载'), findsOneWidget);

    // 马上返回:提示挂到上一页(仍可见、仍可点)。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开相册'), findsOneWidget);
    expect(find.textContaining('已开始下载'), findsOneWidget,
        reason: 'dismiss 窗口内提示随 messenger 挂在上一页');

    // 窗口期内点「查看进度」:本页已 unmount,动作须仍能推传输页。
    await tester.tap(find.text('查看进度'));
    await tester.pumpAndSettle();
    expect(find.byType(TransfersPage), findsOneWidget,
        reason: '展示时刻捕获的 Navigator 跨 pop 存活');

    // 提示不滞留:persist 关闭后随 duration 自动消失(messenger 上的
    // 定时器与页面 pop 无关)。
    await _drainSnackBar(tester);
    expect(find.textContaining('已开始下载'), findsNothing,
        reason: 'persist=false 恢复自动消失,不永久滞留');
  });

  // ── 右上筛选弹层(相册区 + 图片下载格式区) ─────────────────────

  testWidgets('筛选弹层:双相册出相册区,点选切换过滤;格式区三档常在',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    // 汇总 = 全部(含文件夹里的);文件夹相册只含自己的。
    final aggregate = CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(5)]);
    final folder =
        CameraAlbum(name: '100NIKON', folderHandle: 0x11, items: [_photo(5)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [aggregate, folder], loaded: 3, total: 3, complete: true));
    await tester.pump();

    // 筛选收进右上弹层(旧 chips sliver 撤除);标题用兜底名
    expect(find.text('相机相册'), findsOneWidget);
    expect(find.text('全部照片'), findsNothing);
    // 默认过滤 = 全部:三个组都在格
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(5)), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('全部照片'), findsOneWidget);
    expect(find.text('100NIKON'), findsOneWidget);
    expect(find.text('图片下载格式'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('仅 JPG'), findsOneWidget);
    expect(find.text('仅 RAW'), findsOneWidget);

    // 点文件夹名:弹层收,网格只剩该夹内容
    await tester.tap(find.text('100NIKON'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(5)), findsOneWidget);
    expect(find.byKey(ValueKey(1)), findsNothing);
    expect(find.text('相机相册'), findsOneWidget); // 标题回常态

    // 重开弹层切回汇总:两组回归
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部照片'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(5)), findsOneWidget);

    repo.completeLoad([aggregate, folder]);
    await loading;
  });

  testWidgets('筛选弹层:多选中不可达(actions 换全选/退出)', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    final aggregate = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [aggregate], loaded: 2, total: 2, complete: true));
    await tester.pump();

    await tester.longPress(find.byKey(ValueKey(1)));
    await tester.pump();
    expect(find.byIcon(Icons.tune), findsNothing,
        reason: '多选中弹层入口换场不可达(图库页同规矩)');

    repo.completeLoad([aggregate]);
    await loading;
  });

  testWidgets('单相册:弹层无相册区,格式区常在', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
    )));

    final loading = controller.load();
    final aggregate = CameraAlbum.allPhotos([_photo(1)]);
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [aggregate], loaded: 1, total: 1, complete: true));
    await tester.pump();

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsNothing);
    expect(find.text('全部照片'), findsNothing);
    expect(find.text('图片下载格式'), findsOneWidget);

    repo.completeLoad([aggregate]);
    await loading;
  });
}

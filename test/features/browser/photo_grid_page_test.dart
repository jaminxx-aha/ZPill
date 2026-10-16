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
  String? get error => null;

  @override
  String? get deviceName => null;

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

    // 只渲染 0x11 相册的内容;标题取活相册名。
    expect(find.byKey(ValueKey(5)), findsOneWidget);
    expect(find.byKey(ValueKey(1)), findsNothing);
    expect(find.text('100NIKON'), findsOneWidget);

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

  // ── 多选批量下载:格式选择 ─────────────────────────────────────

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

  testWidgets('多选含双格式组:弹格式面板,仅 JPG 时纯 RAW 组跳过', (tester) async {
    final (_, engine) =
        await selectGroups(tester, [_pair(101, 102), _rawPhoto(201)]);

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsOneWidget);
    expect(find.textContaining('其中 1 项为双格式'), findsOneWidget);

    await tester.tap(find.text('仅 JPG'));
    await tester.pumpAndSettle();

    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['DSC_0001.JPG']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('跳过 1 项无 JPG'), findsOneWidget);
    expect(find.text('已选 2 项'), findsNothing); // 下载后清空选择

    await _drainSnackBar(tester);
  });

  testWidgets('多选含双格式组:选 JPG+RAW,缺格式组下另一格式不跳过', (tester) async {
    final (_, engine) =
        await selectGroups(tester, [_pair(101, 102), _rawPhoto(201)]);

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPG + RAW'));
    await tester.pumpAndSettle();

    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name),
        ['DSC_0001.JPG', 'DSC_0001.NEF', 'DSC_0002.NEF']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('跳过'), findsNothing);

    await _drainSnackBar(tester);
  });

  testWidgets('多选取消格式面板:不入队,选中保留(可改选再下)', (tester) async {
    final (_, engine) =
        await selectGroups(tester, [_pair(101, 102), _rawPhoto(201)]);

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    // 点面板外遮罩取消。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(engine.calls, isEmpty);
    expect(find.text('已选 2 项'), findsOneWidget);

    // 改选仅 RAW 再下到应用:双格式组取 NEF,纯 RAW 组照常全量。
    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅 RAW'));
    await tester.pumpAndSettle();

    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['DSC_0001.NEF', 'DSC_0002.NEF']);
    expect(destination, TransferDestination.app);

    await _drainSnackBar(tester);
  });

  testWidgets('多选全单一格式:不弹面板,整组直接入队(行为同旧版)', (tester) async {
    var transfersTapped = false;
    final (_, engine) = await selectGroups(
        tester, [_photo(1), _rawPhoto(201), _photo(3)],
        onOpenTransfers: () => transfersTapped = true);

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

  // ── 文件夹筛选 chips(独立相机相册页) ─────────────────────────

  testWidgets('文件夹 chips:双相册亮出,点选切换过滤并清空跨相册选择',
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

    // chips:全部照片 + 文件夹名;标题用兜底名(过滤态由 chip 表达)
    expect(find.text('相机相册'), findsOneWidget);
    expect(find.text('全部照片'), findsOneWidget);
    expect(find.text('100NIKON'), findsOneWidget);
    // 默认过滤 = 全部:三个组都在格
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(5)), findsOneWidget);

    // 长按进入多选,再切 chip:选择必须清空(跨相册选择无意义)
    await tester.longPress(find.byKey(ValueKey(1)));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('100NIKON'));
    await tester.pump();
    expect(find.byKey(ValueKey(5)), findsOneWidget);
    expect(find.byKey(ValueKey(1)), findsNothing);
    expect(find.text('已选 1 项'), findsNothing);
    expect(find.text('相机相册'), findsOneWidget); // 标题回常态

    // 切回汇总:两组回归
    await tester.tap(find.text('全部照片'));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(5)), findsOneWidget);

    repo.completeLoad([aggregate, folder]);
    await loading;
  });

  testWidgets('单相册:chips 不占位(无分类可言)', (tester) async {
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
    expect(find.byKey(ValueKey(1)), findsOneWidget);

    repo.completeLoad([aggregate]);
    await loading;
  });
}

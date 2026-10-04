import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
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

/// 假缩略图:即时返回路径(文件不存在 → Image.file 走占位,无动画挂起)。
final class _FakeThumbs implements ThumbnailCache {
  @override
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) async =>
      '/tmp/nikonpill_test_thumb_${entry.handle}.jpg';

  @override
  void reset() {}

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
      WidgetTester tester, List<PhotoGroup> groups) async {
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
    final (_, engine) =
        await selectGroups(tester, [_photo(1), _rawPhoto(201), _photo(3)]);

    await tester.tap(find.text('下载到应用'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing);
    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name),
        ['IMG_1.JPG', 'DSC_0002.NEF', 'IMG_3.JPG']);
    expect(destination, TransferDestination.app);

    await _drainSnackBar(tester);
  });
}

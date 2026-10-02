import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
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
  Future<void> connect({String? ip}) async {}

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

Widget _host(PhotoGridPage page) => MaterialApp(home: page);

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
        albums: [CameraAlbum.allPhotos([_entry(1), _entry(2)])],
        loaded: 2,
        total: 4,
        complete: false));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(2)), findsOneWidget);
    expect(find.byKey(ValueKey(3)), findsNothing);

    // 块 2:增长到四个 —— 新 cell 尾部追加,首格原位复用不漂移。
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [CameraAlbum.allPhotos([_entry(1), _entry(2), _entry(3), _entry(4)])],
        loaded: 4,
        total: 4,
        complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey(1)), findsOneWidget);
    expect(find.byKey(ValueKey(3)), findsOneWidget);
    expect(find.byKey(ValueKey(4)), findsOneWidget);

    repo.completeLoad(
        [CameraAlbum.allPhotos([_entry(1), _entry(2), _entry(3), _entry(4)])]);
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
    final album = CameraAlbum.allPhotos([_entry(1), _entry(2)]);
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
        CameraAlbum(name: '100NIKON', folderHandle: 0x11, items: [_entry(5)]);
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_entry(1)]),
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
}

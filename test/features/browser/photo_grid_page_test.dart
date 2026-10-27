import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/features/common/trash_rating_icon.dart';
import 'package:z_pill/data/ui_prefs_store.dart';
import 'package:z_pill/core/browser/album.dart';
import 'package:z_pill/core/browser/object_entry.dart';
import 'package:z_pill/core/media/watermark.dart' show ExifCardData;
import 'package:z_pill/core/browser/object_repository.dart';
import 'package:z_pill/core/browser/photo_group.dart';
import 'package:z_pill/core/browser/thumbnail_cache.dart';
import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/core/ptpip/object_format.dart';
import 'package:z_pill/core/transfer/transfer_engine.dart';
import 'package:z_pill/core/transfer/transfer_task.dart';
import 'package:z_pill/features/browser/album_ratings_controller.dart';
import 'package:z_pill/features/browser/browser_controller.dart';
import 'package:z_pill/features/browser/photo_grid_page.dart';
import 'package:z_pill/features/browser/photo_viewer_page.dart';
import 'package:z_pill/features/common/widgets/hero_zoom.dart';
import 'package:z_pill/features/transfers/transfers_page.dart';
import '../../helpers/fake_connection.dart';

/// 手动驱动的伪仓库(同 browser_controller_test:块事件逐个发,
/// loadAlbums 挂在 Completer 上由测试择机完成)。
final class _FakeRepo implements ObjectRepository {
  final updatesCtrl = StreamController<AlbumsUpdate>.broadcast(sync: true);

  /// 视频时长预置(测试直设,免 PTP 脚本)。
  final Map<int, Duration> durations = {};
  final List<int> durationRequests = [];
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
  void removeHandles(Iterable<int> handles) => removedHandles.addAll(handles);

  // ── 评级面(评级筛选用例驱动;句柄 → 星)──
  final Map<int, int> ratings = {};
  bool ratingsAvailable = false;

  @override
  bool get ratingsLoaded => ratingsAvailable;

  @override
  void requestRating(int handle, {bool trashProbe = true}) {}
  @override
  void requestTrashProbe(int handle) {}
  @override
  Duration? durationFor(int handle) => durations[handle];
  @override
  void requestVideoDuration(int handle) => durationRequests.add(handle);

  @override
  int ratingForHandle(int handle) => ratings[handle] ?? 0;

  @override
  int ratingForGroup(PhotoGroup group) => group.members
      .fold(0, (m, e) => (ratings[e.handle] ?? 0) > m ? ratings[e.handle]! : m);

  @override
  bool ratedUnknownFor(int handle) => false;

  @override
  bool groupRatedUnknown(PhotoGroup group) => false;

  @override
  bool trashMarkedFor(int handle) => false;

  @override
  bool groupTrashStar(PhotoGroup group) => false;

  @override
  PhotoGroup? groupOf(int handle) => null;

  @override
  Future<void> rateGroup(PhotoGroup group, int stars) async {
    for (final m in group.members) {
      if (stars >= 1) {
        ratings[m.handle] = stars;
      } else {
        ratings.remove(m.handle);
      }
    }
  }
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
    final path = '/tmp/zpill_test_thumb_${entry.handle}.jpg';
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

/// 组 → 展示格键(与页面 _expandGroup 同口径:组内出现的格式各一格)。
List<String> cellKeysOf(PhotoGroup group) {
  final formats = <MediaFormat>[];
  for (final m in group.members) {
    final f = mediaFormatOfFilename(m.name);
    if (f != null && !formats.contains(f)) formats.add(f);
  }
  if (formats.isEmpty) return ['${group.key}'];
  return [for (final f in formats) '${group.key}:${f.name}'];
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

/// 单文件视频组(MOV,quickTime 容器码)。
PhotoGroup _video(int handle) => PhotoGroup([
      ObjectEntry(
        handle: handle,
        name: 'DSC_0099.MOV',
        sizeInBytes: 100,
        kind: ObjectKind.video,
        parentHandle: 0x11,
        capturedAt: DateTime.utc(2026, 10, 1, 12),
        formatCode: 0x300D,
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
  Future<void> removeRecord(String taskId) async {}

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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    final loading = controller.load();
    // 块 1:两个对象。
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1), _photo(2)])
    ], loaded: 2, total: 4, complete: false));
    await tester.pump();
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('2:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('3:jpg')), findsNothing);

    // 块 2:增长到四个 —— 新 cell 尾部追加,首格原位复用不漂移。
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3), _photo(4)])
    ], loaded: 4, total: 4, complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('3:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('4:jpg')), findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3), _photo(4)])
    ]);
    await loading;
  });

  testWidgets('视频格:摄像机角标退场,时长胶囊上屏(mvhd 行走)', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    final ratings = AlbumRatingsController(repository: repo);
    addTearDown(ratings.dispose);
    final thumbs = _FakeThumbs();
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: thumbs,
      ratings: ratings,
      uiPrefs: InMemoryUiPrefsStore(),
    )));

    repo.durations[1] = const Duration(seconds: 150); // mvhd 探测成果预置

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_video(1), _photo(2)])
    ], loaded: 2, total: 2, complete: true));
    await tester.pump();
    await tester.pumpAndSettle();

    // 摄像机角标退场;时长胶囊上屏(150s → 2:30),黑底同格式角标。
    expect(repo.durationRequests, contains(1),
        reason: '首位视频当前格也必须发起探测,不能只依赖后续格的前瞻窗');
    expect(find.byIcon(Icons.videocam), findsNothing);
    expect(find.text('2:30'), findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([_video(1), _photo(2)])
    ]);
    await loading;
  });

  testWidgets('首块前骨架:枚举在途显网格形占位,首块到达切真网格', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));
    await tester.pump(); // initState 懒枚举已发起,块未到:骨架态

    // 骨架占位 + 编目文案;旧空心转圈退役,「在动」反馈只留 AppBar 细条。
    expect(find.byKey(const ValueKey('gridSkeleton')), findsOneWidget);
    expect(find.text('正在连接相机读取对象…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 首块到达:骨架退场,真网格上屏。
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1)])
    ], loaded: 1, total: 2, complete: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('gridSkeleton')), findsNothing);
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([_photo(1)])
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('缩略取数失败:断图占位,3s 后限次自动重试(失败 future 不驻留)', (tester) async {
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
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1), _photo(2)])
    ], loaded: 2, total: 2, complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    await tester.pump(); // 取数失败的错误沿下一帧上屏(微任务 → setState → 帧)
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget,
        reason: '句柄 1 取数失败:断图占位');

    // 3s 后自动重试(失败 future 已从缓存移除;假失败解除 → 第二次取数)
    thumbs.failHandles.clear();
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    await tester.pump();
    expect(thumbs.calls.where((h) => h == 1), hasLength(2),
        reason: '自动重试发出第二次取数(失败 future 不驻留)');

    repo.completeLoad([
      CameraAlbum.allPhotos([_photo(1), _photo(2)])
    ]);
    await loading;
  });

  testWidgets('图档级失败:2s 去抖删坏档 + future 失效重取(死路径自愈)', (tester) async {
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
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([group, _photo(2)])
    ], loaded: 2, total: 2, complete: true));
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

    repo.completeLoad([
      CameraAlbum.allPhotos([group, _photo(2)])
    ]);
    await loading;
  });

  testWidgets('前瞻预取:构建沿窗外一窗先取(滚到即现,可视请求先入队)', (tester) async {
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
    final conn = FakeConnection();
    final controller = BrowserController(repository: repo, connection: conn);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    final loading = controller.load();
    final album = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('2:jpg')), findsOneWidget);

    conn.statesCtrl.add(CameraLinkState.disconnected); // albums 被清空
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1)); // 异步广播微任务送达

    // 控制器已清空,但网格保持最后快照(页面级 _lastAlbum 兜底)。
    expect(controller.albums, isEmpty);
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('2:jpg')), findsOneWidget);
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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
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
    expect(find.byKey(ValueKey('5:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('1:jpg')), findsNothing);
    expect(find.text('文件夹'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folderFilter-entry')));
    await tester.pumpAndSettle();
    expect(find.text('100NIKON'), findsOneWidget);
    expect(find.text('全部照片'), findsOneWidget);

    repo.completeLoad([folder]);
    await loading;
  });

  testWidgets('文件夹持久化:清单一致 → 应用持久化选集(按名匹配)',
      (tester) async {
    final prefs = InMemoryUiPrefsStore();
    await prefs.save({
      'grid.folderNames': ['100NIKON'],
      'grid.folderSel': ['100NIKON'],
    });
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: prefs,
    )));

    final loading = controller.load();
    final aggregate = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    final folder = CameraAlbum(
        name: '100NIKON', folderHandle: 0x11, items: [_photo(5)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [aggregate, folder], loaded: 3, total: 3, complete: true));
    await tester.pump();
    repo.completeLoad([aggregate, folder]);
    await loading;
    await tester.pump();

    // 清单一致:持久化选集(100NIKON)生效,汇总内容被筛掉。
    expect(find.byKey(ValueKey('5:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('1:jpg')), findsNothing);
  });

  testWidgets('文件夹持久化:清单不一致 → 重置回全部照片', (tester) async {
    final prefs = InMemoryUiPrefsStore();
    await prefs.save({
      'grid.folderNames': ['200NIKON'], // 上次的夹这次没了
      'grid.folderSel': ['200NIKON'],
    });
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: prefs,
    )));

    final loading = controller.load();
    final aggregate = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    final folder = CameraAlbum(
        name: '100NIKON', folderHandle: 0x11, items: [_photo(5)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [aggregate, folder], loaded: 3, total: 3, complete: true));
    await tester.pump();
    repo.completeLoad([aggregate, folder]);
    await loading;
    await tester.pump();
    await tester.pump(); // 重置沿 post-frame

    // 清单不一致:选集重置,汇总(全部照片)上屏 —— 夹具的 5 只在
    // 文件夹夹里,随选集重置一起消失(= 对账生效)。
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('5:jpg')), findsNothing);
  });

  testWidgets('选项持久化:预置格式选集,进页子面板勾态恢复', (tester) async {
    final prefs = InMemoryUiPrefsStore();
    await prefs.save({
      'grid.formats': ['mov'],
    });
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: prefs,
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_video(1), _photo(2)])
    ], loaded: 2, total: 2, complete: true));
    await tester.pump();
    await tester.pump();

    // 恢复的格式选集直接生效:MOV 在,JPG 被筛掉。
    expect(find.byKey(ValueKey('1:mov')), findsOneWidget);
    expect(find.byKey(ValueKey('2:jpg')), findsNothing);

    // 子面板勾态:MOV 勾、全部未勾。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('formatFilter-entry')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('formatFilter-mov')), findsOneWidget);
    final movCheck = find.descendant(
        of: find.byKey(const ValueKey('formatFilter-mov')),
        matching: find.byIcon(Icons.check));
    expect(movCheck, findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([_video(1), _photo(2)])
    ]);
    await loading;
  });

  testWidgets('类型角标:RAW+JPG 拆分两格 / 纯 raw / 纯 jpg 各自落格', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([
        _pair(101, 102), // DSC_0001 双格式
        _photo(2), // IMG_2.JPG 独立 JPG
        _photo(3),
      ]),
    ], loaded: 4, total: 4, complete: true));
    await tester.pump();

    // 显示.格式:勾上后格式短名上格(默认净格)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('show-format')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();

    // RAW+JPG 拆分:同一次快门两格(每格式一格,用户定稿 2026-10-23)。
    expect(find.text('NEF'), findsOneWidget);
    expect(find.byKey(ValueKey('102:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('102:nef')), findsOneWidget);
    // 独立 JPG(两张):角标 jpg 各一格。
    expect(find.text('JPG'), findsNWidgets(3));

    repo.completeLoad([
      CameraAlbum.allPhotos([_pair(101, 102)])
    ]);
    await loading;
  });

  testWidgets('连拍不聚合:簇进页拆回单快门逐张显格,×N 不上相机格',
      (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    // 连拍簇一条目(仓库第三遍并组产物形态):三张同夹 JPG 时刻相邻。
    ObjectEntry shot(int handle, String name, int ms) => ObjectEntry(
          handle: handle,
          name: name,
          sizeInBytes: 1,
          kind: ObjectKind.image,
          parentHandle: 0x11,
          capturedAt: DateTime.utc(2026, 10, 1, 12, 0, 0, ms),
          formatCode: 0x3801,
        );
    final burst = PhotoGroup([
      shot(11, 'DSC_0001.JPG', 0),
      shot(12, 'DSC_0002.JPG', 200),
      shot(13, 'DSC_0003.JPG', 400),
    ]);
    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([burst, _photo(2)]),
    ], loaded: 4, total: 4, complete: true));
    await tester.pump();

    // 显示.格式:勾上后格式短名上格(默认净格)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('show-format')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();

    // 拆簇:4 格(3 快门 + 散拍)各自 JPG 短名,×N 不出现在相机格。
    expect(find.text('JPG'), findsNWidgets(4));
    expect(find.textContaining('×'), findsNothing);
    // 各快门独立格(键 = 单快门组键 = 最大句柄)。
    expect(find.byKey(const ValueKey('11:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('12:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('13:jpg')), findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([burst])
    ]);
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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
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

    // 格 = 组 × 格式档(RAW+JPG 拆分):逐格勾选。
    final cellKeys = [for (final g in groups) ...cellKeysOf(g)];
    await tester.longPress(find.byKey(ValueKey(cellKeys.first)));
    await tester.pump();
    for (final key in cellKeys.skip(1)) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }
    expect(find.text('已选 ${cellKeys.length} 项'), findsOneWidget);
    return (controller, engine);
  }

  testWidgets('多选含双格式组:筛选「全部」整组全量直接入队,不弹面板', (tester) async {
    final (_, engine) =
        await selectGroups(tester, [_pair(101, 102), _rawPhoto(201)]);

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsNothing, reason: '全部 = 整组全量直接下,不弹格式面板');

    final (entries, destination) = engine.calls.single;
    // 入队随格序 = 排序后展示序(三者同时刻:稳定排序保输入序)。
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
    // 入队随格序 = 排序后展示序(时间从大到小:12:03 → 12:01 → 12:00)。
    expect(
        entries.map((e) => e.name), ['IMG_3.JPG', 'IMG_1.JPG', 'DSC_0002.NEF']);
    expect(destination, TransferDestination.app);

    // SnackBar「查看进度」动作 → 传输页入口
    await tester.tap(find.text('查看进度'));
    await tester.pump();
    expect(transfersTapped, isTrue, reason: 'SnackBar 动作直通传输页');

    await _drainSnackBar(tester);
  });

  testWidgets(
      '底栏两段式下载:默认单「下载」钮,点按换出双目的地;'
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
    await tester.tap(find.byKey(ValueKey('2:jpg')));
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
    expect(entries.map((e) => e.name), ['IMG_2.JPG', 'IMG_1.JPG']);
    expect(destination, TransferDestination.app);

    await _drainSnackBar(tester);
  });

  testWidgets('筛选定格式仅 JPG:下载跳过面板直接收集,缺格式组跳过', (tester) async {
    final repo = _FakeRepo();
    final engine = _FakeEngine();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
      engine: engine,
    )));
    final loading = controller.load();
    final album = CameraAlbum.allPhotos([_pair(101, 102), _rawPhoto(201)]);
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    repo.completeLoad([album]);
    await loading;
    await tester.pump(); // await loading 留下脏树:交互前先落一帧

    // 先在筛选弹层定格式(格式子面板:只勾 JPG;非 JPG 格不可见,
    // 多选中弹层不可达,须先设后选)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('formatFilter-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('formatFilter-jpg')));
    await tester.pumpAndSettle();
    expect(find.text('DSC_0002.NEF'), findsNothing); // NEF 格被筛掉
    await tester.tapAt(const Offset(30, 10)); // 点外收层
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey('102:jpg')));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing, reason: '筛选已定格式:不再弹格式面板');
    final (entries, destination) = engine.calls.single;
    expect(entries.map((e) => e.name), ['DSC_0001.JPG']);
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('跳过'), findsNothing);

    await _drainSnackBar(tester);
  });

  testWidgets('下载后立即返回:提示自动消失,「查看进度」仍可跳传输页', (tester) async {
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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
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
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [album], loaded: 2, total: 2, complete: true));
    await tester.pump();
    repo.completeLoad([album]);
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey('1:jpg')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('2:jpg')));
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

  testWidgets('筛选弹层:双相册出相册区,点选切换过滤;格式区三档常在', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
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
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('5:jpg')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    // 筛选区:三级联子面板入口(文件夹 + 格式;评级未建立不出现)。
    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsOneWidget);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsNothing);

    // 进文件夹子面板点 100NIKON:不收层,网格只剩该夹内容。
    await tester.tap(find.byKey(const ValueKey('folderFilter-entry')));
    await tester.pumpAndSettle();
    expect(find.text('全部照片'), findsOneWidget);
    await tester.tap(find.text('100NIKON'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('5:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('1:jpg')), findsNothing);

    // 点外收层;重开切回全部照片:两组回归。
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folderFilter-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部照片'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(ValueKey('5:jpg')), findsOneWidget);

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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    final loading = controller.load();
    final aggregate = CameraAlbum.allPhotos([_photo(1), _photo(2)]);
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [aggregate], loaded: 2, total: 2, complete: true));
    await tester.pump();

    await tester.longPress(find.byKey(ValueKey('1:jpg')));
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
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
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
    expect(find.text('筛选'), findsOneWidget);
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsOneWidget);

    repo.completeLoad([aggregate]);
    await loading;
  });

  // ── 评级(相机 0xDC8A 真源;角标与筛选分区) ─────────────────────

  testWidgets('评级角标与筛选:数据建立后出分区,星档/无评级收窄网格', (tester) async {
    final repo = _FakeRepo();
    final ratings = AlbumRatingsController(repository: repo);
    addTearDown(ratings.dispose);
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
      ratings: ratings,
    )));

    final loading = controller.load();
    repo.ratings[1] = 3;
    repo.ratings[3] = 5;
    repo.ratingsAvailable = true;
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3)])
    ], loaded: 3, total: 3, complete: true));
    await tester.pump();

    // 显示.评级:勾上后评级图标上格(默认净格);有星条目显 ★+数。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('show-rating')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 10));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);

    // 主面板:评级分区收成单行入口(7 档收进级联子面板)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);
    expect(find.text('无评级'), findsNothing);

    // 点开子面板:与父面板共存(主面板行仍在),全部 + 6 分类;星档行
    // = 行内实心星(1+2+3+4+5 = 15 颗)。「全部」与格式区重名,按键点。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-entry')));
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsOneWidget); // 父面板保持
    expect(find.byKey(const ValueKey('ratingFilter-0')), findsOneWidget);
    expect(find.text('无评级'), findsNothing); // 无评级亦仅图标
    expect(find.byKey(const ValueKey('ratingFilter-1')), findsOneWidget);
    expect(find.text('已评级'), findsNothing); // 已评级不设行
    expect(find.byType(TrashRatingIcon), findsOneWidget); // 删除候选仅图标
    expect(find.text('删除候选'), findsNothing);
    expect(
      find.descendant(
          of: find.byType(MenuItemButton), matching: find.byIcon(Icons.star)),
      findsNWidgets(15),
    );

    // 无评级(仅图标,按键点):网格只剩未评的 2;不收层。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('2:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('1:jpg')), findsNothing);
    expect(find.byKey(const ValueKey('3:jpg')), findsNothing);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);

    // 接着勾 ★5:多选并集 = 2 + 3(星档键 = 枚举序 4-8)。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-8')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('2:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('3:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('1:jpg')), findsNothing);

    // 勾「全部」:互斥清空分类勾选,网格复原。
    await tester.tap(find.byKey(const ValueKey('ratingFilter-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('1:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('2:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('3:jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsOneWidget);

    // 点弹层外:整体收起。
    await tester.tapAt(const Offset(30, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsNothing);

    repo.completeLoad([
      CameraAlbum.allPhotos([_photo(1), _photo(2), _photo(3)])
    ]);
    await loading;
  });

  testWidgets('评级数据未建立:无分区无角标,网格不筛(防「未取到」当「未评」)', (tester) async {
    final repo = _FakeRepo();
    final ratings = AlbumRatingsController(repository: repo);
    addTearDown(ratings.dispose);
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '相机相册',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
      ratings: ratings,
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1), _photo(2)])
    ], loaded: 2, total: 2, complete: true));
    await tester.pump();

    expect(find.byIcon(Icons.star), findsNothing);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ratingFilter-entry')), findsNothing);
    expect(find.text('筛选'), findsOneWidget);
    expect(find.byKey(const ValueKey('formatFilter-entry')), findsOneWidget);

    repo.completeLoad([
      CameraAlbum.allPhotos([_photo(1), _photo(2)])
    ]);
    await loading;
  });

  testWidgets('渐进放大动效:格缩略挂 HeroZoom,点格查看器初始页同 tag 配对', (tester) async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    await tester.pumpWidget(_host(PhotoGridPage(
      controller: controller,
      folderHandle: CameraAlbum.allPhotosHandle,
      fallbackName: '全部照片',
      thumbnails: _FakeThumbs(),
      uiPrefs: InMemoryUiPrefsStore(), // 选项态进程内隔离(防跨用例串味)
    )));

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(albums: [
      CameraAlbum.allPhotos([_photo(1)])
    ], loaded: 1, total: 1, complete: true));
    await tester.pump();
    await tester.pump(); // 缩略 Future 完成(假件微任务回),格出图挂锚
    repo.completeLoad([CameraAlbum.allPhotos([_photo(1)])]);
    await loading;

    // 格缩略挂动效锚(HeroZoom 包 Image,tag = 相机侧配对键)。
    expect(find.byType(HeroZoom), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Hero && w.tag == 'camera-grid-1:jpg'),
        findsOneWidget);

    // 点格进查看器:初始页挂同 tag 配对件(PageView 只建初始页,恰一枚;
    // 下方网格路由 offstage 不计)。
    await tester.tap(find.byType(HeroZoom));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerPage), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Hero && w.tag == 'camera-grid-1:jpg'),
        findsOneWidget);
    // 初始页先显格缩略(动效落点同图,预览席位未回前已上屏):查看器
    // 席位链显示档是全解 FileImage(缩略原档),非格内 300px 降采样键。
    expect(
        find.byWidgetPredicate((w) =>
            w is Image &&
            w.image ==
                FileImage(File('/tmp/zpill_test_thumb_1.jpg'))),
        findsOneWidget);

    // 收查看器:配对件仍在两侧,回程航班落回格位。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HeroZoom), findsOneWidget);
  });
}

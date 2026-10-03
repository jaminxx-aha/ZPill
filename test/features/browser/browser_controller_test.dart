import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/features/browser/browser_controller.dart';

/// 手动驱动的伪仓库:块事件由测试逐个发,loadAlbums 挂在 Completer 上
/// 由测试择机完成(模拟渐进枚举的时序)。updates 用 sync 广播(与真实现
/// 一致,事件即时送达)。
final class _FakeRepo implements ObjectRepository {
  final updatesCtrl = StreamController<AlbumsUpdate>.broadcast(sync: true);
  Completer<List<CameraAlbum>>? _pending;
  int resetCalls = 0;

  /// 完成当前在途的 loadAlbums(已完成的 completer 自动轮换新的一轮)。
  void completeLoad(List<CameraAlbum> albums) => _fresh().complete(albums);

  void failLoad(Exception e) => _fresh().completeError(e);

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

/// 伪连接:只驱动 states 流(控制器只订阅它)。
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

ObjectEntry _entry(int handle) => ObjectEntry(
      handle: handle,
      name: 'IMG_$handle.JPG',
      sizeInBytes: 1,
      kind: ObjectKind.image,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 1, 12, handle),
      formatCode: 0x3801,
    );

CameraAlbum _album(List<ObjectEntry> items) =>
    CameraAlbum.allPhotos([for (final e in items) PhotoGroup([e])]);

void main() {
  test('块到达:albums 逐块增长,每块一次 notify;完成后 syncing 转 false',
      () async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final loading = controller.load();
    expect(controller.syncing, isTrue);
    expect(notifications, 1); // 起点一次

    final a1 = _album([_entry(1), _entry(2)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [a1], loaded: 2, total: 4, complete: false));
    expect(controller.albums, hasLength(1)); // sync 广播即时送达
    expect(controller.progress, (2, 4));
    expect(notifications, 2);

    final a2 = _album([_entry(1), _entry(2), _entry(3), _entry(4)]);
    repo.updatesCtrl.add(
        AlbumsUpdate(albums: [a2], loaded: 4, total: 4, complete: true));
    repo.completeLoad([a2]);
    await loading;

    expect(controller.syncing, isFalse);
    expect(controller.albums.single, same(a2));
    expect(controller.error, isNull);
    expect(notifications, 4); // 块 2 + finally 各一次
  });

  test('并发 load 去重:第二次调用直接返回,不重复发起枚举', () async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);

    final first = controller.load();
    final second = controller.load(); // syncing 中 → 立即返回
    await second;
    // 去重:两次调用只挂起同一个枚举(首次尚未完成,第二次不另起)。

    repo.completeLoad(const []);
    await first;
  });

  test('首块前异常:硬错误屏(albums 空)', () async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);

    final loading = controller.load();
    repo.failLoad(TimeoutException('USB 链路已中断'));
    await loading;

    expect(controller.albums, isEmpty);
    expect(controller.error, contains('加载失败'));
    expect(controller.syncing, isFalse);
  });

  test('若干块后异常:软横幅错误,已到内容保留', () async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);

    final loading = controller.load();
    final a1 = _album([_entry(1), _entry(2)]);
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [a1], loaded: 2, total: 4, complete: false));
    repo.failLoad(TimeoutException('USB 链路已中断'));

    await loading;

    expect(controller.albums, hasLength(1)); // 内容保留
    expect(controller.error, contains('部分对象同步中断'));
  });

  test('断连竞态:迟到的块被丢弃,断连引发的在途异常不上屏', () async {
    final repo = _FakeRepo();
    final conn = _FakeConnection();
    final controller = BrowserController(repository: repo, connection: conn);

    final loading = controller.load();
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [_album([_entry(1)])],
        loaded: 1,
        total: 4,
        complete: false));
    expect(controller.albums, hasLength(1));

    conn.statesCtrl.add(CameraLinkState.disconnected); // _invalidate
    await pumpEventQueue(); // 连接状态流是异步广播,微任务送达
    expect(controller.albums, isEmpty);
    expect(controller.syncing, isFalse);

    // 断连后迟到的块:直接丢弃
    repo.updatesCtrl.add(AlbumsUpdate(
        albums: [_album([_entry(2)])],
        loaded: 2,
        total: 4,
        complete: false));
    expect(controller.albums, isEmpty);

    // 在途枚举因传输异常 reject:不上屏(_invalidate 已清态)
    repo.failLoad(TimeoutException('USB 链路已中断'));
    await loading;
    expect(controller.error, isNull);
    expect(controller.syncing, isFalse);
  });

  test('重连:门闩重新放行,自动加载新枚举', () async {
    final repo = _FakeRepo();
    final conn = _FakeConnection();
    final controller = BrowserController(repository: repo, connection: conn);

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.syncing, isTrue); // 自动加载已发起
    expect(repo.resetCalls, 0);

    repo.completeLoad([_album([_entry(1)])]);
    await pumpEventQueue();
    expect(controller.albums, hasLength(1));
  });

  test('reload():reset 缓存后重新加载(下拉刷新)', () async {
    final repo = _FakeRepo();
    final controller = BrowserController(repository: repo);

    final first = controller.load();
    repo.completeLoad(const []);
    await first;
    expect(controller.albums, isEmpty);

    final reload = controller.reload();
    expect(repo.resetCalls, 1);
    expect(controller.syncing, isTrue);
    final a1 = _album([_entry(1)]);
    repo.completeLoad([a1]);
    await reload;

    expect(controller.albums.single, same(a1));
  });
}

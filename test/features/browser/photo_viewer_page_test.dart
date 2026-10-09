import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/browser/photo_viewer_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/video_player.dart';

/// 假缩略图:即时返回路径(文件不存在 → Image.file 走占位,无动画挂起)。
final class _FakeThumbs implements ThumbnailCache {
  @override
  int get previewMaxPixelSize => 2560;

  @override
  Future<String> pathFor(ObjectEntry entry, ThumbSource source) async =>
      '/tmp/nikonpill_test_preview_${entry.handle}.jpg';

  @override
  void reset() {}

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

/// 假下载器:真实落一个临时文件(播放收口要删它);[gate] 挂住进度
/// 供取消路径摆拍;取消位照 [DownloadCancelledException] 语义抛。
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

/// 假播放器:记录播放路径与速率,[pending] 挂住播放中状态供断言。
/// 抽帧/帧率与该页顺帧路径无关时置 null(实时直放),帧率用例另注。
final class _FakeVideoPlayer implements VideoPlayer {
  _FakeVideoPlayer({this.frameRateOf});

  /// 顺帧门禁数据(按路径;null = 探测不到/无视频轨)。
  final double? Function(String path)? frameRateOf;
  final List<String> played = [];
  final List<double> rates = [];
  Completer<void>? pending;

  @override
  Future<void> play(String path, {double rate = 1.0}) {
    played.add(path);
    rates.add(rate);
    return (pending = Completer<void>()).future;
  }

  @override
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize}) async {
    throw UnimplementedError();
  }

  @override
  Future<double?> frameRate(String path) async =>
      frameRateOf == null ? null : frameRateOf!(path);
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
        {int format = 0x3801, ObjectKind kind = ObjectKind.image}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 8,
      kind: kind,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 1, 12),
      formatCode: format,
    );

Widget _host(PhotoViewerPage page) => MaterialApp(home: page);

/// 结束前冲掉 snackbar 的 4s 自动消失 timer(不能留 pending 到测试末)。
Future<void> _drainSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('双格式组:下载前弹格式选择,仅 RAW 只入队 NEF', (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.JPG'),
      _file(102, 'DSC_0001.NEF', format: 0x3000),
    ]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      engine: engine,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();
    expect(find.text('选择下载格式'), findsOneWidget);
    expect(find.text('这张照片有 JPG 和 RAW 两份文件'), findsOneWidget);

    await tester.tap(find.text('仅 RAW'));
    await tester.pumpAndSettle();

    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'DSC_0001.NEF');
    expect(destination, TransferDestination.gallery);
    expect(find.textContaining('已开始下载到相册(RAW)'), findsOneWidget);

    await _drainSnackBar(tester);
  });

  testWidgets('单格式组:不弹面板直接整组入队', (tester) async {
    final engine = _FakeEngine();
    final group = PhotoGroup([_file(101, 'IMG_0101.JPG')]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      engine: engine,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载到相册'));
    await tester.pumpAndSettle();

    expect(find.text('选择下载格式'), findsNothing);
    final (entries, destination) = engine.calls.single;
    expect(entries.single.name, 'IMG_0101.JPG');
    expect(destination, TransferDestination.gallery);

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:播放钮 → 下载到临时目录 → 全屏播放 → 播完删档', (tester) async {
    final gallery = _FakeGallery();
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      downloader: downloader,
      gallery: gallery,
      videoPlayer: player,
    )));
    await tester.pumpAndSettle();

    // 视频组:播放钮浮层在,信息行注明「视频」
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.textContaining('视频'), findsWidgets);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 下载完成:进度对话框已收,播放已起
    expect(find.text('下载视频'), findsNothing);
    final (entry, dir) = downloader.calls.single;
    expect(entry.name, 'DSC_0001.MOV');
    expect(dir, gallery.temp.path);
    expect(player.played, ['${gallery.temp.path}/DSC_0001.MOV']);
    expect(player.rates, [1.0]); // 帧率未知 → 实时直放不弹门
    // 播放中:临时档还在(播完才删)
    expect(File(player.played.single).existsSync(), isTrue);

    player.pending!.complete();
    // 删档是真 IO(File.delete 完成落在真实事件循环,pumpAndSettle
    // 无帧可泵时会提前返回,全套并发下竞速):runAsync 里轮询到文件消失。
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && File(player.played.single).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    expect(File(player.played.single).existsSync(), isFalse); // 播完删档
  });

  testWidgets('视频组:高帧率先问顺帧,24fps 档按 24/fps 播放', (tester) async {
    final gallery = _FakeGallery();
    final downloader = _FakeDownloader();
    final player = _FakeVideoPlayer(frameRateOf: (_) => 60);
    final group = PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      downloader: downloader,
      gallery: gallery,
      videoPlayer: player,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    // 下载完先进顺帧门,未起播
    expect(find.text('下载视频'), findsNothing);
    expect(find.text('高帧率素材'), findsOneWidget);
    expect(find.text('24fps 顺帧 · 40%'), findsOneWidget);
    expect(player.played, isEmpty);

    await tester.tap(find.text('24fps 顺帧 · 40%'));
    await tester.pumpAndSettle();
    expect(player.rates.single, closeTo(0.4, 1e-9)); // 24 / 60
    expect(player.played, ['${gallery.temp.path}/DSC_0001.MOV']);

    player.pending!.complete();
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && File(player.played.single).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    expect(File(player.played.single).existsSync(), isFalse);
  });

  testWidgets('视频组:取消下载 → 半途而废,弹「已取消」,不播放', (tester) async {
    final gallery = _FakeGallery();
    final downloader = _FakeDownloader()..gate = Completer<void>();
    final player = _FakeVideoPlayer();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      downloader: downloader,
      gallery: gallery,
      videoPlayer: player,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(find.text('下载视频'), findsOneWidget); // 进度对话框在

    await tester.tap(find.text('取消'));
    await tester.pump(); // 置位取消位
    downloader.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('下载视频'), findsNothing); // 对话框收口
    expect(find.text('已取消'), findsOneWidget);
    expect(player.played, isEmpty); // 未进播放
    expect(gallery.temp.listSync(), isEmpty); // 无半成品残留

    await _drainSnackBar(tester);
  });

  testWidgets('视频组:下载失败 → 弹「下载失败」,不播放', (tester) async {
    final gallery = _FakeGallery();
    final downloader = _FakeDownloader()..failNext = true;
    final player = _FakeVideoPlayer();
    final group = PhotoGroup([
      _file(101, 'DSC_0001.MOV',
          format: ObjectFormatCode.quickTime, kind: ObjectKind.video),
    ]);
    await tester.pumpWidget(_host(PhotoViewerPage(
      items: [group],
      initialIndex: 0,
      thumbnails: _FakeThumbs(),
      downloader: downloader,
      gallery: gallery,
      videoPlayer: player,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(find.text('下载视频'), findsNothing);
    expect(find.text('下载失败,请检查连接后重试'), findsOneWidget);
    expect(player.played, isEmpty);

    await _drainSnackBar(tester);
  });
}

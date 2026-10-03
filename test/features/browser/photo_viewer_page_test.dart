import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/browser/photo_viewer_page.dart';

/// 假缩略图:即时返回路径(文件不存在 → Image.file 走占位,无动画挂起)。
final class _FakeThumbs implements ThumbnailCache {
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

ObjectEntry _file(int handle, String name, {int format = 0x3801}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 8,
      kind: ObjectKind.image,
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
}

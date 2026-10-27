import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/browser/object_entry.dart';
import 'package:z_pill/core/transfer/transfer_engine.dart';
import 'package:z_pill/core/transfer/transfer_task.dart';
import 'package:z_pill/features/transfers/transfers_page.dart';
import 'package:z_pill/platform/gallery_saver.dart';

/// 快照流由测试驱动的伪引擎(sync 广播:add 时刻同步送达;removeRecord
/// 出快照,模拟引擎真实单删回放)。
final class _PageEngine implements TransferEngine {
  final tasksCtrl = StreamController<List<TransferTask>>.broadcast(sync: true);
  final removed = <String>[];
  var snapshot = const <TransferTask>[];

  void emit(List<TransferTask> tasks) {
    snapshot = tasks;
    tasksCtrl.add(List.of(tasks));
  }

  @override
  Stream<List<TransferTask>> get tasks => tasksCtrl.stream;

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {}

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> removeRecord(String taskId) async {
    removed.add(taskId);
    emit([for (final t in snapshot) if (t.id != taskId) t]);
  }

  @override
  Future<void> clearHistory() async {}
}

/// 全兜底假相册(refreshAppFiles 的目录通道;真 IO 在假异步里悬置无害)。
final class _FakeGallery implements GallerySaver {
  @override
  Future<String> tempDir() async => '/tmp';
  @override
  Future<String> thumbsDir() async => '/tmp';
  @override
  Future<String> previewsDir() async => '/tmp';
  @override
  Future<String> downloadsDir() async => '/tmp';
  @override
  Future<String> dataDir() async => '/tmp';
  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async =>
      const [];
}

TransferTask _completed(String id, DateTime finishedAt,
        {DateTime? startedAt, int downloadMs = 0, Uri? galleryUri}) =>
    TransferTask(
      id: id,
      handle: int.parse(id.substring(1)),
      filename: id == 't1' ? 'A.JPG' : 'B.JPG',
      totalBytes: 200000,
      destination: TransferDestination.gallery,
      state: TransferState.completed,
      receivedBytes: 200000,
      galleryUri: galleryUri ?? Uri.parse('content://media/$id'),
      startedAt: startedAt,
      finishedAt: finishedAt,
      downloadMs: downloadMs,
    );

void main() {
  testWidgets('排序:进行中在前,历史按下载时间倒序;completed 行带数据行', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
        MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit([
      // 入队序 t1(旧)→ t2(新);t3 还在跑。
      _completed('t1', DateTime(2026, 10, 24, 9, 0, 10),
          startedAt: DateTime(2026, 10, 24, 9, 0), downloadMs: 4000),
      _completed('t2', DateTime(2026, 10, 24, 10, 0, 10),
          startedAt: DateTime(2026, 10, 24, 10, 0), downloadMs: 5000),
      TransferTask(
        id: 't3',
        handle: 3,
        filename: 'C.JPG',
        totalBytes: 100,
        destination: TransferDestination.app,
        state: TransferState.running,
        receivedBytes: 50,
      ),
    ]);
    await tester.pump();

    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title! as Text).data)
        .toList();
    expect(titles, ['C.JPG', 'B.JPG', 'A.JPG'],
        reason: '进行中置顶,历史按下载时间倒序(新在前)');

    // B 行数据行:下载时间 · 大小 · 耗时 · 速度(200KB/5s = 0.0MB/s 起底)。
    final meta = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .firstWhere((s) => s != null && s.contains('10-24 10:00'));
    expect(meta, contains('195.3KB'));
    expect(meta, contains('10.0秒'));
    expect(meta, contains('MB/s'));
  });

  testWidgets('左滑单删:历史行可滑删并出账,进行中行不响应', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
        MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit([
      _completed('t1', DateTime(2026, 10, 24, 9, 0, 10),
          startedAt: DateTime(2026, 10, 24, 9, 0), downloadMs: 4000),
      TransferTask(
        id: 't3',
        handle: 3,
        filename: 'C.JPG',
        totalBytes: 100,
        destination: TransferDestination.app,
        state: TransferState.running,
        receivedBytes: 50,
      ),
    ]);
    await tester.pump();

    // 历史行(A.JPG)左滑 → 单删,快照同步出列,行消失。
    await tester.drag(find.text('A.JPG'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(engine.removed, ['t1']);
    expect(find.text('A.JPG'), findsNothing);
    expect(find.text('C.JPG'), findsOneWidget);

    // 进行中行(C.JPG)不挂 Dismissible:拖动无删除沿。
    expect(find.byType(Dismissible), findsNothing);
    await tester.drag(find.text('C.JPG'), const Offset(-700, 0));
    await tester.pump();
    expect(engine.removed, ['t1']);
  });

  testWidgets('空表:空态文案仍在(持久化清空后同口径)', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
        MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit(const []);
    await tester.pump();

    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.textContaining('暂无传输任务'), findsOneWidget);
  });
}

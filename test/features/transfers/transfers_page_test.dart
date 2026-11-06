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
final class _PageEngine
    implements TransferEngine, TransferRetry, TransferQueueControl {
  final tasksCtrl = StreamController<List<TransferTask>>.broadcast(sync: true);
  final removed = <String>[];
  final retried = <String>[];
  final cancelled = <String>[];
  var clearCalls = 0;
  var pauseCalls = 0;
  var resumeCalls = 0;
  @override
  var paused = false;
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
  Future<void> cancel(String taskId) async => cancelled.add(taskId);

  @override
  Future<void> removeRecord(String taskId) async {
    removed.add(taskId);
    emit([
      for (final t in snapshot)
        if (t.id != taskId) t
    ]);
  }

  @override
  Future<void> clearHistory() async => clearCalls++;

  @override
  bool canRetry(String taskId) => true;

  @override
  Future<bool> retry(String taskId) async {
    retried.add(taskId);
    return true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    paused = true;
    emit(snapshot);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    paused = false;
    emit(snapshot);
  }
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

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
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
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(titles, containsAll(<String>['C.JPG', 'B.JPG', 'A.JPG']),
        reason: '三行都在树上(文件名仍为行标题)');
    double topOf(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(topOf('C.JPG'), lessThan(topOf('B.JPG')), reason: '进行中置顶');
    expect(topOf('B.JPG'), lessThan(topOf('A.JPG')), reason: '历史按下载时间倒序(新在前)');

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

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
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

  testWidgets('过滤档:计数与真实筛选(全部/处理中/完成/需处理)', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit([
      _completed('t1', DateTime(2026, 10, 24, 9, 0, 10)),
      _completed('t2', DateTime(2026, 10, 24, 10, 0, 10)),
      TransferTask(
        id: 't3',
        handle: 3,
        filename: 'RUN.JPG',
        totalBytes: 100,
        destination: TransferDestination.app,
        state: TransferState.running,
        receivedBytes: 50,
      ),
      TransferTask(
        id: 't4',
        handle: 4,
        filename: 'FAIL.MOV',
        totalBytes: 1000,
        destination: TransferDestination.gallery,
        state: TransferState.failed,
        receivedBytes: 400,
        attempts: 2,
        finishedAt: DateTime(2026, 10, 24, 11, 0),
      ),
    ]);
    await tester.pump();

    expect(find.text('全部 4'), findsOneWidget);
    expect(find.text('处理中 1'), findsOneWidget);
    expect(find.text('完成 2'), findsOneWidget);
    expect(find.text('需处理 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('transfer-filter-failed')));
    await tester.pumpAndSettle();
    expect(find.text('FAIL.MOV'), findsOneWidget);
    expect(find.text('RUN.JPG'), findsNothing);
    expect(find.text('A.JPG'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('transfer-filter-completed')));
    await tester.pumpAndSettle();
    expect(find.text('A.JPG'), findsOneWidget);
    expect(find.text('B.JPG'), findsOneWidget);
    expect(find.text('FAIL.MOV'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('transfer-filter-active')));
    await tester.pumpAndSettle();
    expect(find.text('RUN.JPG'), findsOneWidget);
    expect(find.text('A.JPG'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('transfer-filter-all')));
    await tester.pumpAndSettle();
    expect(find.text('FAIL.MOV'), findsOneWidget);
    expect(find.text('RUN.JPG'), findsOneWidget);
  });

  testWidgets('失败/未导入行:需处理计数 + 行内重试,未导入不再出绿勾', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit([
      _completed('t1', DateTime(2026, 10, 24, 9, 0, 10)),
      TransferTask(
        id: 't2',
        handle: 2,
        filename: 'FAIL.JPG',
        totalBytes: 100,
        destination: TransferDestination.gallery,
        state: TransferState.failed,
        attempts: 2,
        finishedAt: DateTime(2026, 10, 24, 10, 0),
      ),
      TransferTask(
        id: 't3',
        handle: 3,
        filename: 'NOIMPORT.JPG',
        totalBytes: 100,
        destination: TransferDestination.gallery,
        state: TransferState.completed,
        receivedBytes: 100,
        finishedAt: DateTime(2026, 10, 24, 11, 0),
      ),
    ]);
    await tester.pump();

    expect(find.text('需处理 2'), findsOneWidget);
    expect(find.text('完成 1'), findsOneWidget,
        reason: '未导入不算完成档');
    expect(find.byIcon(Icons.check_circle), findsOneWidget,
        reason: '只有真正落定的 t1 出绿勾');
    expect(find.byTooltip('重试'), findsOneWidget);
    expect(find.byTooltip('重新下载'), findsOneWidget);

    await tester.tap(find.byTooltip('重新下载'));
    await tester.pump();
    expect(engine.retried, ['t3']);
  });

  testWidgets('清空历史/取消全部:先确认,取消则零动作,确认才执行', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);
    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));

    engine.emit([
      TransferTask(
          id: 't1',
          handle: 1,
          filename: 'RUN.JPG',
          totalBytes: 100,
          destination: TransferDestination.app,
          state: TransferState.running,
          receivedBytes: 10),
      _completed('t2', DateTime(2026, 10, 24, 9, 0, 10)),
    ]);
    await tester.pump();

    await tester.tap(find.byTooltip('清空历史'));
    await tester.pumpAndSettle();
    expect(find.text('清空传输历史?'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(engine.clearCalls, 0);

    await tester.tap(find.byTooltip('取消全部'));
    await tester.pumpAndSettle();
    expect(find.text('取消全部传输?'), findsOneWidget);
    await tester.tap(find.text('取消全部'));
    await tester.pumpAndSettle();
    expect(engine.cancelled, ['t1']);
  });

  testWidgets('空表:空态文案仍在(持久化清空后同口径)', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit(const []);
    await tester.pump();

    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.textContaining('暂无传输任务'), findsOneWidget);
  });

  testWidgets('队列暂停/恢复:按钮随引擎 paused 切换并调用引擎', (tester) async {
    final engine = _PageEngine();
    final controller =
        TransfersController(engine: engine, gallery: _FakeGallery());
    addTearDown(controller.dispose);

    await tester
        .pumpWidget(MaterialApp(home: TransfersPage(controller: controller)));
    engine.emit([
      const TransferTask(
        id: 't1',
        handle: 1,
        filename: 'A.JPG',
        totalBytes: 100,
        destination: TransferDestination.app,
        state: TransferState.running,
        receivedBytes: 40,
      ),
    ]);
    await tester.pump();

    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.pause_circle_outline));
    await tester.pump();
    expect(engine.pauseCalls, 1);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(engine.resumeCalls, 1);
  });
}

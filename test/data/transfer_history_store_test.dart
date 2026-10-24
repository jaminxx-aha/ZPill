import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/data/transfer_history_store.dart';

TransferTask _task(
  String id, {
  TransferState state = TransferState.completed,
  DateTime? startedAt,
  DateTime? finishedAt,
  int downloadMs = 0,
  Uri? galleryUri,
  String? error,
}) =>
    TransferTask(
      id: id,
      handle: 1,
      filename: 'DSC_0001.JPG',
      totalBytes: 200000,
      destination: TransferDestination.gallery,
      state: state,
      receivedBytes: state == TransferState.completed ? 200000 : 40000,
      error: error,
      galleryUri: galleryUri,
      startedAt: startedAt,
      finishedAt: finishedAt,
      downloadMs: downloadMs,
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nikonpill_history');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 路径现值快照进闭包(不捕 root 变量):前案的在途写盘不得漂进
  /// 本案的目录(root 跨用例重赋值,晚解析会串账)。
  FileTransferHistoryStore store() {
    final dir = root.path;
    return FileTransferHistoryStore(dataDir: () async => dir);
  }

  test('round-trip:字段全量落盘读回,新→旧;速度由存档数据可算', () async {
    final s = store();
    await s.upsert(_task('t1',
        startedAt: DateTime(2026, 10, 24, 9, 59, 50),
        finishedAt: DateTime(2026, 10, 24, 10, 0),
        downloadMs: 5000,
        galleryUri: Uri.parse('content://media/1')));
    await s.upsert(_task('t2',
        state: TransferState.failed,
        error: 'boom 0x2002',
        finishedAt: DateTime(2026, 10, 24, 11, 0)));

    final loaded = await store().load(); // 新实例 = 从盘读
    expect(loaded.map((t) => t.id), ['t2', 't1']);
    final t2 = loaded.first;
    expect(t2.state, TransferState.failed);
    expect(t2.error, 'boom 0x2002');
    expect(t2.finishedAt, DateTime(2026, 10, 24, 11, 0));
    final t1 = loaded.last;
    expect(t1.startedAt, DateTime(2026, 10, 24, 9, 59, 50));
    expect(t1.downloadMs, 5000);
    expect(t1.galleryUri, Uri.parse('content://media/1'));
    expect(t1.downloadSpeed, closeTo(200000 * 1000 / 5000, 0.5));
  });

  test('upsert:同 id 去重置顶并更新内容', () async {
    final s = store();
    await s.upsert(_task('t1', finishedAt: DateTime(2026, 10, 24, 10)));
    await s.upsert(_task('t2', finishedAt: DateTime(2026, 10, 24, 11)));
    await s.upsert(_task('t1',
        finishedAt: DateTime(2026, 10, 24, 12),
        galleryUri: Uri.parse('content://media/9')));

    final loaded = await s.load();
    expect(loaded.map((t) => t.id), ['t1', 't2']);
    expect(loaded.first.finishedAt, DateTime(2026, 10, 24, 12));
    expect(loaded.first.galleryUri, Uri.parse('content://media/9'));
  });

  test('容量滚动:超上限裁最旧', () async {
    final s = store();
    for (var i = 0; i < kTransferHistoryCap + 5; i++) {
      await s.upsert(_task('t$i',
          finishedAt: DateTime(2026, 10, 24, 10).add(Duration(minutes: i))));
    }
    final loaded = await s.load();
    expect(loaded, hasLength(kTransferHistoryCap));
    expect(loaded.first.id, 't${kTransferHistoryCap + 4}');
    expect(loaded.map((t) => t.id), isNot(contains('t0')));
  });

  test('remove/clear:单删与清空都反映到盘', () async {
    final s = store();
    await s.upsert(_task('t1', finishedAt: DateTime(2026, 10, 24, 10)));
    await s.upsert(_task('t2', finishedAt: DateTime(2026, 10, 24, 11)));
    await s.remove('t1');
    expect((await store().load()).map((t) => t.id), ['t2']);

    await s.clear();
    expect(await store().load(), isEmpty);
  });

  test('损坏文件:按空表重建不抛', () async {
    File('${root.path}/transfer_history.json')
        .writeAsStringSync('{"v": 1, "records": [ {"id": ');
    expect(await store().load(), isEmpty);
    // 重建可写
    final s = store();
    await s.upsert(_task('t1', finishedAt: DateTime(2026, 10, 24, 10)));
    expect((await store().load()).map((t) => t.id), ['t1']);
  });

  test('脏记录整条弃(缺 id/枚举名不识),好记录保留', () async {
    File('${root.path}/transfer_history.json').writeAsStringSync(jsonEncode({
      'v': 1,
      'records': [
        {'id': 't1', 'state': 'completed', 'destination': 'gallery',
         'filename': 'OK.JPG', 'totalBytes': 3},
        {'id': 't2', 'state': 'completed', 'destination': 'weird',
         'filename': 'BAD.JPG', 'totalBytes': 3},
        {'state': 'completed', 'destination': 'gallery',
         'filename': 'NOID.JPG', 'totalBytes': 3},
      ],
    }));
    final loaded = await store().load();
    expect(loaded.map((t) => t.id), ['t1']);
  });

  test('并发突发 upsert:一串未 await 的账目不丢(批次回填口径)', () async {
    final s = store();
    await s.upsert(_task('t0', finishedAt: DateTime(2026, 10, 24, 10)));
    // 批次导入回填沿的真实形态:一轮同步发起 N 笔,全不 await ——
    // 旧实现各自拿旧基线互覆,只活最后一笔。
    final pending = [
      for (var i = 1; i <= 5; i++)
        s.upsert(_task('t$i',
            finishedAt: DateTime(2026, 10, 24, 10, i),
            galleryUri: Uri.parse('content://media/$i'))),
    ];
    await Future.wait(pending);
    final loaded = await store().load();
    expect(loaded.map((t) => t.id).toSet(),
        {'t0', 't1', 't2', 't3', 't4', 't5'});
    expect(loaded.every((t) => t.id == 't0' || t.galleryUri != null), isTrue);
  });

  test('InMemory 实现:同语义(去重置顶/裁剪/删除/清空)', () async {
    final s = InMemoryTransferHistoryStore(cap: 2);
    await s.upsert(_task('t1', finishedAt: DateTime(2026, 10, 24, 10)));
    await s.upsert(_task('t2', finishedAt: DateTime(2026, 10, 24, 11)));
    await s.upsert(_task('t1', finishedAt: DateTime(2026, 10, 24, 12)));
    await s.upsert(_task('t3', finishedAt: DateTime(2026, 10, 24, 13)));
    expect((await s.load()).map((t) => t.id), ['t3', 't1']);
    await s.remove('t1');
    expect((await s.load()).map((t) => t.id), ['t3']);
    await s.clear();
    expect(await s.load(), isEmpty);
  });
}

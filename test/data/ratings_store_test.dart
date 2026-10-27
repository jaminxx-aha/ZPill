import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/data/ratings_store.dart';
import 'package:z_pill/features/library/library_ratings.dart';

Future<String> _tempDataDir() async =>
    (await Directory.systemTemp.createTemp('zpill_ratings_test_')).path;

void main() {
  // ── 身份键 ────────────────────────────────────────────────────

  test('fileRatingKey:文件名 + 字节;同名不同体积(换卡重拍)不串评', () {
    expect(fileRatingKey('DSC_0001.JPG', 8400000), 'DSC_0001.JPG|8400000');
    expect(
      fileRatingKey('DSC_0001.JPG', 8400000),
      isNot(fileRatingKey('DSC_0001.JPG', 2000)),
    );
  });

  test('fileRatingKey:旧版组键(基名|组总字节)遗留条目天然不命中', () {
    // 旧键无扩展名,文件必带扩展名 → 键空间不相交,无需迁移。
    final legacy = 'DSC_0001|35243545';
    expect(
      legacy,
      isNot(fileRatingKey('DSC_0001.JPG', 35243545)),
    );
    expect(
      legacy,
      isNot(fileRatingKey('DSC_0001.NEF', 35243545)),
    );
  });

  // ── FileRatingsStore ──────────────────────────────────────────

  test('往返:set 后新实例读到;清除(0)移除键;0/负值不入表', () async {
    final dir = await _tempDataDir();
    final store = FileRatingsStore(dataDir: () async => dir);
    await store.set(fileRatingKey('DSC_0001.JPG', 8400000), 5);
    await store.set(fileRatingKey('DSC_0002.NEF', 26843545), 3);
    await store.set(fileRatingKey('DSC_0003.JPG', 1000), 0); // 清除语义

    final reloaded = await FileRatingsStore(dataDir: () async => dir).loadAll();
    expect(reloaded, {
      fileRatingKey('DSC_0001.JPG', 8400000): 5,
      fileRatingKey('DSC_0002.NEF', 26843545): 3,
    });

    await store.set(fileRatingKey('DSC_0001.JPG', 8400000), 0); // 已有键清除
    final again = await FileRatingsStore(dataDir: () async => dir).loadAll();
    expect(again, {fileRatingKey('DSC_0002.NEF', 26843545): 3});
  });

  test('损坏文件:按空表重建(评分可重标)', () async {
    final dir = await _tempDataDir();
    await File('$dir/ratings.json').writeAsString('not json');
    final store = FileRatingsStore(dataDir: () async => dir);
    expect(await store.loadAll(), isEmpty);
    await store.set('a|1', 4);
    final j = jsonDecode(await File('$dir/ratings.json').readAsString());
    expect(j, {'a|1': 4});
  });

  test('畸形载荷(值 <1 或非数):过滤不入表', () async {
    final dir = await _tempDataDir();
    await File('$dir/ratings.json')
        .writeAsString('{"good|1": 3, "zero|1": 0, "str|1": "x"}');
    final store = FileRatingsStore(dataDir: () async => dir);
    expect(await store.loadAll(), {'good|1': 3});
  });

  // ── LibraryRatings ────────────────────────────────────────────

  test('ratingOf:按文件名+字节命中;setFile 写入并通知;清除即移除',
      () async {
    final dir = await _tempDataDir();
    final store = FileRatingsStore(dataDir: () async => dir);
    final controller = LibraryRatings(store: store);
    addTearDown(controller.dispose);
    await pumpEventQueue();
    final file = File('$dir/DSC_0001.JPG');
    await file.writeAsBytes(List.filled(100, 1));

    expect(controller.loaded, isTrue);
    expect(controller.ratingOf(file), 0);

    var notified = 0;
    controller.addListener(() => notified++);
    await controller.setFile('DSC_0001.JPG', 100, 4);
    expect(controller.ratingOf(file), 4);
    expect(notified, greaterThan(0));

    await controller.setFile('DSC_0001.JPG', 100, 0);
    expect(controller.ratingOf(file), 0);
  });

  test('store 失败:loaded 保持 false,读值恒 0', () async {
    final controller = LibraryRatings(store: _FailingStore());
    addTearDown(controller.dispose);
    await pumpEventQueue();
    expect(controller.loaded, isFalse);
    expect(
        controller.ratingOf(File('/nonexistent/DSC_0001.JPG')), 0);
  });
}

final class _FailingStore implements RatingsStore {
  @override
  Future<Map<String, int>> loadAll() async => throw Exception('disk full');

  @override
  Future<void> set(String key, int stars) async => throw Exception('disk full');
}

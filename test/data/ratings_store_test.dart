import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/data/ratings_store.dart';
import 'package:nikon_pill/features/browser/ratings_controller.dart';

Future<String> _tempDataDir() async =>
    (await Directory.systemTemp.createTemp('nikonpill_ratings_test_')).path;

ObjectEntry _file(int handle, String name, {int size = 1000}) => ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: size,
      kind: ObjectKind.image,
      parentHandle: 0x11,
      capturedAt: DateTime.utc(2026, 10, 2, 9, 0, 0),
      formatCode: 0x3801,
    );

void main() {
  // ── 身份键 ────────────────────────────────────────────────────

  test('photoGroupKey:基名 + 组总字节;代表文件切换(JPG↔NEF)与句柄变化下稳定',
      () {
    final jpgFirst = buildPhotoGroups([
      _file(0x23, 'DSC_0001.JPG', size: 8400000),
      _file(0x22, 'DSC_0001.NEF', size: 26843545),
    ]).single;
    // 换会话:句柄全变,但基名与总字节相同 → 同键,评分不丢。
    final nextSession = buildPhotoGroups([
      _file(0x99, 'DSC_0001.JPG', size: 8400000),
      _file(0x88, 'DSC_0001.NEF', size: 26843545),
    ]).single;

    expect(photoGroupKey(jpgFirst), 'DSC_0001|35243545');
    expect(photoGroupKey(nextSession), photoGroupKey(jpgFirst));
  });

  test('photoGroupKey:同基名不同体积(换卡重拍)不串评', () {
    final a = buildPhotoGroups([_file(0x23, 'DSC_0001.JPG')]).single;
    final b = buildPhotoGroups([_file(0x13, 'DSC_0001.JPG', size: 2000)]).single;
    expect(photoGroupKey(a), isNot(photoGroupKey(b)));
  });

  // ── FileRatingsStore ──────────────────────────────────────────

  test('往返:set 后新实例读到;清除(0)移除键;0/负值不入表', () async {
    final dir = await _tempDataDir();
    final store = FileRatingsStore(dataDir: () async => dir);
    await store.set('DSC_0001|35243545', 5);
    await store.set('DSC_0002|1000', 3);
    await store.set('DSC_0003|1000', 0); // 清除语义

    final reloaded = await FileRatingsStore(dataDir: () async => dir).loadAll();
    expect(reloaded, {'DSC_0001|35243545': 5, 'DSC_0002|1000': 3});

    await store.set('DSC_0001|35243545', 0); // 已有键清除
    final again = await FileRatingsStore(dataDir: () async => dir).loadAll();
    expect(again, {'DSC_0002|1000': 3});
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

  // ── RatingsController ─────────────────────────────────────────

  test('乐观上屏:rate 立即生效;store 失败静默回滚', () async {
    final store = InMemoryRatingsStore();
    final controller = RatingsController(store: store);
    addTearDown(controller.dispose);
    await pumpEventQueue();

    final group = buildPhotoGroups([_file(0x23, 'DSC_0001.JPG')]).single;
    expect(controller.ratingOf(group), 0);

    await controller.rate(group, 5);
    expect(controller.ratingOf(group), 5);
    expect(await store.loadAll(), {'DSC_0001|1000': 5});

    await controller.rate(group, 0); // 清除
    expect(controller.ratingOf(group), 0);
    expect(await store.loadAll(), isEmpty);
  });

  test('持久化失败回滚:界面不残留假星', () async {
    final controller = RatingsController(store: _FailingStore());
    addTearDown(controller.dispose);
    await pumpEventQueue();

    final group = buildPhotoGroups([_file(0x23, 'DSC_0001.JPG')]).single;
    await controller.rate(group, 4);
    expect(controller.ratingOf(group), 0); // 回滚
  });
}

final class _FailingStore implements RatingsStore {
  @override
  Future<Map<String, int>> loadAll() async => {};

  @override
  Future<void> set(String key, int stars) async => throw Exception('disk full');
}

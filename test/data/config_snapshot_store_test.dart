import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/remote/config_snapshot.dart';
import 'package:nikon_pill/data/config_snapshot_store.dart';

CameraConfigSnapshot _snap(String model) => CameraConfigSnapshot(
      model: model,
      deviceVersion: 'V1.00',
      serialNumber: 'SN-$model',
      capturedAt: DateTime.utc(2026, 10, 5, 8),
      props: [
        const ConfigPropSnapshot(
            code: 0x5007, type: 'uint16', value: 28, writable: true),
      ],
    );

void main() {
  late Directory tmp;
  late ConfigSnapshotStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nikonpill_snapshots');
    store = ConfigSnapshotStore(dataDir: () async => tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('空仓库:loadAll 空表不抛', () async {
    expect(await store.loadAll(), isEmpty);
  });

  test('save 落盘 + 重读一致(跨实例)', () async {
    await store.save('婚礼室内', _snap('Zf'));
    await store.save('夜景', _snap('Zf'));
    expect(await File('${tmp.path}/config_snapshots.json').exists(), isTrue);

    final fresh = ConfigSnapshotStore(dataDir: () async => tmp.path);
    final all = await fresh.loadAll();
    expect(all.keys, unorderedEquals(['婚礼室内', '夜景']));
    expect(all['婚礼室内']!.model, 'Zf');
    expect(all['婚礼室内']!.props.single.value, 28);
    expect(all['夜景']!.serialNumber, 'SN-Zf');
  });

  test('同名保存覆盖不增条目', () async {
    await store.save('A', _snap('Zf'));
    await store.save('A', _snap('Z6II'));
    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all['A']!.model, 'Z6II');
  });

  test('delete 后不再返回,未存名 delete 无副作用', () async {
    await store.save('A', _snap('Zf'));
    await store.delete('B'); // 不存在:安静
    await store.delete('A');
    expect(await store.loadAll(), isEmpty);
  });

  test('损坏文件:按空表重建不抛', () async {
    final file = File('${tmp.path}/config_snapshots.json')
      ..createSync(recursive: true);
    file.writeAsStringSync('{ not json');
    expect(await ConfigSnapshotStore(dataDir: () async => tmp.path).loadAll(),
        isEmpty);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/data/settings_store.dart';

void main() {
  late Directory tmp;
  late FileSettingsStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nikonpill_settings');
    store = FileSettingsStore(dataDir: () async => tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('默认设置:文件不存在 → 全默认', () async {
    final s = await store.current();
    expect(s.autoTransfer, isFalse);
    expect(s.autoTransferFormat, PhotoDownloadFormat.both);
    expect(s.quality, TransferQuality.original);
  });

  test('update 落盘 + 广播 + 重读一致(往返)', () async {
    final updates = <AppSettings>[];
    store.settings.listen(updates.add);
    final next = const AppSettings().copyWith(
      autoTransfer: true,
      autoTransferFormat: PhotoDownloadFormat.raw,
      batterySaver: true,
      customSavePath: '/tmp/x',
    );
    await store.update(next);
    await pumpEventQueue(); // broadcast 控制器异步派发
    expect(updates.single, next);
    expect(await File('${tmp.path}/settings.json').exists(), isTrue);

    final reread = FileSettingsStore(dataDir: () async => tmp.path);
    expect(await reread.current(), next);
  });

  test('损坏文件:按默认重建不抛', () async {
    final file = File('${tmp.path}/settings.json')
      ..createSync(recursive: true);
    file.writeAsStringSync('{ not json');
    final s = await FileSettingsStore(dataDir: () async => tmp.path).current();
    expect(s, const AppSettings());
  });

  test('未知枚举值(旧版本字段):回落默认', () async {
    final file = File('${tmp.path}/settings.json')..createSync(recursive: true);
    file.writeAsStringSync('{"autoTransfer": true, "autoTransferFormat": "heif"}');
    final s = await FileSettingsStore(dataDir: () async => tmp.path).current();
    expect(s.autoTransfer, isTrue);
    expect(s.autoTransferFormat, PhotoDownloadFormat.both);
  });
}

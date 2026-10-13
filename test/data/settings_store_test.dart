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

  group('取景画质档持久化(2026-10-12 官方 §6.5.11.4-5)', () {
    test('默认 XGA/Fine(2026-10-13 清晰度定档);哨兵 copyWith 可写回 null', () {
      var s = const AppSettings();
      expect(s.liveViewImageSize, 3);
      expect(s.liveViewImageCompression, 5);
      s = s.copyWith(liveViewImageSize: 1, liveViewImageCompression: 5);
      expect(s.liveViewImageSize, 1);
      expect(s.liveViewImageCompression, 5);
      // 「跟随相机」= 显式写回 null(哨兵语义:传值即覆盖)
      s = s.copyWith(liveViewImageSize: null);
      expect(s.liveViewImageSize, isNull);
      expect(s.liveViewImageCompression, 5, reason: '未传字段保持');
    });

    test('JSON 往返;表外值回落「跟随相机」', () {
      final s = const AppSettings()
          .copyWith(liveViewImageSize: 3, liveViewImageCompression: 2);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.liveViewImageSize, 3);
      expect(back.liveViewImageCompression, 2);

      final bogus = AppSettings.fromJson({
        'liveViewImageSize': 9, // 尺寸值域 {1,2,3} 外
        'liveViewImageCompression': 'x',
      });
      expect(bogus.liveViewImageSize, isNull);
      expect(bogus.liveViewImageCompression, isNull);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_lv');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(
          liveViewImageSize: 2, liveViewImageCompression: 3));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      final s = await reloaded.current();
      expect(s.liveViewImageSize, 2);
      expect(s.liveViewImageCompression, 3);
    });
  });

  group('SDRAM 直拍开关持久化(0x90CB,2026-10-13)', () {
    test('默认关;JSON 往返;旧档缺省回落关', () {
      expect(const AppSettings().sdramCapture, isFalse);
      final on = const AppSettings().copyWith(sdramCapture: true);
      final back = AppSettings.fromJson(on.toJson());
      expect(back.sdramCapture, isTrue);
      // 旧版本文件无此键 → 关
      expect(AppSettings.fromJson({'autoTransfer': true}).sdramCapture,
          isFalse);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_sdram');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(sdramCapture: true));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      expect((await reloaded.current()).sdramCapture, isTrue);
    });
  });
}

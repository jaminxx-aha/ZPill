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

  group('BLE GPS 注入开关持久化(0x2007,2026-10-13)', () {
    test('默认关;JSON 往返;旧档缺省回落关', () {
      expect(const AppSettings().bleGpsInject, isFalse);
      final on = const AppSettings().copyWith(bleGpsInject: true);
      final back = AppSettings.fromJson(on.toJson());
      expect(back.bleGpsInject, isTrue);
      // 旧版本文件无此键 → 关
      expect(AppSettings.fromJson({'autoTransfer': true}).bleGpsInject,
          isFalse);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_blegps');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(bleGpsInject: true));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      expect((await reloaded.current()).bleGpsInject, isTrue);
    });
  });

  group('峰值档位持久化(2026-10-14:灵敏度/颜色可配)', () {
    test('默认中灵敏度/金色(= 旧行为);JSON 往返;旧档缺省与表外值回落', () {
      expect(const AppSettings().monitorPeakingLevel, 1);
      expect(const AppSettings().monitorPeakingColor, 0);

      final tuned = const AppSettings().copyWith(
          monitorPeakingLevel: 2, monitorPeakingColor: 1);
      final back = AppSettings.fromJson(tuned.toJson());
      expect(back.monitorPeakingLevel, 2);
      expect(back.monitorPeakingColor, 1);

      // 旧版本文件无此键 → 默认档(中/金 = 旧行为)
      final bare = AppSettings.fromJson({'autoTransfer': true});
      expect(bare.monitorPeakingLevel, 1);
      expect(bare.monitorPeakingColor, 0);
      // 表外值(手改文件)回落默认档
      final bogus = AppSettings.fromJson(
          {'monitorPeakingLevel': 7, 'monitorPeakingColor': -1});
      expect(bogus.monitorPeakingLevel, 1);
      expect(bogus.monitorPeakingColor, 0);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_peaking');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(
          monitorPeakingLevel: 0, monitorPeakingColor: 2));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      final s = await reloaded.current();
      expect(s.monitorPeakingLevel, 0);
      expect(s.monitorPeakingColor, 2);
    });
  });

  group('监看差集五字段持久化(2026-10-14:遮幅/安全框/中心标/波形/LUT)', () {
    test('默认全关;JSON 往返;旧档缺省回落默认(遮幅 off/LUT 关)', () {
      expect(const AppSettings().framingAspect, FramingAspect.off);
      expect(const AppSettings().framingSafeArea, isFalse);
      expect(const AppSettings().framingCenterMark, isFalse);
      expect(const AppSettings().monitorWaveform, isFalse);
      expect(const AppSettings().monitorLutIndex, -1);

      final on = const AppSettings().copyWith(
        framingAspect: FramingAspect.a239,
        framingSafeArea: true,
        framingCenterMark: true,
        monitorWaveform: true,
        monitorLutIndex: 2,
      );
      final back = AppSettings.fromJson(on.toJson());
      expect(back.framingAspect, FramingAspect.a239);
      expect(back.framingSafeArea, isTrue);
      expect(back.framingCenterMark, isTrue);
      expect(back.monitorWaveform, isTrue);
      expect(back.monitorLutIndex, 2);

      final bare = AppSettings.fromJson({'autoTransfer': true});
      expect(bare.framingAspect, FramingAspect.off);
      expect(bare.monitorLutIndex, -1);
    });

    test('遮幅枚举:循环 next 与 label/ratio;未知档名回落 off', () {
      expect(FramingAspect.off.next, FramingAspect.a239);
      expect(FramingAspect.a185.next, FramingAspect.off);
      expect(FramingAspect.a239.ratio, 2.39);
      expect(FramingAspect.off.ratio, isNull);
      expect(FramingAspect.a235.label, '2.35');
      expect(
          AppSettings.fromJson(const {
            'framingAspect': 'bogus',
          }).framingAspect,
          FramingAspect.off);
    });
  });
}

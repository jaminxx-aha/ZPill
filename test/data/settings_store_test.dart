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

  group('峰值档位持久化(2026-10-14:灵敏度/颜色可配;10-15 峰值算法)', () {
    test('默认中灵敏度/金色/双尺度(= 旧行为阈值回退档);JSON 往返;旧档缺省与表外值回落', () {
      expect(const AppSettings().monitorPeakingLevel, 1);
      expect(const AppSettings().monitorPeakingColor, 0);
      expect(const AppSettings().monitorPeakingEngine, 0);

      final tuned = const AppSettings().copyWith(
          monitorPeakingLevel: 2,
          monitorPeakingColor: 1,
          monitorPeakingEngine: 1);
      final back = AppSettings.fromJson(tuned.toJson());
      expect(back.monitorPeakingLevel, 2);
      expect(back.monitorPeakingColor, 1);
      expect(back.monitorPeakingEngine, 1);

      // 旧版本文件无此键 → 默认档(中/金/双尺度 = 缺省引擎不变)
      final bare = AppSettings.fromJson({'autoTransfer': true});
      expect(bare.monitorPeakingLevel, 1);
      expect(bare.monitorPeakingColor, 0);
      expect(bare.monitorPeakingEngine, 0);
      // 表外值(手改文件)回落默认档
      final bogus = AppSettings.fromJson({
        'monitorPeakingLevel': 7,
        'monitorPeakingColor': -1,
        'monitorPeakingEngine': 9
      });
      expect(bogus.monitorPeakingLevel, 1);
      expect(bogus.monitorPeakingColor, 0);
      expect(bogus.monitorPeakingEngine, 0);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_peaking');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(
          monitorPeakingLevel: 0,
          monitorPeakingColor: 2,
          monitorPeakingEngine: 1));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      final s = await reloaded.current();
      expect(s.monitorPeakingLevel, 0);
      expect(s.monitorPeakingColor, 2);
      expect(s.monitorPeakingEngine, 1);
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

  group('示波器族持久化(2026-10-15:档位四选一 + N-Log 刻度)', () {
    test('默认关/全幅刻度;JSON 往返;旧档缺省与表外值回落', () {
      expect(const AppSettings().monitorScope, 0, reason: '默认 off');
      expect(const AppSettings().monitorScopeNLog, isFalse);

      final on = const AppSettings()
          .copyWith(monitorScope: 3, monitorScopeNLog: true);
      final back = AppSettings.fromJson(on.toJson());
      expect(back.monitorScope, 3);
      expect(back.monitorScopeNLog, isTrue);

      // 旧版本文件无此键 → 关 / 全幅
      final bare = AppSettings.fromJson({'autoTransfer': true});
      expect(bare.monitorScope, 0);
      expect(bare.monitorScopeNLog, isFalse);
      // 表外索引(手改文件)回落关;布尔刻度档独立回落 false
      final bogus = AppSettings.fromJson({'monitorScope': 9});
      expect(bogus.monitorScope, 0);
      expect(AppSettings.fromJson({'monitorScope': -1}).monitorScope, 0);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir =
          await Directory.systemTemp.createTemp('np_settings_scope');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(
          monitorScope: 4, monitorScopeNLog: true));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      final s = await reloaded.current();
      expect(s.monitorScope, 4);
      expect(s.monitorScopeNLog, isTrue);
    });
  });

  group('音量键快门开关持久化(2026-10-14 Android)', () {
    test('默认关;JSON 往返;旧档缺省回落关', () {
      expect(const AppSettings().volumeKeyShutter, isFalse);
      final on = const AppSettings().copyWith(volumeKeyShutter: true);
      final back = AppSettings.fromJson(on.toJson());
      expect(back.volumeKeyShutter, isTrue);
      // 旧版本文件无此键 → 关
      expect(AppSettings.fromJson({'autoTransfer': true}).volumeKeyShutter,
          isFalse);
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_volkey');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(const AppSettings().copyWith(volumeKeyShutter: true));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      expect((await reloaded.current()).volumeKeyShutter, isTrue);
    });
  });

  group('界面语言持久化(i18n 第一期,2026-10-14)', () {
    test('默认中文(非跟随系统);copyWith/JSON 往返(en/system)', () {
      expect(const AppSettings().language, AppLanguage.zh,
          reason: '「可跟随系统,默认为中文」—— 默认档是 zh 不是 system');

      final en = const AppSettings().copyWith(language: AppLanguage.en);
      expect(en.language, AppLanguage.en);
      expect(AppSettings.fromJson(en.toJson()).language, AppLanguage.en);

      final sys = const AppSettings().copyWith(language: AppLanguage.system);
      expect(sys.language, AppLanguage.system);
      expect(AppSettings.fromJson(sys.toJson()).language, AppLanguage.system);
    });

    test('旧档缺键/表外值回落中文', () {
      expect(AppSettings.fromJson({'autoTransfer': true}).language,
          AppLanguage.zh,
          reason: '旧版本文件无此键 → 默认中文');
      expect(AppSettings.fromJson({'language': 'fr'}).language,
          AppLanguage.zh,
          reason: '表外值(手改文件)回落中文');
    });

    test('label:三档文案(键;渲染层 t() 落词表)', () {
      expect(AppLanguage.system.label, 'common.followSystem');
      expect(AppLanguage.zh.label, 'lang.zh');
      expect(AppLanguage.en.label, 'lang.en');
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_lang');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store.update(
          const AppSettings().copyWith(language: AppLanguage.en));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      expect((await reloaded.current()).language, AppLanguage.en);
    });
  });

  group('连接方式记忆持久化(2026-10-17 连接页记住上次选中)', () {
    test('默认 usb;copyWith/JSON 往返;旧档缺键/非字符串值回落 usb', () {
      expect(const AppSettings().connectionMethod, 'usb');

      final ap = const AppSettings().copyWith(connectionMethod: 'ap');
      expect(ap.connectionMethod, 'ap');
      expect(AppSettings.fromJson(ap.toJson()).connectionMethod, 'ap');

      final bare = AppSettings.fromJson({'autoTransfer': true});
      expect(bare.connectionMethod, 'usb',
          reason: '旧版本文件无此键 → 默认有线');
      expect(AppSettings.fromJson({'connectionMethod': 7}).connectionMethod,
          'usb',
          reason: '非字符串(手改文件)回落有线;表外名由消费侧兜底');
    });

    test('文件落盘往返(FileSettingsStore)', () async {
      final dir = await Directory.systemTemp.createTemp('np_settings_conn');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(dataDir: () async => dir.path);
      await store
          .update(const AppSettings().copyWith(connectionMethod: 'ble'));
      final reloaded = FileSettingsStore(dataDir: () async => dir.path);
      expect((await reloaded.current()).connectionMethod, 'ble');
    });
  });
}

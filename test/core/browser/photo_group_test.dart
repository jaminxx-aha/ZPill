import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';

/// 单文件条目(参数只留配对关心的字段)。
ObjectEntry _file(
  int handle, {
  required String name,
  int parent = 0x11,
  DateTime? captured,
  int format = 0x3801,
}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 1000,
      kind: ObjectKind.image,
      parentHandle: parent,
      capturedAt: captured,
      formatCode: format,
    );

void main() {
  // ── 规则 1:同文件夹同基名无条件并 ─────────────────────────────

  test('同夹同基名:时刻差 3 秒(连拍落盘漂移)也并组 —— 真机漏并回归', () {
    final groups = buildPhotoGroups([
      _file(0x23,
          name: 'DSC_0001.JPG', captured: DateTime.utc(2026, 10, 2, 9, 0, 3)),
      _file(0x22,
          name: 'DSC_0001.NEF',
          format: 0x3000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.typeLabel, 'jpg+raw');
    expect(groups.single.primary.name, 'DSC_0001.JPG'); // JPG 做代表
    expect(groups.single.key, 0x23); // 组键 = 成员最大句柄
  });

  test('同夹同基名:双份时刻全缺失也并组(DCF 基名唯一性兜底)', () {
    final groups = buildPhotoGroups([
      _file(0x23, name: 'DSC_0001.JPG'),
      _file(0x22, name: 'DSC_0001.NEF', format: 0x3000),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.typeLabel, 'jpg+raw');
  });

  test('同夹不同基名:两张独立照片不并', () {
    final groups = buildPhotoGroups([
      _file(0x13, name: 'DSC_0002.JPG', captured: DateTime.utc(2026, 9, 26)),
      _file(0x12,
          name: 'DSC_0001.NEF',
          format: 0x3000,
          captured: DateTime.utc(2026, 9, 27)),
    ]);

    expect(groups, hasLength(2));
  });

  // ── 规则 2:跨文件夹同基名,佐证通过才并 ───────────────────────

  test('跨夹同基名:时刻差 5 分钟(缓冲落盘)并组,横跨两夹', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827,
          name: 'DSC_0001.JPG',
          parent: 0x2000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
      _file(0x0A1A9827,
          name: 'DSC_0001.NEF',
          parent: 0x1000,
          format: 0x3000,
          captured: DateTime.utc(2026, 10, 2, 9, 5, 0)),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.typeLabel, 'jpg+raw');
    // 双槽分存:两夹相册各计入该组一次。
    expect(groups.single.folderHandles, {0x2000, 0x1000});
  });

  test('跨夹同基名:时刻差 9 个月(换卡重编号)不并', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827,
          name: 'DSC_0001.JPG',
          parent: 0x2000,
          captured: DateTime.utc(2026, 10, 1, 9, 0, 0)),
      _file(0x0A1A9827,
          name: 'DSC_0001.NEF',
          parent: 0x1000,
          format: 0x3000,
          captured: DateTime.utc(2026, 1, 1, 9, 0, 0)),
    ]);

    expect(groups, hasLength(2));
  });

  test('跨夹同基名:时刻齐全差 2 小时,低 24 位相等也不并(时间优先)', () {
    // 重编号后对象号回绕到同值,低位偶然相等 —— 时刻明确远离,不得并。
    final groups = buildPhotoGroups([
      _file(0x291A9827,
          name: 'DSC_0001.JPG',
          parent: 0x2000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
      _file(0x0A1A9827,
          name: 'DSC_0001.NEF',
          parent: 0x1000,
          format: 0x3000,
          captured: DateTime.utc(2026, 10, 2, 11, 0, 0)),
    ]);

    expect(groups, hasLength(2));
  });

  test('跨夹同基名:时刻缺失退回孪生句柄(低 24 位共享)并组', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827,
          name: 'DSC_0001.JPG',
          parent: 0x2000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
      _file(0x0A1A9827, name: 'DSC_0001.NEF', parent: 0x1000, format: 0x3000),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.typeLabel, 'jpg+raw');
  });

  test('跨夹同基名:时刻缺失且低位不同(两次独立快门)不并', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827, name: 'DSC_0001.JPG', parent: 0x2000),
      _file(0x0A1A0001, name: 'DSC_0001.NEF', parent: 0x1000, format: 0x3000),
    ]);

    expect(groups, hasLength(2));
  });

  test('链式三组:槽1/槽2/回绕第三夹经佐证归一(簇任一成员可佐证)', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827,
          name: 'DSC_0001.JPG',
          parent: 0x2000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 3)),
      _file(0x0A1A9827,
          name: 'DSC_0001.NEF',
          parent: 0x1000,
          format: 0x3000,
          captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
      _file(0x111A9827,
          name: 'DSC_0001.JPG',
          parent: 0x3000,
          captured: DateTime.utc(2026, 10, 2, 9, 5, 0)),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.members, hasLength(3));
    expect(groups.single.folderHandles, {0x2000, 0x1000, 0x3000});
  });

  // ── membersFor:下载格式选择过滤 ────────────────────────────────

  group('membersFor 按格式取下载文件', () {
    test('双格式组:仅 JPG/仅 RAW 各取其一,JPG+RAW 全量', () {
      final group = buildPhotoGroups([
        _file(0x23, name: 'DSC_0001.JPG'),
        _file(0x22, name: 'DSC_0001.NEF', format: 0x3000),
      ]).single;

      expect(group.membersFor(PhotoDownloadFormat.jpg).single.name,
          'DSC_0001.JPG');
      expect(group.membersFor(PhotoDownloadFormat.raw).single.name,
          'DSC_0001.NEF');
      expect(group.membersFor(PhotoDownloadFormat.both), hasLength(2));
      expect(group.membersFor(PhotoDownloadFormat.video), isEmpty,
          reason: '纯照片组选「仅视频」→ 空,调用方跳过');
    });

    test('纯 RAW 组:仅 JPG → 空(调用方跳过);仅 RAW/两者 → 全量', () {
      final group = buildPhotoGroups([
        _file(0x22, name: 'DSC_0001.NEF', format: 0x3000),
      ]).single;

      expect(group.membersFor(PhotoDownloadFormat.jpg), isEmpty);
      expect(group.membersFor(PhotoDownloadFormat.raw), hasLength(1));
      expect(group.membersFor(PhotoDownloadFormat.both), hasLength(1));
    });

    test('纯 JPG 组:仅 RAW → 空', () {
      final group =
          buildPhotoGroups([_file(0x23, name: 'DSC_0001.JPG')]).single;

      expect(group.membersFor(PhotoDownloadFormat.raw), isEmpty);
    });

    test('视频组不受格式选择影响:各选择都全量', () {
      final group = PhotoGroup([
        ObjectEntry(
          handle: 0x31,
          name: 'DSC_0001.MP4',
          sizeInBytes: 1000,
          kind: ObjectKind.video,
          parentHandle: 0x11,
          capturedAt: DateTime.utc(2026, 10, 2, 9, 0, 0),
          formatCode: 0x300D,
        ),
      ]);

      for (final format in PhotoDownloadFormat.values) {
        expect(group.membersFor(format), hasLength(1),
            reason: '${format.label} 应全量下载视频');
      }
    });

    test('双 JPG 备份副本:仅 JPG 只取一份,两者全量(备份也下)', () {
      final group = PhotoGroup([
        _file(0x23, name: 'DSC_0001.JPG'),
        _file(0x13, name: 'DSC_0001.JPG'),
      ]);

      expect(group.membersFor(PhotoDownloadFormat.jpg), hasLength(1));
      expect(group.membersFor(PhotoDownloadFormat.both), hasLength(2));
    });
  });

  group('连拍簇合并', () {
    test('同夹 4 连拍(间隔 100ms)并一簇:isBurst、×N 角标、键取最大句柄', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        for (var i = 0; i < 4; i++)
          _file(0x20 + i,
              name: 'DSC_000${i + 1}.JPG',
              captured: t0.add(Duration(milliseconds: 100 * i))),
      ]);

      expect(groups, hasLength(1));
      final burst = groups.single;
      expect(burst.isBurst, isTrue);
      expect(burst.shotCount, 4);
      expect(burst.typeLabel, 'jpg ×4');
      expect(burst.key, 0x23); // 最大句柄(渐进首到,键稳定)
      expect(burst.members, hasLength(4));
    });

    test('连拍簇含双格式组:8 文件一簇,仅 JPG/仅 RAW 每张各取一份', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        for (var i = 0; i < 3; i++) ...[
          _file(0x30 + i * 2,
              name: 'DSC_001$i.JPG',
              captured: t0.add(Duration(milliseconds: 120 * i))),
          _file(0x2F + i * 2,
              name: 'DSC_001$i.NEF',
              format: 0x3000,
              captured: t0.add(Duration(milliseconds: 120 * i))),
        ],
      ]);

      expect(groups, hasLength(1));
      final burst = groups.single;
      expect(burst.shotCount, 3);
      expect(burst.typeLabel, 'jpg+raw ×3');
      expect(burst.members, hasLength(6));
      expect(burst.membersFor(PhotoDownloadFormat.jpg), hasLength(3));
      expect(burst.membersFor(PhotoDownloadFormat.raw), hasLength(3));
      expect(burst.membersFor(PhotoDownloadFormat.both), hasLength(6));
    });

    test('两张连续(段长 < 3)不成簇,保持独立', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        _file(0x21, name: 'DSC_0001.JPG', captured: t0),
        _file(0x20,
            name: 'DSC_0002.JPG',
            captured: t0.add(const Duration(milliseconds: 200))),
      ]);

      expect(groups, hasLength(2));
      expect(groups.every((g) => !g.isBurst), isTrue);
    });

    test('间隔超窗断段:2+2 各不成簇', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        _file(0x23, name: 'DSC_0001.JPG', captured: t0),
        _file(0x22,
            name: 'DSC_0002.JPG',
            captured: t0.add(const Duration(milliseconds: 100))),
        // 2 秒间隔:连拍中断(缓冲清空/松开快门)。
        _file(0x21,
            name: 'DSC_0003.JPG', captured: t0.add(const Duration(seconds: 2))),
        _file(0x20,
            name: 'DSC_0004.JPG',
            captured: t0.add(const Duration(seconds: 2, milliseconds: 100))),
      ]);

      expect(groups, hasLength(4));
      expect(groups.every((g) => !g.isBurst), isTrue);
    });

    test('双槽镜像连拍:同基名跨夹先并,再入簇 —— 一簇 6 文件,每张一份下载', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        _file(0x23, name: 'DSC_0001.JPG', parent: 0x11, captured: t0),
        _file(0x22,
            name: 'DSC_0002.JPG',
            parent: 0x11,
            captured: t0.add(const Duration(milliseconds: 100))),
        _file(0x21,
            name: 'DSC_0003.JPG',
            parent: 0x11,
            captured: t0.add(const Duration(milliseconds: 200))),
        // 另一夹同时刻的镜像副本(双槽同格式备份)。
        _file(0x33, name: 'DSC_0001.JPG', parent: 0x20, captured: t0),
        _file(0x32,
            name: 'DSC_0002.JPG',
            parent: 0x20,
            captured: t0.add(const Duration(milliseconds: 100))),
        _file(0x31,
            name: 'DSC_0003.JPG',
            parent: 0x20,
            captured: t0.add(const Duration(milliseconds: 200))),
      ]);

      // 第二遍把跨夹同基名并成 3 个双副本组,第三遍按时刻聚成一簇。
      expect(groups, hasLength(1));
      final burst = groups.single;
      expect(burst.isBurst, isTrue);
      expect(burst.shotCount, 3); // 基名去重后 3 张
      expect(burst.members, hasLength(6)); // 每张两份备份副本
      // 下载按基名去重:每张一份,不重不漏。
      expect(burst.membersFor(PhotoDownloadFormat.jpg), hasLength(3));
      expect(burst.membersFor(PhotoDownloadFormat.both), hasLength(6));
    });

    test('无时刻条目不参与连拍并簇', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        _file(0x23, name: 'DSC_0001.JPG', captured: t0),
        _file(0x22,
            name: 'DSC_0002.JPG',
            captured: t0.add(const Duration(milliseconds: 100))),
        _file(0x21, name: 'DSC_0003.JPG'), // 无时刻
      ]);

      expect(groups, hasLength(3));
    });
  });

  // ── 实况照片对:同基名 JPG + MOV ────────────────────────────────

  group('实况照片对', () {
    ObjectEntry video(int handle, {required String name, int parent = 0x11}) =>
        ObjectEntry(
          handle: handle,
          name: name,
          sizeInBytes: 2000,
          kind: ObjectKind.video,
          parentHandle: parent,
          capturedAt: DateTime.utc(2026, 10, 2, 9, 0, 0),
          formatCode: 0x300D,
        );

    test('同夹同基名 JPG+MOV 并组:isMotionPair、jpg+mov 角标、代表是静帧', () {
      final groups = buildPhotoGroups([
        _file(0x23,
            name: 'DSC_0001.JPG', captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
        video(0x22, name: 'DSC_0001.MOV'),
      ]);

      expect(groups, hasLength(1));
      final pair = groups.single;
      expect(pair.isMotionPair, isTrue);
      expect(pair.typeLabel, 'jpg+mov');
      expect(pair.isVideo, isFalse); // 组是照片,代表走静帧
      expect(pair.primary.name, 'DSC_0001.JPG');
    });

    test('实况对下载:「仅 JPG」也带视频件(实况成分非另一张);仅 RAW 跳过整组;仅视频只取视频件', () {
      final pair = buildPhotoGroups([
        _file(0x23,
            name: 'DSC_0001.JPG', captured: DateTime.utc(2026, 10, 2, 9, 0, 0)),
        video(0x22, name: 'DSC_0001.MOV'),
      ]).single;

      expect(pair.membersFor(PhotoDownloadFormat.jpg).map((e) => e.name),
          ['DSC_0001.JPG', 'DSC_0001.MOV']);
      expect(pair.membersFor(PhotoDownloadFormat.raw), isEmpty);
      expect(pair.membersFor(PhotoDownloadFormat.both), hasLength(2));
      expect(pair.membersFor(PhotoDownloadFormat.video).map((e) => e.name),
          ['DSC_0001.MOV']);
    });

    test('双格式 + MOV 三件组:jpg+raw+mov 角标;仅 JPG 取 JPG+MOV 略过 NEF', () {
      final t = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        _file(0x24, name: 'DSC_0001.JPG', captured: t),
        _file(0x23, name: 'DSC_0001.NEF', format: 0x3000, captured: t),
        video(0x22, name: 'DSC_0001.MOV'),
      ]);

      expect(groups, hasLength(1));
      final group = groups.single;
      expect(group.typeLabel, 'jpg+raw+mov');
      expect(group.membersFor(PhotoDownloadFormat.jpg).map((e) => e.name),
          ['DSC_0001.JPG', 'DSC_0001.MOV']);
      expect(group.membersFor(PhotoDownloadFormat.both), hasLength(3));
      expect(group.membersFor(PhotoDownloadFormat.video).map((e) => e.name),
          ['DSC_0001.MOV']);
    });

    test('连拍簇含实况对:角标 jpg+mov ×N', () {
      final t0 = DateTime.utc(2026, 10, 2, 9, 0, 0);
      final groups = buildPhotoGroups([
        for (var i = 0; i < 3; i++) ...[
          _file(0x30 + i * 2,
              name: 'DSC_000$i.JPG',
              captured: t0.add(Duration(milliseconds: 100 * i))),
          video(0x2F + i * 2, name: 'DSC_000$i.MOV'),
        ],
      ]);

      expect(groups, hasLength(1));
      final burst = groups.single;
      expect(burst.isBurst, isTrue);
      expect(burst.shotCount, 3);
      expect(burst.typeLabel, 'jpg+mov ×3');
      // 下载:每张静帧 + 各自视频件
      expect(burst.membersFor(PhotoDownloadFormat.jpg), hasLength(6));
    });
  });
}

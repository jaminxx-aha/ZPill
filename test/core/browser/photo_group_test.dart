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
      _file(0x13,
          name: 'DSC_0002.JPG', captured: DateTime.utc(2026, 9, 26)),
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
      _file(0x0A1A9827,
          name: 'DSC_0001.NEF', parent: 0x1000, format: 0x3000),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.typeLabel, 'jpg+raw');
  });

  test('跨夹同基名:时刻缺失且低位不同(两次独立快门)不并', () {
    final groups = buildPhotoGroups([
      _file(0x291A9827, name: 'DSC_0001.JPG', parent: 0x2000),
      _file(0x0A1A0001,
          name: 'DSC_0001.NEF', parent: 0x1000, format: 0x3000),
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
      final group = buildPhotoGroups([_file(0x23, name: 'DSC_0001.JPG')]).single;

      expect(group.membersFor(PhotoDownloadFormat.raw), isEmpty);
    });

    test('视频不受格式选择影响:三种选择都全量', () {
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
}

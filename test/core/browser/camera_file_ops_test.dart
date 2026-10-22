import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/camera_file_ops.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';

import '../ptp/ptp_session_harness.dart' show FakePtpTransport;

ObjectEntry _file(int handle, String name,
        {int parent = 0x11, int format = 0x3801, required DateTime captured}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 1000,
      kind: ObjectKind.image,
      parentHandle: parent,
      capturedAt: captured,
      formatCode: format,
    );

/// 时刻拉开 5 分钟:同夹不同基名本就不并,时刻远离再上双保险
///(不触发连拍簇聚类,单测只关心删除编排)。
final DateTime _t1 = DateTime.utc(2026, 10, 2, 9, 0, 0);
final DateTime _t2 = DateTime.utc(2026, 10, 2, 9, 5, 0);

/// 记录删除句柄的伪仓库(只需 removeHandles)。
final class _RecordingRepo implements ObjectRepository {
  final List<int> removed = [];

  @override
  void removeHandles(Iterable<int> handles) => removed.addAll(handles);

  @override
  Future<List<CameraAlbum>> loadAlbums() async => throw UnimplementedError();

  @override
  Stream<AlbumsUpdate> get updates => const Stream.empty();

  @override
  Future<ObjectEntry> entryFor(int handle) async =>
      throw UnimplementedError();

  @override
  void reset() {}
}

PtpResult _ok() => const PtpResult(responseCode: PtpResponseCode.ok);

void main() {
  test('逐成员 DeleteObject:双格式组两份都删,成功句柄出仓库缓存', () async {
    final fake = FakePtpTransport()
      ..reply(_ok()) // 0x23 JPG
      ..reply(_ok()) // 0x22 NEF
      ..reply(_ok()); // 0x13 独立 JPG
    final session = PtpSession(transport: fake);
    final repo = _RecordingRepo();
    final ops = CameraFileOps(session: session, repository: repo);

    final groups = buildPhotoGroups([
      _file(0x23, 'DSC_0001.JPG', captured: _t1),
      _file(0x22, 'DSC_0001.NEF', format: 0x3000, captured: _t1),
      _file(0x13, 'DSC_0002.JPG', captured: _t2),
    ]);
    final result = await ops.deleteGroups(groups);

    expect(result.deleted, 3);
    expect(result.failed, 0);
    expect(result.allFailed, isFalse);
    expect(
      fake.requests.map((r) => r.opcode),
      everyElement(PtpOperationCode.deleteObject),
    );
    expect(fake.requests.map((r) => r.params.single), [0x23, 0x22, 0x13]);
    expect(repo.removed, [0x23, 0x22, 0x13]);
  });

  test('单文件失败只计数继续:整批不拖死,只有成功句柄出缓存', () async {
    final fake = FakePtpTransport()
      ..reply(_ok()) // 0x23 JPG ✓
      ..reply(const PtpResult(responseCode: 0x2009)) // 0x22 NEF 相机拒绝
      ..reply(_ok()); // 0x13 下一组继续 ✓
    final session = PtpSession(transport: fake);
    final repo = _RecordingRepo();
    final ops = CameraFileOps(session: session, repository: repo);

    final groups = buildPhotoGroups([
      _file(0x23, 'DSC_0001.JPG', captured: _t1),
      _file(0x22, 'DSC_0001.NEF', format: 0x3000, captured: _t1),
      _file(0x13, 'DSC_0002.JPG', captured: _t2),
    ]);
    final result = await ops.deleteGroups(groups);

    expect(result.deleted, 2);
    expect(result.failed, 1);
    expect(repo.removed, [0x23, 0x13]); // 部分失败的组:NEF 句柄留缓存
  });

  test('全部失败:failed 计数,缓存不动(allFailed 供 UI 提示)', () async {
    final fake = FakePtpTransport()
      ..reply(const PtpResult(responseCode: 0x2009));
    final session = PtpSession(transport: fake);
    final repo = _RecordingRepo();
    final ops = CameraFileOps(session: session, repository: repo);

    final result = await ops
        .deleteGroups(buildPhotoGroups([_file(0x13, 'DSC_0002.JPG', captured: _t1)]));

    expect(result.allFailed, isTrue);
    expect(repo.removed, isEmpty);
  });
}

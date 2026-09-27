import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

import '../ptp/ptp_session_test.dart' show FakePtpTransport;

/// 手搓 ObjectInfo 数据集(布局独立于被测代码,ISO 15740 §13.3 的
/// Zf 真机结构,同 object_info_test;浏览所需字段参数化)。
Uint8List _objectInfoDataset({
  required int format,
  required int parent,
  required int size,
  required String name,
  String? captured,
}) {
  final w = ByteWriter()
    ..u32(0x00010001) // StorageID
    ..u16(format) // ObjectFormat
    ..u16(0) // ProtectionStatus
    ..u32(size) // CompressedSize
    ..u16(0x3808) // ThumbFormat
    ..u32(50000)
    ..u32(640)
    ..u32(424)
    ..u32(3968)
    ..u32(2624)
    ..u32(24)
    ..u32(parent) // ParentObject
    ..u16(0) // AssociationType
    ..u32(0) // AssociationDesc
    ..u32(0); // SequenceNumber
  w
    ..u8(name.length + 1)
    ..utf16le(name)
    ..u16(0); // filename(Zf 真机带结尾 NUL)
  if (captured != null) {
    w
      ..u8(15)
      ..utf16le(captured);
  } else {
    w.u8(0);
  }
  return w.takeBytes();
}

/// GetObjectHandles 数据集:u32 计数 + N 个 u32。
Uint8List _handlesDataset(List<int> handles) {
  final w = ByteWriter()..u32(handles.length);
  for (final h in handles) {
    w.u32(h);
  }
  return w.takeBytes();
}

PtpResult _okData(Uint8List dataset) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: dataset);

/// 句柄树:根(0)→ DCIM(0x10)→ 100NIKON(0x11)→ NEF(0x12)/JPG(0x13)。
/// NEF 格式码 0x3000(真机实测),靠 .nef 扩展名兜底分类。
void _replyTree(FakePtpTransport fake) {
  fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3001, parent: 0, size: 0, name: 'DCIM')));
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3001, parent: 0x10, size: 0, name: '100NIKON')));
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3000, parent: 0x11, size: 26843545,
      name: 'DSC_0001.NEF', captured: '20260927T101520')));
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3801, parent: 0x11, size: 8400000,
      name: 'DSC_0002.JPG', captured: '20260926T090000')));
}

void main() {
  test('全量枚举:GetObjectHandles 传 Zf 语义参数(parent=0 全量)', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    await repo.listFolder(parentHandle: 0);

    final req = fake.requests.first;
    expect(req.opcode, PtpOperationCode.getObjectHandles);
    expect(
      req.params,
      [
        GetObjectHandlesParams.storageAll,
        GetObjectHandlesParams.formatAll,
        GetObjectHandlesParams.parentRoot,
      ],
    );
    // 随后逐个 GetObjectInfo。
    expect(fake.requests.where((r) => r.opcode == PtpOperationCode.getObjectInfo),
        hasLength(4));
  });

  test('listFolder 按 parent 过滤;文件夹在前、照片时间倒序;NEF 扩展名兜底', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    final root = await repo.listFolder(parentHandle: 0);
    expect(root.map((e) => e.name), ['DCIM']);
    expect(root.single.isFolder, isTrue);

    final dcim = await repo.listFolder(parentHandle: 0x10);
    expect(dcim.map((e) => e.name), ['100NIKON']);

    final photos = await repo.listFolder(parentHandle: 0x11);
    // 时间倒序:9-27 的 NEF 在 9-26 的 JPG 前。
    expect(photos.map((e) => e.name), ['DSC_0001.NEF', 'DSC_0002.JPG']);
    // NEF 格式码 0x3000 → kind 由 .nef 扩展名兜底为 image。
    expect(photos.first.kind, ObjectKind.image);
    expect(photos.first.sizeInBytes, 26843545);
    expect(photos.first.capturedAt, DateTime.utc(2026, 9, 27, 10, 15, 20));

    // 不存在的 parent:空列表(而非异常)。
    expect(await repo.listFolder(parentHandle: 0xDEAD), isEmpty);
  });

  test('entryFor 查缓存;未枚举到的句柄显式报错', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    await repo.listFolder(parentHandle: 0);
    final entry = await repo.entryFor(0x12);
    expect(entry.name, 'DSC_0001.NEF');
    expect(() => repo.entryFor(0xDEAD), throwsStateError);
  });

  test('reset() 丢弃缓存,下次 listFolder 重新全量枚举', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);
    await repo.listFolder(parentHandle: 0);
    expect(repo.isLoaded, isTrue);

    repo.reset();
    expect(repo.isLoaded, isFalse);

    _replyTree(fake); // 重连后相机重新应答一轮
    final root = await repo.listFolder(parentHandle: 0);
    expect(root.single.name, 'DCIM');
    expect(fake.requests, hasLength(10)); // 两轮各 5 次往返
  });
}

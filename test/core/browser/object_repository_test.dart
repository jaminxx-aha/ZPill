import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
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

    await repo.loadAlbums();

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

  test('loadAlbums:汇总相册在前,文件夹相册按 parent 分组、时间倒序', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    final albums = await repo.loadAlbums();

    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
    final all = albums[0];
    expect(all.isAggregate, isTrue);
    expect(all.folderHandle, CameraAlbum.allPhotosHandle);
    // 汇总含全部 image/video,新的在前(NEF 9-27 先于 JPG 9-26)。
    expect(all.items.map((e) => e.name), ['DSC_0001.NEF', 'DSC_0002.JPG']);
    expect(all.cover!.name, 'DSC_0001.NEF');

    final folder = albums[1];
    expect(folder.folderHandle, 0x11);
    expect(folder.items.map((e) => e.name), ['DSC_0001.NEF', 'DSC_0002.JPG']);
    // NEF 格式码 0x3000 → kind 由 .nef 扩展名兜底为 image;
    // parentHandle 落到 entry(相册分组依据)。
    final nef = folder.items.first;
    expect(nef.kind, ObjectKind.image);
    expect(nef.sizeInBytes, 26843545);
    expect(nef.parentHandle, 0x11);
    expect(nef.capturedAt, DateTime.utc(2026, 9, 27, 10, 15, 20));
  });

  test('loadAlbums:无照片内容的文件夹(MISC)不成为相册', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    fake.reply(_okData(
        _handlesDataset([0x10, 0x11, 0x12, 0x20, 0x21, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 1000, name: 'DSC_0003.JPG')));
    // MISC 文件夹 + 其下的杂项文件(.DSC 订单文件 → other):不该成为相册。
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'MISC')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x20, size: 10, name: 'NIKON001.DSC')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3008, parent: 0x11, size: 2000, name: 'DSC_0004.MOV',
        captured: '20260928T120000')));

    final albums = await repo.loadAlbums();

    // 汇总:JPG + MOV(时间倒序,MOV 9-28 在前);MISC 的 .DSC 不是相册内容。
    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
    expect(albums[0].items.map((e) => e.name),
        ['DSC_0004.MOV', 'DSC_0003.JPG']);
    // MOV 扩展名兜底为 video。
    expect(albums[0].items.first.kind, ObjectKind.video);
  });

  test('loadAlbums:onProgress 逐对象回调进度', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    final progress = <String>[];
    await repo.loadAlbums(onProgress: (loaded, total) {
      progress.add('$loaded/$total');
    });
    expect(progress, ['1/4', '2/4', '3/4', '4/4']);
  });

  test('并发 loadAlbums 共享同一次枚举(不重复往返)', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    final results =
        await Future.wait([repo.loadAlbums(), repo.loadAlbums()]);
    expect(results[0].map((a) => a.name), results[1].map((a) => a.name));
    expect(fake.requests, hasLength(5)); // 1×GetObjectHandles + 4×GetObjectInfo
  });

  test('entryFor 查缓存;未枚举到的句柄显式报错', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);

    await repo.loadAlbums();
    final entry = await repo.entryFor(0x12);
    expect(entry.name, 'DSC_0001.NEF');
    expect(() => repo.entryFor(0xDEAD), throwsStateError);
  });

  test('reset() 丢弃缓存,下次 loadAlbums 重新全量枚举', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);
    await repo.loadAlbums();
    expect(repo.isLoaded, isTrue);

    repo.reset();
    expect(repo.isLoaded, isFalse);

    _replyTree(fake); // 重连后相机重新应答一轮
    final albums = await repo.loadAlbums();
    expect(albums.first.name, '全部照片');
    expect(fake.requests, hasLength(10)); // 两轮各 5 次往返
  });

  test('枚举途中 reset:世代不符的结果被丢弃,不误标已加载', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // ObjectHandles + 第一个 ObjectInfo 正常;第二个 ObjectInfo 挂在门上,
    // 让「枚举途中」的时序可控(同步假传输层会一口气跑完,停不下来)。
    final stall = Completer<void>();
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM')));
    fake.replyAfter(stall.future, _okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 1, name: 'DSC_0001.NEF')));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 1, name: 'DSC_0002.JPG')));

    final loading = repo.loadAlbums();
    await pumpEventQueue();
    repo.reset(); // 枚举挂在门上时断连
    stall.complete(); // 相机侧继续应答,枚举跑完
    await loading;
    expect(repo.isLoaded, isFalse); // 关键:过期枚举不得把缓存标成已加载

    // 重新来一轮正常枚举可用。
    _replyTree(fake);
    final albums = await repo.loadAlbums();
    expect(albums.first.items, isNotEmpty);
  });
}

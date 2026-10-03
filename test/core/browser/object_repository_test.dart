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
  String? modified,
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
  // captureDate / modificationDate:与真机一致三串齐全;null 写空串。
  w.u8(captured == null ? 0 : 15);
  if (captured != null) w.utf16le(captured);
  w.u8(modified == null ? 0 : 15);
  if (modified != null) w.utf16le(modified);
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

/// 相机明确拒答(仓库侧按单对象失败容错跳过的路径)。
const PtpResult _refused =
    PtpResult(responseCode: PtpResponseCode.generalError);

/// 句柄树:根(0)→ DCIM(0x10)→ 100NIKON(0x11)→ NEF(0x12)/JPG(0x13)。
/// NEF 格式码 0x3000(真机实测),靠 .nef 扩展名兜底分类。
///
/// 应答按**请求顺序**排:仓库句柄倒序请求(最新优先),0x13 最先问。
void _replyTree(FakePtpTransport fake) {
  fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3801, parent: 0x11, size: 8400000,
      name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x13
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3000, parent: 0x11, size: 26843545,
      name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
  fake.reply(_okData(_objectInfoDataset(
      format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10
}

int _infoCount(FakePtpTransport fake) =>
    fake.requests
        .where((r) => r.opcode == PtpOperationCode.getObjectInfo)
        .length;

void main() {
  test('全量枚举:GetObjectHandles 传 Zf 语义参数,句柄倒序请求(最新优先)',
      () async {
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
    // 逐个 GetObjectInfo,且请求序 = 句柄倒序(渐进加载最新优先的落点)。
    final infoReqs = fake.requests
        .where((r) => r.opcode == PtpOperationCode.getObjectInfo)
        .toList();
    expect(infoReqs.map((r) => r.params.single), [0x13, 0x12, 0x11, 0x10]);
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
    final nef = folder.items.first.primary;
    expect(nef.kind, ObjectKind.image);
    expect(nef.sizeInBytes, 26843545);
    expect(nef.parentHandle, 0x11);
    expect(nef.capturedAt, DateTime.utc(2026, 9, 27, 10, 15, 20));
    // 基名不同(0001/0002)不合并:两张独立照片,角标各表其类。
    expect(folder.items.first.typeLabel, 'raw');
    expect(folder.items.last.typeLabel, 'jpg');
  });

  test('loadAlbums:无照片内容的文件夹(MISC)不成为相册', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // 应答按倒序请求序:0x22 → 0x10。
    fake.reply(
        _okData(_handlesDataset([0x10, 0x11, 0x12, 0x20, 0x21, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3008, parent: 0x11, size: 2000, name: 'DSC_0004.MOV',
        captured: '20260928T120000'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x20, size: 10, name: 'NIKON001.DSC'))); // 0x21
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'MISC'))); // 0x20
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 1000, name: 'DSC_0003.JPG'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10

    final albums = await repo.loadAlbums();

    // 汇总:JPG + MOV(时间倒序,MOV 9-28 在前);MISC 的 .DSC 不是相册内容。
    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
    expect(albums[0].items.map((e) => e.name),
        ['DSC_0004.MOV', 'DSC_0003.JPG']);
    // MOV 扩展名兜底为 video。
    expect(albums[0].items.first.isVideo, isTrue);
  });

  test('渐进发布:每块合并并广播;文件夹对象未到前文件夹相册不亮相', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(
        session: PtpSession(transport: fake), chunkSize: 2);
    _replyTree(fake);
    final updates = <AlbumsUpdate>[];
    repo.updates.listen(updates.add);

    await repo.loadAlbums();

    // 块序:请求 0x13+0x12(照片)→ 0x11+0x10(文件夹);每块一广播 +
    // 末尾一次完成事件。
    expect(updates.map((u) => (u.loaded, u.total, u.complete)), [
      (2, 4, false),
      (4, 4, false),
      (4, 4, true),
    ]);
    // 块 1:只有文件夹对象的照片先到 —— 文件夹相册暂不亮相(不闪
    // 「文件夹 0x11」占位名),但汇总相册已可用。
    expect(updates[0].albums.map((a) => a.name), ['全部照片']);
    expect(updates[0].albums.single.items, hasLength(2));
    // 块 2:文件夹对象 0x11 到达,具名相册亮相。
    expect(updates[1].albums.map((a) => a.name), ['全部照片', '100NIKON']);
    // 完成事件与 loadAlbums 返回值一致。
    expect(updates.last.albums.map((a) => a.name), ['全部照片', '100NIKON']);
  });

  test('并发 loadAlbums 共享同一次枚举;两个订阅者都收到全部块', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    _replyTree(fake);
    final sub1 = <AlbumsUpdate>[];
    final sub2 = <AlbumsUpdate>[];
    repo.updates.listen(sub1.add);
    repo.updates.listen(sub2.add);

    final results =
        await Future.wait([repo.loadAlbums(), repo.loadAlbums()]);
    expect(results[0].map((a) => a.name), results[1].map((a) => a.name));
    expect(fake.requests, hasLength(5)); // 1×GetObjectHandles + 4×GetObjectInfo
    // 去重不吞事件:非发起方的订阅者也能收到全部广播。
    expect(sub1, hasLength(2)); // 默认 chunkSize=24:单块 + 完成事件
    expect(sub2.map((u) => u.complete), [false, true]);
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

  test('枚举途中 reset:世代废弃提前停,不再发请求、不发布完成事件', () async {
    final fake = FakePtpTransport();
    final repo =
        ObjectRepositoryImpl(session: PtpSession(transport: fake), chunkSize: 2);
    // 块 1(0x13/0x12)正常完成并广播;块 2 的 0x11 挂在门上 —— 门后
    // reset 已发生,世代检查让枚举即刻返回,0x10 不会被请求。
    final stall = Completer<void>();
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x13
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.replyAfter(stall.future, _okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    final updates = <AlbumsUpdate>[];
    final sub = repo.updates.listen(updates.add);

    final loading = repo.loadAlbums();
    await pumpEventQueue(); // 块 1 完成;块 2 的 0x11 请求已发出、挂在门上
    expect(updates.map((u) => u.loaded), [2]);
    repo.reset(); // 门上时断连
    stall.complete(); // 相机侧放行,但世代已废
    await loading;
    expect(repo.isLoaded, isFalse); // 过期枚举不得把缓存标成已加载
    expect(_infoCount(fake), 3); // 0x13/0x12/0x11;0x10 不再被请求(世代检查)
    expect(updates.where((u) => u.complete), isEmpty); // 无完成事件
    await sub.cancel();

    // 重新来一轮正常枚举可用。
    _replyTree(fake);
    final albums = await repo.loadAlbums();
    expect(albums.first.items, isNotEmpty);
    expect(fake.requests, hasLength(9)); // 4(轮 1)+ 5(轮 2)
  });

  test('中途失败:部分缓存保留,重试只补缺失对象(断点续传)', () async {
    final fake = FakePtpTransport();
    final repo =
        ObjectRepositoryImpl(session: PtpSession(transport: fake), chunkSize: 2);
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x13
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.fail(TimeoutException('USB 链路已中断,等待重接')); // 0x11 挂死

    await expectLater(
        repo.loadAlbums(), throwsA(isA<TimeoutException>()));
    expect(repo.isLoaded, isFalse);

    // 续传:句柄重枚举 + 只补 0x11/0x10(0x13/0x12 已在缓存)。
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10
    final albums = await repo.loadAlbums();

    expect(albums.first.items, hasLength(2));
    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
    // 请求序:0x13/0x12 成功入缓存(续传不重问);0x11 失败后重问,0x10 补拉。
    expect(
      fake.requests
          .where((r) => r.opcode == PtpOperationCode.getObjectInfo)
          .map((r) => r.params.single),
      [0x13, 0x12, 0x11, 0x11, 0x10],
    );
  });

  test('相机拒答单个对象:跳过继续,枚举仍完成', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x13 ✓
    fake.reply(_refused); // 0x12:相机拒答(如同刻被删)→ 跳过
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10

    final albums = await repo.loadAlbums();

    expect(repo.isLoaded, isTrue);
    expect(albums[0].items.map((e) => e.name), ['DSC_0002.JPG']); // NEF 被跳过
    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
  });

  test('相机连续拒答 3 个对象:视为会话级问题,上抛终止', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_refused); // 0x13
    fake.reply(_refused); // 0x12
    fake.reply(_refused); // 0x11 → 连续第 3 个,上抛

    await expectLater(
        repo.loadAlbums(), throwsA(isA<PtpResponseException>()));
    expect(repo.isLoaded, isFalse);
    expect(_infoCount(fake), 3); // 0x10 不再被请求(防空转)
  });

  test('空相机:仍广播一次完成事件', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    fake.reply(_okData(_handlesDataset([])));
    final updates = <AlbumsUpdate>[];
    repo.updates.listen(updates.add);

    final albums = await repo.loadAlbums();

    expect(albums, hasLength(1)); // 仅空的汇总相册
    expect(albums.single.items, isEmpty);
    expect(updates.map((u) => (u.loaded, u.total, u.complete)),
        [(0, 0, true)]);
  });

  // ── RAW+JPG 合并 ──────────────────────────────────────────────

  test('RAW+JPG 合并:同基名同时刻归一组,角标 jpg+raw,代表文件取 JPG', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // 句柄升序 [夹, NEF, JPG, 独立JPG];倒序请求:0x24 → 0x23 → 0x11 → 0x10。
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x22, 0x23, 0x24])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 2000000,
        name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x24
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20260927T101520'))); // 0x23
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10

    final albums = await repo.loadAlbums();

    // 汇总:2 项(合并后),新的在前;组代表文件 = JPG。
    final all = albums[0];
    expect(all.items, hasLength(2));
    expect(all.items.map((g) => g.name), ['DSC_0001.JPG', 'DSC_0002.JPG']);

    final pair = all.items.first;
    expect(pair.typeLabel, 'jpg+raw');
    expect(pair.hasJpg, isTrue);
    expect(pair.hasRaw, isTrue);
    expect(pair.primary.name, 'DSC_0001.JPG'); // JPG 优先做缩略图/代表
    expect(pair.totalBytes, 8400000 + 26843545); // 下载 = 两份合计
    expect(pair.members.map((e) => e.name),
        unorderedEquals(['DSC_0001.NEF', 'DSC_0001.JPG']));
    // 组键稳定取成员最大句柄(渐进配对前后不漂移的落点)。
    expect(pair.key, 0x23);
    // 独立 JPG:单文件组,角标 jpg。
    expect(all.items.last.typeLabel, 'jpg');
    expect(all.items.last.members, hasLength(1));

    // 文件夹相册同样合并,张数 = 快门数而非文件数。
    final folder = albums[1];
    expect(folder.items, hasLength(2));
    expect(folder.items.first.typeLabel, 'jpg+raw');
  });

  test('跨卡槽 RAW/JPG 分存:不同文件夹同基名同时刻也合并,两夹各现一次', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // slot1 夹 0x10 放 NEF,slot2 夹 0x20 放 JPG,同快门同基名。
    fake.reply(_okData(_handlesDataset([0x10, 0x12, 0x20, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x20, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20260927T101520'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT2'))); // 0x20
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x10, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT1'))); // 0x10

    final albums = await repo.loadAlbums();

    // 汇总:跨夹合并为一项。
    final all = albums[0];
    expect(all.items, hasLength(1));
    expect(all.items.single.typeLabel, 'jpg+raw');
    // 两个文件夹相册各计入该组一次(组横跨两夹);两夹最新时间同
    //(同一组),排序回退按名:SLOT1 在前。
    expect(albums.map((a) => a.name), ['全部照片', 'SLOT1', 'SLOT2']);
    expect(albums[1].items.single.typeLabel, 'jpg+raw');
    expect(albums[2].items.single.typeLabel, 'jpg+raw');
  });

  test('同名不同时刻不合并:时间闸防跨天重编号误并', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // 两张独立照片:同基名(跨夹)、拍摄时刻差一年 —— 不得配对。
    fake.reply(_okData(_handlesDataset([0x10, 0x12, 0x20, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x20, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20261001T090000'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT2'))); // 0x20
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x10, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20250101T090000'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT1'))); // 0x10

    final albums = await repo.loadAlbums();

    expect(albums[0].items, hasLength(2)); // 各自独立,不合并
    expect(albums[0].items.map((g) => g.typeLabel), ['jpg', 'raw']);
  });

  test('渐进配对:RAW 后到并入,组键不漂移,角标升级为 jpg+raw', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(
        session: PtpSession(transport: fake), chunkSize: 2);
    // 句柄升序 [SLOT1夹, NEF, SLOT2夹, JPG];倒序块 1 = [0x22(JPG), 0x20(夹)],
    // 块 2 = [0x12(NEF), 0x10(夹)] —— 配对的两份拆在两块。
    fake.reply(_okData(_handlesDataset([0x10, 0x12, 0x20, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x20, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20260927T101520'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT2'))); // 0x20
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x10, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'SLOT1'))); // 0x10
    final updates = <AlbumsUpdate>[];
    repo.updates.listen(updates.add);

    await repo.loadAlbums();

    // 块 1(仅 JPG 到):单项、角标 jpg、键 = 最大句柄 0x22。
    final early = updates[0].albums[0].items;
    expect(early, hasLength(1));
    expect(early.single.typeLabel, 'jpg');
    expect(early.single.key, 0x22);
    // 块 2(NEF 到):并入同组 —— 仍单项、键不变、角标升级。
    final merged = updates[1].albums[0].items;
    expect(merged, hasLength(1));
    expect(merged.single.key, 0x22);
    expect(merged.single.typeLabel, 'jpg+raw');
    expect(merged.single.members, hasLength(2));
  });

  test('真机回归:同文件夹同基名、拍摄时刻差 3 秒(连拍落盘漂移)也合并', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // 同夹 0x11:JPG 落盘晚 3 秒(CaptureDate 各记各的提交时刻)。
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x22, 0x23])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20261002T090003'))); // 0x23
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20261002T090000'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10

    final albums = await repo.loadAlbums();

    expect(albums[0].items, hasLength(1));
    expect(albums[0].items.single.typeLabel, 'jpg+raw');
    expect(albums[0].items.single.totalBytes, 8400000 + 26843545);
    expect(albums[1].items.single.typeLabel, 'jpg+raw'); // 文件夹相册同并
  });

  test('CaptureDate 缺失:回落 ModificationDate 补齐拍摄时刻', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // NEF 的 captureDate 空串、modificationDate 在 —— 时刻不得丢(排序/
    // 跨夹佐证都靠它)。
    fake.reply(_okData(_handlesDataset([0x10, 0x11, 0x12, 0x13])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x11, size: 8400000,
        name: 'DSC_0002.JPG', captured: '20260926T090000'))); // 0x13
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x11, size: 26843545,
        name: 'DSC_0001.NEF', modified: '20260927T101520'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0x10, size: 0, name: '100NIKON'))); // 0x11
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: 'DCIM'))); // 0x10

    final albums = await repo.loadAlbums();

    final nef = albums[0].items.first.primary;
    expect(nef.capturedAt, DateTime.utc(2026, 9, 27, 10, 15, 20));
    // 时刻可用的下游:汇总按时间倒序排(NEF 9-27 新于 JPG 9-26)。
    expect(albums[0].items.map((g) => g.name), ['DSC_0001.NEF', 'DSC_0002.JPG']);
  });

  test('双槽同名文件夹:并成一个相册瓦片,内容为并集(不再两份)', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(session: PtpSession(transport: fake));
    // 两槽各有一个「100NIKON」(不同句柄),同一快门的 JPG/NEF 分存两夹
    //(真机双槽镜像/分存的实际形态)。
    fake.reply(_okData(_handlesDataset([0x10, 0x12, 0x20, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x20, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20260927T101520'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: '100NIKON'))); // 0x20 槽2
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x10, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: '100NIKON'))); // 0x10 槽1

    final albums = await repo.loadAlbums();

    // 一个 100NIKON 相册(同名瓦片不再重复),组只出现一次。
    expect(albums.map((a) => a.name), ['全部照片', '100NIKON']);
    expect(albums[1].items, hasLength(1));
    expect(albums[1].items.single.typeLabel, 'jpg+raw');
    expect(albums[1].items.single.folderHandles, {0x10, 0x20});
    // 句柄取最小,确定性(渐进发布间稳定)。
    expect(albums[1].folderHandle, 0x10);
  });

  test('双槽同名文件夹渐进发布:夹对象先后到达也只亮相一个同名相册', () async {
    final fake = FakePtpTransport();
    final repo = ObjectRepositoryImpl(
        session: PtpSession(transport: fake), chunkSize: 3);
    // 倒序块 1 = [0x22(JPG), 0x20(槽2夹), 0x12(NEF)],块 2 = [0x10(槽1夹)]:
    // 槽 2 的夹对象先到(相册以 0x20 亮相),槽 1 的夹对象后到 → 并名。
    fake.reply(_okData(_handlesDataset([0x10, 0x12, 0x20, 0x22])));
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3801, parent: 0x20, size: 8400000,
        name: 'DSC_0001.JPG', captured: '20260927T101520'))); // 0x22
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: '100NIKON'))); // 0x20
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3000, parent: 0x10, size: 26843545,
        name: 'DSC_0001.NEF', captured: '20260927T101520'))); // 0x12
    fake.reply(_okData(_objectInfoDataset(
        format: 0x3001, parent: 0, size: 0, name: '100NIKON'))); // 0x10
    final updates = <AlbumsUpdate>[];
    repo.updates.listen(updates.add);

    await repo.loadAlbums();

    // 块 1:槽 1 夹对象未到 —— 但组横跨两夹,槽 2 的 100NIKON 已含全组,
    //亮相的始终只有一个 100NIKON。
    expect(updates[0].albums.map((a) => a.name), ['全部照片', '100NIKON']);
    expect(updates[0].albums[1].items.single.typeLabel, 'jpg+raw');
    // 块 2(槽 1 夹到):同名并合,句柄取最小 0x10;仍只有一个。
    expect(updates[1].albums.map((a) => a.name), ['全部照片', '100NIKON']);
    expect(updates[1].albums[1].folderHandle, 0x10);
    expect(updates[1].albums[1].items.single.typeLabel, 'jpg+raw');
  });
}

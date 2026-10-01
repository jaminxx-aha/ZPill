import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

import '../ptp/ptp_session_test.dart'
    show FakePtpTransport, buildDeviceInfoDataset;

/// 假相册服务:目录落在临时目录(每个用例独立,互不污染)。
final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver()
      : root = Directory.systemTemp.createTempSync('nikonpill_test_gallery');

  final Directory root;

  @override
  Future<String> tempDir() async => _ensure('${root.path}/temp');

  @override
  Future<String> thumbsDir() async => _ensure('${root.path}/thumbs');

  @override
  Future<String> previewsDir() async => _ensure('${root.path}/previews');

  @override
  Future<String> downloadsDir() async => _ensure('${root.path}/downloads');

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async =>
      throw UnimplementedError();

  static Future<String> _ensure(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return path;
  }
}

final Uint8List _jpeg =
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46]);

PtpResult _okData(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

ObjectEntry _entry(int handle,
        {String name = 'DSC_0001.JPG', int size = 100}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: size,
      kind: ObjectKind.image,
      parentHandle: 0x11,
    );

void main() {
  test('未命中拉取落盘;命中后不再发请求', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final path = await cache.pathFor(entry, ThumbSource.grid);
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(fake.requests.map((r) => r.opcode), [PtpOperationCode.getThumb]);

    final again = await cache.pathFor(entry, ThumbSource.grid);
    expect(again, path);
    expect(fake.requests.length, 1); // 命中:无新请求
  });

  test('同键并发请求合并为一次拉取', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final paths = await Future.wait([
      cache.pathFor(entry, ThumbSource.grid),
      cache.pathFor(entry, ThumbSource.grid),
    ]);
    expect(paths[0], paths[1]);
    expect(fake.requests.length, 1);
  });

  test('内容键跨实例稳定:新实例直接命中磁盘,不进相机', () async {
    final gallery = FakeGallerySaver();
    final fake1 = FakePtpTransport()..reply(_okData(_jpeg));
    final entry = _entry(0x12);
    await ThumbnailCache(session: PtpSession(transport: fake1), gallery: gallery)
        .pathFor(entry, ThumbSource.grid);

    // 新实例(内存索引为空)→ 磁盘命中,零请求。
    final fake2 = FakePtpTransport();
    final path = await ThumbnailCache(session: PtpSession(transport: fake2), gallery: gallery)
        .pathFor(entry, ThumbSource.grid);
    expect(fake2.requests, isEmpty);
    expect(File(path).existsSync(), isTrue);
  });

  test('reset 只清内存索引:磁盘内容键仍然命中', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);
    final path = await cache.pathFor(entry, ThumbSource.grid);

    cache.reset();
    final again = await cache.pathFor(entry, ThumbSource.grid);
    expect(again, path);
    expect(fake.requests.length, 1);
  });

  test('LRU:超出上限按最久未访问驱逐删盘', () async {
    final gallery = FakeGallerySaver();
    final fake = FakePtpTransport();
    final bytes = Uint8List.fromList(List.generate(60, (i) => i));
    // 每张 60B,上限 130B(恰好装两张):第 3 张进来时最久未访问的
    // 第 1 张被驱逐,两张留存。
    final cache = ThumbnailCache(
      session: PtpSession(transport: fake),
      gallery: gallery,
      gridLimitBytes: 130,
    );
    Future<String> fetch(String name) {
      fake.reply(_okData(bytes));
      return cache.pathFor(
          _entry(0x12, name: name, size: 60), ThumbSource.grid);
    }

    final p1 = await fetch('A.JPG');
    final p2 = await fetch('B.JPG');
    final p3 = await fetch('C.JPG');
    expect(File(p1).existsSync(), isFalse); // A(最久未访问)被驱逐
    expect(File(p2).existsSync(), isTrue);
    expect(File(p3).existsSync(), isTrue);

    // 重新访问 A(磁盘已删)→ 重新拉取,A 回到最新端,B 成为最旧被驱逐。
    fake.reply(_okData(bytes));
    final p1again = await cache.pathFor(
        _entry(0x12, name: 'A.JPG', size: 60), ThumbSource.grid);
    expect(p1again, p1);
    expect(File(p1).existsSync(), isTrue);
    expect(File(p2).existsSync(), isFalse);
  });

  test('preview:相机不支持 0x90C4 时回落 GetThumb', () async {
    final fake = FakePtpTransport()
      // getLargeThumb 的能力检查(GetDeviceInfo,buildDeviceInfoDataset 不含 0x90C4)
      ..reply(_okData(buildDeviceInfoDataset()))
      // 回落的 getThumb
      ..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.preview);
    expect(File(path).existsSync(), isTrue);
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, PtpOperationCode.getThumb]);
  });

  test('preview:0x90C4 在册则直接走大图预览', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(buildDeviceInfoDataset(
          operations: [0x1001, NikonOperationCode.getLargeThumb])))
      ..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.preview);
    expect(File(path).existsSync(), isTrue);
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, NikonOperationCode.getLargeThumb]);
  });
}

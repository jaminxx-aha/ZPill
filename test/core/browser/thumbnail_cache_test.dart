import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/thumbnail_cache.dart';
import 'package:nikon_pill/core/media/jpeg_orientation.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';
import 'package:nikon_pill/platform/raw_decoder.dart';

import '../ptp/ptp_session_harness.dart' show FakePtpTransport;

/// 假相册服务:目录落在临时目录(每个用例独立,互不污染)。
final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver()
      : root = Directory.systemTemp.createTempSync('nikonpill_test_gallery');

  final Directory root;

  @override
  Future<String> dataDir() async => _ensure('${root.path}/data');

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

/// 裸 JPEG(SOI + APP0 JFIF,无 EXIF)—— 相机缩略的原型形状。
final Uint8List _jpeg = Uint8List.fromList(
    [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46]);

/// 手搓 TIFF 头(II*\0,IFD0@8,单 Orientation 条目)—— NEF 文件头形状。
/// 与实现互为独立来源(不调被测代码拼)。
Uint8List _tiffHead(int orientation) {
  final tiff = ByteData(8 + 2 + 12 + 4);
  tiff.setUint8(0, 0x49);
  tiff.setUint8(1, 0x49);
  tiff.setUint16(2, 0x2A, Endian.little);
  tiff.setUint32(4, 8, Endian.little); // IFD0 偏移
  tiff.setUint16(8, 1, Endian.little); // 条目数
  tiff.setUint16(10, 0x0112, Endian.little); // Orientation
  tiff.setUint16(12, 3, Endian.little); // SHORT
  tiff.setUint32(14, 1, Endian.little); // count 1
  tiff.setUint16(18, orientation, Endian.little); // 值内联
  return tiff.buffer.asUint8List();
}

/// 手搓 JPG 文件头(SOI + APP1 Exif + EOI)—— 原文件头读的回包形状。
Uint8List _jpgHead(int orientation) {
  final tiff = _tiffHead(orientation);
  final payload = [...'Exif'.codeUnits, 0, 0, ...tiff];
  final segLen = 2 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...payload, //
    0xFF, 0xD9,
  ]);
}

/// 手搓带 Make/Model 的 JPG 头(exifCardOf 用):SOI + APP1 Exif(IFD0
/// 两条内联字符串条目)+ EOI。字段全的载荷解析见 watermark_test,这里
/// 只验证「头读 → 出卡 → 记忆」的协议行为。
Uint8List _jpgExifHead() {
  final tiff = ByteData(38);
  void u16(int off, int v) => tiff.setUint16(off, v, Endian.little);
  void u32(int off, int v) => tiff.setUint32(off, v, Endian.little);
  tiff.setUint8(0, 0x49);
  tiff.setUint8(1, 0x49);
  u16(2, 42);
  u32(4, 8);
  u16(8, 2); // IFD0 条目数
  // Make 0x010F ASCII count=4 'NIKN'(4B 内联)
  u16(10, 0x010F);
  u16(12, 2);
  u32(14, 4);
  tiff.setUint8(18, 0x4E);
  tiff.setUint8(19, 0x49);
  tiff.setUint8(20, 0x4B);
  tiff.setUint8(21, 0x4E);
  // Model 0x0110 ASCII count=3 'Zf\0'(内联 + 补齐;内联路径不摆空格,
  // 带空格字符串的偏移路径解析见 watermark_test)
  u16(22, 0x0110);
  u16(24, 2);
  u32(26, 3);
  tiff.setUint8(30, 0x5A);
  tiff.setUint8(31, 0x66);
  tiff.setUint8(32, 0);
  tiff.setUint8(33, 0);
  u32(34, 0); // 下一 IFD = 0
  final payload = [...'Exif'.codeUnits, 0, 0, ...tiff.buffer.asUint8List()];
  final segLen = 2 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...payload, //
    0xFF, 0xD9,
  ]);
}

/// 假下载器:落一个伪对象文件并回报;记录调用入参供断言;[gate] 挂住
/// 供排队用例摆拍在途。
final class _FakeDownloader implements ObjectDownloader {
  final List<(ObjectEntry, String)> calls = [];
  bool failNext = false;
  Completer<void>? gate;

  @override
  int? get partialChunkBytes => null;

  @override
  Future<ObjectDownload> download(
    ObjectEntry entry, {
    required String targetDir,
    void Function(int receivedBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls.add((entry, targetDir));
    if (gate != null) {
      await gate!.future;
    }
    if (failNext) {
      failNext = false;
      throw const FormatException('假下载失败');
    }
    final path = '$targetDir/${entry.name}';
    File(path).writeAsBytesSync(List.filled(4, 1));
    onProgress?.call(entry.sizeInBytes);
    return ObjectDownload(
        path: path,
        bytes: entry.sizeInBytes,
        elapsed: Duration.zero,
        averageBytesPerSecond: 1);
  }
}

/// 假 RAW 解码器:返回固定 JPEG;可置败。
final class _FakeRawDecoder implements RawDecoder {
  int calls = 0;
  bool fail = false;

  @override
  Future<Uint8List> decodeJpeg(String path, {required int maxPixelSize}) async {
    calls++;
    if (fail) {
      throw const FormatException('假解码失败');
    }
    return _jpeg;
  }
}

PtpResult _okData(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

ObjectEntry _entry(int handle,
        {String name = 'DSC_0001.JPG',
        int size = 100,
        ObjectKind kind = ObjectKind.image}) =>
    ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: size,
      kind: kind,
      parentHandle: 0x11,
    );

/// 轮询等后台(warm 的 fire-and-forget 链)真 IO 落地。
Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 400 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('未命中拉取落盘;命中后不再发请求', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 0x90C4 高清(裸)
      ..reply(_okData(_jpgHead(1))); // 横拍:无注入(字节不变)
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final path = await cache.pathFor(entry, ThumbSource.grid);
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getLargeThumb, PtpOperationCode.getPartialObject]);

    final again = await cache.pathFor(entry, ThumbSource.grid);
    expect(again, path);
    expect(fake.requests.length, 2); // 命中:无新请求
  });

  test('同键并发请求合并为一次拉取(含方向头读)', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final paths = await Future.wait([
      cache.pathFor(entry, ThumbSource.grid),
      cache.pathFor(entry, ThumbSource.grid),
    ]);
    expect(paths[0], paths[1]);
    expect(fake.requests.length, 2); // 一次缩略 + 一次头读
  });

  test('内容键跨实例稳定:新实例直接命中磁盘,不进相机', () async {
    final gallery = FakeGallerySaver();
    final fake1 = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    final entry = _entry(0x12);
    await ThumbnailCache(
            session: PtpSession(transport: fake1), gallery: gallery)
        .pathFor(entry, ThumbSource.grid);

    // 新实例(内存索引为空)→ 磁盘命中,零请求。
    final fake2 = FakePtpTransport();
    final path = await ThumbnailCache(
            session: PtpSession(transport: fake2), gallery: gallery)
        .pathFor(entry, ThumbSource.grid);
    expect(fake2.requests, isEmpty);
    expect(File(path).existsSync(), isTrue);
  });

  test('reset 只清内存索引:磁盘内容键仍然命中', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);
    final path = await cache.pathFor(entry, ThumbSource.grid);

    cache.reset();
    final again = await cache.pathFor(entry, ThumbSource.grid);
    expect(again, path);
    expect(fake.requests.length, 2); // reset 后磁盘命中,无新请求
  });

  test('LRU:超出上限按最久未访问驱逐删盘', () async {
    final gallery = FakeGallerySaver();
    final fake = FakePtpTransport();
    // SOI 开头的 60B(0x90C4 高清档收下的最小 JPEG 形状)
    final bytes =
        Uint8List.fromList([0xFF, 0xD8, ...List.generate(58, (i) => i)]);
    // 每张 60B,上限 130B(恰好装两张):第 3 张进来时最久未访问的
    // 第 1 张被驱逐,两张留存。
    final cache = ThumbnailCache(
      session: PtpSession(transport: fake),
      gallery: gallery,
      gridLimitBytes: 130,
    );
    // 拉一张 = 0x90C4 高清 + 头读两步(头回 Orientation=1 → 不注入,
    // 60B 不变;三条都不降级 —— 0x90C4 全成功)
    Future<String> fetch(String name) {
      fake.reply(_okData(bytes));
      fake.reply(_okData(_jpgHead(1)));
      return cache.pathFor(
          _entry(0x12, name: name, size: 60), ThumbSource.grid);
    }

    final p1 = await fetch('A.JPG');
    final p2 = await fetch('B.JPG');
    final p3 = await fetch('C.JPG');
    expect(File(p1).existsSync(), isFalse); // A(最久未访问)被驱逐
    expect(File(p2).existsSync(), isTrue);
    expect(File(p3).existsSync(), isTrue);

    // 重新访问 A(磁盘已删)→ 重新拉缩略;方向已记忆(A 内容键)不再
    // 头读。A 回到最新端,B 成为最旧被驱逐。
    fake.reply(_okData(bytes));
    final p1again = await cache.pathFor(
        _entry(0x12, name: 'A.JPG', size: 60), ThumbSource.grid);
    expect(p1again, p1);
    expect(File(p1).existsSync(), isTrue);
    expect(File(p2).existsSync(), isFalse);
  });

  // ── 字节账 O(1) 记账(2026-10-22:驱逐沿增量账,不再每次全表求和)──

  test('字节账:插入/命中提升/驱逐/盘档落空各沿,账恒等于全表重算', () async {
    final gallery = FakeGallerySaver();
    final fake = FakePtpTransport();
    // SOI 开头的 60B(0x90C4 高清档收下的最小 JPEG 形状,同上 LRU 用例)
    final bytes =
        Uint8List.fromList([0xFF, 0xD8, ...List.generate(58, (i) => i)]);
    // 每张 60B、上限 130B:两张恰好,第三张起必须驱逐
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake),
        gallery: gallery,
        gridLimitBytes: 130);
    Future<String> fetch(String name) {
      fake.reply(_okData(bytes)); // 0x90C4 高清
      fake.reply(_okData(_jpgHead(1))); // 头读(横拍不注入,60B 不变)
      return cache.pathFor(
          _entry(0x12, name: name, size: 60), ThumbSource.grid);
    }

    /// 检查点:增量字节账 == 索引在册字节全表求和(重算是旧版每次驱逐
    /// 前的逐条求和 —— 与增量维护相互独立的对照路径,漂移即翻)。
    void check(ThumbSource source) {
      final a = debugLruAccount(cache, source);
      expect(a.account, a.entries.values.fold(0, (p, b) => p + b),
          reason: '$source 档字节账 == 全表重算(在册 ${a.entries.length} 张)');
    }

    // ① 插入两张:账 120 ≤ 130,无驱逐
    final pa = await fetch('A.JPG');
    final pb = await fetch('B.JPG');
    expect(File(pa).existsSync(), isTrue);
    expect(File(pb).existsSync(), isTrue);
    check(ThumbSource.grid);

    // ② 命中提升 ×2:移尾不动字节 —— 若命中误入账,120 涨破 130 会
    // 假性驱逐(B 盘档还在即账未漂移)
    await cache.pathFor(
        _entry(0x12, name: 'A.JPG', size: 60), ThumbSource.grid);
    await cache.pathFor(
        _entry(0x12, name: 'A.JPG', size: 60), ThumbSource.grid);
    expect(File(pb).existsSync(), isTrue, reason: '命中不加账:未假性驱逐');
    check(ThumbSource.grid);

    // ③ 第三张:180 > 130,逐最旧 —— A 刚被回访提升,逐的是 B
    final pc = await fetch('C.JPG');
    expect(File(pb).existsSync(), isFalse); // B(最久未访问)被逐
    expect(File(pa).existsSync(), isTrue);
    expect(File(pc).existsSync(), isTrue);
    check(ThumbSource.grid); // 在册 A + C = 120

    // ④ 预览档入账:两档账各自独立(grid 账与在册条目原样不动)
    final gridBefore = debugLruAccount(cache, ThumbSource.grid);
    fake.reply(_okData(bytes)); // 0x920F FHD(preview 席位)
    fake.reply(_okData(_jpgHead(1))); // 头读
    await cache.pathFor(
        _entry(0x13, name: 'D.JPG', size: 60), ThumbSource.preview);
    final gridAfter = debugLruAccount(cache, ThumbSource.grid);
    expect(gridAfter.account, gridBefore.account,
        reason: '预览档入账不搅 grid 账');
    check(ThumbSource.grid);
    check(ThumbSource.preview);

    // ⑤ 盘档落空边界:手删 C 的盘档后回访 —— 命中沿 existsSync 落空,
    // 出表出账当未命中重拉(方向已按内容键记忆,免头读:仅一笔
    // 0x90C4);回位后账 == 重算,且未假性驱逐 A
    File(pc).deleteSync();
    final requestsBefore = fake.requests.length;
    fake.reply(_okData(bytes));
    final pcAgain = await cache.pathFor(
        _entry(0x12, name: 'C.JPG', size: 60), ThumbSource.grid);
    expect(pcAgain, pc);
    expect(fake.requests.length, requestsBefore + 1, reason: '只重拉缩略');
    expect(fake.requests.last.opcode, NikonOperationCode.getLargeThumb);
    expect(File(pc).existsSync(), isTrue, reason: '重拉回位');
    expect(File(pa).existsSync(), isTrue, reason: '回位时未假性驱逐');
    check(ThumbSource.grid);
  });

  // ── 方向规整(2026-10-09:相机缩略是裸 JPEG,注入原文件头方向)──

  test('网格缩略:竖拍裸 JPEG 注入原文件头方向(落盘即转正)', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 0x90C4 高清(裸,无 EXIF)
      ..reply(_okData(_jpgHead(8))); // 原文件头:竖拍 Orientation=8
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    final written = File(path).readAsBytesSync();
    expect(jpegHasExif(written), isTrue);
    expect(jpegExifOrientation(written), 8); // 引擎解码即转正
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getLargeThumb, PtpOperationCode.getPartialObject]);
  });

  test('方向头读按内容键记忆:网格与预览只读一次头,预览同享转正', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 网格缩略(裸)
      ..reply(_okData(_jpgHead(8))) // 头读 → 8(记忆)
      ..reply(_okData(_jpeg)); // 预览 FHD 0x920F(裸)
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final grid = await cache.pathFor(entry, ThumbSource.grid);
    expect(jpegExifOrientation(File(grid).readAsBytesSync()), 8);
    final preview = await cache.pathFor(entry, ThumbSource.preview);
    expect(jpegExifOrientation(File(preview).readAsBytesSync()), 8);

    // 无第二次头读(方向已按内容键记忆;预览走 FHD 席位)
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getPartialObject,
      NikonOperationCode.getFhdPicture,
    ]);
  });

  test('缩略自带 EXIF:不读头不注入(引擎自会转)', () async {
    final withExif = injectJpegOrientation(_jpeg, 8);
    final fake = FakePtpTransport()..reply(_okData(withExif));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    expect(File(path).readAsBytesSync(), withExif); // 原样落盘
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getLargeThumb]); // 无头读
  });

  test('视频条目:不读头不注入(海报无 EXIF 语义)', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(
        _entry(0x12, name: 'DSC_0001.MOV', kind: ObjectKind.video),
        ThumbSource.grid);
    expect(File(path).readAsBytesSync(), _jpeg); // 原样落盘
    expect(
        fake.requests.map((r) => r.opcode), [PtpOperationCode.getThumb]); // 无头读
  });

  test('头读失败(旧机身拒 0x101B)→ 不注入,缩略照常', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 0x90C4 高清(裸)
      ..reply(PtpResult(responseCode: PtpResponseCode.operationNotSupported));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    expect(File(path).readAsBytesSync(), _jpeg); // 裸缩略照常(不转正)
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getLargeThumb, PtpOperationCode.getPartialObject]);
  });

  // ── 0x90C4 高清缩略(N-link 手法:网格 JPG 高清优先,诚实降级)──

  test('网格 JPG:0x90C4 成功出高清,lt_ 键落盘;旧小图缓存不挡高清', () async {
    final gallery = FakeGallerySaver();
    final thumbsDir = await gallery.thumbsDir();
    // 旧版小图缓存(plain 键)+ 格式标记(免被清空闸扫掉):键不分档
    // 的话这里会被当成高清档直接命中
    File('$thumbsDir/.fmt-v2').writeAsStringSync('cleared');
    final smallJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    File('$thumbsDir/DSC_0001.JPG_100.jpg').writeAsBytesSync(smallJpeg);

    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 0x90C4 高清(裸)
      ..reply(_okData(_jpgHead(1))); // 头读(横拍不注入)
    final cache =
        ThumbnailCache(session: PtpSession(transport: fake), gallery: gallery);

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    // 高清档独立键(lt_):不是旧小图档的路径,内容是 0x90C4 回包
    expect(path, endsWith('lt_DSC_0001.JPG_100.jpg'));
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getLargeThumb, PtpOperationCode.getPartialObject]);
    // 旧小图档已清(免孤儿档占盘不进 LRU 账)
    expect(File('$thumbsDir/DSC_0001.JPG_100.jpg').existsSync(), isFalse);

    // 再取:内存命中高清档,零新请求
    final again = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    expect(again, path);
    expect(fake.requests.length, 2);
  });

  test('网格 JPG:0x90C4 回非 JPEG(NEF 条带形态)→ 回落 0x100A,垃圾不落盘', () async {
    final gallery = FakeGallerySaver();
    final strip = Uint8List.fromList(List.filled(40, 0x77)); // 整段无 SOI
    final fake = FakePtpTransport()
      ..reply(_okData(strip)) // 0x90C4 OK 但非 JPEG
      ..reply(_okData(_jpeg)) // 回落 getThumb
      ..reply(_okData(_jpgHead(1)));
    final session = PtpSession(transport: fake);
    final cache = ThumbnailCache(session: session, gallery: gallery);

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(path, endsWith('DSC_0001.JPG_100.jpg')); // 小图档保持旧制键
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getThumb,
      PtpOperationCode.getPartialObject,
    ]);
    // 非 JPEG 载荷也置会话降级旗标(视为不支持)
    expect(session.largeThumbDegraded, isTrue);
    // 高清档未落盘(垃圾字节不进 .jpg 缓存)
    final thumbsDir = await gallery.thumbsDir();
    expect(File('$thumbsDir/lt_DSC_0001.JPG_100.jpg').existsSync(), isFalse);
  });

  test('会话级降级:首个 JPG 失败(错误应答)后,后续 JPG 不再发 0x90C4', () async {
    final fake = FakePtpTransport();
    final session = PtpSession(transport: fake);
    final cache = ThumbnailCache(session: session, gallery: FakeGallerySaver());
    final a = _entry(0x12, name: 'A.JPG');
    final b = _entry(0x13, name: 'B.JPG');
    fake
      ..reply(PtpResult(
          responseCode: PtpResponseCode.operationNotSupported)) // A 的 0x90C4 被拒
      ..reply(_okData(_jpeg)) // A 回落 getThumb
      ..reply(_okData(_jpgHead(1))) // A 头读
      ..reply(_okData(_jpeg)) // B 直走 getThumb(降级:不试 0x90C4)
      ..reply(_okData(_jpgHead(1))); // B 头读

    final pa = await cache.pathFor(a, ThumbSource.grid);
    final pb = await cache.pathFor(b, ThumbSource.grid);
    expect(File(pa).existsSync(), isTrue);
    expect(File(pb).existsSync(), isTrue);
    expect(session.largeThumbDegraded, isTrue);
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getLargeThumb, // A 首试(失败,置旗标)
      PtpOperationCode.getThumb, // A 回落小图
      PtpOperationCode.getPartialObject, // A 头读
      PtpOperationCode.getThumb, // B 直走小图
      PtpOperationCode.getPartialObject, // B 头读
    ]);
  });

  test('网格 JPG:0x90C4 超时(USB 单事务形态)→ 回落 0x100A 小图', () async {
    final fake = FakePtpTransport()
      ..fail(TimeoutException('bulkRead 窗口内未收到数据'))
      ..reply(_okData(_jpeg)) // 回落 getThumb
      ..reply(_okData(_jpgHead(1)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.grid);
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getThumb,
      PtpOperationCode.getPartialObject,
    ]);
  });

  test('网格 NEF:不试 0x90C4,照旧 0x100A 小图', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // getThumb
      ..reply(_okData(_tiffHead(6))); // NEF 头读(TIFF 头即 IFD0)
    final session = PtpSession(transport: fake);
    final cache = ThumbnailCache(session: session, gallery: FakeGallerySaver());

    final path = await cache.pathFor(
        _entry(0x12, name: 'DSC_0001.NEF'), ThumbSource.grid);
    expect(jpegExifOrientation(File(path).readAsBytesSync()), 6);
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getThumb, PtpOperationCode.getPartialObject]);
    expect(session.largeThumbDegraded, isFalse); // 没碰过 0x90C4
  });

  // ── exifCardOf:查看器信息栏的 EXIF 头读 ──

  test('exifCardOf:64KB 头读一次出卡,内容键记忆不重拉', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpgExifHead()));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    final card = await cache.exifCardOf(entry);
    expect(card?.model, 'Zf');
    final again = await cache.exifCardOf(entry);
    expect(again?.model, 'Zf', reason: '记忆命中');

    expect(fake.requests, hasLength(1));
    expect(fake.requests.single.opcode, PtpOperationCode.getPartialObject);
    expect(fake.requests.single.params, [0x12, 0, 64 * 1024]);
  });

  test('exifCardOf:64KB 档被拒 → 16KB 档兜底出卡', () async {
    final fake = FakePtpTransport()
      ..reply(PtpResult(responseCode: PtpResponseCode.operationNotSupported))
      ..reply(_okData(_jpgExifHead()));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    expect((await cache.exifCardOf(_entry(0x12)))?.model, 'Zf');
    expect(fake.requests.map((r) => r.params[2]), [64 * 1024, 16 * 1024],
        reason: '先 64KB 再 16KB');
  });

  test('exifCardOf:协议全败 → null 且不驻留(下次点开重试成功)', () async {
    final fake = FakePtpTransport()
      ..reply(PtpResult(responseCode: PtpResponseCode.operationNotSupported))
      ..reply(PtpResult(responseCode: PtpResponseCode.deviceBusy))
      ..reply(_okData(_jpgExifHead()));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    expect(await cache.exifCardOf(entry), isNull);
    expect((await cache.exifCardOf(entry))?.model, 'Zf',
        reason: '失败未驻留,第二次重试读到');
    expect(fake.requests, hasLength(3));
  });

  test('exifCardOf:确无 EXIF 的头(解析 null)驻留,不反复头读', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg)); // 无 APP1 的头
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());
    final entry = _entry(0x12);

    expect(await cache.exifCardOf(entry), isNull);
    expect(await cache.exifCardOf(entry), isNull);
    expect(fake.requests, hasLength(1), reason: '「确无」是结论,驻留');
  });

  test('exifCardOf:视频条目 → null 且零请求', () async {
    final fake = FakePtpTransport();
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    expect(
        await cache.exifCardOf(
            _entry(0x12, name: 'DSC_0001.MOV', kind: ObjectKind.video)),
        isNull);
    expect(fake.requests, isEmpty);
  });

  // ── preview 分流 ──

  test(
      'preview:0x920F 直发不查能力表(op 表不含也走 FHD;'
      '无线 STA 的小表是假门),fhd_ 独立键落盘,网格不吃', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.preview);
    expect(path, endsWith('fhd_DSC_0001.JPG_100.jpg'));
    expect(File(path).existsSync(), isTrue);
    // 无 getDeviceInfo(直发),FHD 请求在前、头读在后
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getFhdPicture, PtpOperationCode.getPartialObject]);

    // 再取:内存命中,零新请求
    final again = await cache.pathFor(_entry(0x12), ThumbSource.preview);
    expect(again, path);
    expect(fake.requests.length, 2);
  });

  test('preview:相机拒 0x920F(错误码)→ 置降级,回落 0x90C4 高清档', () async {
    final fake = FakePtpTransport()
      ..reply(PtpResult(
          responseCode: PtpResponseCode.operationNotSupported)) // 0x920F 被拒
      ..reply(_okData(_jpeg)) // 回落 getLargeThumb
      ..reply(_okData(_jpgHead(1)));
    final session = PtpSession(transport: fake);
    final cache = ThumbnailCache(session: session, gallery: FakeGallerySaver());

    final path = await cache.pathFor(_entry(0x12), ThumbSource.preview);
    expect(File(path).readAsBytesSync(), _jpeg);
    expect(path, endsWith('lt_DSC_0001.JPG_100.jpg'));
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getFhdPicture,
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getPartialObject
    ]);

    // 降级旗标:第二张 JPG 预览直走 0x90C4,不再逐张试 0x920F
    fake
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    await cache.pathFor(_entry(0x13, name: 'DSC_0002.JPG', size: 200),
        ThumbSource.preview);
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getFhdPicture,
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getPartialObject,
      NikonOperationCode.getLargeThumb,
      PtpOperationCode.getPartialObject,
    ]);

    // reset(断连)复位:重探 0x920F(这次成功,直接回 FHD 席位)
    cache.reset();
    fake
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(1)));
    final retry = await cache.pathFor(
        _entry(0x14, name: 'DSC_0003.JPG', size: 300), ThumbSource.preview);
    expect(retry, endsWith('fhd_DSC_0003.JPG_300.jpg'));
    expect(fake.requests.length, 7);
    expect(fake.requests[5].opcode, NikonOperationCode.getFhdPicture,
        reason: 'reset 后重探 0x920F');
  });

  test('preview:视频海报直走 GetThumb(不试 0x90C4,不拖垮降级旗标)', () async {
    final fake = FakePtpTransport()..reply(_okData(_jpeg));
    final session = PtpSession(transport: fake);
    final cache = ThumbnailCache(session: session, gallery: FakeGallerySaver());

    final path = await cache.pathFor(
        _entry(0x12, name: 'DSC_0001.MOV', kind: ObjectKind.video),
        ThumbSource.preview);
    expect(File(path).readAsBytesSync(), _jpeg); // 视频不读头不注入
    expect(fake.requests.map((r) => r.opcode), [PtpOperationCode.getThumb]);
    expect(session.largeThumbDegraded, isFalse); // 视频失败不连累 JPG
  });

  test(
      'preview:NEF 中档 = 0x920F FHD 直发(不查能力表),方向注入后先显;'
      'warm 后整档解码换高清', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 0x920F FHD(裸)
      ..reply(_okData(_tiffHead(6))); // 头读:NEF 头即 TIFF(竖拍 6)
    final gallery = FakeGallerySaver();
    final downloader = _FakeDownloader();
    final decoder = _FakeRawDecoder();
    final upgrades = <PreviewUpgrade>[];
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake),
        gallery: gallery,
        downloader: downloader,
        rawDecoder: decoder)
      ..previewUpgrades.listen(upgrades.add);
    final entry = _entry(0x12, name: 'DSC_0001.NEF');

    // 打开即回:0x920F 中档(带方向注入),不等整档
    final path = await cache.pathFor(entry, ThumbSource.preview);
    expect(jpegExifOrientation(File(path).readAsBytesSync()), 6);
    expect(downloader.calls, isEmpty);
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getFhdPicture, PtpOperationCode.getPartialObject]);

    // 页 settle 预热:整档下载 + 原生解码 → 高清席位 + 换图事件
    await cache.warmPreview(entry);
    expect(downloader.calls.single.$1.name, 'DSC_0001.NEF');
    expect(decoder.calls, 1);
    expect(upgrades, hasLength(1));
    expect(upgrades.single.handle, 0x12);
    expect(upgrades.single.sizeInBytes, 100);
    expect(File(upgrades.single.path).readAsBytesSync(), _jpeg);
    expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty);

    // 再开:直取高清席位(无新相机请求)
    final again = await cache.pathFor(entry, ThumbSource.preview);
    expect(again, upgrades.single.path);
    expect(fake.requests.length, 2);
  });

  test('preview:NEF 0x920F 拒(0xA00F 无 FHD 数据)→ 回落 GetThumb 小图', () async {
    final fake = FakePtpTransport()
      ..reply(PtpResult(
          responseCode: NikonResponseCode.noFullHdPresent)) // 0x920F 拒
      ..reply(_okData(_jpeg)) // 回落 getThumb
      ..reply(_okData(_jpgHead(1)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake), gallery: FakeGallerySaver());

    final path = await cache.pathFor(
        _entry(0x12, name: 'DSC_0001.NEF'), ThumbSource.preview);
    expect(File(path).existsSync(), isTrue);
    expect(fake.requests.map((r) => r.opcode), [
      NikonOperationCode.getFhdPicture,
      PtpOperationCode.getThumb,
      PtpOperationCode.getPartialObject
    ]);
  });

  test('preview:JPG 高清席位 —— 0x920F FHD 小图先显,warm 整档解码换高清', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg)) // 小图 0x920F FHD(裸)
      ..reply(_okData(_jpgHead(1))); // 头读(横拍不注入)
    final gallery = FakeGallerySaver();
    final downloader = _FakeDownloader();
    final decoder = _FakeRawDecoder();
    final upgrades = <PreviewUpgrade>[];
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake),
        gallery: gallery,
        downloader: downloader,
        rawDecoder: decoder)
      ..previewUpgrades.listen(upgrades.add);
    final entry = _entry(0x12); // DSC_0001.JPG

    final small = await cache.pathFor(entry, ThumbSource.preview);
    expect(File(small).readAsBytesSync(), _jpeg);
    expect(small, endsWith('fhd_DSC_0001.JPG_100.jpg'));
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getFhdPicture, PtpOperationCode.getPartialObject]);
    expect(upgrades, isEmpty);

    await cache.warmPreview(entry);
    expect(downloader.calls.single.$1.name, 'DSC_0001.JPG');
    expect(decoder.calls, 1);
    expect(upgrades.single.handle, 0x12);
    // 再开:直取高清席位(不再走小图)
    final again = await cache.pathFor(entry, ThumbSource.preview);
    expect(again, upgrades.single.path);
    expect(again, isNot(small));
  });

  test('preview:NEF 无解码器平台(Android/ohos)→ 只有小图席位', () async {
    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_tiffHead(6)));
    final cache = ThumbnailCache(
        session: PtpSession(transport: fake),
        gallery: FakeGallerySaver(),
        rawDecoder: null);

    final path = await cache.pathFor(
        _entry(0x12, name: 'DSC_0001.NEF'), ThumbSource.preview);
    expect(jpegExifOrientation(File(path).readAsBytesSync()), 6);
    expect(fake.requests.map((r) => r.opcode),
        [NikonOperationCode.getFhdPicture, PtpOperationCode.getPartialObject]);
    // warm 是无操作:不拉整档
    await cache.warmPreview(_entry(0x12, name: 'DSC_0001.NEF'));
    expect(fake.requests.length, 2);
  });

  test('preview:NEF warm 下载/解码失败 → 小图保留无事件,本会话不重试', () async {
    for (final (which, downloader, decoder) in [
      ('下载失败', _FakeDownloader()..failNext = true, _FakeRawDecoder()),
      ('解码失败', _FakeDownloader(), _FakeRawDecoder()..fail = true),
    ]) {
      final gallery = FakeGallerySaver(); // 每子用例独立:防内容键串味
      final fake = FakePtpTransport()
        ..reply(_okData(_jpeg))
        ..reply(_okData(_tiffHead(6)));
      final upgrades = <PreviewUpgrade>[];
      final cache = ThumbnailCache(
          session: PtpSession(transport: fake),
          gallery: gallery,
          downloader: downloader,
          rawDecoder: decoder)
        ..previewUpgrades.listen(upgrades.add);
      final entry = _entry(0x12, name: 'DSC_0001.NEF');

      final path = await cache.pathFor(entry, ThumbSource.preview);
      await cache.warmPreview(entry);
      expect(upgrades, isEmpty, reason: which); // 无换图事件
      expect(File(path).existsSync(), isTrue, reason: which); // 小图还在
      // 再 warm:本会话不重试(_hqTried 已记)
      await cache.warmPreview(entry);
      expect(downloader.calls, hasLength(1), reason: which);
      expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty,
          reason: '失败的临时档已删($which)');
    }
  });

  test('warmPreview 单槽排队:在途不顶,排队只留最新(快速翻页只暖停留页)', () async {
    final gallery = FakeGallerySaver();
    final gate = Completer<void>();
    final downloader = _FakeDownloader()..gate = gate;
    final decoder = _FakeRawDecoder();
    final upgrades = <PreviewUpgrade>[];
    final cache = ThumbnailCache(
        session: PtpSession(transport: FakePtpTransport()),
        gallery: gallery,
        downloader: downloader,
        rawDecoder: decoder)
      ..previewUpgrades.listen(upgrades.add);
    final a = _entry(0x12, name: 'A.JPG');
    final b = _entry(0x13, name: 'B.JPG');
    final c = _entry(0x14, name: 'C.JPG');

    unawaited(cache.warmPreview(a)); // A 起跑,挂在闸上
    await _until(() => downloader.calls.isNotEmpty);
    expect(downloader.calls.single.$1.name, 'A.JPG');
    await cache.warmPreview(b); // 排队(未起跑)
    await cache.warmPreview(c); // 顶掉 b
    expect(downloader.calls, hasLength(1)); // b 没占带宽

    gate.complete();
    await _until(() => upgrades.length >= 2); // A、C 两事件都送达才收口
    expect(downloader.calls.map((e) => e.$1.name), ['A.JPG', 'C.JPG']);
    expect(upgrades.map((u) => u.handle), [0x12, 0x14]);
  });

  test('warmPreview:视频条目直接跳(海报无高清语义)', () async {
    final downloader = _FakeDownloader();
    final cache = ThumbnailCache(
        session: PtpSession(transport: FakePtpTransport()),
        gallery: FakeGallerySaver(),
        downloader: downloader,
        rawDecoder: _FakeRawDecoder());

    await cache.warmPreview(
        _entry(0x12, name: 'DSC_0001.MOV', kind: ObjectKind.video));
    expect(downloader.calls, isEmpty);
  });

  // ── 格式清空闸(2026-10-09:方向注入上线,旧缓存一次性重建)──

  test('格式清空闸:旧版本缓存(未注入方向)一次性清,不再命中旧档', () async {
    final gallery = FakeGallerySaver();
    final entry = _entry(0x12);
    // 旧版本写的同内容键缓存(裸、无注入)—— 升级前的浏览留存
    final thumbsDir = await gallery.thumbsDir();
    File('$thumbsDir/DSC_0001.JPG_100.jpg').writeAsBytesSync(_jpeg);

    final fake = FakePtpTransport()
      ..reply(_okData(_jpeg))
      ..reply(_okData(_jpgHead(8))); // 竖拍:注入 8
    final cache =
        ThumbnailCache(session: PtpSession(transport: fake), gallery: gallery);

    final path = await cache.pathFor(entry, ThumbSource.grid);
    expect(jpegExifOrientation(File(path).readAsBytesSync()), 8); // 新档带注入
    expect(File('$thumbsDir/.fmt-v2').existsSync(), isTrue); // 标记档在

    // 新实例:标记在 → 不再清,磁盘命中零请求
    final fake2 = FakePtpTransport();
    final again = await ThumbnailCache(
            session: PtpSession(transport: fake2), gallery: gallery)
        .pathFor(entry, ThumbSource.grid);
    expect(again, path);
    expect(fake2.requests, isEmpty);
  });
}

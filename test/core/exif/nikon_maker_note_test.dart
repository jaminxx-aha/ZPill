// 快门数探针解析器用例:合成 EXIF/MakerNote/HEIF 字节,不碰真机。
//
// 主 TIFF 与 Nikon 子 TIFF 故意异序(用例 1/2),锁死「两个域字节序
// 各自独立解析」这一真实形态。Nikon MakerNote 头双代际都覆盖:
// 0210(9B,老式)与 1100(10B,Z 系新式,2026-10-22 真 NEF 实证)。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/exif/nikon_maker_note.dart';

void _w16(BytesBuilder b, int v, bool big) =>
    b.add(big ? [v >> 8 & 0xFF, v & 0xFF] : [v & 0xFF, v >> 8 & 0xFF]);

void _w32(BytesBuilder b, int v, bool big) => b.add(big
    ? [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]
    : [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF]);

/// 合成 Nikon v2 MakerNote(自描述子 TIFF)。
/// [zHeader] = Z 系新式 1100(10B 头 + version type 7);
/// false = 老式 0210(9B 头 + version type 2)。
Uint8List _buildMakerNote(
    {required bool subBig,
    required bool includeShutterTag,
    int shutterCount = 0,
    bool zHeader = false}) {
  final nEntries = includeShutterTag ? 2 : 1;
  final sub = BytesBuilder()
    ..add(subBig ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]);
  _w32(sub, 8, subBig); // Nikon IFD 固定 @8
  _w16(sub, nEntries, subBig);
  // 0x0001 MakerNoteVersion:ASCII×4,内联在 value 字段。
  _w16(sub, 0x0001, subBig);
  _w16(sub, zHeader ? 7 : 2, subBig);
  _w32(sub, 4, subBig);
  sub.add(zHeader ? [0x31, 0x31, 0x30, 0x30] : [0x30, 0x32, 0x31, 0x30]);
  if (includeShutterTag) {
    // 0x00A7 ShutterCount:LONG×1,值内联。
    _w16(sub, 0x00A7, subBig);
    _w16(sub, 4, subBig);
    _w32(sub, 1, subBig);
    _w32(sub, shutterCount, subBig);
  }
  _w32(sub, 0, subBig); // next IFD
  return (BytesBuilder()
        ..add(const [0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00, 0x02])
        ..add(zHeader ? const [0x11, 0x00, 0x00] : const [0x10, 0x00])
        ..add(sub.toBytes()))
      .toBytes();
}

/// 合成主 TIFF 载荷(IFD0→ExifIFD→DateTimeOriginal+MakerNote),
/// 布局:0..7 TIFF 头 | 8..25 IFD0 | 26..55 ExifIFD | 56..76 原时 | 77.. MakerNote。
Uint8List _buildTiffPayload(
    {required bool mainBig, required Uint8List mn, bool withMakerNote = true}) {
  final dt = [...'2026:10:22 12:34:56'.codeUnits, 0];
  const ifd0Off = 8;
  const exifOff = ifd0Off + 2 + 12 + 4; // 26
  const dtOff = exifOff + 2 + 24 + 4; // 56
  final mnOff = dtOff + dt.length; // 77
  final tiff = BytesBuilder()
    ..add(mainBig ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]);
  _w32(tiff, ifd0Off, mainBig);
  _w16(tiff, 1, mainBig); // IFD0:仅 0x8769
  _w16(tiff, 0x8769, mainBig);
  _w16(tiff, 4, mainBig);
  _w32(tiff, 1, mainBig);
  _w32(tiff, exifOff, mainBig);
  _w32(tiff, 0, mainBig);
  _w16(tiff, withMakerNote ? 2 : 1, mainBig); // ExifIFD:0x9003 [+0x927C]
  _w16(tiff, 0x9003, mainBig);
  _w16(tiff, 2, mainBig);
  _w32(tiff, dt.length, mainBig);
  _w32(tiff, dtOff, mainBig);
  if (withMakerNote) {
    _w16(tiff, 0x927C, mainBig);
    _w16(tiff, 7, mainBig);
    _w32(tiff, mn.length, mainBig);
    _w32(tiff, mnOff, mainBig);
  }
  _w32(tiff, 0, mainBig);
  tiff.add(dt);
  if (withMakerNote) tiff.add(mn);
  return tiff.toBytes();
}

/// JPEG APP1 包裹(asPlainTiff=true 时裸 TIFF ≈ NEF 头)。
Uint8List _buildExif(
    {required bool mainBig,
    required bool subBig,
    required bool includeShutterTag,
    int shutterCount = 123456,
    bool asPlainTiff = false,
    bool zHeader = false,
    bool withMakerNote = true}) {
  final mn = _buildMakerNote(
      subBig: subBig,
      includeShutterTag: includeShutterTag,
      shutterCount: shutterCount,
      zHeader: zHeader);
  final tiffBytes = _buildTiffPayload(mainBig: mainBig, mn: mn, withMakerNote: withMakerNote);
  if (asPlainTiff) return tiffBytes;
  final app1Len = 2 + 6 + tiffBytes.length;
  return (BytesBuilder()
        ..add([
          0xFF, 0xD8, 0xFF, 0xE1, app1Len >> 8 & 0xFF, app1Len & 0xFF, //
          0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
        ])
        ..add(tiffBytes)
        ..add([0xFF, 0xD9]))
      .toBytes();
}

Uint8List _box(String type, List<int> body) {
  final size = body.length + 8;
  return (BytesBuilder()
        ..add([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF])
        ..add(type.codeUnits)
        ..add(body))
      .toBytes();
}

/// 合成最小 HEIF:ftyp + meta(iinf[infe v2 'Exif' id7] + iloc v0) + item。
/// [exifDataBlockPrefix] = 按规范加 4B tiff_header_offset 前缀
/// (Nikon HIF 真机形态:offset=6,后随 2B 附加数据)。
Uint8List _buildHeif(Uint8List tiffPayload,
    {bool exifDataBlockPrefix = true, List<int> prefixBytes = const [0, 0, 0, 6]}) {
  final ftyp = _box('ftyp', [...'heic'.codeUnits, 0, 0, 0, 0]);
  final infe = _box('infe', const [
    0x02, 0x00, 0x00, 0x00, // version 2, flags 0
    0x00, 0x07, // item_ID = 7
    0x00, 0x00, // protection = 0
    0x45, 0x78, 0x69, 0x66, 0x00, // 'Exif' + NUL name
  ]);
  final iinfBody = BytesBuilder()
    ..add(const [0, 0, 0, 0, 0, 1]) // v0: flags 4B + count u16 = 1
    ..add(infe);
  final iinf = _box('iinf', iinfBody.toBytes());
  const ilocLen = 8 + 4 + 1 + 1 + 2 + 2 + 2 + 2 + 4 + 4; // 30,恒定
  final itemData = exifDataBlockPrefix
      ? (BytesBuilder()
            ..add(prefixBytes) // tiff_header_offset(真机=6)
            ..add(const [0xDE, 0xAD]) // 附加 2B(真机同款)
            ..add(tiffPayload))
          .toBytes()
      : tiffPayload;
  final payloadOff = ftyp.length + 12 + iinf.length + ilocLen;
  final ilocBody = BytesBuilder()
    ..add(const [0, 0, 0, 0]) // version 0, flags 0
    ..add(const [0x44, 0x00]) // offset4/length4, base0
    ..add(const [0, 1]) // item_count = 1
    ..add(const [0, 7]) // item_ID = 7
    ..add(const [0, 0]) // data_reference_index = 0
    ..add(const [0, 1]) // extent_count = 1
    ..add([
      payloadOff >> 24 & 0xFF, payloadOff >> 16 & 0xFF,
      payloadOff >> 8 & 0xFF, payloadOff & 0xFF,
    ])
    ..add([
      itemData.length >> 24 & 0xFF, itemData.length >> 16 & 0xFF,
      itemData.length >> 8 & 0xFF, itemData.length & 0xFF,
    ]);
  final iloc = _box('iloc', ilocBody.toBytes());
  final metaBody = BytesBuilder()
    ..add(const [0, 0, 0, 0]) // meta FullBox flags
    ..add(iinf)
    ..add(iloc);
  final meta = _box('meta', metaBody.toBytes());
  return (BytesBuilder()..add(ftyp)..add(meta)..add(itemData)).toBytes();
}

void main() {
  test('JPEG APP1:主 MM 子 II 异序,快门数/版本/原时全中', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: true, subBig: false, includeShutterTag: true, shutterCount: 123456));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isTrue);
    expect(r.makerNoteVersion, '0210');
    expect(r.shutterCount, 123456);
    expect(r.dateTimeOriginal, '2026:10:22 12:34:56');
    expect(r.makerNoteHex, isNull);
  });

  test('裸 TIFF(NEF 形态):主 II 子 MM 异序同样命中', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: false,
        subBig: true,
        includeShutterTag: true,
        shutterCount: 987654,
        asPlainTiff: true));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isTrue);
    expect(r.shutterCount, 987654);
    expect(r.makerNoteVersion, '0210');
  });

  test('Z 系新式 1100 头(10B,version type 7):真机同款形态命中', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: true,
        subBig: true,
        includeShutterTag: true,
        shutterCount: 36884,
        zHeader: true));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isTrue);
    expect(r.makerNoteVersion, '1100');
    expect(r.shutterCount, 36884);
  });

  test('HEIF(HIF)容器:ISOBMFF Exif item → 快门数命中', () {
    final payload = _buildTiffPayload(
        mainBig: true,
        mn: _buildMakerNote(
            subBig: false,
            includeShutterTag: true,
            shutterCount: 777777,
            zHeader: true));
    final r = parseNikonShutterCount(_buildHeif(payload));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isTrue);
    expect(r.makerNoteVersion, '1100');
    expect(r.shutterCount, 777777);
    expect(r.dateTimeOriginal, '2026:10:22 12:34:56');
  });

  test('HEIF 无 ExifDataBlock 前缀(规范宽容形态):直接 TIFF 开场也命中', () {
    final payload = _buildTiffPayload(
        mainBig: true,
        mn: _buildMakerNote(
            subBig: true, includeShutterTag: true, shutterCount: 2468, zHeader: true));
    final r = parseNikonShutterCount(_buildHeif(payload, exifDataBlockPrefix: false));
    expect(r.exifFound, isTrue);
    expect(r.shutterCount, 2468);
  });

  test('HEIF ExifDataBlock offset 字段失真:16B 窗搜兜底命中', () {
    final payload = _buildTiffPayload(
        mainBig: true,
        mn: _buildMakerNote(
            subBig: true, includeShutterTag: true, shutterCount: 1357, zHeader: true));
    final r = parseNikonShutterCount(_buildHeif(
        payload,
        prefixBytes: const [0xFF, 0xFF, 0xFF, 0xFF]));
    expect(r.exifFound, isTrue);
    expect(r.shutterCount, 1357);
  });

  test('nikonTagDump: 全 tag 串含 0x00A7 值与版本 ASCII', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: true,
        subBig: true,
        includeShutterTag: true,
        shutterCount: 777777,
        zHeader: true));
    expect(r.nikonTagDump, isNotNull);
    expect(r.nikonTagDump, contains('0xA7:4/1=777777'));
    expect(r.nikonTagDump, contains('(1100)'));
  });

  test('nikonTagDump: 失败路径为 null', () {
    final r = parseNikonShutterCount(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]));
    expect(r.nikonTagDump, isNull);
  });

  test('MakerNote 在但无 0x00A7:快门数 null,段与版本照报,附 hex', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: true, subBig: true, includeShutterTag: false));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isTrue);
    expect(r.makerNoteVersion, '0210');
    expect(r.shutterCount, isNull);
    expect(r.makerNoteHex, isNotNull);
  });

  test('无 MakerNote(0x927C 缺):段未找到', () {
    final r = parseNikonShutterCount(_buildExif(
        mainBig: true, subBig: true, includeShutterTag: false, withMakerNote: false));
    expect(r.exifFound, isTrue);
    expect(r.makerNoteFound, isFalse);
    expect(r.shutterCount, isNull);
  });

  test('纯 JPEG 无 EXIF 容器', () {
    final r = parseNikonShutterCount(Uint8List.fromList(
        [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x0A, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9]));
    expect(r.exifFound, isFalse);
    expect(r.shutterCount, isNull);
  });

  test('垃圾字节不抛', () {
    final r = parseNikonShutterCount(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
    expect(r.exifFound, isFalse);
    expect(r.shutterCount, isNull);
  });

  test('MakerNote 偏移越界(头部截断):不抛,快门数 null', () {
    final full = _buildExif(
        mainBig: true, subBig: true, includeShutterTag: true, shutterCount: 42);
    final r = parseNikonShutterCount(Uint8List.sublistView(full, 0, 60));
    expect(r.shutterCount, isNull);
  });

  test('HEIF 载荷起点在头部读数之外:不抛,快门数 null', () {
    final payload = _buildTiffPayload(
        mainBig: true,
        mn: _buildMakerNote(subBig: true, includeShutterTag: true, zHeader: true));
    final full = _buildHeif(payload);
    final r = parseNikonShutterCount(Uint8List.sublistView(full, 0, 40));
    expect(r.shutterCount, isNull);
  });
}

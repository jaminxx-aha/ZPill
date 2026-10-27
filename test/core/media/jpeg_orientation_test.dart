import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/media/jpeg_orientation.dart';

// ── 真机探针产物夹具(2026-10-09 Zf 实拍,tools/usb_probe 抓档)──

/// 竖拍 JPG「DSC_6183 姊妹档 291A9827」的文件头前 2KB(生产头读同尺寸)。
/// APP1 Exif 段声明 65534B(MakerNote 40KB+ 撑大)—— 头读必然截断,
/// 方向条目表在段内前 ~400B,截断容忍照解出 Orientation=8。
const _zfiJpgHeadB64 = [
  '/9j/4f/+RXhpZgAASUkqAAgAAAANAA8BAgASAAAArAAAABABAgAKAAAAwAAAABIBAwABAAAACAAAABoBBQABAAAAzAAAABsBBQAB',
  'AAAA1AAAACgBAwABAAAAAgAAADEBAgANAAAA3AAAADIBAgAUAAAA7AAAADsBAgAlAAAAAAEAABMCAwABAAAAAgAAAJiCAgA3AAAA',
  'KAEAAGmHBAABAAAAYAEAACWIBAABAAAA4KMAAPSjAAAAAE5JS09OIENPUlBPUkFUSU9OAAAATklLT04gWiBmAAAALAEAAAEAAAAs',
  'AQAAAQAAAFZlci4wMy4wMAAAAAAAAAAyMDI2OjA5OjMwIDEwOjM5OjAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADEAmoIFAAEAAAC0',
  'AwAAnYIFAAEAAAC8AwAAIogDAAEAAAADAAAAJ4gDAAEAAABkAAAAMIgDAAEAAAACAAAAMogEAAEAAABkAAAAAJAHAAQAAAAwMjMy',
  'A5ACABQAAADEAwAABJACABQAAADYAwAAEJACAAcAAADsAwAAEZACAAcAAAD0AwAAEpACAAcAAAD8AwAAAZEHAAQAAAABAgMAApEF',
  'AAEAAAAEBAAABJIKAAEAAAAMBAAAB5IDAAEAAAACAAAACJIDAAEAAAAAAAAACZIDAAEAAAAAAAAACpIFAAEAAAAUBAAAfJIHAPCe',
  'AADQBAAAhpIHACwAAAAcBAAAkJICAAMAAAAwNgAAkZICAAMAAAAwNgAAkpICAAMAAAAwNgAAAKAHAAQAAAAwMTAwAaADAAEAAAAB',
  'AAAAAqADAAEAAACgFwAAA6ADAAEAAADADwAABaAEAAEAAADAowAAF6IDAAEAAAACAAAAAKMHAAEAAAADAAAAAaMHAAEAAAABAAAA',
  'AqMHAAgAAABIBAAAAaQDAAEAAAABAAAAAqQDAAEAAAAAAAAAA6QDAAEAAAAAAAAABaQDAAEAAAAYAAAABqQDAAEAAAAAAAAAB6QD',
  'AAEAAAAAAAAACKQDAAEAAAAAAAAACaQDAAEAAAAAAAAACqQDAAEAAAAAAAAADKQDAAEAAAAAAAAAMaQCAAgAAABQBAAAMqQFAAQA',
  'AABYBAAAM6QCAAYAAAB4BAAANKQCAEEAAACABAAANaQCAAsAAADEBAAAYKQDAAEAAAABAAAAAAAAAAAACgAAAMQJAACQAQAAZAAA',
  'ADIwMjY6MDk6MzAgMTA6Mzk6MDAAMjAyNjowOTozMCAxMDozOTowMAArMDg6MDAAACswODowMAAAKzA4OjAwAAAEAAAAAQAAAAAA',
  'AAAGAAAA8AAAAAoAAABBU0NJSQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAgAAAQECODAxNDQxMQDw',
  'AAAACgAAALAEAAAKAAAAkAEAAGQAAACQAQAAZAAAAE5JS09OAAAATklLS09SIFogMjQtMTIwbW0gZi80IFMAAAAAAAAAAAAAAAAA',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAyMDMwNzgyOCAgAABOaWtvbgACEQAASUkqAAgAAABOAAEABwAEAAAAMDIx',
  'MQQAAgAIAAAAtgMAAAUAAgANAAAAvgMAAAcAAgAHAAAAzgMAAAgAAgANAAAA1gMAAAkAAgAUAAAA5gMAAAwABQAEAAAA+gMAAA0A',
  'BwAEAAAAAAEGAA4ABwAEAAAAAAEMABYAAwAEAAAAGgQAABcABwAEAAAAAAEGABgABwAEAAAAAAEGABkACgABAAAAIgQAABsAAwAH',
  'AAAAKgQAABwABwADAAAAAAEGAB0AAgAIAAAAOgQAAB4AAwABAAAAAQAAAB8ABwAJAAAAQgQAACIAAwABAAAABwAAACMABwBsAAAA',
  'TgQAACQABwAEAAAA4AEAACUABwAOAAAAugQAACoAAwABAAAAAAAAACsABwAQAAAAygQAADQAAwABAAAAUQAAADUABwAGAAAA2gQA',
  'ADcABAABAAAA4TsAADsABQAEAAAA4gQAADwAAwABAAAAAQAAAD4AAwABAAAAAQAAAD8ACgACAAAAAgUAAEAABwAMAAAAEgUAAEIA',
  'BwAGAAAAHgUAAEMABwAMAAAAJgUAAEQAAwABAAAAAwAAAEcABwAMAAAAMgUAAE0ABwBUAAAAPgUAAE8AAwABAAAAzhgAAFMABwCw',
  'AAAAkgUAAFQABwAUAAAAQgYAAFUABwAIAAAAVgYAAFYABwAQAAAAXgYAAFcABwAIAAAAbgYAAFkABwAIAAAAdgYAAFoABwAMAAAA',
  'fgYAAFsABwAIAAAAigYAAFwABwBYAAAAkgYAAF0ABwAIAAAA6gYAAF4ABwAcAAAA8gYAAGAABwAIAAAADgcAAGEABwAQAAAAFgcA',
  'AGsABwAQAAAAJgcAAIMAAQABAAAAAAAAAIQABQAEAAAANgcAAIcAAQABAAAAAAAAAIkAAwABAAAAIAAAAIoAAwABAAAAAQAAAIsA',
  'BwAEAAAAPAEMAIwABwBCAgAAVgcAAJEABwA8kgAAmgkAAJUAAgAFAAAA1psAAJcABwCmAAAA3psAAJgABwBsAAAAhpwAAJ4AAwAK',
  'AAAA8pwAAKIABAABAAAAs6ymAKMAAQA=',
];

/// 横拍 NEF 0A1A9859 的文件头前 1KB:文件即 TIFF(II*\0,IFD0@8),
/// Orientation=1(无转正含义)。
const _zfiNefHeadB64 = [
  'SUkqAAgAAAAWAP4ABAABAAAAAQAAAAMBAwABAAAABgAAAA8BAgASAAAAGAEAABABAgAKAAAALAEAABIBAwABAAAAAQAAABoBBQAB',
  'AAAAOAEAABsBBQABAAAAQAEAACgBAwABAAAAAgAAADEBAgANAAAASAEAADIBAgAUAAAAWAEAADsBAgAlAAAAbAEAAEoBBAAGAAAA',
  'lAEAAAECBAABAAAADJkBAAICBAABAAAAwxsAABMCAwABAAAAAgAAABQCBQAGAAAArAEAALwCAQAAiAAA3AEAAJiCAgA3AAAA3IkA',
  'AGmHBAABAAAAKIoAACWIBAABAAAA+JgBAAOQAgAUAAAAFIoAABaSAQAEAAAAAQAAAAAAAAAAAE5JS09OIENPUlBPUkFUSU9OAAAA',
  'TklLT04gWiBmAAAALAEAAAEAAAAsAQAAAQAAAFZlci4wMy4wMAAAAAAAAAAyMDI2OjEwOjA5IDAxOjA0OjEzAAAAAAAAAAAAAAAA',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADQtAEAdLUBAEC6AQDkugEApLsBAGS8AQAAAAAAAQAAAP8AAAABAAAAAAAAAAEA',
  'AAD/AAAAAQAAAAAAAAABAAAA/wAAAAEAAAA8P3hwYWNrZXQgYmVnaW49Iu+7vyIgaWQ9Ilc1TTBNcENlaGlIenJlU3pOVGN6a2M5',
  'ZCI/Pjx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iPjxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5v',
  'cmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+PHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRw',
  'Oi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIj48eG1wOkNyZWF0b3JUb29sPk5JS09OIFogZiBWZXIuMDMuMDAgICA8L3htcDpDcmVh',
  'dG9yVG9vbD48eG1wOkNyZWF0ZURhdGU+MjAyNi0xMC0wOVQwMTowNDoxMy4xMTwveG1wOkNyZWF0ZURhdGU+PHhtcDpSYXRpbmc+',
  'MDwveG1wOlJhdGluZz4gPC9yZGY6RGVzY3JpcHRpb24+PHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6Y3JkPSJo',
  'dHRwOi8vbnMuYWRvYmUuY29tL2NhbWVyYS1yYXctZGVmYXVsdHMvMS4wLyI+PGNyZDpFeHBvc3VyZTIwMTI+MC4wMDwvY3JkOkV4',
  'cG9zdXJlMjAxMj48Y3JkOkhpZ2hsaWdodHMyMDEyPjA8L2NyZDpIaWdobGlnaHRzMg==',
];

/// NEF 解码预览(GetThumb 回的文件内嵌 IFD1 缩略):7107B 裸 JPEG,
/// 160×120 横盒、无 EXIF —— 相机缩略的原型形状。
const _zfiBareThumbB64 = [
  '/9j/2wCEAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAgECAgIBAgICAgMCAgICAgICAgMCAgMDAwMDAgIDAwMDAwMDAwMBAQEB',
  'AQEBAQEBAQMCAgIDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA//EAaIAAAEFAQEBAQEB',
  'AAAAAAAAAAABAgMEBQYHCAkKCxAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK',
  'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ip',
  'qrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6AQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJ',
  'CgsRAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4',
  'OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG',
  'x8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/AABEIAHgAoAMBIQACEQEDEQH/2gAMAwEAAhEDEQA/AP4OIPhh8S7nb9m+',
  'Hnjm43kBPI8Ja/LuJOABttznnjitEfBj4wt934UfEo/TwL4oP/trWCxOGd0sRHT+8v8AMlzgt5r7yUfBL4znp8Iviefp4B8Vn/20',
  'p4+BvxrPT4PfFI/T4feLT/7aU/rGH/5/x/8AAl/mL2lP+dfeh4+BPxvPT4N/FU/T4eeLv/kOnD4DfHI9Pgz8Vz9Ph34vP/tnS+s4',
  'b/oIj/4Ev8w9pT/nX3od/wAKE+Oh6fBb4s/+G58Yf/IdL/woL47Hp8Ffi1/4bjxj/wDIdH1nDf8AQRH/AMCX+Ye0p/8APxfehf8A',
  'hQHx3/6In8W//Db+Mf8A5Cpf+Gf/AI8f9ET+Ln/ht/GX/wAhUfWcN/0ER/8AAl/mHtaX/Pxfeg/4Z/8Ajx/0RP4uf+G38Zf/ACFS',
  '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',
];

Uint8List _b64(String s) =>
    Uint8List.fromList(base64Decode(s.replaceAll(RegExp(r'\s'), '')));

Uint8List _fixture(List<String> lines) => _b64(lines.join());

/// 手搓 TIFF 头(小端/大端):II/MM + 0x2A + IFD0@8 + 单条 Orientation。
/// 与实现互为独立来源(不调被测代码拼)。
Uint8List _tiffHead(int orientation, {bool little = true}) {
  final bo = little ? Endian.little : Endian.big;
  final tiff = ByteData(8 + 2 + 12 + 4);
  tiff.setUint8(0, little ? 0x49 : 0x4D);
  tiff.setUint8(1, little ? 0x49 : 0x4D);
  tiff.setUint16(2, 0x2A, bo);
  tiff.setUint32(4, 8, bo); // IFD0 偏移
  tiff.setUint16(8, 1, bo); // 条目数
  tiff.setUint16(10, 0x0112, bo); // Orientation
  tiff.setUint16(12, 3, bo); // SHORT
  tiff.setUint32(14, 1, bo); // count 1
  tiff.setUint16(18, orientation, bo); // 值内联
  return tiff.buffer.asUint8List();
}

/// 手搓带 EXIF 的 JPEG(SOI + APP1 Exif + EOI)。
Uint8List _jpgWithExif(int orientation) {
  final payload = [...'Exif'.codeUnits, 0, 0, ..._tiffHead(orientation)];
  final segLen = 2 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...payload, //
    0xFF, 0xD9,
  ]);
}

/// 手搓裸 JPEG(SOI + APP0 JFIF + EOI,无 EXIF)。
final _bareJpg = Uint8List.fromList([
  0xFF, 0xD8, // SOI
  0xFF, 0xE0, 0x00, 0x07, ...'JFIF'.codeUnits, 0, // APP0 JFIF
  0xFF, 0xD9, // EOI
]);

void main() {
  test('真机竖拍 JPG 头:APP1 声明 65534B 头读截断,照解 Orientation=8',
      () {
    final head = _fixture(_zfiJpgHeadB64);
    expect(head.length, 2048);
    expect(head[0], 0xFF);
    expect(head[1], 0xD8);
    expect(jpegHasExif(head), isTrue); // 截断的 Exif 段也算「有」
    expect(orientationFromHead(head), 8);
  });

  test('真机横拍 NEF 头:文件即 TIFF,Orientation=1(无转正)', () {
    final head = _fixture(_zfiNefHeadB64);
    expect(head[0], 0x49);
    expect(orientationFromHead(head), 1);
  });

  test('真机裸缩略(160×120 无 EXIF):注入 8 → 引擎解码即转正 120×160',
      () async {
    final thumb = _fixture(_zfiBareThumbB64);
    expect(jpegHasExif(thumb), isFalse);
    expect(jpegExifOrientation(thumb), 0);

    final oriented = injectJpegOrientation(thumb, 8);
    expect(oriented.length, thumb.length + 36); // SOI 后插 FFE1+len(4)+负载(32)B
    expect(jpegHasExif(oriented), isTrue);
    expect(jpegExifOrientation(oriented), 8);
    // 原像素数据原样跟在注入段之后(SOI 2 + 注入段 36)
    expect(oriented.sublist(38), thumb.sublist(2));
    // 再注不动(已带 EXIF)
    expect(injectJpegOrientation(oriented, 8), same(oriented));

    // 引擎解码自动应用 EXIF Orientation(裸 160×120 → 转正 120×160)
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.runAsync(() async {
      final codec = await ui.instantiateImageCodec(oriented);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 120);
      expect(frame.image.height, 160);
      frame.image.dispose();
      final bare = await ui.instantiateImageCodec(thumb);
      final bareFrame = await bare.getNextFrame();
      expect(bareFrame.image.width, 160); // 不注入:维持横盒
      expect(bareFrame.image.height, 120);
      bareFrame.image.dispose();
    });
  });

  test('orientationFromHead:手搓 TIFF 小端/大端、JPG 多段、非图像回 0',
      () {
    expect(orientationFromHead(_tiffHead(6)), 6); // NEF 形状(II)
    expect(orientationFromHead(_tiffHead(5, little: false)), 5); // MM
    expect(orientationFromHead(_jpgWithExif(8)), 8);
    expect(orientationFromHead(_bareJpg), 0); // 裸 JPEG 无方向
    // MOV 头(ftyp 盒):非 JPEG 非 TIFF
    final mov = Uint8List.fromList(
        [0, 0, 0, 0x14, ...'ftypqt  '.codeUnits, 1, 2, 3, 4]);
    expect(orientationFromHead(mov), 0);
    expect(orientationFromHead(Uint8List(0)), 0); // 空
    expect(orientationFromHead(Uint8List.fromList([0xFF])), 0); // 太短
  });

  test('jpegHasExif / jpegExifOrientation:SOS 前 Exif、SOS 后不算、'
      '截断非 Exif 段不算', () {
    expect(jpegHasExif(_jpgWithExif(8)), isTrue);
    expect(jpegExifOrientation(_jpgWithExif(8)), 8);
    expect(jpegHasExif(_bareJpg), isFalse);

    // SOS 后的 APP1(合规 JPEG 不会这样,防御):不算
    final afterSos = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, // SOI + SOS
      ..._jpgWithExif(8), // 这之后的「APP1」不该被找到
    ]);
    expect(jpegHasExif(afterSos), isFalse);

    // 头读截断在非 Exif 段(APP0 声明大于已读):段界不可信,不再扫
    final truncatedApp0 = Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE0, 0xFF, 0xFF, 0x4A, 0x46, // APP0 声明 65535B,只给了几字节
      0xFF, 0xE1, 0x00, 0x08, ...'Exif'.codeUnits, 0, 0, // 后面就算有 Exif 也读不出段界
    ]);
    expect(jpegHasExif(truncatedApp0), isFalse);
  });

  test('injectJpegOrientation:无转正含义/超界/已带/非 JPEG 原样返回', () {
    expect(injectJpegOrientation(_bareJpg, 0), same(_bareJpg));
    expect(injectJpegOrientation(_bareJpg, 1), same(_bareJpg)); // 正常横拍
    expect(injectJpegOrientation(_bareJpg, 9), same(_bareJpg));
    expect(injectJpegOrientation(_bareJpg, -1), same(_bareJpg));
    final withExif = _jpgWithExif(8);
    expect(injectJpegOrientation(withExif, 6), same(withExif));
    final tiff = _tiffHead(8);
    expect(injectJpegOrientation(tiff, 8), same(tiff)); // 非 JPEG
    // 注入段结构:SOI 后紧跟 FFE1,长度字段 = 2 + 段负载
    final out = injectJpegOrientation(_bareJpg, 8);
    expect(out[2], 0xFF);
    expect(out[3], 0xE1);
    final segLen = (out[4] << 8) | out[5];
    expect(segLen, 2 + 6 + 26); // Exif\0\0(6) + TIFF(8+2+12+4=26)
  });
}

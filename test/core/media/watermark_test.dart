import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/watermark.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/settings_store.dart' show WatermarkStyle;

/// 小端 TIFF EXIF 载荷:IFD0(Make/Model/DateTime + Exif 指针)+
/// Exif 子表(FNumber/曝光/ISO/焦距)。偏移手工排布:
/// 头 8 + IFD0 54(8..61)+ ExifIFD 54(62..115)+ 数据区(116..)。
/// 注意:字符串 ≤ 4 字节时 EXIF 值内联存储,故用真实长度的
/// 'NIKON CORPORATION' / 'NIKON Z f' 走偏移路径。
Uint8List _exifPayload() {
  const ascii = 2, short = 3, long = 4, rational = 5;
  const makeOff = 116, modelOff = 134, dateOff = 144;
  const fNumOff = 164, expOff = 172, focalOff = 180;
  const exifIfdOff = 62;
  final w = ByteWriter()
    ..u16(0x4949) // 'II'
    ..u16(42)
    ..u32(8)
    // IFD0
    ..u16(4)
    ..u16(0x010F)
    ..u16(ascii)
    ..u32(18)
    ..u32(makeOff)
    ..u16(0x0110)
    ..u16(ascii)
    ..u32(10)
    ..u32(modelOff)
    ..u16(0x0132)
    ..u16(ascii)
    ..u32(20)
    ..u32(dateOff)
    ..u16(0x8769)
    ..u16(long)
    ..u32(1)
    ..u32(exifIfdOff)
    ..u32(0)
    // Exif 子表
    ..u16(4)
    ..u16(0x829D)
    ..u16(rational)
    ..u32(1)
    ..u32(fNumOff)
    ..u16(0x829A)
    ..u16(rational)
    ..u32(1)
    ..u32(expOff)
    ..u16(0x8827)
    ..u16(short)
    ..u32(1)
    ..u16(100)
    ..u16(0)
    ..u16(0x920A)
    ..u16(rational)
    ..u32(1)
    ..u32(focalOff)
    ..u32(0)
    // 数据区
    ..raw('NIKON CORPORATION'.codeUnits)
    ..u8(0)
    ..raw('NIKON Z f'.codeUnits)
    ..u8(0)
    ..raw('2026:10:02 09:05:33'.codeUnits)
    ..u8(0)
    ..u32(18)
    ..u32(10) // ƒ/1.8
    ..u32(1)
    ..u32(250) // 1/250s
    ..u32(85)
    ..u32(1); // 85mm
  return w.takeBytes();
}

/// 带 EXIF 的 60×40 渐变 JPEG(SOI 后插 Exif APP1)。
Uint8List _exifJpeg({img.Image? photo}) {
  photo ??= _gradient(60, 40);
  final jpeg = img.encodeJpg(photo);
  final payload = _exifPayload();
  final segLen = 2 + 6 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF,
    ...'Exif'.codeUnits, 0, 0,
    ...payload,
    ...jpeg.sublist(2),
  ]);
}

img.Image _gradient(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p
      ..r = (p.x * 4) & 0xFF
      ..g = (p.y * 6) & 0xFF
      ..b = 128
      ..a = 255;
  }
  return image;
}

/// 假文本光栅:红色实心块(宽 ≈ 字号×字数/2),几何断言用。
Future<img.Image> _fakeRaster(String text, double fontSizePx, int color) async {
  final h = fontSizePx.round();
  final image = img.Image(width: h * text.length ~/ 2 + 4, height: h);
  img.fillRect(image,
      x1: 0,
      y1: 0,
      x2: image.width - 1,
      y2: image.height - 1,
      color: img.ColorRgba8(200, 30, 30, 255));
  return image;
}

/// 含 Model + Orientation 两项的极简 EXIF 载荷(IFD0:Model 走偏移路径,
/// Orientation SHORT 内联;Model 是为了剥离方向标签后 EXIF 仍非空 ——
/// image 包对空 EXIF 不写 APP1,输出会整体无 EXIF)。
Uint8List _orientationPayload(int o) {
  const modelOff = 38; // 头 8 + 项数 2 + 两项 24 + next 4
  final w = ByteWriter()
    ..u16(0x4949) // 'II'
    ..u16(42)
    ..u32(8)
    ..u16(2)
    ..u16(0x0110)
    ..u16(2)
    ..u32(10)
    ..u32(modelOff)
    ..u16(0x0112)
    ..u16(3)
    ..u32(1)
    ..u16(o)
    ..u16(0)
    ..u32(0)
    ..raw('NIKON Z f'.codeUnits)
    ..u8(0);
  return w.takeBytes();
}

/// 带 Orientation 的 600×800 渐变 JPEG(SOI 后插 Exif APP1)。
Uint8List _orientedJpeg(int orientation) {
  final jpeg = img.encodeJpg(_gradient(600, 800));
  final payload = _orientationPayload(orientation);
  final segLen = 2 + 6 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF,
    ...'Exif'.codeUnits, 0, 0,
    ...payload,
    ...jpeg.sublist(2),
  ]);
}

void main() {
  test('readJpegExif:APP1 解析出机型/参数/时刻', () {
    final exif = readJpegExif(_exifJpeg());
    expect(exif, isNotNull);
    final card = exifCardDataOf(exif!);
    expect(card.make, 'NIKON CORPORATION');
    expect(card.model, 'NIKON Z f');
    expect(card.titleLine, 'NIKON Z f'); // 型号已含厂牌:去重
    expect(card.fNumber, 1.8);
    expect(card.exposureSec, closeTo(1 / 250, 1e-9));
    expect(card.iso, 100);
    expect(card.focalLengthMm, 85);
    expect(card.paramLine, '85mm ƒ/1.8 · 1/250s · ISO 100');
    expect(card.takenAt, DateTime(2026, 10, 2, 9, 5, 33));
  });

  test('无 EXIF 的 JPEG:readJpegExif → null,卡片摘要为空', () {
    final jpeg = img.encodeJpg(_gradient(20, 20));
    expect(readJpegExif(jpeg), isNull);
    final card = exifCardDataOf(img.ExifData());
    expect(card.titleLine, isEmpty);
    expect(card.paramLine, isEmpty);
    expect(card.takenAt, isNull);
  });

  test('APP1 段声明超头读:段尾截断仍解出(Zf 实测 65534B 段 vs 64KB 头读差 2B)', () {
    // Zf 最新 JPG 的 EXIF APP1 声明 65534B(MakerNote 40KB+),64KB 头读
    // 2+2+65534 = 65538 差 2B —— 截掉的是段尾填充/缩略图尾,IFD 全在前段。
    // 镜像该形状:载荷尾部补 2B 填充,声明再 +2,头读恰好缺最后 2B。
    final payload = Uint8List.fromList([..._exifPayload(), 0, 0]);
    final segLen = 2 + 6 + payload.length + 2; // 声明比在场多 2B
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF,
      ...'Exif'.codeUnits, 0, 0,
      ...payload.sublist(0, payload.length - 2), // 声明的最后 2B 缺席
    ]);
    final exif = readJpegExif(jpeg);
    expect(exif, isNotNull, reason: '段尾截断不该拒整段(2026-10-09 修)');
    final card = exifCardDataOf(exif!);
    expect(card.model, 'NIKON Z f');
    expect(card.focalLengthMm, 85); // 截断尾是填充,条目数据完整
  });

  test('截断的非 Exif 段:无法跨过 → null(段扫描止步)', () {
    // XMP APP1 声明 70000B、头读只有 200B:Exif APP1 在头读之外,
    // 跨不过截断段(2026-10-09 修的另一半语义:截断仅对 Exif 本段宽容)。
    final xmp = Uint8List.fromList([
      ...'http://ns.adobe.com/xap/1.0/'.codeUnits,
      0,
      ...List.filled(150, 0x20),
    ]);
    const segLen = 70000;
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF,
      ...xmp.sublist(0, xmp.length - 2),
      ..._exifJpeg().sublist(2), // 真 Exif 段跟在后(头读视角全在段外)
    ]);
    expect(readJpegExif(jpeg), isNull);
  });

  group('exifCardFromHead:文件头统一解析(JPG / NEF 同路)', () {
    test('JPG 头:与 readJpegExif 同出', () {
      final card = exifCardFromHead(_exifJpeg());
      expect(card, isNotNull);
      expect(card!.model, 'NIKON Z f');
      expect(card.paramLine, '85mm ƒ/1.8 · 1/250s · ISO 100');
    });

    test('NEF 头:文件头即 TIFF(IFD0@8)直进解析', () {
      // 本载荷与 NEF 头同构(II 42 IFD0@8);真实 NEF 的 Exif 子表
      // 走同一 0x8769 指针。缺 LensModel 不炸,缺项为 null。
      final card = exifCardFromHead(_exifPayload());
      expect(card, isNotNull);
      expect(card!.model, 'NIKON Z f');
      expect(card.focalLengthMm, 85);
      expect(card.lens, isNull);
    });

    test('非 JPG/TIFF 头(MOV / 乱字节 / 太短)→ null 不抛', () {
      expect(exifCardFromHead(Uint8List(0)), isNull);
      expect(exifCardFromHead(Uint8List.fromList([0, 1, 2])), isNull);
      // MOV:ftyp 盒头
      expect(
          exifCardFromHead(
              Uint8List.fromList([0, 0, 0, 0x14, ...'ftypqt  '.codeUnits])),
          isNull);
      // 单 'I' 不是 TIFF(II 对校验)
      expect(
          exifCardFromHead(
              Uint8List.fromList([0x49, 0x4D, ...List.filled(16, 0)])),
          isNull);
    });
  });

  test('格式化:厂牌去重、整档光圈、秒级快门、焦段取整', () {
    expect(const ExifCardData(make: 'NIKON', model: 'NIKON Z f').titleLine,
        'NIKON Z f');
    expect(
        const ExifCardData(
                fNumber: 8, exposureSec: 2.5, iso: 640, focalLengthMm: 85.4)
            .paramLine,
        '85mm ƒ/8 · 2.5s · ISO 640');
    expect(
        const ExifCardData(exposureSec: 0.004).paramLine, contains('1/250s'));
  });

  test('corner:右下角叠字,画幅不变,EXIF 保留', () async {
    final jpeg = _exifJpeg();
    final out = await applyWatermark(
        jpeg, const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
        raster: _fakeRaster);
    expect(identical(out, jpeg), isFalse);

    final decoded = img.decodeJpg(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, 60);
    expect(decoded.height, 40);
    // 角标落点(fontSize 16 → margin 11,badge 28×16):
    // dstX = 60-28-11 = 21,dstY = 40-16-11 = 13 → (30, 20) 在红块内。
    final p = decoded.getPixel(30, 20);
    expect(p.r, greaterThan(150));
    expect(p.g, lessThan(90));
    // 重编码保留 EXIF(encodeJpg 回写 APP1)。
    expect(readJpegExif(out)?.imageIfd[0x0110]?.toString(), 'NIKON Z f');
  });

  test('card:白衬纸加宽加高,照片居中无损,EXIF 保留', () async {
    final jpeg = _exifJpeg();
    final out = await applyWatermark(
        jpeg, const WatermarkOptions(style: WatermarkStyle.card, text: 'Aha'),
        raster: _fakeRaster);
    expect(identical(out, jpeg), isFalse);

    final decoded = img.decodeJpg(out);
    expect(decoded!.width, greaterThan(60));
    expect(decoded.height, greaterThan(40 + 20)); // 照片 + 至少三行文字区
    // 四角是白衬纸
    for (final (x, y) in [
      (0, 0),
      (decoded.width - 1, 0),
      (0, decoded.height - 1),
      (decoded.width - 1, decoded.height - 1)
    ]) {
      final c = decoded.getPixel(x, y);
      expect(c.r, greaterThan(235));
      expect(c.g, greaterThan(235));
      expect(c.b, greaterThan(235));
    }
    // 照片区居中:左上角衬纸宽 = (out.width - 60) / 2
    final sidePad = (decoded.width - 60) ~/ 2;
    final p = decoded.getPixel(sidePad + 30, sidePad + 20);
    expect(p.r, closeTo(120, 14));
    expect(p.g, closeTo(120, 14));
    // EXIF 随行
    expect(readJpegExif(out)?.imageIfd[0x0110]?.toString(), 'NIKON Z f');
  });

  test('off / 非 JPEG:原实例直返;小图放不下角标也直返', () async {
    final jpeg = _exifJpeg();
    expect(
        await applyWatermark(
            jpeg, const WatermarkOptions(style: WatermarkStyle.off)),
        same(jpeg));
    final notJpeg = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
    expect(
        await applyWatermark(
            notJpeg, const WatermarkOptions(style: WatermarkStyle.corner)),
        same(notJpeg));

    // 20×15 小图:fontSize 钳 16 → margin 11 → maxW ≤ 0,放不下。
    final tiny = img.encodeJpg(_gradient(20, 15));
    expect(
        await applyWatermark(tiny,
            const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
            raster: _fakeRaster),
        same(tiny));
  });

  test('SOI 后无 SOF(垃圾字节):原实例直返,不进子 isolate', () async {
    final junk = Uint8List.fromList([0xFF, 0xD8, 0x00, 0x01, 0x02, 0x03]);
    expect(
        await applyWatermark(junk,
            const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
            raster: _fakeRaster),
        same(junk));
  });

  test('文本光栅抛异常:原实例直返(水印不拖垮传输)', () async {
    final jpeg = _exifJpeg();
    Future<img.Image> boom(String text, double fontSizePx, int color) async =>
        throw Exception('raster boom');
    expect(
        await applyWatermark(jpeg,
            const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
            raster: boom),
        same(jpeg));
  });

  test('orientation 6:显示宽取烘焙后宽(帧高),字号随显示宽', () async {
    // 编码 600×800(竖),烘焙后 800×600(横);displayWidth=800 →
    // fontSize 24 → margin 17,假角标 40×24 → 落点 (743, 559)。
    // 若显示宽误取编码宽 600(fontSize 18 → 角标 31×18 @ (756, 569)),
    // 断言点 (748, 567) 落在错位角标之外,断言即翻。
    final jpeg = _orientedJpeg(6);
    final out = await applyWatermark(
        jpeg, const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
        raster: _fakeRaster);
    final decoded = img.decodeJpg(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, 800);
    expect(decoded.height, 600);
    final p = decoded.getPixel(748, 567);
    expect(p.r, greaterThan(150));
    expect(p.g, lessThan(90));
    expect(p.b, lessThan(90)); // 假红块 (200,30,30);照片渐变恒 b=128
    final q = decoded.getPixel(729, 567); // 角标左沿外:仍是照片像素
    expect(q.b, greaterThan(100));
    // bakeOrientation 把方向烘进像素后剥除 Orientation 标签,其余 EXIF 随行。
    final outExif = readJpegExif(out);
    expect(outExif, isNotNull);
    expect(outExif!.imageIfd.hasOrientation, isFalse);
    expect(outExif.imageIfd[0x0110]?.toString(), 'NIKON Z f');
  });

  test('orientation 1:解码直通画幅不变,标签剥除,字号随编码宽', () async {
    // 600×800;displayWidth=600 → fontSize 18 → margin 13,假角标 31×18
    // → 落点 (556, 769)。
    final jpeg = _orientedJpeg(1);
    final out = await applyWatermark(
        jpeg, const WatermarkOptions(style: WatermarkStyle.corner, text: 'Aha'),
        raster: _fakeRaster);
    final decoded = img.decodeJpg(out);
    expect(decoded!.width, 600);
    expect(decoded.height, 800);
    final p = decoded.getPixel(560, 772);
    expect(p.r, greaterThan(150));
    expect(p.g, lessThan(90));
    expect(readJpegExif(out)!.imageIfd.hasOrientation, isFalse);
  });

  group('jpegEncodedCanvasSize:帧头嗅探画幅', () {
    test('基线 SOF0(APP1 在前):600×800', () {
      expect(jpegEncodedCanvasSize(_orientedJpeg(1)), (600, 800));
    });

    test('渐进式 SOF2(DHT 在前照段长跳过):40×60', () {
      // SOI + DHT(占位)+ SOF2(precision 8,h 40,w 60,单分量)+ EOI。
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xC4, 0x00, 0x03, 0x00,
        0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x00, 0x28, 0x00, 0x3C, 0x01, 0x00,
        0xFF, 0xD9,
      ]);
      expect(jpegEncodedCanvasSize(jpeg), (60, 40));
    });

    test('无 SOF / 非 SOI / 太短 → null', () {
      expect(
          jpegEncodedCanvasSize(Uint8List.fromList([0xFF, 0xD8, 0x00, 0x01])),
          isNull);
      expect(
          jpegEncodedCanvasSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
          isNull);
      expect(jpegEncodedCanvasSize(Uint8List.fromList([0xFF, 0xD8])), isNull);
    });
  });
}

/// NEF/NRW 内嵌缩略提取(纯 Dart,平台无关)。
///
/// 背景(2026-10-24 ohos 图库缩略缺口):Zf 的 NEF 里没有任何大尺寸
/// JPEG(320×212/1620×1080 预览都是 RAW 条带,见 raw_decoder.dart 库
/// 注),唯一可直接取用的位图是 IFD0 0x0201(JPEGInterchangeFormat)
/// 指向的 160×120 缩略 JPEG —— 与相机相册 GetThumb 同源同质(撑满
/// 全屏糊,三列网格够用)。平台无原生 RAW 解码器(ohos/Android,
/// `nikonpill/raw` 缺席或拒绝)时,网格缩略与大图查看以此为兜底
/// ([nefEmbeddedJpeg] 装配成品);NEF 全尺寸解码仍走原生(iOS ImageIO)。
///
/// 结构:文件即 TIFF(II*/MM*,IFD0@8),条目表在头部 ~300B 内;
/// 一次头读 + 一次缩略段读,不碰 RAW 条带(28MB 档只读几 KB)。
/// 方向(0x0112)与缩略一并带回 —— 内嵌缩略是裸 JPEG(无 EXIF),
/// 交 [injectJpegOrientation] 注入后引擎解码即转正(相机相册
/// `_orientThumb` 同法)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'jpeg_orientation.dart';
import 'letterbox.dart';

/// 头读窗口:IFD0 条目表(Zf NEF 22 条 ≈ 272B)远在此内。
const _kHeadBytes = 2048;

/// 缩略段读上限护栏:160×120 JPEG 实测 ~4KB,罩住异常头不至于
/// 误读进 RAW 条带。
const _kMaxThumbBytes = 1 << 20;

/// 内嵌缩略与 EXIF 方向:jpeg 为裸 JPEG(SOI..EOI);orientation
/// 1-8,无标签回 0(交注入函数裁决)。
typedef NefEmbeddedThumb = ({Uint8List jpeg, int orientation});

/// 提取 NEF/NRW 的内嵌缩略。非 TIFF/无 0x0201 条目/段越界/载荷非
/// JPEG 回 null(调用方回落原图源/图标格)。
Future<NefEmbeddedThumb?> extractNefEmbeddedThumb(String path) async {
  final raf = await File(path).open();
  try {
    final size = await raf.length();
    final head = await raf.read(_kHeadBytes);
    if (head.length < 8) {
      return null;
    }
    // 字节序:II*<0>(little)/ MM<0>* (big),magic 42。
    final bool? little = switch ((head[0], head[1], head[2], head[3])) {
      (0x49, 0x49, 42, 0) => true,
      (0x4D, 0x4D, 0, 42) => false,
      _ => null,
    };
    if (little == null) {
      return null;
    }
    int u16(int offset) => little
        ? (head[offset] | head[offset + 1] << 8)
        : (head[offset] << 8 | head[offset + 1]);
    int u32(int offset) => little
        ? (u16(offset) | u16(offset + 2) << 16)
        : (u16(offset) << 16 | u16(offset + 2));

    final ifd0 = u32(4);
    if (ifd0 < 8 || ifd0 + 2 > head.length) {
      return null;
    }
    final entryCount = u16(ifd0);
    int? jpegOffset;
    int? jpegLength;
    var orientation = 0;
    for (var i = 0; i < entryCount; i++) {
      final entry = ifd0 + 2 + i * 12;
      if (entry + 12 > head.length) {
        return null; // 条目表被头读截断:结构超出预期,不作半解
      }
      // 值读法按字段类型:SHORT(3) 在值域前 2 字节,LONG(4) 占满
      // 4 字节(count 1 内联;本组三标签皆是)。
      final tag = u16(entry);
      final type = u16(entry + 2);
      final value = switch (type) {
        3 => u16(entry + 8),
        4 => u32(entry + 8),
        _ => null,
      };
      if (value == null) {
        continue;
      }
      switch (tag) {
        case 0x0201: // JPEGInterchangeFormat
          jpegOffset = value;
        case 0x0202: // JPEGInterchangeFormatLength
          jpegLength = value;
        case 0x0112: // Orientation
          orientation = value;
      }
    }
    if (jpegOffset == null ||
        jpegLength == null ||
        jpegLength <= 0 ||
        jpegLength > _kMaxThumbBytes ||
        jpegOffset < 8 ||
        jpegOffset + jpegLength > size) {
      return null;
    }
    await raf.setPosition(jpegOffset);
    final jpeg = await raf.read(jpegLength);
    // 载荷真伪:SOI(FFD8 + FF 标记)起、EOI(FFD9)收尾。
    if (jpeg.length < 4 ||
        jpeg[0] != 0xFF ||
        jpeg[1] != 0xD8 ||
        jpeg[2] != 0xFF ||
        jpeg[jpeg.length - 2] != 0xFF ||
        jpeg[jpeg.length - 1] != 0xD9) {
      return null;
    }
    return (jpeg: jpeg, orientation: orientation);
  } on FileSystemException {
    return null;
  } finally {
    await raf.close();
  }
}

/// 内嵌缩略兜底成品 JPEG:提取 → 注入 EXIF 方向(引擎解码即转正)→
/// 信箱黑边裁剪(无黑边/裁剪异常原样 —— 裁剪是妆补,[trimLetterboxJpeg]
/// 自吞错回 null,不挡兜底本身)。大图查看的解码兜底用(图库查看器
/// 解码缓存装配);网格缩略在各自的串行链里就地装配,不走这里。无内嵌
/// 缩略/非 NEF 结构回 null(调用方回落占位)。
Future<Uint8List?> nefEmbeddedJpeg(String path) async {
  final embedded = await extractNefEmbeddedThumb(path);
  if (embedded == null) {
    return null;
  }
  final oriented = injectJpegOrientation(embedded.jpeg, embedded.orientation);
  return await trimLetterboxJpeg(oriented) ?? oriented;
}

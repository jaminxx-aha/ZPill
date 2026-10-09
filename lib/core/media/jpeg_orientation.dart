/// 缩略图 EXIF 方向规整(JPEG/NEF 头部读取 + 裸 JPEG 注入)。
///
/// 背景(2026-10-09 真机探针定案):尼康相机回的缩略是**裸 JPEG** ——
/// 竖拍照片的像素按传感器方向横置存储,且不带 EXIF(Zf 竖拍 JPG 的
/// GetThumb = 文件内嵌 IFD1 缩略,160×120 横盒、SOI 后直接 DQT;无线上
/// 0x90C4 大图同样无 APP1)。方向真身只在**原文件**头部:JPG 的 APP1
/// EXIF IFD0(条目表在文件头 ~400B 内)、NEF 文件头即 TIFF(IFD0@8)。
///
/// 修法:取原文件头(≤2KB GetPartialObject)解析 Orientation → 注入
/// 缩略 JPEG 的 APP1 → Flutter 引擎解码自动应用 EXIF Orientation(实测
/// 160×120 + Orientation=8 解码为 120×160),网格与查看器同享一份缓存,
/// 无需各处加旋转件。NEF 解码预览(iOS ImageIO
/// kCGImageSourceCreateThumbnailWithTransform)**已经转正**,不得再注入
/// (会二次旋转);视频海报无 EXIF 语义,同样跳过。
library;

import 'dart:typed_data';

/// JPEG 是否带 Exif APP1 段(带方向的缩略交给引擎,不再注入)。
bool jpegHasExif(Uint8List jpeg) => _findExifApp1(jpeg) != null;

/// JPEG APP1 Exif 里 IFD0 的 Orientation 值(1-8);无段/无标签/非 JPEG
/// 回 0。
int jpegExifOrientation(Uint8List jpeg) {
  final span = _findExifApp1(jpeg);
  if (span == null) return 0;
  return _ifd0Orientation(ByteData.sublistView(jpeg, span.$1, span.$2));
}

/// 文件头(≤2KB)解析 Orientation:JPG(Ffd8 → APP1 Exif)或 NEF/TIFF
/// (II/MM 开头,IFD0@8)。解析不了回 0。
int orientationFromHead(Uint8List head) {
  if (head.length >= 4 && head[0] == 0xFF && head[1] == 0xD8) {
    return jpegExifOrientation(head);
  }
  if (head.length >= 8 && (head[0] == 0x49 || head[0] == 0x4D)) {
    return _ifd0Orientation(ByteData.sublistView(head));
  }
  return 0;
}

/// 给裸 JPEG 注入 EXIF Orientation:SOI 后插一段最小 APP1
/// (Exif\0\0 + TIFF II 0x2A + IFD0 单条目)。已带 Exif APP1、非 JPEG、
/// 或 orientation 无转正含义(≤1 / >8)时原样返回。
Uint8List injectJpegOrientation(Uint8List jpeg, int orientation) {
  if (jpeg.length < 2 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
  if (orientation <= 1 || orientation > 8) return jpeg;
  if (jpegHasExif(jpeg)) return jpeg;
  // TIFF(小端):II 0x002A IFD0@8;IFD0 1 条目:Orientation(SHORT×1,
  // 值内联)+ 下一 IFD = 0。
  final tiff = <int>[
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, //
    0x01, 0x00, // IFD0 条目数 1
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, // tag 0x0112 SHORT count 1
    orientation, 0x00, 0x00, 0x00, // 值内联 + 补齐
    0x00, 0x00, 0x00, 0x00, // 下一 IFD = 0
  ];
  final payload = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
  final segLen = 2 + payload.length;
  final out = BytesBuilder();
  out.add(jpeg.sublist(0, 2)); // SOI
  out.addByte(0xFF);
  out.addByte(0xE1);
  out.addByte((segLen >> 8) & 0xFF);
  out.addByte(segLen & 0xFF);
  out.add(payload);
  out.add(jpeg.sublist(2));
  return out.toBytes();
}

/// JPEG 段扫描:找 Exif APP1,返回 (段内 TIFF 起偏移, 段尾偏移)。
/// 头读截断容忍:Zf JPG 的 APP1 实测声明 65534B(MakerNote 40KB+
/// 撑大),头读必然盖不住整段 —— Exif 段夹到可用字节照解(方向条目表
/// 在段内前 ~400B,同 readJpegExif 的截断容忍);其余段截断 = 头里
/// 再无 EXIF 可找。非 JPEG / 段失步 / SOS 前无 Exif 均回 null。
(int, int)? _findExifApp1(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  var off = 2;
  while (off + 4 <= jpeg.length) {
    if (jpeg[off] != 0xFF) return null; // 段失步:不是可解的 JPEG 头
    final marker = jpeg[off + 1];
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      off += 2; // 独立标记,无长度
      continue;
    }
    if (marker == 0xDA) return null; // SOS:EXIF 必在其前
    final segLen = (jpeg[off + 2] << 8) | jpeg[off + 3];
    if (segLen < 2) return null;
    var segEnd = off + 2 + segLen;
    if (segEnd > jpeg.length && marker != 0xE1) {
      return null; // 截断的非 Exif 段:后面(即便有数据)也读不出段界
    }
    if (marker == 0xE1 &&
        jpeg.length >= off + 10 &&
        segLen >= 8 &&
        jpeg[off + 4] == 0x45 &&
        jpeg[off + 5] == 0x78 &&
        jpeg[off + 6] == 0x69 &&
        jpeg[off + 7] == 0x66 &&
        jpeg[off + 8] == 0 &&
        jpeg[off + 9] == 0) {
      // Exif 段尾夹到可用字节(截断容忍,见上)
      return (off + 10, segEnd > jpeg.length ? jpeg.length : segEnd);
    }
    off += 2 + segLen;
  }
  return null;
}

/// TIFF 头(含 IFD0 条目表)解析 Orientation;结构不符回 0。
int _ifd0Orientation(ByteData tiff) {
  if (tiff.lengthInBytes < 10) return 0;
  final little = tiff.getUint8(0) == 0x49;
  if (little ? tiff.getUint8(1) != 0x49 : tiff.getUint8(1) != 0x4D) return 0;
  final bo = little ? Endian.little : Endian.big;
  final ifd0 = tiff.getUint32(4, bo);
  if (ifd0 < 8 || ifd0 + 2 > tiff.lengthInBytes) return 0;
  final count = tiff.getUint16(ifd0, bo);
  for (var i = 0; i < count; i++) {
    final e = ifd0 + 2 + i * 12;
    if (e + 12 > tiff.lengthInBytes) break;
    if (tiff.getUint16(e, bo) == 0x0112 && // Orientation
        tiff.getUint16(e + 2, bo) == 3 && // SHORT
        tiff.getUint32(e + 4, bo) == 1) {
      return tiff.getUint16(e + 8, bo); // 值内联(2B ≤ 4B)
    }
  }
  return 0;
}

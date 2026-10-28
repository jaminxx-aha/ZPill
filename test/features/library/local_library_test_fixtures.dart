import 'dart:typed_data';

import 'package:z_pill/core/utils/byte_writer.dart';

/// 带 EXIF 的「JPG」字节(SOI + APP1 Exif + EOI,无图像数据):IFD0
/// Make/Model + Exif 子表 光圈/快门/ISO/焦距,无 takenAt(时间行走
/// mtime 兜底的用例语义)。布局:头 8 + IFD0 42(8..49,3 条目)+
/// Exif 54(50..103)+ 数据区(104..)。Make/Model 用真实长度(>4B)
/// —— EXIF 规则:值 ≤4 字节内联存储,短串会踩中内联路径测不到偏移。
Uint8List jpgExifBytes() {
  const ascii = 2, short = 3, long = 4, rational = 5;
  const makeOff = 104,
      modelOff = 122,
      fNumOff = 131,
      expOff = 139,
      focalOff = 147;
  final w = ByteWriter()
    ..u16(0x4949)
    ..u16(42)
    ..u32(8)
    // IFD0:Make / Model / Exif 指针(count 含结尾 NUL:17 字符 → 18)
    ..u16(3)
    ..u16(0x010F)
    ..u16(ascii)
    ..u32(18)
    ..u32(makeOff)
    ..u16(0x0110)
    ..u16(ascii)
    ..u32(9)
    ..u32(modelOff)
    ..u16(0x8769)
    ..u16(long)
    ..u32(1)
    ..u32(50)
    ..u32(0)
    // Exif 子表:光圈 / 快门 / ISO / 焦距
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
    ..raw('NIKON Zf'.codeUnits)
    ..u8(0)
    ..u32(2)
    ..u32(1) // ƒ/2
    ..u32(1)
    ..u32(250) // 1/250s
    ..u32(40)
    ..u32(1); // 40mm
  final payload = w.takeBytes();
  final segLen = 2 + 6 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...'Exif'.codeUnits, 0, 0, //
    ...payload, //
    0xFF, 0xD9, //
  ]);
}

/// 最小 NEF 合成(II 小端,IFD0@8 条目升序):宽/高/方向/JPEG 偏移/
/// 长度 + 填充 + [thumb] 内嵌缩略。结构对齐 Zf NEF(nef_thumb.dart
/// 提取器口径),专供「无原生 RAW 解码器 → 内嵌缩略兜底」用例。
Uint8List nefWithEmbeddedThumb(Uint8List thumb, {int orientation = 1}) {
  final entries = <(int, int, int)>[
    (0x0100, 4, 160), // width
    (0x0101, 4, 120), // height
    (0x0112, 3, orientation), // Orientation(SHORT)
    (0x0201, 4, 0), // JPEGInterchangeFormat(合成时回填)
    (0x0202, 4, thumb.length),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  const ifdOffset = 8;
  final ifdSize = 2 + entries.length * 12 + 4;
  final thumbOffset = ifdOffset + ifdSize + 64;
  final out = Uint8List(thumbOffset + thumb.length);
  final d = ByteData.view(out.buffer);
  out.setAll(0, [0x49, 0x49, 0x2A, 0x00]); // II*\0
  d.setUint32(4, ifdOffset, Endian.little);
  d.setUint16(ifdOffset, entries.length, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final e = ifdOffset + 2 + i * 12;
    final (tag, type, value) = entries[i];
    d.setUint16(e, tag, Endian.little);
    d.setUint16(e + 2, type, Endian.little);
    d.setUint32(e + 4, 1, Endian.little); // count
    d.setUint32(e + 8, tag == 0x0201 ? thumbOffset : value, Endian.little);
  }
  d.setUint32(ifdOffset + 2 + entries.length * 12, 0, Endian.little);
  out.setRange(thumbOffset, thumbOffset + thumb.length, thumb);
  return out;
}

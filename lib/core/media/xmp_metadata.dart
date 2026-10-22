/// XMP 元数据注入(GPS/IPTC/版权元数据附加):把 dc:creator /
/// dc:rights / xmp:Rating / exif GPS 写进 JPEG 的 APP1 XMP 段
///(字节拼接,不重编码 —— 画质零损耗)。
///
/// 注入位置:已有 XMP APP1 段则**替换**(重复段会让阅读器各取其一),
/// 否则插在 SOI 与 APP0(JFIF)之后。段头命名空间
/// `http://ns.adobe.com/xap/1.0/\0`(与 EXIF APP1 的 `Exif\0\0` 区分)。
///
/// 非 JPEG / 元数据为空 → 原样返回(同一实例,调用方免拷贝)。
/// RAW(NEF)的 XMP 是 TIFF 结构,不走本路径(侧车文件另议)。
library;

import 'dart:convert';
import 'dart:typed_data';

final class XmpMetadata {
  const XmpMetadata({
    this.creator,
    this.rights,
    this.rating,
    this.latitude,
    this.longitude,
  });

  /// 作者(dc:creator)。
  final String? creator;

  /// 版权(dc:rights)。
  final String? rights;

  /// 评分 1-5(xmp:Rating)。
  final int? rating;

  /// GPS 十进制度(正 = 北纬 / 东经)。
  final double? latitude;
  final double? longitude;

  bool get isEmpty =>
      (creator == null || creator!.isEmpty) &&
      (rights == null || rights!.isEmpty) &&
      (rating == null || rating! < 1) &&
      (latitude == null || longitude == null);
}

/// XMP APP1 段头命名空间(规范规定带结尾 NUL)。
final List<int> _kXmpApp1Header = [
  ...'http://ns.adobe.com/xap/1.0/'.codeUnits,
  0,
];

/// 构造最小合法 XMP 包(独立函数:测试直接对照字节)。
String buildXmpPacket(XmpMetadata meta) {
  final attrs = <String>[
    if (meta.creator?.isNotEmpty ?? false)
      '<dc:creator><rdf:Seq><rdf:li>${_xmlEscape(meta.creator!)}</rdf:li></rdf:Seq></dc:creator>',
    if (meta.rights?.isNotEmpty ?? false)
      '<dc:rights><rdf:Alt><rdf:li xml:lang="x-default">${_xmlEscape(meta.rights!)}</rdf:li></rdf:Alt></dc:rights>',
    if (meta.rating != null && meta.rating! >= 1)
      '<xmp:Rating>${meta.rating}</xmp:Rating>',
    if (meta.latitude != null && meta.longitude != null) ...[
      '<exif:GPSLatitude>${_gpsCoord(meta.latitude!, 'N', 'S')}</exif:GPSLatitude>',
      '<exif:GPSLongitude>${_gpsCoord(meta.longitude!, 'E', 'W')}</exif:GPSLongitude>',
    ],
  ];
  return '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="ZPill 1.0">\n'
      ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
      '  <rdf:Description rdf:about=""\n'
      '    xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
      '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
      '    xmlns:exif="http://ns.adobe.com/exif/1.0/">\n'
      '   ${attrs.join('\n   ')}\n'
      '  </rdf:Description>\n'
      ' </rdf:RDF>\n'
      '</x:xmpmeta>\n'
      '<?xpacket end="w"?>\n';
}

/// 把 XMP 包注入 JPEG(见 library 注);[meta] 为空或非 JPEG 返回原实例。
Uint8List injectXmpIntoJpeg(Uint8List jpeg, XmpMetadata meta) {
  if (meta.isEmpty) return jpeg;
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
  // 段扫描:SOI 后逐段走(marker + u16 长度,长度含自身 2 字节)。
  var pos = 2;
  var insertAt = 2;
  final xmpSpans = <(int, int)>[]; // 已有 XMP APP1 段的 [start, end)
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) break; // 熵编码数据开始,扫描止步
    final marker = jpeg[pos + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) break; // 无长度段
    final segLen = jpeg[pos + 2] << 8 | jpeg[pos + 3];
    if (segLen < 2 || pos + 2 + segLen > jpeg.length) break;
    if (marker == 0xE0 && insertAt == pos) {
      insertAt = pos + 2 + segLen; // APP0(JFIF)之后插
    } else if (marker == 0xE1 &&
        segLen > _kXmpApp1Header.length &&
        _hasPrefix(jpeg, pos + 4, _kXmpApp1Header)) {
      xmpSpans.add((pos, pos + 2 + segLen));
    }
    pos += 2 + segLen;
  }
  // 先移除旧 XMP 段(替换语义),再按原 insertAt 减去前方被删长度。
  var cleaned = jpeg;
  var shift = 0;
  for (final (start, end) in xmpSpans) {
    cleaned = Uint8List.fromList([
      ...cleaned.sublist(0, start - shift),
      ...cleaned.sublist(end - shift),
    ]);
    if (end <= insertAt) shift = end - start + shift;
  }
  final insertPos = insertAt - shift;
  // 新段:FFE1 + u16 段长(含自身,大端)+ 命名空间头 + XMP 包。
  // 包体按 UTF-8 编码(作者/版权可含中文,codeUnits 会把 >0xFF 截断)。
  final packetBytes = utf8.encode(buildXmpPacket(meta));
  final segLen = 2 + _kXmpApp1Header.length + packetBytes.length;
  final out = BytesBuilder(copy: false)
    ..add(cleaned.sublist(0, insertPos))
    // JPEG 段长是大端(ByteWriter 是 PTP 小端,勿用)。
    ..add([0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF])
    ..add(_kXmpApp1Header)
    ..add(packetBytes)
    ..add(cleaned.sublist(insertPos));
  return out.toBytes();
}

/// 十进制度 → XMP GPS 文本 `D,M.mmmmH`(如 `50,46.7382N`)。
String _gpsCoord(double value, String positive, String negative) {
  final hemi = value >= 0 ? positive : negative;
  final abs = value.abs();
  final degrees = abs.floor();
  final minutes = (abs - degrees) * 60;
  return '$degrees,${minutes.toStringAsFixed(4)}$hemi';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

bool _hasPrefix(Uint8List bytes, int offset, List<int> prefix) {
  if (offset + prefix.length > bytes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[offset + i] != prefix[i]) return false;
  }
  return true;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/media/xmp_metadata.dart';

/// XMP APP1 段命名空间头(与实现同款:小端问题勿扰,这里是字节常量)。
final List<int> kXmpHeader = [...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0];

/// 最小合法 JFIF APP0:FF E0 0010 + 'JFIF\0' + 01 01 + 0001 0001 + 0000。
const List<int> kApp0 = [
  0xFF, 0xE0, 0x00, 0x10, //
  0x4A, 0x46, 0x49, 0x46, 0x00, // JFIF\0
  0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
];

Uint8List _jpeg([List<List<int>> segments = const []]) => Uint8List.fromList([
      0xFF, 0xD8, // SOI
      ...kApp0,
      for (final seg in segments) ...seg,
      0xFF, 0xDA, 0x00, 0x02, // SOS(空段,扫描止步即可)
      0x12, 0x34, 0x56, 0x78, // 假熵编码数据
      0xFF, 0xD9, // EOI
    ]);

/// 预置一个旧 XMP APP1 段(替换语义测试用)。
List<int> _xmpSegment(String packet) {
  final bytes = packet.codeUnits;
  final segLen = 2 + kXmpHeader.length + bytes.length;
  return [
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, //
    ...kXmpHeader, ...bytes,
  ];
}

/// 取 [jpeg] 中所有 XMP APP1 段的包文本。
List<String> _xmpPackets(Uint8List jpeg) {
  final out = <String>[];
  var pos = 2;
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) break;
    final marker = jpeg[pos + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) break;
    final segLen = jpeg[pos + 2] << 8 | jpeg[pos + 3];
    if (marker == 0xE1 &&
        segLen > kXmpHeader.length &&
        jpeg.sublist(pos + 4, pos + 4 + kXmpHeader.length).toString() ==
            kXmpHeader.toString()) {
      out.add(utf8.decode(
          jpeg.sublist(pos + 4 + kXmpHeader.length, pos + 2 + segLen)));
    }
    pos += 2 + segLen;
  }
  return out;
}

void main() {
  test('buildXmpPacket:四字段齐发,XML 转义与 GPS 格式', () {
    final packet = buildXmpPacket(const XmpMetadata(
      creator: 'Aha & <Studio>',
      rights: '© 2026',
      rating: 4,
      latitude: 50.778966,
      longitude: -1.354411,
    ));
    expect(packet, startsWith('<?xpacket begin='));
    expect(packet, endsWith('<?xpacket end="w"?>\n'));
    expect(packet, contains('<dc:creator><rdf:Seq><rdf:li>'
        'Aha &amp; &lt;Studio&gt;</rdf:li></rdf:Seq></dc:creator>'));
    expect(packet, contains('<dc:rights><rdf:Alt><rdf:li xml:lang="x-default">'
        '© 2026</rdf:li></rdf:Alt></dc:rights>'));
    expect(packet, contains('<xmp:Rating>4</xmp:Rating>'));
    expect(packet, contains('<exif:GPSLatitude>50,46.7380N</exif:GPSLatitude>'));
    expect(packet, contains('<exif:GPSLongitude>1,21.2647W</exif:GPSLongitude>'));
  });

  test('buildXmpPacket:部分字段只出现已给项', () {
    final packet = buildXmpPacket(const XmpMetadata(rating: 2));
    expect(packet, contains('<xmp:Rating>2</xmp:Rating>'));
    expect(packet, isNot(contains('dc:creator')));
    expect(packet, isNot(contains('GPSLatitude')));
  });

  test('注入:新段插在 APP0 之后,段长大端、包体完整、原字节不损', () {
    final src = _jpeg();
    final out = injectXmpIntoJpeg(src, const XmpMetadata(creator: 'Aha'));

    // 前缀 SOI+APP0 原样、XMP 段紧跟其后
    expect(out.sublist(0, 2 + kApp0.length), src.sublist(0, 2 + kApp0.length));
    final segStart = 2 + kApp0.length;
    expect(out[segStart], 0xFF);
    expect(out[segStart + 1], 0xE1);
    final segLen = out[segStart + 2] << 8 | out[segStart + 3];
    expect(out.length, src.length + 2 + segLen); // 净增 = 整段
    // 包文本可从段边界完整切出
    final packets = _xmpPackets(out);
    expect(packets, hasLength(1));
    expect(packets.single, buildXmpPacket(const XmpMetadata(creator: 'Aha')));
    // EOI 仍收尾
    expect(out[out.length - 2], 0xFF);
    expect(out[out.length - 1], 0xD9);
  });

  test('替换语义:已有 XMP 段被替换,不残留双段', () {
    final oldSeg = _xmpSegment('<x:xmpmeta>OLD</x:xmpmeta>');
    final src = _jpeg([oldSeg]);
    final out = injectXmpIntoJpeg(src, const XmpMetadata(creator: 'New'));

    final packets = _xmpPackets(out);
    expect(packets, hasLength(1)); // 不是追加,是替换
    expect(packets.single, contains('New'));
    expect(packets.single, isNot(contains('OLD')));
    // 长度 = 原 JPEG - 旧段 + 新段(包体按 UTF-8 计长)。
    final newPacket = buildXmpPacket(const XmpMetadata(creator: 'New'));
    expect(out.length,
        src.length - oldSeg.length + (4 + kXmpHeader.length + utf8.encode(newPacket).length));
  });

  test('非 JPEG / 空元数据:原实例直返(零拷贝)', () {
    final notJpeg = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
    expect(identical(injectXmpIntoJpeg(notJpeg, const XmpMetadata(rating: 3)), notJpeg),
        isTrue);

    final jpeg = _jpeg();
    expect(identical(injectXmpIntoJpeg(jpeg, const XmpMetadata()), jpeg), isTrue);
    expect(
        identical(
            injectXmpIntoJpeg(jpeg, const XmpMetadata(rating: 0)), jpeg),
        isTrue);
  });
}

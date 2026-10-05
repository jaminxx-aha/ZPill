import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/media/motion_photo.dart';

/// XMP APP1 段头(标准 xap 命名空间 + 结尾 NUL),与实现同源。
final List<int> _kHeader = [...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0];

/// 合成 JPEG:SOI + APP0 + XMP APP1 + SOS + 伪熵数据 + EOI(不要求可解码,
/// 拆分器只走段结构)。
Uint8List _xmpJpeg(String packet) {
  final body = utf8.encode(packet);
  final segLen = _kHeader.length + body.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, 0xE0, 0x00, 0x10,
    ...'JFIF'.codeUnits, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xE1, segLen >> 8, segLen & 0xFF, ..._kHeader, ...body,
    0xFF, 0xDA, 0x00, 0x02,
    0x12, 0x34, 0x56, 0x78,
    0xFF, 0xD9,
  ]);
}

/// 无 XMP 的普通 JPEG(走 APP0 → SOS,拆分器应止步于 SOS)。
Uint8List _plainJpeg() => Uint8List.fromList([
      0xFF, 0xD8,
      0xFF, 0xE0, 0x00, 0x10,
      ...'JFIF'.codeUnits, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xFF, 0xDA, 0x00, 0x02,
      0x12, 0x34, 0x56, 0x78,
      0xFF, 0xD9,
    ]);

String _microXmp(int offset) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/" '
    'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">'
    '<GCamera:MicroVideoOffset>$offset</GCamera:MicroVideoOffset></x:xmpmeta>';

String _containerXmp(int length, {bool lengthFirst = false}) {
  final attrs = lengthFirst
      ? 'Item:Length="$length" Item:Semantic="Motion"'
      : 'Item:Semantic="Motion" Item:Length="$length"';
  return '<x:xmpmeta xmlns:x="adobe:ns:meta/" '
      'xmlns:Container="http://ns.google.com/photos/1.0/container/">'
      '<Container:Directory><rdf:Bag '
      'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
      '<Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>'
      '<Container:Item $attrs Item:Mime="video/mp4"/>'
      '</rdf:Bag></Container:Directory></x:xmpmeta>';
}

/// 最小 MP4:ftyp box,16 字节(box 长度合法 + 已知类型)。
Uint8List _mp4() => Uint8List.fromList([
      0, 0, 0, 16, ...'ftyp'.codeUnits,
      ...'isom'.codeUnits, 0, 0, 0, 0,
    ]);

void main() {
  final mp4 = _mp4();

  test('MicroVideoOffset:静帧原样剥离,视频 = 尾段', () {
    final jpeg = _xmpJpeg(_microXmp(mp4.length));
    final file = Uint8List.fromList([...jpeg, ...mp4]);

    final split = splitMotionPhoto(file);

    expect(split, isNotNull);
    expect(split!.image, jpeg);
    expect(split.video, mp4);
  });

  test('MicroVideoOffset 属性式(RDF 属性序列化)也拆得出', () {
    const packet = '<rdf:RDF '
        'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
        'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">'
        '<rdf:Description rdf:about="" GCamera:MicroVideoOffset="16"/>'
        '</rdf:RDF>';
    final file = Uint8List.fromList([..._xmpJpeg(packet), ...mp4]);

    final split = splitMotionPhoto(file);

    expect(split, isNotNull);
    expect(split!.video, mp4);
  });

  test('Container Item(Semantic=Motion + Length):两种属性顺序都拆得出', () {
    for (final lengthFirst in [false, true]) {
      final jpeg =
          _xmpJpeg(_containerXmp(mp4.length, lengthFirst: lengthFirst));
      final file = Uint8List.fromList([...jpeg, ...mp4]);

      final split = splitMotionPhoto(file);

      expect(split, isNotNull, reason: 'lengthFirst=$lengthFirst');
      expect(split!.image, jpeg);
      expect(split.video, mp4);
    }
  });

  test('Container 多项共存:只取 Motion 项的 Length(Primary 项不干扰)', () {
    // Primary 项在前且带自己的 Length(静帧长度);Motion 项在后。
    // 若解析不按块绑定,会拿 Primary 的长度把拆点切进静帧中间。
    final packet = _containerXmp(mp4.length)
        .replaceFirst('Item:Semantic="Primary" Item:Mime="image/jpeg"',
            'Item:Semantic="Primary" Item:Length="40" Item:Mime="image/jpeg"');
    final file = Uint8List.fromList([..._xmpJpeg(packet), ...mp4]);

    final split = splitMotionPhoto(file);

    expect(split, isNotNull);
    expect(split!.video, mp4);
  });

  test('新旧标记同存:MicroVideoOffset 优先(Container 值故意给错)', () {
    // 新标记值越界(拆点吞掉静帧);旧标记正确 → 旧标记先匹配才能拆出。
    final packet = '${_microXmp(mp4.length)}${_containerXmp(99999)}';
    final file = Uint8List.fromList([..._xmpJpeg(packet), ...mp4]);

    final split = splitMotionPhoto(file);

    expect(split, isNotNull);
    expect(split!.video, mp4);
  });

  test('防御:普通 JPEG / 无标记 / 越界拆点 / 尾段非 MP4 → null', () {
    // 普通 JPEG(无 XMP)
    expect(splitMotionPhoto(_plainJpeg()), isNull);
    // XMP 但无视频标记
    expect(splitMotionPhoto(_xmpJpeg('<x:xmpmeta xmlns:x="adobe:ns:meta/"/>')),
        isNull);
    // 偏移 0:拆点 = 文件尾(视频段 < 8 字节)
    expect(
        splitMotionPhoto(
            Uint8List.fromList([..._xmpJpeg(_microXmp(0)), ...mp4])),
        isNull);
    // 偏移吞掉整个静帧(< 32 字节)
    expect(
        splitMotionPhoto(Uint8List
            .fromList([..._xmpJpeg(_microXmp(0xFFFFFF)), ...mp4])),
        isNull);
    // box 长度合法但类型未知
    final junk = Uint8List.fromList(
        [0, 0, 0, 16, ...'XXXX'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(
        splitMotionPhoto(
            Uint8List.fromList([..._xmpJpeg(_microXmp(16)), ...junk])),
        isNull);
    // box 长度本身越界(全 0x41)
    final noBox = Uint8List.fromList(List.filled(16, 0x41));
    expect(
        splitMotionPhoto(
            Uint8List.fromList([..._xmpJpeg(_microXmp(16)), ...noBox])),
        isNull);
  });

  test('非 JPEG(过短 / 无段结构)→ null', () {
    expect(splitMotionPhoto(Uint8List.fromList([1, 2, 3])), isNull);
    expect(splitMotionPhoto(Uint8List.fromList(List.filled(64, 0xFF))), isNull);
  });

  test('splice → split 往返:视频恒等,静帧可再拆(幂等)', () {
    final photo = img.Image(width: 40, height: 30);
    for (final p in photo) {
      p
        ..r = (p.x * 6) & 0xFF
        ..g = (p.y * 8) & 0xFF
        ..b = 128
        ..a = 255;
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(photo));

    final spliced = spliceMotionPhoto(jpeg, mp4);
    final split = splitMotionPhoto(spliced);

    expect(split, isNotNull);
    expect(split!.video, mp4);
    // 拆出的静帧已带 XMP 标记;再拼一次 = 原样(injectXmpApp1 原位替换同包)
    expect(spliceMotionPhoto(split.image, split.video), spliced);
  });

  test('injectXmpApp1:无 XMP 插在 SOI 后,原段整体后移', () {
    final plain = _plainJpeg();
    final packet = _microXmp(16);

    final injected = injectXmpApp1(plain, packet);

    expect(injected[0], 0xFF);
    expect(injected[1], 0xD8);
    expect(injected[2], 0xFF); // APP1 紧跟 SOI
    expect(injected[3], 0xE1);
    final segLen = _kHeader.length + utf8.encode(packet).length + 2;
    expect(injected.length, plain.length + 2 + segLen);
    expect(injected.sublist(4 + segLen), plain.sublist(2)); // 原内容原样后移
  });

  test('injectXmpApp1:已有 XMP APP1 原位替换(旧包不残留)', () {
    final withOld =
        _xmpJpeg('<x:xmpmeta xmlns:x="adobe:ns:meta/">OLD</x:xmpmeta>');

    final replaced = injectXmpApp1(withOld, _microXmp(16));

    final text = utf8.decode(replaced, allowMalformed: true);
    expect(text, contains('MicroVideoOffset'));
    expect(text, isNot(contains('OLD')));
  });

  test('injectXmpApp1:非 JPEG 原样直返', () {
    final notJpeg = Uint8List.fromList([9, 9, 9, 9]);
    expect(identical(injectXmpApp1(notJpeg, 'x'), notJpeg), isTrue);
  });
}

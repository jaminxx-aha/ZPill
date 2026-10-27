import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/media/nef_thumb.dart';

/// 最小 NEF 合成:II/MM TIFF 头 + IFD0(宽/高/方向/JPEG 偏移/长度)+
/// 填充 + 内嵌缩略载荷。结构对齐 Zf NEF(II、IFD0@8、条目升序)。
/// [orientation] 传 null = 条目缺省(真机 NEF 罕见,护栏用)。
Uint8List _nefWithThumb({
  required Uint8List thumb,
  int? orientation = 1,
  bool little = true,
  bool withThumb = true,
  int pad = 64,
  bool truncateTail = false,
}) {
  final entries = <(int, int, int)>[]; // (tag, type, value)
  entries.add((0x0100, 4, 160)); // width
  entries.add((0x0101, 4, 120)); // height
  if (orientation != null) {
    entries.add((0x0112, 3, orientation)); // Orientation(SHORT)
  }
  if (withThumb) {
    entries.add((0x0201, 4, 0)); // 偏移(合成时直写真值)
    entries.add((0x0202, 4, thumb.length));
  }
  entries.sort((a, b) => a.$1.compareTo(b.$1)); // TIFF 条目须升序
  const ifdOffset = 8;
  final ifdSize = 2 + entries.length * 12 + 4;
  final thumbOffset = ifdOffset + ifdSize + pad;
  final total = thumbOffset + (withThumb ? thumb.length : 0);
  final out = Uint8List(truncateTail ? total - 2 : total);
  final d = ByteData.view(out.buffer);
  final en = little ? Endian.little : Endian.big;
  out[0] = little ? 0x49 : 0x4D;
  out[1] = little ? 0x49 : 0x4D;
  d.setUint16(2, 42, en);
  d.setUint32(4, ifdOffset, en);
  d.setUint16(ifdOffset, entries.length, en);
  for (var i = 0; i < entries.length; i++) {
    final e = ifdOffset + 2 + i * 12;
    final (tag, type, value) = entries[i];
    d.setUint16(e, tag, en);
    d.setUint16(e + 2, type, en);
    d.setUint32(e + 4, 1, en); // count
    // TIFF 值域左对齐:SHORT(3) 占前 2 字节,LONG(4) 占满 4 字节。
    if (tag == 0x0201) {
      d.setUint32(e + 8, thumbOffset, en);
    } else if (type == 3) {
      d.setUint16(e + 8, value, en);
    } else {
      d.setUint32(e + 8, value, en);
    }
  }
  d.setUint32(ifdOffset + 2 + entries.length * 12, 0, en); // next IFD
  for (var i = ifdOffset + ifdSize; i < thumbOffset; i++) {
    out[i] = 0xAB; // IFD 与缩略之间的填充
  }
  if (withThumb && !truncateTail) {
    out.setRange(thumbOffset, thumbOffset + thumb.length, thumb);
  }
  return out;
}

/// 4 字节裸 JPEG(SOI+EOI):提取器只验结构标记,不解码。
const _bareJpeg = [0xFF, 0xD8, 0xFF, 0xD9];

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nef_thumb_test');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  Future<NefEmbeddedThumb?> extract(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync(bytes);
    return extractNefEmbeddedThumb(f.path);
  }

  test('II 小端:内嵌缩略与方向一并带回', () async {
    final t = await extract(
        'a.nef', _nefWithThumb(thumb: Uint8List.fromList(_bareJpeg), orientation: 8));
    expect(t, isNotNull);
    expect(t!.jpeg, _bareJpeg);
    expect(t.orientation, 8);
  });

  test('MM 大端同构可解(方向 1)', () async {
    final t = await extract(
        'a.nef', _nefWithThumb(thumb: Uint8List.fromList(_bareJpeg), little: false));
    expect(t, isNotNull);
    expect(t!.orientation, 1);
  });

  test('方向条目缺省回 0(注入函数裁决无转正含义)', () async {
    final t = await extract(
        'a.nef', _nefWithThumb(thumb: Uint8List.fromList(_bareJpeg), orientation: null));
    expect(t, isNotNull);
    expect(t!.orientation, 0);
  });

  test('非 TIFF 载荷回 null(垃圾字节/空文件)', () async {
    expect(await extract('a.nef', [1, 2, 3]), isNull);
    expect(await extract('a.nef', <int>[]), isNull);
  });

  test('无 0x0201 条目回 null', () async {
    final t = await extract('a.nef',
        _nefWithThumb(thumb: Uint8List.fromList(_bareJpeg), withThumb: false));
    expect(t, isNull);
  });

  test('载荷非 JPEG(SOI/EOI 标记不符)回 null', () async {
    final t = await extract(
        'a.nef', _nefWithThumb(thumb: Uint8List.fromList([1, 2, 3, 4, 5, 6])));
    expect(t, isNull);
  });

  test('缩略段越界(尾截后头声明长度超出文件)回 null', () async {
    final t = await extract('a.nef',
        _nefWithThumb(thumb: Uint8List.fromList(_bareJpeg), truncateTail: true));
    expect(t, isNull);
  });
}

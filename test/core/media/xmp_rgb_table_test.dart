import 'dart:io' show ZLibEncoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/media/cube_lut.dart';
import 'package:z_pill/core/media/xmp_rgb_table.dart';

/// XMP RGBTable 解码链测试。向量全部独立合成:测试侧自带编码器
/// (delta→zlib→base85),语义锚点是不依赖任何实现的手算 base85 向量。

// ── 测试侧编码器(与 lib 各自独立实现;字母表语义由下方手算向量
//    硬编码锚定,编码器引用 lib 的 kZ85Alphabet 不构成循环论证)────

/// Z85 小端 base85 编码(每 4 字节一组 → 5 数位,首数位最低;尾组
/// n 字节 → n+1 数位)。
String encodeBase85(List<int> bytes) {
  final sb = StringBuffer();
  for (var o = 0; o < bytes.length; o += 4) {
    final count = math.min(4, bytes.length - o);
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= bytes[o + i] << (8 * i);
    }
    for (var i = 0; i < count + 1; i++) {
      sb.write(kZ85Alphabet[value % 85]);
      value ~/= 85;
    }
  }
  return sb.toString();
}

/// 载荷(16 字节头 + 小端 int16 增量)→ [4 字节小端长度][zlib 流]。
Uint8List pack(Uint8List payload) {
  final z = ZLibEncoder().convert(payload);
  final out = Uint8List(4 + z.length);
  ByteData.sublistView(out).setUint32(0, payload.length, Endian.little);
  out.setAll(4, z);
  return out;
}

/// 组装载荷:头 (1,1,3,N) + [deltas](N³×3 个,由调用方保证)。
Uint8List payloadOf(int size, List<int> deltas) {
  final bd = ByteData(16 + deltas.length * 2);
  bd
    ..setInt32(0, 1, Endian.little)
    ..setInt32(4, 1, Endian.little)
    ..setInt32(8, 3, Endian.little)
    ..setInt32(12, size, Endian.little);
  for (var i = 0; i < deltas.length; i++) {
    bd.setInt16(16 + i * 2, deltas[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

/// 按格式规范独立重写的恒等表:identity[i] = (i·65535 + N÷2) ÷ (N−1)。
/// (测试与 lib 各自表述同一规范,互为对照。)
List<int> identityRamp(int n) =>
    List<int>.generate(n, (i) => (i * 0xffff + (n >> 1)) ~/ (n - 1));

/// 值下标(红最快;i = cell×3+通道)对应的恒等表项。
int identityAt(int n, int i) {
  final cell = i ~/ 3, ch = i % 3;
  final r = cell % n, g = (cell ~/ n) % n, b = cell ~/ (n * n);
  return identityRamp(n)[ch == 0 ? r : (ch == 1 ? g : b)];
}

/// 模 65536 折进 int16 有符号域。
int signed16(int v) {
  v &= 0xffff;
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// 目标绝对值(N³×3,红最快输出序)→ int16 增量流。注意流序是参考
/// 实现的读取序(r 外层、b 内层)—— 与输出序(红最快)不同,恰为
/// 格点下标的进制位置换(编码侧必须做这次重排,解码链才闭环)。
List<int> deltasFor(int n, List<int> targets) {
  final deltas = List<int>.filled(targets.length, 0);
  var k = 0;
  for (var r = 0; r < n; r++) {
    for (var g = 0; g < n; g++) {
      for (var b = 0; b < n; b++) {
        final i = ((b * n + g) * n + r) * 3; // 该格点在输出序中的下标
        for (var ch = 0; ch < 3; ch++) {
          deltas[k * 3 + ch] =
              signed16(targets[i + ch] - identityAt(n, i + ch));
        }
        k++;
      }
    }
  }
  return deltas;
}

/// 属性式 XMP:[tableValue] 进 `crs:Table_<id>`;[rgbTableId] 缺省走
/// Table_* 回落;[otherTable] 追加干扰表;[quote] 切换属性引号风格。
String xmpAttr(String tableValue,
        {String? rgbTableId, String? otherTable, String quote = '"'}) =>
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '  <rdf:Description rdf:about=""\n'
    '    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"\n'
    '${rgbTableId == null ? '' : '    crs:RGBTable=$quote$rgbTableId$quote\n'}'
    '    crs:Table_${rgbTableId ?? 'x'}=$quote$tableValue$quote'
    '${otherTable == null ? '' : ' crs:Table_other=$quote$otherTable$quote'}/>\n'
    ' </rdf:RDF>\n'
    '</x:xmpmeta>\n'
    '<?xpacket end="w"?>\n';

/// 一条现成的 N=2 全零增量表(identity 依公式为 [1, 0],两处 quirk 都
/// 踩到;测试侧编码器生成后固化字面量)。
const kTinyTable = ':0000OcImwM!emwO1/)wKOJQvZ2100H6SM2';

void main() {
  group('base85(Z85 小端)—— 手算向量,不依赖实现', () {
    test('4 字节组:0x04030201 → 数位 [10,60,50,24,1] → aYOo1', () {
      // 0x04030201 = 67305985;小端数位 67305985 = 10 + 60·85 + 50·85²
      // + 24·85³ + 1·85⁴;查 Z85 表:'a','Y','O','o','1'。
      expect(decodeBase85Z85('aYOo1'), [1, 2, 3, 4]);
    });

    test("大小写敏感:'o'(24)与 'O'(50) 是不同数位", () {
      // aYoO1(小写 o 在前)= 10 + 60·85 + 24·85² + 50·85³ + 1·85⁴
      // = 83085385 = 0x04F3C849。
      expect(decodeBase85Z85('aYoO1'), [0x49, 0xC8, 0xF3, 0x04]);
    });

    test('尾组:3 字节 → 4 数位;1 字节 → 2 数位', () {
      // 0x030201 = 197121 = 6 + 24·85 + 27·85² + 0·85³ → "6or0";
      // 单字节 0x01 → 数位 [1,0] → "10"。
      expect(decodeBase85Z85('6or0'), [1, 2, 3]);
      expect(decodeBase85Z85('10'), [1]);
    });

    test("'z' 是普通数位(35),不是 Ascii85 的零组简写", () {
      // zz = 35 + 35·85 = 3010 → 单字节 0xC2(高位按尾组规则丢弃)。
      expect(decodeBase85Z85('zz'), [0xC2]);
    });

    test('非法字符跳过:空白/换行/Ascii85 包裹符 <~ ~>', () {
      expect(decodeBase85Z85('<~ aYOo1 ~>'), [1, 2, 3, 4]);
      expect(decodeBase85Z85('aY\n Oo1\t'), [1, 2, 3, 4]);
      expect(decodeBase85Z85('aY,O;o1'), [1, 2, 3, 4]); // , ; 不在字母表
      expect(decodeBase85Z85(''), isEmpty);
      expect(decodeBase85Z85('啊'), isEmpty); // 非 ASCII 跳过
      expect(decodeBase85Z85('a'), isEmpty); // 孤数位无贡献
    });
  });

  group('全链:零增量 = 恒等表', () {
    test('N=3 恒等锚点:0 / 32768 / 65535', () {
      final table = parseXmpRgbTable(xmpAttr(
          encodeBase85(pack(payloadOf(3, List.filled(27 * 3, 0)))),
          rgbTableId: 't'));
      expect(table.size, 3);
      expect(table.values.length, 27 * 3);
      // 格点 (r,g,b):值 = identity[r/g/b](红最快:输出下标 3 是
      // (1,0,0) 的 R、9 是 (0,1,0) 的 G、27 是 (0,0,1) 的 B)。
      expect(table.values.sublist(0, 3), [0, 0, 0]);
      expect(table.values.sublist(3, 6), [32768, 0, 0]); // identity[1] = (65535+1)~/2
      expect(table.values.sublist(6, 9), [65535, 0, 0]); // (2,0,0):identity[2]
      expect(table.values.sublist(9, 12), [0, 32768, 0]); // (0,1,0):G 通道
      expect(table.values.sublist(27, 30), [0, 0, 32768]); // (0,0,1):B 通道
      expect(table.values.sublist(table.values.length - 3),
          [65535, 65535, 65535]); // (2,2,2) 顶角
    });

    test('N=2 恒等 quirk:identity = [1, 0](对齐参考实现)', () {
      final table = parseXmpRgbTable(xmpAttr(kTinyTable, rgbTableId: 't'));
      expect(table.size, 2);
      // identity[i] = (i·65535 + N÷2) ÷ (N−1):i=0 → (0+1)÷1 = 1(被
      // 取整项抬高);i=1 → 65536,& 0xFFFF 回绕成 0。两端都反直觉,
      // 参考实现既有行为,原样对齐。
      expect(table.values.sublist(0, 3), [1, 1, 1]); // (0,0,0):identity[0]
      expect(table.values.sublist(table.values.length - 3), [0, 0, 0]); // (1,1,1)
    });

    test('toCubeLut:恒等表三线性回输入,域 0..1', () {
      final lut = parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(payloadOf(3, List.filled(27 * 3, 0)))),
              rgbTableId: 't'))
          .toCubeLut();
      expect(lut.size, 3);
      expect(lut.title, 'XMP LUT');
      // 中点精确命中格点 (1,1,1) → 32768/65535。
      for (final v in lut.apply(0.5, 0.5, 0.5)) {
        expect(v, closeTo(32768 / 65535, 1e-6));
      }
      expect(lut.apply(1, 1, 1), [1.0, 1.0, 1.0]);
      expect(lut.apply(0, 0, 0), [0.0, 0.0, 0.0]);
    });
  });

  group('全链:非零增量逐值断言(方向/回绕/通道序)', () {
    test('N=4 伪随机目标表:解出的每个值 == 目标(含回绕)', () {
      const n = 4;
      // 目标 = 确定性散布(乘大质数取模);特别埋两个回绕点:
      // (0,0,0) R(identity=0)目标 65530(存成 int16 即 -6,回绕回原值);
      // (3,0,0) R(identity[3]=65535)目标 5(存成 +6,回绕回原值)。
      final targets = List<int>.generate(n * n * n * 3, (i) {
        if (i == 0) return 65530; // (0,0,0) R:identity[0]=0
        if (i == ((0 * n + 0) * n + (n - 1)) * 3) {
          return 5; // (3,0,0) R:identity[n-1]=65535
        }
        return (i * 2654435761) & 0xffff;
      });
      final table = parseXmpRgbTable(xmpAttr(
          encodeBase85(pack(payloadOf(n, deltasFor(n, targets)))),
          rgbTableId: 't'));
      expect(table.size, n);
      // 逐值相等:增量方向(加)、恒等表、int16 小端、16 位回绕、
      // 红最快下标,任何一环错都会在此爆。
      for (var i = 0; i < targets.length; i++) {
        expect(table.values[i], targets[i], reason: '下标 $i');
      }
    });

    test('XMP → toCubeLut:格点精确命中目标值(往返闭环)', () {
      const n = 3;
      final targets = List<int>.generate(
          n * n * n * 3, (i) => ((i * 7 + 11) * 40503) & 0xffff);
      final lut = parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(payloadOf(n, deltasFor(n, targets)))),
              rgbTableId: 't'))
          .toCubeLut();
      for (var b = 0; b < n; b++) {
        for (var g = 0; g < n; g++) {
          for (var r = 0; r < n; r++) {
            final i = ((b * n + g) * n + r) * 3;
            final out = lut.apply(r / (n - 1), g / (n - 1), b / (n - 1));
            for (var ch = 0; ch < 3; ch++) {
              expect(out[ch], closeTo(targets[i + ch] / 65535, 1e-5),
                  reason: '格点 ($r,$g,$b) 通道 $ch');
            }
          }
        }
      }
    });
  });

  group('坏数据 → FormatException', () {
    test('坏 base85:全非字母表字符 → 解出不足 4 字节', () {
      // , ; 均不在 Z85 字母表,解出 0 字节,连长度前缀都凑不齐。
      expect(() => parseXmpRgbTable(xmpAttr(',;;', rgbTableId: 't')),
          throwsA(isA<FormatException>()));
    });

    test('坏 zlib:头部垃圾 → 压缩数据损坏', () {
      final garbage = Uint8List(20)..[4] = 0x90; // 前 4 字节长度前缀,后为坏流
      ByteData.sublistView(garbage).setUint32(0, 100, Endian.little);
      expect(
          () => parseXmpRgbTable(
              xmpAttr(encodeBase85(garbage), rgbTableId: 't')),
          throwsA(isA<FormatException>()));
    });

    test('zlib 截断/长度前缀不符/长度域外', () {
      final payload = payloadOf(2, List.filled(24, 0));
      final packed = pack(payload);
      // 截断流:必须截进数据本体才掉长度(本载荷 zlib 段 24 字节,截
      // 1..5 只丢校验和/收尾字节,dart 解码器仍给全量输出 —— 解出的值
      // 与完整流一致,无害;截 6 起输出掉到 14 字节)→ 长度不符。
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(
                  Uint8List.fromList(packed.sublist(0, packed.length - 6))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      // 前缀声明长度 +1:解压成功但长度不符。
      final wrongLen = Uint8List.fromList(packed);
      ByteData.sublistView(wrongLen)
          .setUint32(0, payload.length + 1, Endian.little);
      expect(
          () => parseXmpRgbTable(
              xmpAttr(encodeBase85(wrongLen), rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      // 前缀声明 0(域外)。
      final zeroLen = Uint8List.fromList(packed);
      ByteData.sublistView(zeroLen).setUint32(0, 0, Endian.little);
      expect(
          () => parseXmpRgbTable(
              xmpAttr(encodeBase85(zeroLen), rgbTableId: 't')),
          throwsA(isA<FormatException>()));
    });

    test('载荷头/维度荒谬:版本错、N=1、N=66、增量不足', () {
      Uint8List withHeader(int v1, int v2, int v3, int n, int cellBytes) {
        final bd = ByteData(16 + cellBytes);
        bd
          ..setInt32(0, v1, Endian.little)
          ..setInt32(4, v2, Endian.little)
          ..setInt32(8, v3, Endian.little)
          ..setInt32(12, n, Endian.little);
        return bd.buffer.asUint8List();
      }

      // 版本/通道数不对。
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(withHeader(2, 1, 3, 2, 48))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(withHeader(1, 1, 4, 2, 48))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      // 尺寸域外(先于立方计算拒绝,cellBytes 无关紧要)。
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(withHeader(1, 1, 3, 1, 0))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(withHeader(1, 1, 3, 66, 0))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      // N=2 声明但增量只够 4 格(需 8 格)。
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(withHeader(1, 1, 3, 2, 4 * 6))),
              rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      // 载荷不足 16 字节头。
      expect(
          () => parseXmpRgbTable(xmpAttr(
              encodeBase85(pack(Uint8List(10))), rgbTableId: 't')),
          throwsA(isA<FormatException>()));
    });

    test('输入护栏:>32MB 拒收', () {
      expect(() => parseXmpRgbTable('x' * (32 * 1024 * 1024 + 1)),
          throwsA(isA<FormatException>()));
    });
  });

  group('XXE 防护:DOCTYPE/ENTITY 拒收', () {
    test('外部实体文档拒收(即使表数据本身有效)', () {
      final xxe = xmpAttr(kTinyTable, rgbTableId: 't').replaceFirst(
          '<rdf:RDF',
          '<!DOCTYPE rdf:RDF [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>\n'
              '<rdf:RDF');
      expect(() => parseXmpRgbTable(xxe), throwsA(isA<FormatException>()));
    });

    test('大小写不敏感;注释里的 ENTITY 声明同样拒收', () {
      expect(() => parseXmpRgbTable('<!DoCtYpE x>\n<root/>'),
          throwsA(isA<FormatException>()));
      expect(() => parseXmpRgbTable('<!-- <!ENTITY e SYSTEM "x"> --><root/>'),
          throwsA(isA<FormatException>()));
    });
  });

  group('XMP 结构变体', () {
    test('RGBTable 与 Table_<id> 分居两个 Description', () {
      final table = parseXmpRgbTable(
          '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
          ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n'
          '          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">\n'
          '  <rdf:Description rdf:about="" crs:RGBTable="look42"/>\n'
          '  <rdf:Description rdf:about="" crs:Table_look42="$kTinyTable"/>\n'
          ' </rdf:RDF>\n'
          '</x:xmpmeta>\n');
      expect(table.size, 2);
    });

    test('无 RGBTable:回落首个 Table_* 属性;有 ID 时优先精确命中', () {
      // 无 ID:回落。
      expect(parseXmpRgbTable(xmpAttr(kTinyTable)).size, 2);
      // 有 ID 且存在干扰表:精确命中 Table_t,不误取 Table_other。
      final good = encodeBase85(pack(payloadOf(3, List.filled(81, 0))));
      final table = parseXmpRgbTable(
          xmpAttr(good, rgbTableId: 't', otherTable: kTinyTable));
      expect(table.size, 3);
      // ID 指向不存在的表:回落首个非空 Table_*(= good)。
      expect(
          parseXmpRgbTable(
                  xmpAttr(good, rgbTableId: 'missing', otherTable: kTinyTable))
              .size,
          3);
    });

    test('子元素式(exiftool 改写形态)+ 数字字符引用 ID', () {
      final enc = encodeBase85(pack(payloadOf(2, List.filled(24, 0))));
      final table = parseXmpRgbTable(
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
          ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n'
          '          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">\n'
          '  <rdf:Description rdf:about="">\n'
          '   <crs:RGBTable>&#65;</crs:RGBTable>\n'
          '   <crs:Table_A>$enc</crs:Table_A>\n'
          '  </rdf:Description>\n'
          ' </rdf:RDF>\n'
          '</x:xmpmeta>\n');
      expect(table.size, 2);
    });

    test('属性值折行(值内换行)照常解码;引号内 > 不误断标签尾', () {
      final enc = encodeBase85(pack(payloadOf(3, List.filled(81, 0))));
      // 值内每 10 字符折一行:base85 跳过换行,属性正则跨行取值。
      final wrapped =
          xmpAttr(enc.replaceAllMapped(RegExp(r'.{10}'), (m) => '${m[0]}\n'),
              rgbTableId: 't');
      expect(parseXmpRgbTable(wrapped).size, 3);

      final withGt = xmpAttr(enc, rgbTableId: 't')
          .replaceFirst('rdf:about=""', 'rdf:about="" note="a>b"');
      expect(parseXmpRgbTable(withGt).size, 3);
    });

    test("单引号值含 &apos; 实体:还原后照常解码(撇号=数位 73)", () {
      final enc = encodeBase85(pack(payloadOf(3, List.filled(81, 0))));
      // 撇号由构造保证:追加尾组 "D'0" = 字节 [100,24](值 6244 =
      // 39 + 73·85 + 0·85²);该尾组在 zlib 流之后,属尾随垃圾 ——
      // 与参考实现 inflater.finished() 语义一致地被容忍。
      final withApos = "${enc}D'0";
      expect(parseXmpRgbTable(xmpAttr(withApos, rgbTableId: 't')).size, 3);
      // 换成 &apos; 实体 + 单引号属性值:还原出撇号数位才能解回。
      final escaped = withApos.replaceAll("'", '&apos;');
      expect(
          parseXmpRgbTable(
              xmpAttr(escaped, rgbTableId: 't', quote: "'")).size,
          3);
    });

    test('无表可识别 → FormatException', () {
      expect(() => parseXmpRgbTable(xmpAttr('', rgbTableId: 't')),
          throwsA(isA<FormatException>()));
      expect(
          () => parseXmpRgbTable(
              '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
              ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
              '  <rdf:Description rdf:about=""/>\n'
              ' </rdf:RDF>\n'
              '</x:xmpmeta>\n'),
          throwsA(isA<FormatException>()));
    });
  });

  group('looksLikeXmp(导入分派)', () {
    test('XMP 标记命中;.cube 文本不命中', () {
      expect(looksLikeXmp(xmpAttr(kTinyTable, rgbTableId: 't')), isTrue);
      expect(looksLikeXmp('<?xpacket begin=""?>\n<x/>'), isTrue);
      expect(looksLikeXmp('<x:xmpmeta/>'), isTrue);
      expect(
          looksLikeXmp('TITLE "a"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n'
              '1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n'),
          isFalse);
      expect(looksLikeXmp('垃圾'), isFalse);
    });
  });

  group('CubeLut.fromTable', () {
    test('直接构造(0..1 域):格点精确命中', () {
      // 位置编码表:格点值 = 自身坐标(红最快),中点插值必回中点。
      final lut = CubeLut.fromTable('pos', 2, [
        0.0, 0.0, 0.0, //
        1.0, 0.0, 0.0, //
        0.0, 1.0, 0.0, //
        1.0, 1.0, 0.0, //
        0.0, 0.0, 1.0, //
        1.0, 0.0, 1.0, //
        0.0, 1.0, 1.0, //
        1.0, 1.0, 1.0, //
      ]);
      expect(lut.size, 2);
      expect(lut.title, 'pos');
      expect(lut.apply(1, 0, 0), [1.0, 0.0, 0.0]);
      expect(lut.apply(0.5, 0.5, 0.5), [0.5, 0.5, 0.5]);
    });

    test('畸形拒绝:坏尺寸/错长度/非有限值', () {
      expect(() => CubeLut.fromTable('t', 1, []),
          throwsA(isA<FormatException>()));
      expect(() => CubeLut.fromTable('t', 2, [1.0, 2.0, 3.0]),
          throwsA(isA<FormatException>()));
      expect(() => CubeLut.fromTable('t', 2, List.filled(24, double.nan)),
          throwsA(isA<FormatException>()));
    });
  });
}

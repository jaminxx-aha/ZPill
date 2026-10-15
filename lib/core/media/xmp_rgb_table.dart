/// Adobe XMP RGBTable 色彩表 → 3D LUT(图库编辑 LUT 导入,.xmp 与
/// .cube 并列)。
///
/// 格式语义(逆向自 Camera_Bridge 参考实现的 XMP 导入链;`crs:RGBTable`
/// 未见于 Adobe 官方文档与 ExifTool 标签库,以下按参考实现定案):
///
/// 1. **XMP 定位**:RDF `rdf:Description` 元素上 `crs:RGBTable="id"` 给
///    表 ID,`crs:Table_<id>` 属性携带编码数据(可分布在多个 Description);
///    无 `RGBTable` 时回落到首个非空 `Table_*` 属性。属性式之外亦接受等价
///    子元素式(`<crs:RGBTable>id</crs:RGBTable>`,exiftool 等工具会把
///    XMP 改写成这种形态)。
/// 2. **base85 = Z85 变体,不是 Ascii85**:字母表
///    `0-9a-zA-Z.-:+=^!/*?`'|()[]{}@%$#`(Z85,85 字符);85 进制**小端
///    数位序** —— 首字符是最低位(value += 数位×85^序),5 字符一组解出
///    4 字节(组内小端),尾组 n 字符解出 n−1 字节(孤数位无贡献)。
///    不在字母表内的字符(空白、换行,以及 Ascii85 的 `<~`/`~>` 包裹符)
///    一律跳过。无 z 简写('z' 在 Z85 中就是普通数位,不能当零组)。
/// 3. **压缩**:base85 解码结果 = [4 字节小端 u32 = 解压后长度][zlib 流];
///    解压输出必须与长度前缀精确相等(截断/超长都拒,长度只认 1..16M)。
///    无害差异:dart 的 ZLibDecoder 不校验流收尾,只丢掉尾部校验和的
///    截断仍能解出全量数据(值与完整流一致)才被容忍 —— 参考实现的
///    `finished()` 判定更严,但此类输入解出的表完全相同。
/// 4. **载荷**:小端 int32 头 ×4 = `(1, 1, 3, N)`;N = 每轴格点数
///    (2..65)。**真 3D 表**(N³ 格 × 3 通道,非 HueSatMap 型 2D 表),
///    故转 LUT 保原生 N 网格、不重采样 —— 重采样只会在三线性插值之上
///    量化有损,不会更准。随后 N³×3 个小端 int16 是**相对恒等表的增量
///    (delta),方向为加**,流序 r 外层、b 内层(与输出的红最快序不同,
///    恰为格点下标的进制位置换):`identity[i] = (i·65535 + N÷2) ÷ (N−1)`
///    (整除;N=2 时该表为 [1, 0] —— i=0 被取整项抬成 1、i=1 算出
///    65536 按 16 位回绕成 0,参考实现的既有行为,原样对齐),终值 =
///    `(delta + identity[通道格点]) & 0xFFFF`(16 位回绕),再 ÷65535
///    归一 0..1。通道序红最快(与 .cube 一致),域 0..1。
///
/// XXE 防护:不引 XML 解析器(最小文本抽取,顺带免去新依赖),不解析
/// 实体;入口直接**拒收**含 `<!DOCTYPE` / `<!ENTITY` 声明的文档(不安全
/// 声明无法无损剥除,拒收是与参考实现一致的等价且更强手段);提取到的
/// 值只做 5 个预定义字符实体与数字字符引用的还原,不触任何外部资源。
library;

import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'cube_lut.dart';

/// Z85 字母表(见 library 文档第 2 条;与 Ascii85 的 `!`–`u` 不同)。
const String kZ85Alphabet = '0123456789abcdefghijklmnopqrstuvwxyz'
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?'
    '`\'|()[]{}@%\$#';

/// 每码元的数位值(−1 = 非法,解码时跳过)。
final List<int> _z85Digits = _buildZ85Digits();

List<int> _buildZ85Digits() {
  final table = List<int>.filled(256, -1);
  var value = 0;
  for (final c in kZ85Alphabet.codeUnits) {
    table[c] = value++;
  }
  return table;
}

/// 剪贴板文本是否像 XMP(导入入口分派 .xmp / .cube 用):XMP 必有
/// rdf:Description(或 xpacket / x:xmpmeta 包标记),.cube 数据行不含
/// 这些串。
bool looksLikeXmp(String text) =>
    text.contains('rdf:Description') ||
    text.contains('x:xmpmeta') ||
    text.contains('<?xpacket');

/// 解析 XMP 文本里的 RGBTable(全链:拒 XXE → 抽表串 → base85 →
/// zlib → 增量还原)。格式不符抛 [FormatException](人话,调用方按导入
/// 失败提示)。
XmpRgbTable parseXmpRgbTable(String xmp) {
  if (xmp.length > 32 * 1024 * 1024) {
    throw const FormatException('XMP 文件过大(>32MB)');
  }
  _rejectXxe(xmp);
  final encoded = _extractTableData(xmp);
  return XmpRgbTable.fromPayload(
      _inflateLengthPrefixed(decodeBase85Z85(encoded)));
}

/// 解码完成的 RGB 色表:真 3D,每轴 [size] 格、每格 3 个 u16 绝对值
/// (恒等表 + 增量已还原),红最快(与 .cube 行序一致),值域 0..65535。
final class XmpRgbTable {
  const XmpRgbTable._(this.size, this.values);

  /// 每轴格点数 N(表共 N³ × 3 项)。
  final int size;

  /// N³ × 3 个 u16(红最快)。
  final Uint16List values;

  /// 解析解压后的载荷:16 字节头(4 × 小端 int32 = 1,1,3,N)+
  /// N³×3 个小端 int16 增量。头部/尺寸/长度不符 → FormatException。
  factory XmpRgbTable.fromPayload(Uint8List raw) {
    if (raw.length < 16) {
      throw const FormatException('XMP 表载荷不完整(不足 16 字节头)');
    }
    final bd = ByteData.sublistView(raw);
    final major = bd.getInt32(0, Endian.little);
    final minor = bd.getInt32(4, Endian.little);
    final channels = bd.getInt32(8, Endian.little);
    final size = bd.getInt32(12, Endian.little);
    if (major != 1 || minor != 1 || channels != 3) {
      throw FormatException(
          '不支持的 XMP RGB Table 头($major.$minor/$channels,应 1.1/3)');
    }
    // 先验域再算立方,防 int 溢出(N 声明值可达 2³¹)。
    if (size < 2 || size > 65) {
      throw FormatException('XMP 表尺寸 $size 超出 2..65');
    }
    final cells = size * size * size;
    if (raw.length - 16 < cells * 3 * 2) {
      throw const FormatException('XMP 表载荷不完整(增量数据不足)');
    }
    // 恒等表:i·65535 经 +N/2 再整除 (N−1) 取整;N=2 时为 [1, 0]
    // (i=0 被取整项抬成 1、i=1 的 65536 经 16 位回绕成 0 —— 参考
    // 实现的既有行为,原样对齐)。
    final identity = List<int>.generate(
        size, (i) => (i * 0xffff + (size >> 1)) ~/ (size - 1));
    final values = Uint16List(cells * 3);
    var o = 16;
    for (var r = 0; r < size; r++) {
      for (var g = 0; g < size; g++) {
        for (var b = 0; b < size; b++) {
          final i = ((b * size + g) * size + r) * 3;
          values[i] = (bd.getInt16(o, Endian.little) + identity[r]) & 0xffff;
          values[i + 1] =
              (bd.getInt16(o + 2, Endian.little) + identity[g]) & 0xffff;
          values[i + 2] =
              (bd.getInt16(o + 4, Endian.little) + identity[b]) & 0xffff;
          o += 6;
        }
      }
    }
    return XmpRgbTable._(size, values);
  }

  /// 转 3D LUT(0..1 域,红最快,保原生 N 网格)。
  CubeLut toCubeLut() {
    final table = Float32List(values.length);
    for (var i = 0; i < values.length; i++) {
      table[i] = values[i] / 65535;
    }
    return CubeLut.fromTable('XMP LUT', size, table);
  }
}

/// base85(Z85 变体)解码,语义见 library 文档第 2 条。
Uint8List decodeBase85Z85(String encoded) {
  const pow85 = [1, 85, 7225, 614125, 52200625];
  final out = BytesBuilder(copy: false);
  var value = 0;
  var phase = 0;
  for (final c in encoded.codeUnits) {
    if (c >= 256) continue; // 非 ASCII:按非法字符跳过
    final digit = _z85Digits[c];
    if (digit < 0) continue; // 空白/换行/包裹符:跳过(参考实现语义)
    value += digit * pow85[phase];
    if (++phase == 5) {
      out
        ..addByte(value & 0xff)
        ..addByte((value >> 8) & 0xff)
        ..addByte((value >> 16) & 0xff)
        ..addByte((value >> 24) & 0xff);
      value = 0;
      phase = 0;
    }
  }
  if (phase > 1) {
    for (var i = 0; i < phase - 1; i++) {
      out.addByte((value >> (8 * i)) & 0xff);
    }
  }
  return out.toBytes();
}

/// [4 字节小端长度前缀][zlib 流] 解压;输出须与前缀精确等长。
Uint8List _inflateLengthPrefixed(Uint8List packed) {
  if (packed.length < 4) {
    throw const FormatException('XMP 表数据不完整(不足 4 字节长度前缀)');
  }
  final expected = ByteData.sublistView(packed).getUint32(0, Endian.little);
  if (expected < 1 || expected > 16 * 1024 * 1024) {
    throw FormatException('XMP 表解压长度异常($expected,允许 1..16M)');
  }
  List<int> raw;
  try {
    raw = ZLibDecoder().convert(packed.sublist(4));
  } on FormatException catch (e) {
    throw FormatException('XMP 表压缩数据损坏(${e.message})');
  }
  if (raw.length != expected) {
    throw FormatException(
        'XMP 表解压长度不符:声明 $expected 字节,实得 ${raw.length}');
  }
  return Uint8List.fromList(raw);
}

// ── XMP 文本抽取(最小正则,不引 XML 解析器)──────────────────────────
// 注:正则一律用非原始字符串书写 —— Dart 原始串里 \' 不构成转义(反斜杠
// 保留、引号照常终结串),含单/双引号的模式只能显式转义。

/// 开标签(标签名 + 属性区;引号内的 `>` 不误断标签尾)。
final RegExp _kOpenTagPattern = RegExp(
    '<([A-Za-z_][\\w.-]*)(?::([A-Za-z_][\\w.-]*))?'
    '((?:"[^"]*"|\'[^\']*\'|[^>"\'])*)>');

/// 属性区内的单条属性(`前缀:名` 或裸名 = 双/单引号值)。
final RegExp _kAttrPattern = RegExp(
    '([A-Za-z_][\\w.-]*)(?::([A-Za-z_][\\w.-]*))?'
    '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')');

/// 子元素式 RGBTable / Table_*(内容无 `<`,Z85 串天然满足)。
final RegExp _kElemPattern = RegExp(
    '<([A-Za-z_][\\w.-]*):((?:RGBTable)|(?:Table_[A-Za-z0-9_.\\-]+))'
    '(?:\\s[^>]*)?>([^<]*)</[A-Za-z_][\\w.-]*:[A-Za-z_][\\w.-]*\\s*>');

/// 拒收含 DOCTYPE/ENTITY 声明的文档(XXE 防护,见 library 文档)。
void _rejectXxe(String xmp) {
  final lower = xmp.toLowerCase();
  if (lower.contains('<!doctype') || lower.contains('<!entity')) {
    throw const FormatException('XMP 含 DOCTYPE/ENTITY 声明,已拒收(XXE 防护)');
  }
}

/// 抽出表数据串。命中序(参考实现优先级 + 元素式扩展):
/// `Table_<id>` 属性 > 任意 `Table_*` 属性 > `Table_<id>` 元素 >
/// 任意 `Table_*` 元素;`<id>` 取首个非空 `RGBTable`。
String _extractTableData(String xmp) {
  // 属性式:只认局部名 Description 的开标签(参考实现只读
  // rdf:Description 的属性;文本抽取无法核对命名空间 URI,前缀不设限)。
  String? tableId;
  final tableAttrs = <(String, String)>[]; // (局部名, 值),文档序
  for (final tag in _kOpenTagPattern.allMatches(xmp)) {
    if ((tag.group(2) ?? tag.group(1)) != 'Description') continue;
    for (final a in _kAttrPattern.allMatches(tag.group(3) ?? '')) {
      final local = a.group(2) ?? a.group(1);
      if (local == null) continue;
      final value = _unescapeXml(a.group(3) ?? a.group(4) ?? '');
      if (local == 'RGBTable') {
        final id = value.trim();
        if (tableId == null && id.isNotEmpty) tableId = id;
      } else if (local.startsWith('Table_')) {
        tableAttrs.add((local, value));
      }
    }
  }
  // 元素式。
  String? elemId;
  final tableElems = <(String, String)>[];
  for (final e in _kElemPattern.allMatches(xmp)) {
    final value = _unescapeXml(e.group(3) ?? '');
    if (e.group(2) == 'RGBTable') {
      final id = value.trim();
      if (elemId == null && id.isNotEmpty) elemId = id;
    } else {
      tableElems.add((e.group(2)!, value));
    }
  }

  String? pickById(List<(String, String)> entries, String? id) {
    if (id == null) return null;
    for (final (name, value) in entries) {
      if (name == 'Table_$id' && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String? pickFirst(List<(String, String)> entries) {
    for (final (_, value) in entries) {
      if (value.trim().isNotEmpty) return value;
    }
    return null;
  }

  final encoded = pickById(tableAttrs, tableId) ??
      pickFirst(tableAttrs) ??
      pickById(tableElems, tableId ?? elemId) ??
      pickFirst(tableElems);
  if (encoded == null || encoded.trim().isEmpty) {
    throw const FormatException('该 XMP 不包含可识别的 RGBTable 数据');
  }
  return encoded;
}

/// 单遍还原 5 个预定义字符实体与数字字符引用(链式 replaceAll 会把
/// `&amp;lt;` 错解成 `<`,单遍遍历天然正确;未知实体原样保留)。
String _unescapeXml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(
      RegExp(r'&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);'), (m) {
    switch (m.group(1)) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final hex = m.group(1)!.startsWith('#x');
    final code =
        (int.tryParse(m.group(1)!.substring(hex ? 2 : 1), radix: hex ? 16 : 10)
                ?.clamp(0, 0x10FFFF)) ??
            0xFFFD; // 非法码位 → U+FFFD
    return String.fromCharCode(code);
  });
}

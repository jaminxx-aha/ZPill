/// Nikon EXIF/MakerNote 快门数解析(纯字节解析,无 IO,可单测)。
///
/// 容器三形态定位 EXIF 载荷(独立自洽 TIFF):JPEG APP1 / NEF 直开
/// TIFF / HEIF ISOBMFF(Z 系 .HIF,PTP 格式 0xB200 —— meta 盒 →
/// iinf 'Exif' item → iloc 定位,数据段 = ExifDataBlock:4B 大端
/// tiff_header_offset(真机=6,后随 "Exif\0\0" 标签)+ TIFF)。
/// 随后 IFD0 → ExifIFD 0x8769 → MakerNote 0x927C → Nikon 子 IFD
/// 0x00A7(ShutterCount);主 TIFF 与 Nikon 子 TIFF 字节序各自独立,
/// 子 TIFF 头长随固件代际不同(0210=9B、1100=10B)按签名定位。
///
/// 真机闭环(2026-10-22):Zf DSC_6362.HIF → 15963,与 DateTimeOriginal
/// 交叉验证一致。SDK 全族无快门数属性(见 debug/nikon_exif_probe.dart
/// 库注),此解析是唯一现实来源,口径 = 最后一张照片时刻的计数。
library;

import 'dart:typed_data';

import '../log/app_log.dart';

/// EXIF tag:ExifIFD 指针(IFD0)。
const int _kTagExifIfd = 0x8769;
/// EXIF tag:DateTimeOriginal(ExifIFD)。
const int _kTagDateTimeOriginal = 0x9003;
/// EXIF tag:MakerNote(ExifIFD)。
const int _kTagMakerNote = 0x927C;
/// Nikon 子 IFD tag:MakerNoteVersion(ASCII 4B,type 2/7)。
const int _kTagNikonVersion = 0x0001;
/// Nikon 子 IFD tag:ShutterCount(LONG,ExifTool Nikon::Main 口径)。
const int _kTagNikonShutterCount = 0x00A7;

/// 解析结果:每步事实留痕,失败从 [note] 逐级定位。
final class NikonShutterCountResult {
  const NikonShutterCountResult({
    required this.exifFound,
    required this.makerNoteFound,
    this.makerNoteVersion,
    this.shutterCount,
    this.dateTimeOriginal,
    required this.note,
    this.makerNoteHex,
    this.nikonTagDump,
  });

  /// 找到 EXIF 载荷(JPEG APP1 / TIFF 直开 / HEIF Exif item)。
  final bool exifFound;

  /// 找到 Nikon MakerNote 段(0x927C)。
  final bool makerNoteFound;

  /// Nikon MakerNote 版本串(如 "0210" / "1100")。
  final String? makerNoteVersion;

  /// ShutterCount(0x00A7);null = 段在但无此 tag / 版本不受支持。
  final int? shutterCount;

  /// DateTimeOriginal(0x9003),佐证解析到的确是那张照片。
  final String? dateTimeOriginal;

  /// 定位路径 / 失败点,进日志。
  final String note;

  /// MakerNote 头 48B 转储(失败/无 tag 时给,诊断用)。
  final String? makerNoteHex;

  /// Nikon 子 IFD 全 tag dump(「tag:type/count=value」以 ' | ' 相连;
  /// count≤4 给内联值,type 2/7×4 附 ASCII 括注,count>4 给前 8B hex)。
  /// 拍摄前后各读一次 diff,可找出随拍摄递增的计数 tag(2026-10-23
  /// 探针 v8:0x00A7 疑似只计机械快门,找真实总快门数来源)。
  final String? nikonTagDump;
}

String _h(int v) => '0x${v.toRadixString(16).toUpperCase()}';

bool _isTiffSig(Uint8List b, int p) =>
    p + 4 <= b.length &&
    ((b[p] == 0x49 && b[p + 1] == 0x49 && b[p + 2] == 0x2A && b[p + 3] == 0) ||
        (b[p] == 0x4D && b[p + 1] == 0x4D && b[p + 2] == 0 && b[p + 3] == 0x2A));

int _be16(Uint8List b, int p) =>
    (b[p] << 8) | b[p + 1];

int _be32(Uint8List b, int p) =>
    (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

/// 大端整读 [n] 字节(1..8,ISOBMFF iloc 的 offset/length 域)。
int _beN(Uint8List b, int p, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | b[p + i];
  }
  return v;
}

bool _isType(Uint8List b, int p, String s) {
  for (var i = 0; i < 4; i++) {
    if (b[p + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

/// ISOBMFF(HEIF)定位 'Exif' item 数据段:ftyp 开场 → 顶层扫到
/// 'meta'(FullBox)→ 子盒 'iinf' 找 item_type=='Exif' 的 item_ID →
/// 'iloc' 取该 item 的 extent(construction 0 = 文件绝对偏移;多
/// extent 按 item 数据顺序拼接,Exif item 数据本身是自洽 TIFF)。
/// 返回 (offset, length);null = 不是 HEIF 或定位失败(note 说明)。
(int, int, String)? _locateHeifExifItem(Uint8List b) {
  if (b.length < 12 || !_isType(b, 4, 'ftyp')) return null;
  var p = 0;
  while (p + 8 <= b.length) {
    final size = _be32(b, p);
    if (size < 8) return (0, 0, 'ISOBMFF 盒 size<8(@${_h(p)})');
    if (p + size > b.length) return (0, 0, 'ISOBMFF 盒越界(@${_h(p)})');
    if (_isType(b, p + 4, 'meta')) {
      // FullBox:跳 4B version/flags。头 512KB 截断时 meta 可能不完整。
      final r = _scanMetaForExif(b, p + 12, p + size);
      return (r.$1, r.$2, 'HEIF meta@${_h(p)};${r.$3}');
    }
    p += size;
  }
  return (0, 0, 'HEIF:顶层未见 meta 盒');
}

(int, int, String) _scanMetaForExif(Uint8List b, int start, int end) {
  int? exifItemId;
  String? ilocNote;
  (int, int)? extent;
  var p = start;
  while (p + 8 <= end) {
    final size = _be32(b, p);
    if (size < 8 || p + size > end) break;
    final type = p + 4;
    if (_isType(b, type, 'iinf')) {
      final ver = b[p + 8];
      var q = p + 12;
      final count = ver == 0 ? _be16(b, q) : _be32(b, q);
      q += ver == 0 ? 2 : 4;
      for (var i = 0; i < count && q + 8 <= end; i++) {
        final esize = _be32(b, q);
        if (esize < 8 || q + esize > end) break;
        if (_isType(b, q + 4, 'infe')) {
          final iver = b[q + 8];
          if (iver == 2 || iver == 3) {
            final idPos = q + 12;
            final id = iver == 2 ? _be16(b, idPos) : _be32(b, idPos);
            final typePos = idPos + (iver == 2 ? 2 : 4) + 2;
            if (typePos + 4 <= end && _isType(b, typePos, 'Exif')) {
              exifItemId = id;
            }
          }
        }
        q += esize;
      }
    } else if (_isType(b, type, 'iloc')) {
      final r = _parseIloc(b, p, size, exifItemId);
      extent = (r.$1, r.$2);
      ilocNote = r.$3;
    }
    p += size;
  }
  if (exifItemId == null) {
    return (0, 0, 'iinf 无 Exif item(iinf/iloc 扫描 ${ilocNote ?? '未跑'}');
  }
  if (extent == null) {
    return (0, 0, 'iloc 未见 item $exifItemId 的定位($ilocNote)');
  }
  if (extent.$1 == 0 && extent.$2 == 0) {
    return (0, 0, 'iloc 定位为空($ilocNote)');
  }
  return (extent.$1, extent.$2, 'Exif item=$exifItemId @${_h(extent.$1)}/${extent.$2}B');
}

/// 解 iloc 盒,取 [wantId](可为 null:取第一个 item)的拼接 extent。
/// 返回 (offsetStart, totalLen, note);offset 以文件为基准
/// (construction 0)。idat 构造(1)不支持,Nikon 不会用。
(int, int, String) _parseIloc(Uint8List b, int boxOff, int boxSize, int? wantId) {
  final ver = b[boxOff + 8];
  var p = boxOff + 12;
  final sizes = b[p];
  final offsetSize = sizes >> 4;
  final lengthSize = sizes & 0x0F;
  final baseSize = b[p + 1] >> 4;
  final indexSize = ver >= 1 ? b[p + 1] & 0x0F : 0;
  p += 2;
  final count = ver < 2 ? _be16(b, p) : _be32(b, p);
  p += ver < 2 ? 2 : 4;
  for (var i = 0; i < count; i++) {
    if (p + 4 > boxOff + boxSize) break;
    final id = ver < 2 ? _be16(b, p) : _be32(b, p);
    p += ver < 2 ? 2 : 4;
    if (ver >= 1) p += 2; // construction_method
    p += 2; // data_reference_index
    final base = baseSize == 0 ? 0 : _beN(b, p, baseSize);
    p += baseSize;
    final extentCount = _be16(b, p);
    p += 2;
    if (wantId != null && id != wantId) {
      // 逐 extent 顺序跳过(index 域 + offset + length)。
      for (var e = 0; e < extentCount; e++) {
        if (indexSize > 0) p += indexSize;
        p += offsetSize + lengthSize;
      }
      continue;
    }
    final spans = <(int, int)>[];
    for (var e = 0; e < extentCount; e++) {
      if (indexSize > 0) p += indexSize;
      final off = _beN(b, p, offsetSize);
      p += offsetSize;
      final len = _beN(b, p, lengthSize);
      p += lengthSize;
      spans.add((base + off, len));
    }
    if (spans.isEmpty) return (0, 0, 'item $id 无 extent');
    if (ver >= 1) {
      // construction_method 在上方跳过的 2B 里,重读一次:
      final cmPos = _ilocConstructionPos(b, boxOff, ver, id);
      if (cmPos != null) {
        final cm = _be16(b, cmPos);
        if (cm != 0) return (0, 0, 'item $id construction=$cm(idat)不支持');
      }
    }
    final total = spans.fold<int>(0, (s, e) => s + e.$2);
    return (spans.first.$1, total,
        'item $id ${spans.length} extent 首起 ${_h(spans.first.$1)} 共 ${total}B');
  }
  return (0, 0, 'iloc 未含目标 item(ver $ver)');
}

/// 回定位指定 item 的 construction_method 域(v1/2)。
int? _ilocConstructionPos(Uint8List b, int boxOff, int ver, int wantId) {
  final verByte = b[boxOff + 8];
  if (verByte < 1) return null;
  var p = boxOff + 12;
  final offsetSize = b[p] >> 4;
  final baseSize = b[p + 1] >> 4;
  p += 2;
  final count = ver < 2 ? _be16(b, p) : _be32(b, p);
  p += ver < 2 ? 2 : 4;
  for (var i = 0; i < count; i++) {
    if (p + 4 > b.length) break;
    final id = ver < 2 ? _be16(b, p) : _be32(b, p);
    p += ver < 2 ? 2 : 4;
    final cmPos = p;
    p += 2 + 2; // construction + data_ref
    p += baseSize;
    final extentCount = _be16(b, p);
    p += 2;
    if (id == wantId) return cmPos;
    for (var e = 0; e < extentCount; e++) {
      p += offsetSize * 2;
    }
  }
  return null;
}

/// 在 [b] 里定位 EXIF 载荷(独立自洽的 TIFF 块)。
/// 返回 (offset, length, note)。
(int, int, String) _locateExifPayload(Uint8List b) {
  // JPEG:FFD8 → 段扫 APP1「Exif\0\0」。
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xFF || (marker >= 0xD0 && marker <= 0xD9) || marker == 0x01) {
        if (marker == 0xD9 || marker == 0xDA) break; // EOI/SOS 未见 EXIF
        i += 2;
        continue;
      }
      final segLen = _be16(b, i + 2);
      final isApp1 = marker == 0xE1 &&
          i + 10 <= b.length &&
          _isType(b, i + 4, 'Exif') &&
          b[i + 8] == 0 &&
          b[i + 9] == 0;
      if (isApp1) {
        return (i + 10, segLen - 8, 'JPEG APP1@${_h(i)}');
      }
      i += 2 + segLen;
    }
    return (0, 0, 'JPEG 段扫未见 APP1 Exif');
  }
  // NEF/TIFF 直开。
  if (_isTiffSig(b, 0)) {
    return (0, b.length, 'TIFF 直开');
  }
  // HEIF(Z 系 HIF):ISOBMFF 'Exif' item。item 数据 = ExifDataBlock:
  // 4B 大端 tiff_header_offset + TIFF(offset=0 直接开场;Nikon HIF
  // 真机实证 offset=6,前缀字段后另随 2B 附加数据)。
  final heif = _locateHeifExifItem(b);
  if (heif != null) {
    var (off, len, note) = heif;
    if ((off != 0 || len != 0) && !_isTiffSig(b, off) && len >= 8) {
      // Exif item 数据 = ExifDataBlock(4B 大端 tiff_header_offset)+TIFF;
      // Nikon HIF 实测 offset=6。offset 语义若有出入,兜底在前 16B
      // 窗内直接搜 TIFF 签名;成败都打头 16B hex 进日志。
      final hdr = _be32(b, off);
      int? cut;
      if (hdr > 0 &&
          hdr < len &&
          off + hdr + 4 <= b.length &&
          _isTiffSig(b, off + hdr)) {
        cut = hdr;
      } else {
        for (var q = 1; q <= 16 && q < len && off + q + 4 <= b.length; q++) {
          if (_isTiffSig(b, off + q)) {
            cut = q;
            break;
          }
        }
      }
      final headHex = AppLog.hex(
          Uint8List.sublistView(b, off, off + (16 < len ? 16 : len)),
          max: 16);
      if (cut != null) {
        off += cut;
        len -= cut;
        note = '$note;头16B=$headHex;跳过前缀 ${cut}B';
      } else {
        note = '$note;头16B=$headHex;窗内无 TIFF 签名';
      }
    }
    return (off, len, note);
  }
  return (0, 0, '非 JPEG/TIFF/HEIF 开场(${b.take(4).map((e) => _h(e)).join(' ')})');
}

final class _IfdEntry {
  const _IfdEntry(this.tag, this.type, this.count, this.valueField);

  final int tag;
  final int type;
  final int count;
  /// entry 的 value 字段原值(LONG 内联值,或大数据的偏移)。
  final int valueField;
}

/// 读一张 IFD。[base] = 本 TIFF 域起点(主 TIFF 或 Nikon 子 TIFF),
/// 条目内偏移全部相对 [base]。越界即停(截断容错,探针要真相不要炸)。
List<_IfdEntry> _readIfd(
  Uint8List b,
  int base,
  int ifdOff,
  int Function(int) rd16,
  int Function(int) rd32,
) {
  final abs = base + ifdOff;
  if (abs + 2 > b.length) return const [];
  final count = rd16(abs);
  if (count > 256) return const []; // 上限防跑飞
  final entries = <_IfdEntry>[];
  var p = abs + 2;
  for (var i = 0; i < count; i++) {
    if (p + 12 > b.length) break;
    entries.add(_IfdEntry(rd16(p), rd16(p + 2), rd32(p + 4), rd32(p + 8)));
    p += 12;
  }
  return entries;
}

NikonShutterCountResult parseNikonShutterCount(Uint8List bytes) {
  final located = _locateExifPayload(bytes);
  final containerNote = located.$3;
  if (located.$1 == 0 && located.$2 == 0) {
    return NikonShutterCountResult(
      exifFound: false,
      makerNoteFound: false,
      nikonTagDump: null,
      note: containerNote,
    );
  }
  final off = located.$1;
  var len = located.$2;
  if (off + len > bytes.length) {
    len = bytes.length - off; // 头部截断:能解多少解多少,note 已有长度
    if (len <= 0) {
      return NikonShutterCountResult(
        exifFound: true,
        makerNoteFound: false,
        note: '$containerNote;载荷起点越界(头部读数不够)',
      );
    }
  }
  final exif = Uint8List.sublistView(bytes, off, off + len);
  return _parseTiffPayload(exif, containerNote);
}

NikonShutterCountResult _parseTiffPayload(Uint8List exif, String containerNote) {
  if (!_isTiffSig(exif, 0)) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: false,
      nikonTagDump: null,
      note: '$containerNote;载荷非 TIFF 开场(${exif.take(4).map(_h).join(' ')})',
    );
  }
  final bigEndian = exif[0] == 0x4D; // 'M' = MM 大端,'I' = II 小端
  int rd16(int p) => p + 2 <= exif.length
      ? (bigEndian ? (exif[p] << 8) | exif[p + 1] : exif[p] | (exif[p + 1] << 8))
      : 0;
  int rd32(int p) => p + 4 <= exif.length
      ? (bigEndian
          ? (exif[p] << 24) | (exif[p + 1] << 16) | (exif[p + 2] << 8) | exif[p + 3]
          : exif[p] |
              (exif[p + 1] << 8) |
              (exif[p + 2] << 16) |
              (exif[p + 3] << 24))
      : 0;

  final path = StringBuffer(
      '$containerNote(${bigEndian ? 'MM' : 'II'})');

  final ifd0 = _readIfd(exif, 0, rd32(4), rd16, rd32);
  _IfdEntry? exifPtr;
  for (final e in ifd0) {
    if (e.tag == _kTagExifIfd) exifPtr = e;
  }
  if (exifPtr == null) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: false,
      nikonTagDump: null,
      note: '$path;IFD0 无 0x8769(ExifIFD)',
    );
  }
  final exifIfd = _readIfd(exif, 0, exifPtr.valueField, rd16, rd32);
  path.write(';ExifIFD@${_h(exifPtr.valueField)}');

  String? dtOriginal;
  for (final e in exifIfd) {
    if (e.tag != _kTagDateTimeOriginal || e.type != 2) continue;
    final idx = exifIfd.indexOf(e);
    final entryOff = exifPtr.valueField + 2 + 12 * idx;
    final dataOff = e.count <= 4 ? entryOff + 8 : e.valueField;
    final end = dataOff + e.count <= exif.length
        ? dataOff + e.count
        : exif.length;
    dtOriginal = String.fromCharCodes([
      for (var p = dataOff; p < end && exif[p] != 0; p++) exif[p],
    ]);
  }

  _IfdEntry? mn;
  for (final e in exifIfd) {
    if (e.tag == _kTagMakerNote) mn = e;
  }
  if (mn == null) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: false,
      dateTimeOriginal: dtOriginal,
      note: '$path;ExifIFD 无 0x927C(MakerNote)',
    );
  }
  final mnOff = mn.valueField; // UNDEFINED count>4:value 字段即偏移
  final mnEnd = mnOff + mn.count <= exif.length
      ? mnOff + mn.count
      : exif.length;
  if (mnOff + 16 > exif.length) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: true,
      dateTimeOriginal: dtOriginal,
      note: '$path;MakerNote 头被截断(头部读数不够,加大 _kHeadBytes)',
    );
  }
  final hexDump = AppLog.hex(
      Uint8List.sublistView(
          exif, mnOff, mnOff + 48 < mnEnd ? mnOff + 48 : mnEnd),
      max: 48);

  // Nikon MakerNote:「Nikon\0」+ 版本字节;子 TIFF 头长随固件代际不同
  // (0210=9B、1100=10B)—— 直接在版本字节后的小窗里搜子 TIFF 签名。
  if (exif[mnOff] != 0x4E ||
      exif[mnOff + 1] != 0x69 ||
      exif[mnOff + 2] != 0x6B ||
      exif[mnOff + 3] != 0x6F ||
      exif[mnOff + 4] != 0x6E ||
      exif[mnOff + 5] != 0) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: true,
      dateTimeOriginal: dtOriginal,
      note: '$path;MakerNote 非 Nikon 头',
      makerNoteHex: hexDump,
    );
  }
  int? subTiff;
  for (var p = mnOff + 7; p <= mnOff + 16 && p + 4 <= exif.length; p++) {
    if (_isTiffSig(exif, p)) {
      subTiff = p;
      break;
    }
  }
  if (subTiff == null) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: true,
      dateTimeOriginal: dtOriginal,
      note: '$path;Nikon 头后 10B 窗无子 TIFF 签名',
      makerNoteHex: hexDump,
    );
  }
  final subBig = exif[subTiff] == 0x4D;
  int sRd16(int p) => p + 2 <= exif.length
      ? (subBig ? (exif[p] << 8) | exif[p + 1] : exif[p] | (exif[p + 1] << 8))
      : 0;
  int sRd32(int p) => p + 4 <= exif.length
      ? (subBig
          ? (exif[p] << 24) | (exif[p + 1] << 16) | (exif[p + 2] << 8) | exif[p + 3]
          : exif[p] |
              (exif[p + 1] << 8) |
              (exif[p + 2] << 16) |
              (exif[p + 3] << 24))
      : 0;
  if (sRd16(subTiff + 2) != 0x2A) {
    return NikonShutterCountResult(
      exifFound: true,
      makerNoteFound: true,
      dateTimeOriginal: dtOriginal,
      note: '$path;Nikon 子 TIFF magic 非 42',
      makerNoteHex: hexDump,
    );
  }
  final nIfd = _readIfd(exif, subTiff, sRd32(subTiff + 4), sRd16, sRd32);

  String? versionText;
  int? shutterCount;
  final nIfdBase = sRd32(subTiff + 4);
  final dump = StringBuffer();
  for (final e in nIfd) {
    final idx = nIfd.indexOf(e);
    final entryOff = subTiff + nIfdBase + 2 + 12 * idx;
    dump.write('${_h(e.tag)}:${e.type}/${e.count}=');
    if (e.count <= 4) {
      dump.write(e.valueField);
      if ((e.type == 2 || e.type == 7) && e.count == 4) {
        final dataOff = entryOff + 8;
        if (dataOff + 4 <= exif.length) {
          dump.write('(${String.fromCharCodes(exif.sublist(dataOff, dataOff + 4))})');
        }
      }
    } else {
      final dataOff = subTiff + e.valueField;
      final n = e.count < 8 ? e.count : 8;
      if (dataOff + n <= exif.length) {
        dump.write(AppLog.hex(
            Uint8List.sublistView(exif, dataOff, dataOff + n), max: 8));
      }
    }
    dump.write(' | ');
  }
  for (final e in nIfd) {
    if (e.tag == _kTagNikonVersion &&
        (e.type == 2 || e.type == 7) &&
        e.count == 4) {
      final idx = nIfd.indexOf(e);
      final entryOff = subTiff + sRd32(subTiff + 4) + 2 + 12 * idx;
      final dataOff = entryOff + 8; // count=4 内联(ASCII 原样 4 字节)
      if (dataOff + 4 <= exif.length) {
        versionText =
            String.fromCharCodes(exif.sublist(dataOff, dataOff + 4));
      }
    }
    if (e.tag == _kTagNikonShutterCount && e.type == 4 && e.count == 1) {
      shutterCount = e.valueField; // LONG×1 内联,序由 sRd32 解
    }
  }
  path.write(';MakerNote@${_h(mnOff)}(${subBig ? 'MM' : 'II'})');
  return NikonShutterCountResult(
    exifFound: true,
    makerNoteFound: true,
    makerNoteVersion: versionText,
    shutterCount: shutterCount,
    nikonTagDump: dump.toString(),
    dateTimeOriginal: dtOriginal,
    note: shutterCount == null
        ? '$path;Nikon IFD 无 0x00A7'
        : '$path;0x00A7 命中',
    makerNoteHex: shutterCount == null ? hexDump : null,
  );
}

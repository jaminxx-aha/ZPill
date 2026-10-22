/// 运动照片(Motion Photo)拆分(实况照片导出用)。
///
/// 尼康「运动照片」是单个 .JPG:静帧 JPEG 之后直接拼接 MP4 视频段,
/// XMP 标记偏移 —— 与 Google Motion Photo 字节格式同源。iOS/ohos 的
/// 实况照片(动态照片)导入需要独立的 JPG + MOV 两个文件,故下载后
/// 按标记拆开配对导入;Android 反向拼回单文件(平台侧)。
///
/// XMP 两种标记都支持(**尼康具体用哪种待真机核对**):
/// - 旧版 MicroVideo:`GCamera:MicroVideoOffset="N"` = 从文件**末尾**
///   往前数 N 字节为视频段起点;
/// - 新版 Motion Photo v1:`Container:Directory` 里 `Item:Semantic=
///   "Motion"` 的 `Item:Length="N"` = 视频段长 N 字节(同样贴文件尾)。
///
/// 防御:视频段必须以 MP4 box 开头(ftyp/moov/…),拆点越界或四不像
/// 一律返回 null(调用方按普通照片处理,宁可丢实况不落垃圾字节)。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 拆分产物:静帧 JPEG(原文件头部字节)与 MP4 视频段。
final class MotionPhotoSplit {
  const MotionPhotoSplit({required this.image, required this.video});

  final Uint8List image;
  final Uint8List video;
}

/// 运动照片 JPG 的 XMP APP1 段头(标准 xap 命名空间,带结尾 NUL)。
final List<int> _kXmpApp1Header = [...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0];

/// 尝试把运动照片文件拆成 静帧 + 视频;非运动照片 / 标记不可信 → null。
MotionPhotoSplit? splitMotionPhoto(Uint8List file) {
  if (file.length < 8 || file[0] != 0xFF || file[1] != 0xD8) return null;

  // 扫 APP 段找 XMP(避开熵编码数据:非 0xFF 打头即止)。
  var pos = 2;
  String? xmp;
  while (pos + 4 <= file.length && xmp == null) {
    if (file[pos] != 0xFF) return null;
    final marker = file[pos + 1];
    if (marker == 0xDA) return null; // SOS:后面是熵数据,无 XMP
    final segLen = (file[pos + 2] << 8) | file[pos + 3];
    if (segLen < 2 || pos + 2 + segLen > file.length) return null;
    if (marker == 0xE1 && segLen > 2 + _kXmpApp1Header.length) {
      final bodyStart = pos + 4;
      if (_startsWith(file, bodyStart, _kXmpApp1Header)) {
        xmp = latin1.decode(file.sublist(
            bodyStart + _kXmpApp1Header.length, pos + 2 + segLen));
      }
    }
    pos += 2 + segLen;
  }
  if (xmp == null) return null;

  final videoStart = _videoStartFromXmp(xmp, file.length);
  if (videoStart == null) return null;
  final video = Uint8List.sublistView(file, videoStart);
  if (!_looksLikeMp4(video)) return null;
  return MotionPhotoSplit(
    image: Uint8List.sublistView(file, 0, videoStart),
    video: video,
  );
}

/// 从 XMP 文本解出视频段起点(相对文件头);无标记 / 拆点越界 → null。
int? _videoStartFromXmp(String xmp, int fileLength) {
  final n = _microVideoOffset(xmp) ?? _motionItemLength(xmp);
  if (n == null) return null;
  return _validStart(fileLength - n, fileLength);
}

/// 旧版标记:GCamera:MicroVideoOffset = 视频段字节数(贴文件尾)。
/// 属性式(`MicroVideoOffset="N"`)与元素式(`<MicroVideoOffset>N</…>`)
/// 都是合法 RDF 序列化,真机两种都有,都收。
int? _microVideoOffset(String xmp) {
  final m = RegExp(
          r'(?:GCamera|Camera):MicroVideoOffset="(\d+)"|'
          r'<(?:GCamera|Camera):MicroVideoOffset>(\d+)</')
      .firstMatch(xmp);
  if (m == null) return null;
  return int.tryParse(m.group(1) ?? m.group(2) ?? '');
}

/// 新版标记:Container:Directory 里 Semantic="Motion" 的 Item 的 Length。
/// 主形态是 Length 与 Semantic 同在 Item 标签上的属性式(顺序不限);
/// 元素式 `<Item:Length>N</Item:Length>` 兜底。块内绑定 —— Primary 项
/// 也带 Length,不能张冠李戴。
int? _motionItemLength(String xmp) {
  final itemBlock = RegExp(
      r'<Container:Item\b[^>]*?(?:/>|>.*?</Container:Item>)',
      dotAll: true);
  for (final m in itemBlock.allMatches(xmp)) {
    final block = m.group(0)!;
    final isMotion =
        RegExp('Item:Semantic="Motion"').hasMatch(block) ||
            RegExp('<Item:Semantic>Motion</Item:Semantic>').hasMatch(block);
    if (!isMotion) continue;
    final len = RegExp(r'Item:Length="(\d+)"|<Item:Length>(\d+)<')
        .firstMatch(block);
    if (len != null) return int.tryParse(len.group(1) ?? len.group(2) ?? '');
  }
  return null;
}

int? _validStart(int start, int fileLength) {
  // 静帧至少要装得下一个最小 JPEG,视频至少 8 字节(box 头)。
  if (start < 32 || start > fileLength - 8) return null;
  return start;
}

/// MP4 起始防御:前 4 字节是合理 box 长度,4..8 是已知 box 类型。
bool _looksLikeMp4(Uint8List bytes) {
  if (bytes.length < 8) return false;
  final boxSize = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  if (boxSize < 8 || boxSize > bytes.length) return false;
  const known = {'ftyp', 'moov', 'mdat', 'free', 'skip', 'wide', 'uuid', 'styp'};
  final type = String.fromCharCodes(bytes.sublist(4, 8));
  return known.contains(type);
}

bool _startsWith(Uint8List data, int offset, List<int> prefix) {
  if (offset + prefix.length > data.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[offset + i] != prefix[i]) return false;
  }
  return true;
}

/// 拼回运动照片(Android 平台导入用,反向操作):静帧 JPEG + MP4 →
/// 单文件,并写 MicroVideoOffset 标记(XMP APP1 插在 SOI 之后;已有
/// XMP 段则替换,重复段阅读器各取其一)。
Uint8List spliceMotionPhoto(Uint8List image, Uint8List video) {
  final packet =
      '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="ZPill 1.0">\n'
      ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
      '  <rdf:Description rdf:about=""\n'
      '    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">\n'
      '   <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>\n'
      '   <GCamera:MicroVideo>1</GCamera:MicroVideo>\n'
      '   <GCamera:MicroVideoConfidence>100</GCamera:MicroVideoConfidence>\n'
      '   <GCamera:MicroVideoOffset>${video.length}</GCamera:MicroVideoOffset>\n'
      '  </rdf:Description>\n'
      ' </rdf:RDF>\n'
      '</x:xmpmeta>\n'
      '<?xpacket end="w"?>\n';
  return Uint8List.fromList([
    ...injectXmpApp1(image, packet),
    ...video,
  ]);
}

/// 把 XMP 包作为 APP1 段插进 JPEG:已有 XMP APP1 则替换,否则插在
/// SOI 之后。非 JPEG 原样返回。
Uint8List injectXmpApp1(Uint8List jpeg, String packet) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
  final body = utf8.encode(packet);
  final segment = <int>[
    0xFF, 0xE1,
    (body.length + _kXmpApp1Header.length + 2) >> 8,
    (body.length + _kXmpApp1Header.length + 2) & 0xFF,
    ..._kXmpApp1Header,
    ...body,
  ];
  // 已有 XMP APP1:定位后替换(一次)。
  var pos = 2;
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) return jpeg;
    final marker = jpeg[pos + 1];
    if (marker == 0xDA) break;
    final segLen = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
    if (segLen < 2 || pos + 2 + segLen > jpeg.length) return jpeg;
    if (marker == 0xE1 &&
        segLen > 2 + _kXmpApp1Header.length &&
        _startsWith(jpeg, pos + 4, _kXmpApp1Header)) {
      return Uint8List.fromList([
        ...jpeg.sublist(0, pos),
        ...segment,
        ...jpeg.sublist(pos + 2 + segLen),
      ]);
    }
    pos += 2 + segLen;
  }
  return Uint8List.fromList([...jpeg.sublist(0, 2), ...segment, ...jpeg.sublist(2)]);
}

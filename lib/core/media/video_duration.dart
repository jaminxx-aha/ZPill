/// MOV/MP4 容器时长提取:箱行走(ISO BMFF,**大端**尺寸)→ 顶层找
/// moov → 子箱找 mvhd → version 0/1 两形解析 timescale/duration →
/// Duration。Nikon MOV 的 moov 常在 mdat 之后(尾部),行走按尺寸跳过
/// mdat 不读载荷,仅需数次小读。[fetch] = (offset, length) → 字节,
/// 越界由调用方截断;找不到/预算尽/病箱 = null(调用方不显时长)。
///
/// 时长格式化:[formatVideoDuration] —— ≥1h = h:mm:ss,否则 m:ss。
library;

import 'dart:typed_data';

Future<Duration?> readVideoDuration(
    Future<Uint8List?> Function(int offset, int length) fetch) async {
  var reads = 0;
  Future<Uint8List?> read(int off, int len) async {
    if (reads >= 24 || off < 0 || len <= 0) return null;
    reads++;
    return fetch(off, len);
  }

  int u32(List<int> b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  // 顶层箱行走找 moov。
  var offset = 0;
  var moovStart = -1;
  while (true) {
    final hdr = await read(offset, 64);
    if (hdr == null || hdr.length < 8) return null;
    var boxSize = u32(hdr, 0);
    final type = String.fromCharCodes(hdr.sublist(4, 8));
    if (boxSize == 1) {
      if (hdr.length < 16) return null;
      var large = 0;
      for (final b in hdr.sublist(8, 16)) {
        large = (large << 8) | b;
      }
      boxSize = large;
    } else if (boxSize == 0) {
      return null; // 到 EOF 仍未遇 moov:结构异常,放弃
    }
    if (boxSize < 8) return null;
    if (type == 'moov') {
      moovStart = offset + 8;
      break;
    }
    offset += boxSize;
  }

  // moov 子箱找 mvhd(通常首个)。
  var moff = moovStart;
  var mvhdAt = -1;
  for (var i = 0; i < 16; i++) {
    final hdr = await read(moff, 64);
    if (hdr == null || hdr.length < 8) return null;
    final boxSize = u32(hdr, 0);
    if (boxSize < 8) return null;
    if (String.fromCharCodes(hdr.sublist(4, 8)) == 'mvhd') {
      mvhdAt = moff;
      break;
    }
    moff += boxSize;
  }
  if (mvhdAt < 0) return null;

  // mvhd:version(1)+flags(3) 后,v0 = ctime4/mtime4/timescale4/
  // duration4;v1 = ctime8/mtime8/timescale4/duration8。
  final mvhd = await read(mvhdAt, 64);
  if (mvhd == null || mvhd.length < 32) return null;
  final version = mvhd[8];
  final int tsOff;
  final int durOff;
  final int durBytes;
  if (version == 1) {
    tsOff = 8 + 4 + 16;
    durOff = tsOff + 4;
    durBytes = 8;
  } else {
    tsOff = 8 + 4 + 8;
    durOff = tsOff + 4;
    durBytes = 4;
  }
  if (mvhd.length < durOff + durBytes) return null;
  final timescale = u32(mvhd, tsOff);
  if (timescale <= 0) return null;
  var dur = 0;
  for (var i = 0; i < durBytes; i++) {
    dur = (dur << 8) | mvhd[durOff + i];
  }
  if (dur <= 0) return null;
  return Duration(milliseconds: dur * 1000 ~/ timescale);
}

/// 时长文案:≥1h = h:mm:ss,否则 m:ss(视频缩略胶囊用)。
String formatVideoDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// null 安全格式化(null 进 null 出,格侧免判空)。
String? formatVideoDurationOrNull(Duration? d) =>
    d == null ? null : formatVideoDuration(d);

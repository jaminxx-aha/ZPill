/// Nikon MOV/MP4 容器评级提取:箱行走(ISO BMFF,**大端**尺寸)→
/// moov → udta → NCDT → NCTG,在 NCTG 头部找 `01 00 08 00 01` 后的
/// u16 LE 评级 —— 1-5 = 星档,0 = 无评级,**0xFFFF = 删除候选**(机身
/// 「垃圾桶」,与 JPEG XMP Rating=-1 同约定;2026-10-23 真机 ★4/★5/
/// 垃圾桶三样张标定,NCTG 是唯一在文件层携带视频评级的通道)。
///
/// 找不到模式/预算尽 = null(调用方保持无评级,不误判);读次数硬
/// 上限防病箱空转。[fetch] = (offset, length) → 字节,越界由调用方
/// 截断;仓库侧接 GetPartialObject。
library;

import 'dart:typed_data';

Future<int?> readVideoRating(
    Future<Uint8List?> Function(int offset, int length) fetch) async {
  var reads = 0;
  Future<Uint8List?> read(int off, int len) async {
    if (reads >= 40 || off < 0 || len <= 0) return null;
    reads++;
    return fetch(off, len);
  }

  // 顶层箱行走找 moov(尺寸大端;mdat 按尺寸跳过不读载荷)。
  var offset = 0;
  var moovStart = -1;
  var moovEnd = -1;
  while (true) {
    final hdr = await read(offset, 64);
    if (hdr == null || hdr.length < 8) return null;
    var boxSize =
        (hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
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
      moovEnd = offset + boxSize;
      break;
    }
    offset += boxSize;
  }

  // moov 子箱找 udta。
  var uoff = moovStart;
  var udtaPayload = -1;
  while (uoff + 8 <= moovEnd) {
    final hdr = await read(uoff, 64);
    if (hdr == null || hdr.length < 8) return null;
    final boxSize =
        (hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
    final type = String.fromCharCodes(hdr.sublist(4, 8));
    if (boxSize < 8) return null;
    if (type == 'udta') {
      udtaPayload = uoff + 8;
      break;
    }
    uoff += boxSize;
  }
  if (udtaPayload < 0) return null;

  // udta 头部 1KB:NCDT 子箱 → 内层 NCHD/NCTG —— NCTG 载荷前 1KB 含
  // 评级条目(真机 NCTG+0x190 处),无需读全 2MB。
  final head = await read(udtaPayload, 1024);
  if (head == null || head.length < 32) return null;

  // NCDT 子箱(BE 头;尺寸可能超出缓冲,只解析头内可见部分)。
  if (String.fromCharCodes(head.sublist(4, 8)) != 'NCDT') return null;
  var noff = 8;
  while (noff + 8 <= head.length) {
    final nsize =
        (head[noff] << 24) | (head[noff + 1] << 16) | (head[noff + 2] << 8) | head[noff + 3];
    if (nsize < 8) return null;
    final ntype = String.fromCharCodes(head.sublist(noff + 4, noff + 8));
    if (ntype == 'NCTG') {
      // NCTG 载荷:u32 版本 + 条目 [u16 tag LE][u16 count LE][value];
      // 评级条目 = tag 1 / count 8,value 前 4B = `01 00 [u16 LE 评级]`。
      // 搜 5 字节特征 `01 00 08 00 01`,其后 u16 LE 即评级(可见字节内;
      // NCTG 全长 ~5KB 超出 1KB 窗口,评级条目在头部 ~0x190 处必可见)。
      for (var i = noff + 8; i + 7 <= head.length; i++) {
        if (head[i] == 0x01 &&
            head[i + 1] == 0x00 &&
            head[i + 2] == 0x08 &&
            head[i + 3] == 0x00 &&
            head[i + 4] == 0x01) {
          final value = head[i + 5] | (head[i + 6] << 8);
          return value <= 5 || value == 0xffff ? value : null;
        }
      }
      return null;
    }
    noff += nsize;
  }
  return null;
}

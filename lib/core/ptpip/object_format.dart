/// PTP ObjectFormatCode(ISO 15740)节选 + 浏览层文件分类。
///
/// 分类决定「类型过滤(JPEG/NEF/TIFF/MP4/MOV)」与「保存到相册时的
/// MIME / 目录映射」。
library;

/// 浏览/传输层的文件分类(UI 与相册保存共用)。
enum ObjectKind { folder, image, video, other }

abstract final class ObjectFormatCode {
  static const int undefined = 0x3000;
  static const int association = 0x3001; // 文件夹

  // ── 音视频容器(0x30xx) ──
  static const int wav = 0x3008;
  static const int mp3 = 0x3009;
  static const int avi = 0x300A;
  static const int mpeg = 0x300B;
  static const int asf = 0x300C;
  static const int quickTime = 0x300D; // MOV 容器

  // ── 静态图像(0x38xx) ──
  static const int exifJpeg = 0x3801;
  static const int tiffEp = 0x3802;
  static const int bmp = 0x3804;
  static const int gif = 0x3807;
  static const int jfif = 0x3808;
  static const int png = 0x380B;
  static const int tiff = 0x380D;

  // ── MTP 扩展(0xB9xx) ──
  static const int mp4 = 0xB982; // Zf 实测在册(MTP 标准码)
  static const int heif = 0xB200; // HEIF(§6.6.3.3 评级适用表在册;Zf .HIF)

  // 2026-09-27 Zf 真机落定(GetObjectInfo 实测):NEF 报 0x3000(Undefined),
  // 尼康不给专用码 —— 浏览层必须按 .nef 扩展名兜底识别。0xB101 是
  // Canon/Sony 的码,勿用。
}

/// 格式码 → 分类。无法识别的码走 [ObjectKind.other],
/// 由浏览层用文件扩展名二次兜底(.nef/.mp4/.mov);
/// .nef 兜底是必需设计:NEF 的格式码就是 0x3000(真机实测)。
ObjectKind kindForFormatCode(int formatCode) {
  switch (formatCode) {
    case ObjectFormatCode.association:
      return ObjectKind.folder;
    case ObjectFormatCode.exifJpeg:
    case ObjectFormatCode.jfif:
    case ObjectFormatCode.tiffEp:
    case ObjectFormatCode.tiff:
    case ObjectFormatCode.png:
    case ObjectFormatCode.bmp:
    case ObjectFormatCode.gif:
    case ObjectFormatCode.heif: // HEIF(.HIF):图像语义,Zf 表在册
      return ObjectKind.image;
    case ObjectFormatCode.quickTime:
    case ObjectFormatCode.mpeg:
    case ObjectFormatCode.avi:
    case ObjectFormatCode.asf:
    case ObjectFormatCode.mp4:
      return ObjectKind.video;
    default:
      return ObjectKind.other;
  }
}

/// 扩展名兜底分类(浏览层二次兜底):NEF 的格式码就是 0x3000(真机实测),
/// 只能靠文件名识别;MP4/MOV 的 MTP 码同理兜底。
ObjectKind kindForFilename(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= filename.length) {
    return ObjectKind.other;
  }
  switch (filename.substring(dot + 1).toLowerCase()) {
    case 'jpg':
    case 'jpeg':
    case 'jpe':
    case 'nef':
    case 'nrw':
    case 'tif':
    case 'tiff':
    case 'png':
    case 'bmp':
    case 'gif':
    case 'heic':
    case 'hif': // 尼康 HEIF 扩展名
      return ObjectKind.image;
    case 'mp4':
    case 'mov':
    case 'avi':
    case 'mts':
    case 'm4v':
      return ObjectKind.video;
    default:
      return ObjectKind.other;
  }
}

/// 保存到系统相册时的 MIME 映射。
/// NEF 无标准 MIME,用通用二进制流,相册目录按图片处理。
String? mimeForFormatCode(int formatCode) {
  switch (formatCode) {
    case ObjectFormatCode.exifJpeg:
    case ObjectFormatCode.jfif:
      return 'image/jpeg';
    case ObjectFormatCode.tiffEp:
    case ObjectFormatCode.tiff:
      return 'image/tiff';
    case ObjectFormatCode.png:
      return 'image/png';
    case ObjectFormatCode.quickTime:
      return 'video/quicktime';
    case ObjectFormatCode.mpeg:
      return 'video/mpeg';
    case ObjectFormatCode.mp4:
      return 'video/mp4';
    default:
      return null; // undefined 等:由扩展名兜底
  }
}

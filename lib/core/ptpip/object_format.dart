/// PTP ObjectFormatCode(ISO 15740)节选 + 浏览层文件分类。
///
/// 分类决定「类型过滤(JPEG/NEF/TIFF/MP4/MOV)」与「保存到相册时的
/// MIME / 目录映射」(TODO.md §三/§四)。
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

  // TODO(P0): 尼康 NEF —— 真机 GetObjectInfo 通常报尼康扩展码 0xB101,
  // 部分机身报 undefined/TIFF;以真机响应为准订正。
  static const int nikonNef = 0xB101;

  // TODO(P0): MP4 —— 相机常将其报为 quickTime/undefined,
  // 浏览层按扩展名兜底,此处码值以真机核对。
}

/// 格式码 → 分类。无法识别的码走 [ObjectKind.other],
/// 由浏览层用文件扩展名二次兜底(.nef/.mp4/.mov)。
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
    case ObjectFormatCode.nikonNef:
      return ObjectKind.image;
    case ObjectFormatCode.quickTime:
    case ObjectFormatCode.mpeg:
    case ObjectFormatCode.avi:
    case ObjectFormatCode.asf:
      return ObjectKind.video;
    default:
      return ObjectKind.other;
  }
}

/// 保存到系统相册时的 MIME 映射(TODO.md §四 P1)。
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
    case ObjectFormatCode.nikonNef:
      return 'image/x-nikon-nef';
    case ObjectFormatCode.quickTime:
      return 'video/quicktime';
    case ObjectFormatCode.mpeg:
      return 'video/mpeg';
    default:
      return null; // undefined 等:由扩展名兜底
  }
}

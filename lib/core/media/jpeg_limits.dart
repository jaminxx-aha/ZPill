/// JPEG 解码前的资源边界。
///
/// `image` 包的 `decodeJpg` 会先分配完整像素缓冲,之后再 resize 不能
/// 阻止恶意超大画幅先耗尽内存。`JpegDecoder.startDecode` 只读头部信息,
/// 因此用它先验证宽高和总像素数。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 照片编辑/水印允许整图解码的最大像素数(Nikon Z 系最高约 45MP)。
const int kMaxJpegDecodePixels = 64 * 1024 * 1024;

/// 取景分析和相机缩略图只应有小画幅,上限收得更紧。
const int kMaxPreviewJpegDecodePixels = 16 * 1024 * 1024;

bool jpegWithinDecodeLimits(
  Uint8List jpeg, {
  int maxPixels = kMaxJpegDecodePixels,
}) {
  if (maxPixels < 1 || jpeg.length < 4) return false;
  try {
    final info = img.JpegDecoder().startDecode(jpeg);
    if (info == null || info.width <= 0 || info.height <= 0) return false;
    return info.width * info.height <= maxPixels;
  } on Object {
    return false;
  }
}

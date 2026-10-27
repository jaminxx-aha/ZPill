/// 假相机的对象表:合成媒体 + 缺省人设 + 真实文件目录装载。
///
/// 纯 Dart(仅 dart:io / package:image),零 Flutter 依赖 —— 同一份实现
/// 既被 `tools/mock_camera/bin` 的 CLI 用,也被 `test/e2e` 的回环测试用。
///
/// 合成原则:
/// - 缩略图/大缩略/拍后新对象 = **真可解码 JPEG**(image 包编码,渐变
///   填充、确定性输出)—— 手动冒烟时 app 侧缩略图管线能真正渲染;
/// - NEF/MOV 正文 = 确定性伪随机字节(LCG):不可压缩、逐字节可比,
///   e2e 断言「下载重组 == mock 合成」时有区分度(全零/重复 pattern
///   掩盖错位类 bug)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:z_pill/core/ptpip/object_format.dart';

/// 一个合成对象(句柄 → 元数据 + 三档载荷)。
///
/// 字段语义对齐 PTP ObjectInfo(`lib/core/ptpip/object_info.dart`);
/// handle 只能由 mock 的对象表分配,与「禁止由文件路径推导 handle」的
/// 铁律同向。
final class MockObject {
  const MockObject({
    required this.handle,
    required this.storageId,
    required this.format,
    required this.filename,
    required this.body,
    required this.thumb,
    required this.largeThumb,
    required this.parent,
    required this.captureDate,
    this.thumbWidth = 0,
    this.thumbHeight = 0,
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  final int handle;
  final int storageId;

  /// ObjectFormatCode(0x3801 JPEG / 0x3000 NEF 真机实测即 Undefined /
  /// 0xB982 MP4 / 0x3001 文件夹)。
  final int format;
  final String filename;

  /// GetObject / GetPartialObject 的正文。
  final Uint8List body;

  /// GetThumb(0x100A)载荷。
  final Uint8List thumb;

  /// GetLargeThumb(0x90C4)载荷。
  final Uint8List largeThumb;

  /// 所属文件夹句柄(根 = 0)。
  final int parent;

  /// PTP 日期串(YYYYMMDDThhmmss.s)。
  final String captureDate;
  final int thumbWidth;
  final int thumbHeight;
  final int imageWidth;
  final int imageHeight;

  bool get isFolder => format == ObjectFormatCode.association;
}

/// 合成一张确定性渐变 JPEG(可解码,SOI 起头)。
///
/// [seed] 只挪渐变色相,不引入随机 —— 同参必出同字节,测试可作 golden。
Uint8List synthesizeJpeg(int width, int height, {int seed = 0}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final r = (x * 255) ~/ (width == 1 ? 1 : width - 1);
      final g = (y * 255) ~/ (height == 1 ? 1 : height - 1);
      final b = ((x + y + seed) * 255) ~/ (width + height);
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return img.encodeJpg(image, quality: 90);
}

/// 合成确定性伪随机字节(LCG):NEF/MOV 正文用。
Uint8List synthesizeBlob(int length, {int seed = 1}) {
  final out = Uint8List(length);
  var state = 0x6D2B79F5 ^ seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (state >> 16) & 0xFF;
  }
  return out;
}

/// 缺省人设的对象表(5 个对象:DCIM 文件夹 + 2 JPG + 1 NEF + 1 MOV)。
///
/// 尺寸刻意收敛(640×480 / 2MB):e2e 每用例都 boot 一个新 mock,合成
/// 成本必须留在百毫秒级;NEF 2MB 足够压出 GetPartialObject 的多块重组。
List<MockObject> defaultMockObjects() => [
      MockObject(
        handle: 0x00010000,
        storageId: 0x00010001,
        format: ObjectFormatCode.association,
        filename: 'DCIM',
        body: Uint8List(0),
        thumb: Uint8List(0),
        largeThumb: Uint8List(0),
        parent: 0,
        captureDate: '20261015T101530.00',
      ),
      MockObject(
        handle: 0x00010001,
        storageId: 0x00010001,
        format: ObjectFormatCode.exifJpeg,
        filename: 'DSC_0001.JPG',
        body: synthesizeJpeg(640, 480, seed: 1),
        thumb: synthesizeJpeg(160, 120, seed: 1),
        largeThumb: synthesizeJpeg(320, 240, seed: 1),
        parent: 0x00010000,
        captureDate: '20261015T101530.00',
        thumbWidth: 160,
        thumbHeight: 120,
        imageWidth: 640,
        imageHeight: 480,
      ),
      MockObject(
        handle: 0x00010002,
        storageId: 0x00010001,
        format: ObjectFormatCode.exifJpeg,
        filename: 'DSC_0002.JPG',
        body: synthesizeJpeg(640, 480, seed: 2),
        thumb: synthesizeJpeg(160, 120, seed: 2),
        largeThumb: synthesizeJpeg(320, 240, seed: 2),
        parent: 0x00010000,
        captureDate: '20261015T102101.00',
        thumbWidth: 160,
        thumbHeight: 120,
        imageWidth: 640,
        imageHeight: 480,
      ),
      MockObject(
        handle: 0x00010003,
        storageId: 0x00010001,
        // NEF 的格式码真机实测就是 0x3000 Undefined(浏览层按扩展名兜底)。
        format: ObjectFormatCode.undefined,
        filename: 'DSC_0003.NEF',
        body: synthesizeBlob(2 * 1024 * 1024, seed: 3),
        thumb: synthesizeJpeg(160, 120, seed: 3),
        largeThumb: synthesizeJpeg(320, 240, seed: 3),
        parent: 0x00010000,
        captureDate: '20261015T103012.00',
        thumbWidth: 160,
        thumbHeight: 120,
        imageWidth: 6048,
        imageHeight: 4024,
      ),
      MockObject(
        handle: 0x00010004,
        storageId: 0x00010001,
        // MOV 容器 Zf 真机在册 MTP 码 0xB982(按 mp4 口径)。
        format: ObjectFormatCode.mp4,
        filename: 'DSC_0004.MOV',
        body: synthesizeBlob(256 * 1024, seed: 4),
        thumb: synthesizeJpeg(160, 120, seed: 4),
        largeThumb: synthesizeJpeg(320, 240, seed: 4),
        parent: 0x00010000,
        captureDate: '20261015T110244.00',
        thumbWidth: 160,
        thumbHeight: 120,
        imageWidth: 3840,
        imageHeight: 2160,
      ),
    ];

/// 从真实目录装载对象(CLI `--objects-dir`):文件名/大小如实,正文 =
/// 文件字节;JPEG 文件自任缩略,其余类型缩略仍合成(NEF/MOV 的内嵌
/// 缩略不可凭空造)。目录不存在/为空抛 [UsageException 形态的] Exception。
List<MockObject> loadObjectsFromDirectory(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    throw ArgumentError('对象目录不存在: $dirPath');
  }
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    throw ArgumentError('对象目录为空: $dirPath');
  }
  final objects = <MockObject>[
    MockObject(
      handle: 0x00010000,
      storageId: 0x00010001,
      format: ObjectFormatCode.association,
      filename: 'DCIM',
      body: Uint8List(0),
      thumb: Uint8List(0),
      largeThumb: Uint8List(0),
      parent: 0,
      captureDate: '20261015T101530.00',
    ),
  ];
  var handle = 0x00010001;
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    final body = file.readAsBytesSync();
    final isJpeg = ext == 'jpg' || ext == 'jpeg';
    // 真实 JPEG 自任缩略(手动冒烟时缩略即原片);其余合成占位缩略。
    final thumb = isJpeg ? body : synthesizeJpeg(160, 120, seed: handle);
    objects.add(MockObject(
      handle: handle,
      storageId: 0x00010001,
      format: switch (ext) {
        'jpg' || 'jpeg' => ObjectFormatCode.exifJpeg,
        'nef' || 'nrw' => ObjectFormatCode.undefined,
        'mov' => ObjectFormatCode.quickTime,
        'mp4' => ObjectFormatCode.mp4,
        _ => ObjectFormatCode.undefined,
      },
      filename: name,
      body: body,
      thumb: thumb,
      largeThumb: isJpeg ? body : thumb,
      parent: 0x00010000,
      captureDate: '20261015T101530.00',
      thumbWidth: isJpeg ? 0 : 160,
      thumbHeight: isJpeg ? 0 : 120,
    ));
    handle++;
  }
  return objects;
}

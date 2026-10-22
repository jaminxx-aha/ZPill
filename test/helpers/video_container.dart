/// 合成 Nikon MOV 容器(ftyp/moov/mvhd/udta/NCDT/NCHD/NCTG),NCTG 内
/// 注入评级条目(`01 00 08 00 01` + u16 LE 评级)—— 视频评级甄别测试
/// 共用(video_rating_test / object_repository_test)。
library;

import 'dart:typed_data';

List<int> videoBox(String type, List<int> payload) => [
      ...[(payload.length + 8) >> 24, (payload.length + 8) >> 16,
          (payload.length + 8) >> 8, (payload.length + 8)],
      ...type.codeUnits,
      ...payload,
    ];

/// [rating]:1-5 = 星档,0 = 无评级,0xFFFF = 删除候选。
Uint8List videoContainerBytes(int rating) {
  final nctgPayload = <int>[
    ...[0, 0, 0, 1], // 版本 u32
    ...[0x00, 0x02, 0x00, 0x12], // tag 2 / count 18
    ...'NIKON CORPORATION '.codeUnits, // 18B
    ...[0x00, 0x01, 0x00, 0x08], // tag 1 / count 8
    ...[0x01, 0x00, 0x08, 0x00, 0x01], // 评级条目特征前缀
    rating & 0xFF,
    (rating >> 8) & 0xFF, // 评级 u16 LE
    ...[0x00, 0x10, 0x02, 0x00], // 后随条目(分辨率族)
    ...[0x02, 0x80, 0x01, 0x68],
  ];
  final ncdtPayload = [
    ...videoBox('NCHD', List.filled(10, 0)),
    ...videoBox('NCTG', nctgPayload),
  ];
  final moovPayload = [
    ...videoBox('mvhd', List.filled(100, 0)),
    ...videoBox('udta', videoBox('NCDT', ncdtPayload)),
  ];
  return Uint8List.fromList([
    ...videoBox('ftyp', List.filled(16, 0)),
    ...videoBox('moov', moovPayload),
  ]);
}

/// readVideoRating 单测:合成 MOV 容器(结构按 2026-10-23 真机
/// ★4/★5/垃圾桶 NCTG 逐字节标定),评级条目注入/缺失/预算各态。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/media/video_rating.dart';

import '../../helpers/video_container.dart';

Uint8List _slice(Uint8List c, int off, int len) =>
    Uint8List.sublistView(c, off, (off + len).clamp(0, c.length));

void main() {
  Future<int?> run(Uint8List c) =>
      readVideoRating((off, len) async => _slice(c, off, len));

  test('★4:评级条目 u16 LE = 4', () async {
    expect(await run(videoContainerBytes(4)), 4);
  });

  test('★5:5', () async {
    expect(await run(videoContainerBytes(5)), 5);
  });

  test('删除候选:0xFFFF', () async {
    expect(await run(videoContainerBytes(0xffff)), 0xffff);
  });

  test('无评级:0', () async {
    expect(await run(videoContainerBytes(0)), 0);
  });

  test('模式缺席:null(不误判)', () async {
    final c = videoContainerBytes(4)
      ..setRange(212, 217, [0x02, 0x00, 0x08, 0x00, 0x02]); // 破坏特征
    expect(await run(c), isNull);
  });

  test('无 moov:null', () async {
    final c = Uint8List.fromList(videoBox('ftyp', List.filled(16, 0)));
    expect(await run(c), isNull);
  });
}

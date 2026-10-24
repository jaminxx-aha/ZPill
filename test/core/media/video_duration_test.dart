// mvhd 时长解析单测:合成容器(v0/v1/moov 在尾/病箱)。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/media/video_duration.dart';

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...payload,
  ]);
}

Uint8List _mvhdV0(int timescale, int duration) => _box('mvhd', [
      0x00, 0x00, 0x00, 0x00, // version 0 + flags
      0, 0, 0, 1, // ctime
      0, 0, 0, 2, // mtime
      ...[(timescale >> 24) & 0xff, (timescale >> 16) & 0xff,
          (timescale >> 8) & 0xff, timescale & 0xff],
      ...[(duration >> 24) & 0xff, (duration >> 16) & 0xff,
          (duration >> 8) & 0xff, duration & 0xff],
      0, 0, 0, 1, // rate
      1, 0, 0, 0, // volume
    ]);

Uint8List _mvhdV1(int timescale, int duration) => _box('mvhd', [
      0x01, 0x00, 0x00, 0x00, // version 1 + flags
      ...List.filled(8, 0), // ctime
      ...List.filled(8, 0), // mtime
      ...[(timescale >> 24) & 0xff, (timescale >> 16) & 0xff,
          (timescale >> 8) & 0xff, timescale & 0xff],
      ...[0, 0, 0, 0, (duration >> 24) & 0xff, (duration >> 16) & 0xff,
          (duration >> 8) & 0xff, duration & 0xff],
    ]);

Uint8List slice(Uint8List b, int off, int len) {
  if (off >= b.length) return Uint8List(0);
  final end = off + len > b.length ? b.length : off + len;
  return Uint8List.sublistView(b, off, end);
}

void main() {
  test('v0:moov 在头(mdat 之前),时长 = duration/timescale', () async {
    final bytes = Uint8List.fromList([
      ..._box('ftyp', List.filled(8, 0x20)),
      ..._box('moov', [..._mvhdV0(600, 90000)]), // 150s
      ..._box('mdat', List.filled(64, 0xaa)),
    ]);
    final d = await readVideoDuration((off, len) async => slice(bytes, off, len));
    expect(d, const Duration(seconds: 150));
  });

  test('v1:moov 在尾(Nikon 形态,mdat 按尺寸跳过)', () async {
    final bytes = Uint8List.fromList([
      ..._box('ftyp', List.filled(8, 0x20)),
      ..._box('mdat', List.filled(2000, 0xaa)),
      ..._box('moov', [..._mvhdV1(1000, 61000)]), // 61s
    ]);
    final d = await readVideoDuration((off, len) async => slice(bytes, off, len));
    expect(d, const Duration(seconds: 61));
  });

  test('无 moov/病箱:返回 null 不误判', () async {
    final noMoov = Uint8List.fromList([
      ..._box('ftyp', List.filled(8, 0x20)),
      ..._box('mdat', List.filled(64, 0xaa)),
    ]);
    expect(await readVideoDuration((off, len) async => slice(noMoov, off, len)),
        isNull);
    final truncated = Uint8List.fromList([0, 0, 0, 1]); // 病箱头
    expect(
        await readVideoDuration(
            (off, len) async => Uint8List.sublistView(truncated)),
        isNull);
  });

  test('formatVideoDuration:m:ss 与 h:mm:ss', () {
    expect(formatVideoDuration(const Duration(seconds: 61)), '1:01');
    expect(formatVideoDuration(const Duration(seconds: 5)), '0:05');
    expect(formatVideoDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });
}

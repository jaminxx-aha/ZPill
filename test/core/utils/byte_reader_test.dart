import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/utils/byte_reader.dart';
import 'package:z_pill/core/utils/byte_writer.dart';

void main() {
  group('ByteWriter/ByteReader 小端序(字节序错误的包会被相机静默丢弃)', () {
    test('u16 小端字节序', () {
      final w = ByteWriter()..u16(0x1234);
      expect(w.takeBytes(), [0x34, 0x12]);
    });

    test('u32 小端字节序', () {
      final w = ByteWriter()..u32(0x12345678);
      expect(w.takeBytes(), [0x78, 0x56, 0x34, 0x12]);
    });

    test('u64 小端字节序(承载大文件总长度)', () {
      final w = ByteWriter()..u64(0x0102030405060708);
      expect(w.takeBytes(), [8, 7, 6, 5, 4, 3, 2, 1]);

      final r = ByteReader(Uint8List.fromList([8, 7, 6, 5, 4, 3, 2, 1]));
      expect(r.u64(), 0x0102030405060708);
    });

    test('UTF-16LE 往返(InitCommandReq 主机名)', () {
      final w = ByteWriter()..u32(12)..utf16le('Nikon');
      final bytes = w.takeBytes();
      expect(bytes.length, 4 + 10);
      expect(bytes.sublist(4), [0x4E, 0, 0x69, 0, 0x6B, 0, 0x6F, 0, 0x6E, 0]);

      final r = ByteReader(bytes)..u32();
      expect(r.utf16le(10), 'Nikon');
    });

    test('raw 读取返回副本且推进 offset', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final r = ByteReader(bytes);
      final first = r.raw(2);
      expect(first, [1, 2]);
      first[0] = 99;
      expect(bytes[0], 1, reason: 'raw() 必须返回副本,避免污染协议缓冲');
      expect(r.remaining, 2);
    });
  });
}

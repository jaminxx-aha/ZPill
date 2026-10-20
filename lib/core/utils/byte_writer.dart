/// 小端序字节写入器;约定同 [ByteReader](全部小端)。
library;

import 'dart:typed_data';

final class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  int get length => _b.length;

  void u8(int v) => _b.add(Uint8List(1)..[0] = v & 0xFF);

  void u16(int v) => _b.add(_bytes(2, (bd) => bd.setUint16(0, v, Endian.little)));

  void u32(int v) => _b.add(_bytes(4, (bd) => bd.setUint32(0, v, Endian.little)));

  void u64(int v) => _b.add(_bytes(8, (bd) => bd.setUint64(0, v, Endian.little)));

  void raw(List<int> bytes) => _b.add(bytes);

  /// 写入 UTF-16LE 字节(不含长度前缀)。
  /// PTP-IP InitCommandReq 的主机名长度字段是 **uint32**,
  /// 而 PTP 数据集内字符串长度是 uint8 —— 长度字段由调用方按各自布局显式写,
  /// 避免宽度错位。
  void utf16le(String s) {
    final units = s.codeUnits;
    final out = Uint8List(units.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.little);
    }
    _b.add(out);
  }

  /// 写 PTP STRING 数据集类型(u8 字符数 + UTF-16LE;null = 0xFF 未提供)。
  /// 与 [ByteReader.ptpString] 互逆,不写结尾 NUL(读侧自剥)。
  void ptpString(String? s) {
    if (s == null) {
      u8(0xFF);
      return;
    }
    final units = s.codeUnits;
    u8(units.length);
    utf16le(s);
  }

  Uint8List takeBytes() => _b.takeBytes();

  Uint8List _bytes(int size, void Function(ByteData bd) write) {
    final b = Uint8List(size);
    write(ByteData.sublistView(b));
    return b;
  }
}

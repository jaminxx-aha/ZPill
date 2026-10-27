/// 小端序字节读取器。
///
/// PTP-IP 所有多字节字段均为小端(字节序错误时相机会静默丢弃,
/// 极易误诊为"端口未激活")。
/// 因此协议字节读写**只允许**经由 [ByteReader]/[ByteWriter],禁止手写位移。
library;

import 'dart:typed_data';

final class ByteReader {
  ByteReader(this.bytes, [this.offset = 0]) {
    if (offset < 0 || offset > bytes.length) {
      throw ArgumentError.value(offset, 'offset', '超出字节缓冲范围');
    }
  }

  final Uint8List bytes;
  int offset;

  bool get eof => offset >= bytes.length;
  int get remaining => bytes.length - offset;

  int u8() {
    _need(1);
    return bytes[offset++];
  }

  int u16() {
    _need(2);
    final v = ByteData.sublistView(bytes, offset, offset + 2)
        .getUint16(0, Endian.little);
    offset += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = ByteData.sublistView(bytes, offset, offset + 4)
        .getUint32(0, Endian.little);
    offset += 4;
    return v;
  }

  /// Dart int 为 64 位补码,足够承载 uint64 文件总长度。
  int u64() {
    _need(8);
    final v = ByteData.sublistView(bytes, offset, offset + 8)
        .getUint64(0, Endian.little);
    offset += 8;
    return v;
  }

  /// 读 [length] 字节(返回副本,不与源共享缓冲)。
  Uint8List raw(int length) {
    _need(length);
    final view = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return Uint8List.fromList(view);
  }

  /// 读 [length] 字节(返回**视图**,与源共享缓冲):大块载荷用
  /// (整帧转发免一遍拷贝),调用方不得原地修改、须自行保证源存活;
  /// 小字段仍用 [raw](副本,源释放后仍可持有)。
  Uint8List rawView(int length) {
    _need(length);
    final view = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return view;
  }

  /// 读 UTF-16LE 字符串([byteLength] 必须为偶数)。
  String utf16le(int byteLength) {
    if (byteLength.isOdd) {
      throw FormatException('UTF-16LE 字节长度 $byteLength 不是偶数');
    }
    _need(byteLength);
    final units = <int>[];
    final end = offset + byteLength;
    for (; offset < end; offset += 2) {
      units.add(bytes[offset] | (bytes[offset + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  /// 读 PTP STRING 数据集类型(ISO 15740):u8 字符数 + UTF-16LE 内容。
  ///
  /// 字符数 0xFF 表示「未提供」返回 null;结尾 NUL 终止符剥掉
  /// (真机实测:Zf 的文件名/卷标都带 1 个 NUL,不剥会导致扩展名判断失效)。
  String? ptpString() {
    final n = u8();
    if (n == 0xFF) return null;
    if (n == 0) return '';
    _need(2 * n);
    var s = utf16le(2 * n);
    while (s.endsWith('\u0000')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 读 NUL 终止的 UTF-16LE 字符串,无长度前缀。
  ///
  /// 尼康 Wi-Fi 方言(MTP/IP 布局,Camera_Bridge 实证):
  /// InitCommandResponse 的相机名与 InitCommandRequest 的主机名都用这种。
  /// 读不到 NUL 时读到缓冲末尾(宽容截断)。
  String utf16z() {
    final units = <int>[];
    while (offset + 1 < bytes.length) {
      final u = bytes[offset] | (bytes[offset + 1] << 8);
      offset += 2;
      if (u == 0) return String.fromCharCodes(units);
      units.add(u);
    }
    if (offset < bytes.length) offset++; // 末尾孤字节,对齐吞掉
    return String.fromCharCodes(units);
  }

  void _need(int length) {
    if (length < 0) {
      throw FormatException('字节读取长度 $length 为负');
    }
    if (length > remaining) {
      throw FormatException(
          '字节读取越界(需 $length B,剩 $remaining B,offset=$offset)');
    }
  }
}

/// Nikon 智能设备模式 TIME 载荷:10 字节小端,写 GATT 特征 0x2006。
///
/// 布局:年 u16 LE + 月(1-12)/日/时/分/秒(各 1B,UTC)+ 夏令时偏移
/// (1B,恒 0 —— 时区字节已含 DST)+ 时区时(1B 有符号)+ 时区分
/// (1B 有符号,与时同号)。
///
/// 时区拆分用截断而非向下取整:UTC-3:30 须为 (-3, -30),floor 会错成
/// (-4, +30)。西半球负偏移未真机核验,实施后须验证。
library;

import 'dart:typed_data';

final class TimePayload {
  static const int length = 10;

  /// 构建 10 字节载荷。[now] 取其 UTC 字段;时区缺省用本机时区
  /// (东半球为正,同 [DateTime.timeZoneOffset] 语义)。
  static Uint8List build(DateTime now, {Duration? timeZoneOffset}) {
    final utc = now.toUtc();
    final offsetMinutes = (timeZoneOffset ?? now.timeZoneOffset).inMinutes;
    final hours = offsetMinutes ~/ 60; // Dart ~/ 向零截断,与时同号
    final minutes = offsetMinutes.remainder(60);

    final data = ByteData(length)
      ..setUint16(0, utc.year, Endian.little)
      ..setUint8(2, utc.month)
      ..setUint8(3, utc.day)
      ..setUint8(4, utc.hour)
      ..setUint8(5, utc.minute)
      ..setUint8(6, utc.second)
      ..setUint8(7, 0)
      ..setInt8(8, hours)
      ..setInt8(9, minutes);
    return data.buffer.asUint8List();
  }
}

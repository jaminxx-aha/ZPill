/// Nikon 智能设备模式 GEO 载荷:41 字节小端,写 GATT 特征 0x2007。
///
/// 布局(相机方言定案,与 SnapBridge smali + nsg 双源交叉证实):
/// 头 0x007F LE(2B)+ 纬向/度/分/submin1/submin2(5B)+ 经向同构(5B)+
/// 卫星数(1B,0-100)+ 海拔基准 'P'/'M'+海拔绝对值 u16 LE(3B)+
/// UTC 年 u16 LE/月/日/时/分/秒(7B)+ 百分秒(1B,ms/10)+
/// 有效位 0x01(1B)+ "WGS-84" ASCII(6B)+ 零填充(10B)。
///
/// 分数分编码:submin1 = 分的小数部分 ×100 取整(0-99),submin2 = 余数再
/// ×100 取整(0-99)—— 两组「百分之一分」,非两个十进制数字节。
library;

import 'dart:typed_data';

/// 一次定位快照:十进制度、海拔米、卫星数、UTC 时刻。
class GeoFix {
  final double latitude;
  final double longitude;
  final double altitude;
  final int satellites;
  final DateTime utcTime;

  const GeoFix({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.satellites,
    required this.utcTime,
  });
}

final class GeoPayload {
  static const int length = 41;
  static const int header = 0x007F;
  static const int valid = 0x01;

  static const int _north = 0x4E; // 'N'
  static const int _south = 0x53; // 'S'
  static const int _east = 0x45; // 'E'
  static const int _west = 0x57; // 'W'
  static const int _altAbove = 0x50; // 'P'
  static const int _altBelow = 0x4D; // 'M'

  /// 构建 41 字节载荷。
  Uint8List build(GeoFix fix) {
    final lat = _decimalToNikon(fix.latitude, _north, _south);
    final lon = _decimalToNikon(fix.longitude, _east, _west);
    final t = fix.utcTime.toUtc();
    final sats = fix.satellites.clamp(0, 100);
    final alt = fix.altitude.truncate();

    final data = ByteData(length);
    var off = 0;
    void u8(int v) => data.setUint8(off++, v & 0xFF);

    data.setUint16(off, header, Endian.little);
    off += 2;

    u8(lat.$1);
    u8(lat.$2);
    u8(lat.$3);
    u8(lat.$4);
    u8(lat.$5);

    u8(lon.$1);
    u8(lon.$2);
    u8(lon.$3);
    u8(lon.$4);
    u8(lon.$5);

    u8(sats);

    u8(fix.altitude >= 0 ? _altAbove : _altBelow);
    data.setUint16(off, alt.abs() & 0xFFFF, Endian.little);
    off += 2;

    data.setUint16(off, t.year, Endian.little);
    off += 2;
    u8(t.month); // Dart 月即 1-12,无 JS 的 0 基偏移
    u8(t.day);
    u8(t.hour);
    u8(t.minute);
    u8(t.second);
    u8(t.millisecond ~/ 10);

    u8(valid);

    const wgs84 = <int>[0x57, 0x47, 0x53, 0x2D, 0x38, 0x34]; // "WGS-84"
    for (final c in wgs84) {
      u8(c);
    }
    while (off < length) {
      u8(0);
    }
    return data.buffer.asUint8List();
  }

  /// 十进制度 → (方向, 度, 分, submin1, submin2)。
  ///
  /// 度/分向下取整;分的小数部分 ×100 与 ×10000 依次取整得 submin1/2。
  static (int, int, int, int, int) _decimalToNikon(
    double decimal,
    int positiveRef,
    int negativeRef,
  ) {
    final direction = decimal < 0 ? negativeRef : positiveRef;
    final abs = decimal.abs();
    final degrees = abs.floor();
    final minutesFull = (abs - degrees) * 60.0;
    final minutes = minutesFull.floor();
    final submin1Full = (minutesFull - minutes) * 100.0;
    final submin1 = submin1Full.floor();
    final submin2Full = (submin1Full - submin1) * 100.0;
    final submin2 = submin2Full.floor();
    return (direction, degrees, minutes, submin1, submin2);
  }
}

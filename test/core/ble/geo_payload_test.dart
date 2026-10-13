import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/geo_payload.dart';

GeoFix fix({
  double lat = 35.5,
  double lon = -74.0,
  double alt = -50,
  int sats = 18,
  DateTime? time,
}) =>
    GeoFix(
      latitude: lat,
      longitude: lon,
      altitude: alt,
      satellites: sats,
      utcTime: time ?? DateTime.utc(2026, 10, 13, 8, 30, 0, 230),
    );

void main() {
  group('GeoPayload', () {
    test('已知坐标逐字节:35.5/-74.0/海拔 -50/卫星 18', () {
      final payload = GeoPayload().build(fix());
      expect(payload.length, 41);
      expect(
        payload,
        <int>[
          0x7F, 0x00, // 头 0x007F LE
          0x4E, 0x23, 0x1E, 0x00, 0x00, // N 35°30.0000'
          0x57, 0x4A, 0x00, 0x00, 0x00, // W 74°00.0000'
          0x12, // 卫星 18
          0x4D, 0x32, 0x00, // 'M' 海拔 50(负 → M)
          0xEA, 0x07, // 2026
          0x0A, 0x0D, 0x08, 0x1E, 0x00, // 10-13 08:30:00 UTC
          0x17, // 百分秒 23(ms 230/10)
          0x01, // 有效位
          0x57, 0x47, 0x53, 0x2D, 0x38, 0x34, // "WGS-84"
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 填充
        ],
      );
    });

    test('海拔正负基准:8848 → P/0x2290,0 → P', () {
      final up = GeoPayload().build(fix(alt: 8848));
      expect(up[13], 0x50); // 'P'
      expect(up[14], 0x90);
      expect(up[15], 0x22);

      final zero = GeoPayload().build(fix(alt: 0));
      expect(zero[13], 0x50);
      expect(zero[14], 0x00);
      expect(zero[15], 0x00);
    });

    test('卫星数钳 0-100', () {
      expect(GeoPayload().build(fix(sats: 120))[12], 100);
      expect(GeoPayload().build(fix(sats: -3))[12], 0);
    });

    test('坐标往返:编码字段还原误差 ≤ 4e-6 度(submin2 两个单位内)', () {
      // 非整分坐标走往返断言 —— 浮点 floor 在十进制边界处天然可能偏 1 个
      // 百分位,与参考实现一致,精度 1e-4 分 ≈ 0.19 m,协议即此粒度。
      const lat = 35.6812376;
      const lon = 139.7454309;
      final payload = GeoPayload().build(fix(lat: lat, lon: lon, alt: 3740, sats: 24));

      double decodeDir(int ref, int deg, int min, int s1, int s2) {
        final positive = ref == 0x4E || ref == 0x45;
        final value = deg + (min + (s1 + s2 / 100) / 100) / 60;
        return positive ? value : -value;
      }

      final decodedLat = decodeDir(payload[2], payload[3], payload[4], payload[5], payload[6]);
      final decodedLon = decodeDir(payload[7], payload[8], payload[9], payload[10], payload[11]);
      expect((decodedLat - lat).abs(), lessThan(4e-6));
      expect((decodedLon - lon).abs(), lessThan(4e-6));
      expect(payload[2], 0x4E);
      expect(payload[7], 0x45);
    });

    test('南纬西经方向字节', () {
      final payload = GeoPayload().build(fix(lat: -33.8688, lon: -151.2093));
      expect(payload[2], 0x53); // 'S'
      expect(payload[7], 0x57); // 'W'
    });
  });
}

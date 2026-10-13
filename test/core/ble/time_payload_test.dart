import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/time_payload.dart';

void main() {
  group('TimePayload', () {
    test('10 字节布局:UTC 字段 + DST 0 + 时区同号拆分', () {
      final payload = TimePayload.build(
        DateTime.utc(2026, 10, 13, 12, 34, 56),
        timeZoneOffset: const Duration(hours: 8),
      );
      expect(payload.length, 10);
      expect(
        payload,
        <int>[
          0xEA, 0x07, // 2026 u16 LE
          0x0A, 0x0D, 0x0C, 0x22, 0x38, // 月日时分秒
          0x00, // DST 恒 0
          0x08, 0x00, // UTC+8:00
        ],
      );
    });

    test('西半球负偏移:UTC-3:30 → (-3, -30) 同号(截断非 floor)', () {
      final payload = TimePayload.build(
        DateTime.utc(2026, 10, 13, 12, 34, 56),
        timeZoneOffset: const Duration(hours: -3, minutes: -30),
      );
      // Uint8List 读回无符号:int8 -3 落盘 0xFD、-30 落盘 0xE2。
      expect(payload[8], 0xFD); // setInt8(-3)
      expect(payload[9], 0xE2); // setInt8(-30)
    });

    test('四分之一时区:UTC+5:45 → (5, 45)', () {
      final payload = TimePayload.build(
        DateTime.utc(2026, 10, 13, 12, 34, 56),
        timeZoneOffset: const Duration(hours: 5, minutes: 45),
      );
      expect(payload[8], 5);
      expect(payload[9], 45);
    });

    test('缺省时区:UTC 字段与时区无关,恒可断言', () {
      final payload = TimePayload.build(DateTime.utc(2026, 10, 13, 12, 34, 56));
      expect(payload[0], 0xEA);
      expect(payload[1], 0x07);
      expect(payload[2], 0x0A);
      expect(payload[3], 0x0D);
      expect(payload[4], 0x0C);
      expect(payload[5], 0x22);
      expect(payload[6], 0x38);
      expect(payload[7], 0x00);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/platform/motion_host.dart';

void main() {
  group('MotionOrientation.fromList', () {
    test('[pitch, roll] 正常解析,数值保真', () {
      final o = MotionOrientation.fromList(<Object?>[0.5236, -0.1745]);
      expect(o.pitchRad, closeTo(0.5236, 1e-9));
      expect(o.rollRad, closeTo(-0.1745, 1e-9));
    });

    test('度数文案(1 位小数)', () {
      final o = MotionOrientation(pitchRad: 0.1745329252, rollRad: -0.5235987756);
      expect(o.pitchText, '10.0°');
      expect(o.rollText, '-30.0°');
    });

    test('载荷不是二元列表 → FormatException', () {
      expect(() => MotionOrientation.fromList(<Object?>[0.1]),
          throwsFormatException);
      expect(() => MotionOrientation.fromList(<Object?>[0.1, 0.2, 0.3]),
          throwsFormatException);
      expect(() => MotionOrientation.fromList('bad'), throwsFormatException);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/ble/ble_keepalive.dart';
import 'package:nikon_pill/core/ble/geo_payload.dart';

/// BleKeepalive 纯策略单元:档位间隔 / TIME 到点 / GEO 去重门 / 距离。
/// 假时钟直排时间轴,不真等 45s。
void main() {
  final t0 = DateTime.utc(2026, 10, 15, 12, 0, 0);

  GeoFix fixAt(double lat) => GeoFix(
        latitude: lat,
        longitude: 139.0,
        altitude: 10,
        satellites: 8,
        utcTime: t0,
      );

  test('档位:缺省前台 45s;切后台 90s;切回前台恢复', () {
    final k = BleKeepalive();
    expect(k.isForeground, isTrue);
    expect(k.interval, BleKeepalive.foregroundInterval);
    expect(k.interval, const Duration(seconds: 45));
    k.foreground = false;
    expect(k.isForeground, isFalse);
    expect(k.interval, BleKeepalive.backgroundInterval);
    expect(k.interval, const Duration(seconds: 90));
    k.foreground = true;
    expect(k.interval, const Duration(seconds: 45));
  });

  test('TIME 到点:首笔(无成功锚)恒到点;不足档位间隔不到;到点即写', () {
    final k = BleKeepalive();
    final okAt = t0;
    expect(k.timeDue(t0, null), isTrue); // Ready 后首笔(收口校时)
    expect(k.timeDue(t0.add(const Duration(seconds: 44)), okAt), isFalse);
    expect(k.timeDue(t0.add(const Duration(seconds: 45)), okAt), isTrue);

    k.foreground = false; // 后台档拉长到 90s
    expect(k.timeDue(t0.add(const Duration(seconds: 89)), okAt), isFalse);
    expect(k.timeDue(t0.add(const Duration(seconds: 90)), okAt), isTrue);
  });

  test('GEO 去重门:无成功记录恒过;≥1.1m 或 ≥3s 即过;两者同缺才跳', () {
    final k = BleKeepalive();
    final lastOk = fixAt(35.5);
    final okAt = t0;

    // 首笔:无历史 → 过。
    expect(k.geoPassesDedup(t0, fixAt(35.5), null, null), isTrue);

    // <3s 且 <1.1m(~1.0m)→ 跳。
    expect(
        k.geoPassesDedup(
            t0.add(const Duration(seconds: 2)), fixAt(35.500009), lastOk, okAt),
        isFalse);

    // <3s 但 ≥1.1m(~1.11m)→ 过。
    expect(
        k.geoPassesDedup(
            t0.add(const Duration(seconds: 2)), fixAt(35.50001), lastOk, okAt),
        isTrue);

    // ≥3s 但未动 → 过。
    expect(
        k.geoPassesDedup(
            t0.add(const Duration(seconds: 3)), fixAt(35.5), lastOk, okAt),
        isTrue);
  });

  test('距离:同点为 0;纬向 0.001° ≈ 111m;经向随纬度收缩', () {
    expect(BleKeepalive.distanceM(fixAt(35.5), fixAt(35.5)), 0);
    final latM = BleKeepalive.distanceM(fixAt(35.5), fixAt(35.501));
    expect(latM, closeTo(111.2, 0.5));
    // 经度差 0.001° 在纬度 35.5 处 ≈ 111.2 × cos(35.5°) ≈ 90.6m。
    final lonM = BleKeepalive.distanceM(
        GeoFix(
            latitude: 35.5,
            longitude: 139.0,
            altitude: 10,
            satellites: 8,
            utcTime: t0),
        GeoFix(
            latitude: 35.5,
            longitude: 139.001,
            altitude: 10,
            satellites: 8,
            utcTime: t0));
    expect(lonM, closeTo(90.6, 0.5));
  });
}

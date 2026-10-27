import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/log/app_log.dart';

void main() {
  setUp(() => AppLog.resetForTest());

  group('记录与行格式', () {
    test('级别/域/消息原样进环,行格式带符号与域', () {
      AppLog.i(AppLog.protocol, '→ GetDeviceInfo tid=0');
      AppLog.e(AppLog.usb, 'bulkRead 失败');

      final es = AppLog.entries;
      expect(es, hasLength(2));
      expect(es[0].level, AppLogLevel.info);
      expect(es[0].domain, 'protocol');
      expect(es[0].message, '→ GetDeviceInfo tid=0');
      expect(es[1].line, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[E/usb\] ')));
    });

    test('log() 动态级别(原生日志透传路径)', () {
      AppLog.log(AppLogLevel.warn, AppLog.native, 'BLE didDisconnect');
      expect(AppLog.entries.single.level, AppLogLevel.warn);
      expect(AppLog.entries.single.domain, 'native');
    });
  });

  group('环形缓冲', () {
    test('溢出弃最老,窗口内保持时间序', () {
      AppLog.configure(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        AppLog.i(AppLog.transfer, 't$i');
      }
      expect(AppLog.entries.map((e) => e.message).toList(), ['t3', 't4', 't5']);
    });

    test('容量 1 退化为只留最新,不崩', () {
      AppLog.configure(capacity: 1);
      AppLog.d(AppLog.ble, 'a');
      AppLog.d(AppLog.ble, 'b');
      expect(AppLog.entries.single.message, 'b');
    });
  });

  group('dump 过滤', () {
    test('minLevel 滤低级别', () {
      AppLog.d(AppLog.protocol, 'd');
      AppLog.w(AppLog.protocol, 'w');
      AppLog.e(AppLog.protocol, 'e');
      final out = AppLog.dump(minLevel: AppLogLevel.warn);
      expect(out.contains(' d'), isFalse);
      expect(out.contains('[W/protocol] w'), isTrue);
      expect(out.contains('[E/protocol] e'), isTrue);
    });

    test('domain 单选', () {
      AppLog.i(AppLog.protocol, 'p');
      AppLog.i(AppLog.ble, 'b');
      final out = AppLog.dump(domain: AppLog.ble);
      expect(out.contains('p'), isFalse);
      expect(out.contains('[I/ble] b'), isTrue);
    });
  });

  group('verbose 闸门', () {
    test('默认全关,开关即生效', () {
      expect(AppLog.isVerbose(AppLog.protocol), isFalse);
      AppLog.setVerbose(AppLog.protocol);
      expect(AppLog.isVerbose(AppLog.protocol), isTrue);
      AppLog.setVerbose(AppLog.protocol, on: false);
      expect(AppLog.isVerbose(AppLog.protocol), isFalse);
      // 其他域不受牵连
      expect(AppLog.isVerbose(AppLog.usb), isFalse);
    });
  });

  group('hex 转储', () {
    test('默认截断尾部并标余量', () {
      final bytes = List<int>.generate(40, (i) => i);
      final out = AppLog.hex(bytes);
      expect(out.startsWith('00 01 02 03'), isTrue);
      expect(out.endsWith('…+8B'), isTrue);
    });

    test('sensitive ≤32B 整体打码(含 17B 配对帧)', () {
      expect(AppLog.hex([1, 2, 3], sensitive: true), '<脱敏 3B>');
      expect(AppLog.hex(List.filled(17, 1), sensitive: true), '<脱敏 17B>');
      expect(AppLog.hex(List.filled(32, 1), sensitive: true), '<脱敏 32B>');
    });

    test('sensitive 长块只露前后 4B、中段打码', () {
      final blob = List<int>.generate(97, (i) => (0xA0 + i) & 0xFF);
      final out = AppLog.hex(blob, sensitive: true);
      expect(out.startsWith('A0 A1 A2 A3'), isTrue);
      expect(out.endsWith('FD FE FF 00'), isTrue);
      expect(out.contains('…(脱敏 89B)'), isTrue);
    });

    test('空与恰好 max 不加余量标记', () {
      expect(AppLog.hex(const []), '(空)');
      expect(AppLog.hex([1, 2], max: 2), '01 02');
    });
  });

  group('装配出口', () {
    test('mirror 收全量行,errorTail 只收 error', () {
      final mirrored = <String>[];
      final tailed = <String>[];
      AppLog.configure(mirror: mirrored.add, errorTail: tailed.add);
      AppLog.d(AppLog.ble, 'd');
      AppLog.w(AppLog.ble, 'w');
      AppLog.e(AppLog.ble, 'e');

      expect(mirrored, hasLength(3));
      expect(tailed, hasLength(1));
      expect(tailed.single, contains('[E/ble] e'));
    });

    test('未 configure 时纯内存,回调不炸', () {
      expect(() => AppLog.e(AppLog.usb, 'x'), returnsNormally);
      expect(AppLog.entries.single.message, 'x');
    });
  });

  group('resetForTest 隔离', () {
    test('清缓冲、verbose 与回调', () {
      AppLog.configure(mirror: (_) {}, errorTail: (_) {});
      AppLog.setVerbose(AppLog.ble);
      AppLog.i(AppLog.ble, 'old');
      AppLog.resetForTest();

      expect(AppLog.entries, isEmpty);
      expect(AppLog.isVerbose(AppLog.ble), isFalse);
      expect(AppLog.mirror, isNull);
      expect(AppLog.errorTail, isNull);
      // reset 后缓冲容量回默认:写 defaultCapacity 条不溢出报错
      for (var i = 0; i < AppLog.defaultCapacity; i++) {
        AppLog.d(AppLog.transfer, 'x$i');
      }
      expect(AppLog.entries, hasLength(AppLog.defaultCapacity));
    });
  });
}

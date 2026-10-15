import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptpip/probe.dart';
import 'package:nikon_pill/core/ptpip/subnet_scan.dart';

void main() {
  group('subnetCandidates(/24 候选生成,纯函数)', () {
    test('单接口:1..254 全主机位,去本机/网络位/广播位', () {
      final out = subnetCandidates(const ['192.168.0.5']);
      expect(out, hasLength(253)); // 254 个主机位 - 本机
      expect(out, containsAll(['192.168.0.1', '192.168.0.254']));
      expect(out, isNot(contains('192.168.0.0')), reason: '网络位');
      expect(out, isNot(contains('192.168.0.255')), reason: '广播位');
      expect(out, isNot(contains('192.168.0.5')), reason: '本机自身');
    });

    test('本机在 .1 / .254 边界:仍生成对侧全部', () {
      final low = subnetCandidates(const ['10.0.0.1']);
      expect(low, hasLength(253));
      expect(low.first, '10.0.0.2');
      expect(low.last, '10.0.0.254');
      final high = subnetCandidates(const ['10.0.0.254']);
      expect(high, hasLength(253));
      expect(high.first, '10.0.0.1');
      expect(high.last, '10.0.0.253');
    });

    test('多接口:跨 /24 各自展开,同 /24 去重保序', () {
      final out =
          subnetCandidates(const ['192.168.0.5', '192.168.0.9', '10.1.2.3']);
      expect(out.where((ip) => ip.startsWith('192.168.0.')), hasLength(252));
      expect(out.where((ip) => ip.startsWith('10.1.2.')), hasLength(253));
      expect(out, hasLength(505));
      expect(out.toSet().length, out.length, reason: '无重复');
    });

    test('非法/回环/链路本地/IPv6 跳过;带空白容错', () {
      expect(subnetCandidates(const []), isEmpty);
      expect(subnetCandidates(const ['127.0.0.1']), isEmpty, reason: '回环');
      expect(
          subnetCandidates(const ['169.254.7.7']), isEmpty, reason: '链路本地');
      expect(
          subnetCandidates(
              const ['fe80::1', 'not-an-ip', '', '  ', '256.1.1.1', '1.2.3']),
          isEmpty);
      expect(
          subnetCandidates(const [' 192.168.1.2 ']), contains('192.168.1.1'));
    });
  });

  group('SubnetCameraScanner.scan', () {
    test('端口检查并发池:峰值封顶 concurrency,候选全覆盖', () async {
      var inFlight = 0;
      var peak = 0;
      final checked = <String>{};
      Future<bool> check(String host, int port, Duration timeout) async {
        checked.add(host);
        inFlight++;
        peak = max(peak, inFlight);
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        return host == '192.168.0.42'; // 只有 .42 开放
      }

      final scanner = SubnetCameraScanner(
        interfaceIps: () async => ['192.168.0.5'],
        concurrency: 4,
        connectCheck: check,
        probe: (host) async => ProbedCamera(
          host: host,
          name: 'NIKON Z f',
          cameraGuid: Uint8List(16),
        ),
      );
      final found = await scanner.scan();

      expect(peak, lessThanOrEqualTo(4), reason: '并发池上限');
      expect(peak, 4, reason: '候选充足时打满池(253 > 4)');
      expect(checked.length, 253, reason: '候选逐个覆盖');
      // 只有开放主机被探测,命中入榜
      expect(found, hasLength(1));
      expect(found.single.host, '192.168.0.42');
      expect(found.single.name, 'NIKON Z f');
    });

    test('开放主机串行探测:绝不并发双探测;按末段数值排序;失败不重试', () async {
      var inFlight = 0;
      var peak = 0;
      final probed = <String>[];
      final scanner = SubnetCameraScanner(
        interfaceIps: () async => ['192.168.0.5'],
        connectCheck: (host, port, timeout) async => host == '192.168.0.9' ||
            host == '192.168.0.20' ||
            host == '192.168.0.2',
        probe: (host) async {
          inFlight++;
          peak = max(peak, inFlight);
          await Future<void>.delayed(Duration.zero);
          probed.add(host);
          inFlight--;
          return host == '192.168.0.20'
              ? null // 探测失败(呛住形态):不入榜、不重试(硬约束②)
              : ProbedCamera(
                  host: host,
                  name: host == '192.168.0.2' ? 'NIKON Z f' : '',
                  cameraGuid: Uint8List(0),
                  initFailReason: host == '192.168.0.2' ? null : 0x1,
                );
        },
      );
      final found = await scanner.scan();
      expect(peak, 1, reason: '开放主机串行探测,绝不并发双探测(硬约束④)');
      // 末段数值序:2 < 9 < 20(纯字符串序会是 .2 < .20 < .9)
      expect(probed, ['192.168.0.2', '192.168.0.9', '192.168.0.20']);
      expect(probed.where((h) => h == '192.168.0.20'), hasLength(1),
          reason: '失败主机不重试');
      expect(found, hasLength(2));
      expect(found.first.host, '192.168.0.2');
      expect(found.first.rejected, isFalse);
      expect(found.last.host, '192.168.0.9');
      expect(found.last.rejected, isTrue, reason: 'InitFail 相机照样入榜');
    });

    test('连接超时预算透传到端口检查', () async {
      Duration? seenTimeout;
      final scanner = SubnetCameraScanner(
        interfaceIps: () async => ['192.168.0.5'],
        connectTimeout: const Duration(milliseconds: 650),
        connectCheck: (host, port, timeout) async {
          seenTimeout = timeout;
          return false;
        },
      );
      expect(await scanner.scan(), isEmpty);
      expect(seenTimeout, const Duration(milliseconds: 650));
    });

    test('无接口地址(取用失败形态)→ 空结果,零连接', () async {
      var connectCalls = 0;
      final scanner = SubnetCameraScanner(
        interfaceIps: () async => [],
        connectCheck: (host, port, timeout) async {
          connectCalls++;
          return false;
        },
      );
      expect(await scanner.scan(), isEmpty);
      expect(connectCalls, 0);
    });

    test('全部端口关闭 → 空结果,零探测', () async {
      var probeCalls = 0;
      final scanner = SubnetCameraScanner(
        interfaceIps: () async => ['192.168.0.5'],
        connectCheck: (host, port, timeout) async => false,
        probe: (host) async {
          probeCalls++;
          return null;
        },
      );
      expect(await scanner.scan(), isEmpty);
      expect(probeCalls, 0);
    });
  });
}

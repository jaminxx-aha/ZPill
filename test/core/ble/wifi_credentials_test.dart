import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/blowfish_hasher.dart';
import 'package:z_pill/core/ble/wifi_credentials.dart';

/// 用与解密同核的 Blowfish 构造 97B 凭据 blob(测试向量制造器):
/// 32B SSID + 64B 密码(NUL 补齐)+ 1B 安全;[cbc] = CBC(IV=0) 模式。
Uint8List craftBlob(
  String ssid,
  String password,
  int security, {
  required bool cbc,
}) {
  final hasher = BlowfishHasher(key: BlowfishHasher.nikonKey);
  List<int> encrypt(List<int> plain) {
    final out = <int>[];
    var (pl, pr) = (0, 0);
    for (var i = 0; i + 8 <= plain.length; i += 8) {
      final m0 = _u32Be(plain, i);
      final m1 = _u32Be(plain, i + 4);
      final (cl, cr) = hasher.encryptBlock(
          cbc ? m0 ^ pl : m0, cbc ? m1 ^ pr : m1);
      out.addAll(_be32(cl));
      out.addAll(_be32(cr));
      (pl, pr) = (cl, cr);
    }
    return out;
  }

  List<int> padded(String s, int size) {
    final units = s.codeUnits;
    final out = List<int>.filled(size, 0);
    for (var i = 0; i < units.length && i < size; i++) {
      out[i] = units[i] & 0xFF;
    }
    return out;
  }

  return Uint8List.fromList([
    ...encrypt(padded(ssid, 32)),
    ...encrypt(padded(password, 64)),
    security,
  ]);
}

int _u32Be(List<int> b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

List<int> _be32(int v) => <int>[
      (v >>> 24) & 0xFF,
      (v >>> 16) & 0xFF,
      (v >>> 8) & 0xFF,
      v & 0xFF,
    ];

void main() {
  group('decodeWifiCredentials', () {
    test('ECB 模式往返:SSID/密码/安全全对上', () {
      final blob = craftBlob('Z 50_2_ABC123', 'nk0399x8yz', 0x02, cbc: false);
      final creds = decodeWifiCredentials(blob);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Z 50_2_ABC123');
      expect(creds.password, 'nk0399x8yz');
      expect(creds.security, 0x02);
      expect(creds.keySource, endsWith('+ecb'));
      expect(creds.securityLabel, 'WPA2');
    });

    test('CBC(IV=0) 模式往返', () {
      final blob = craftBlob('Zf_80114411', 'wpa2pass99', 0x03, cbc: true);
      final creds = decodeWifiCredentials(blob);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Zf_80114411');
      expect(creds.password, 'wpa2pass99');
      expect(creds.keySource, endsWith('+cbc-iv0'));
      expect(creds.securityLabel, 'WPA3');
    });

    test('开放网络空密码接受', () {
      final blob = craftBlob('NikonAP', '', 0x01, cbc: false);
      final creds = decodeWifiCredentials(blob);
      expect(creds, isNotNull);
      expect(creds!.password, isEmpty);
      expect(creds.securityLabel, '开放');
    });

    test('非开放安全空密码拒绝', () {
      final blob = craftBlob('NikonAP', '', 0x02, cbc: false);
      expect(decodeWifiCredentials(blob), isNull);
    });

    test('乱码 blob(解不出可打印明文)如实 null', () {
      final blob = Uint8List.fromList(
          List<int>.generate(97, (i) => (i * 7 + 3) & 0xFF));
      expect(decodeWifiCredentials(blob), isNull);
    });

    test('短 blob / 安全字节越界拒绝', () {
      final blob = craftBlob('ssid', 'pass', 0x02, cbc: false);
      expect(decodeWifiCredentials(blob.sublist(0, 96)), isNull);
      final badSecurity = Uint8List.fromList([...blob.sublist(0, 96), 0x7F]);
      expect(decodeWifiCredentials(badSecurity), isNull);
    });

    test('候选密钥扩充路径:仅 extraKeys 命中也可解', () {
      final blob = craftBlob('ssid', 'pass', 0x02, cbc: false);
      expect(decodeWifiCredentials(blob, extraKeys: const []), isNotNull);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ble/blowfish_hasher.dart';
import 'package:z_pill/core/ble/wifi_credentials.dart';

/// 用与解密同核的 Blowfish 构造 97B 凭据 blob(测试向量制造器):
/// 32B SSID + 64B 密码(NUL 补齐)+ 1B 安全;[cbc] = CBC(IV=0) 模式;
/// [key] 缺省握手定键,LSS 派生路径传会话密钥 K。
Uint8List craftBlob(
  String ssid,
  String password,
  int security, {
  required bool cbc,
  List<int>? key,
}) {
  final hasher = BlowfishHasher(key: key ?? BlowfishHasher.nikonKey);
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
      final blob = craftBlob('Z 50_2_ABC123', 'nk0399x8yz', 0x01, cbc: false);
      final creds = decodeWifiCredentials(blob);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Z 50_2_ABC123');
      expect(creds.password, 'nk0399x8yz');
      expect(creds.security, 0x01);
      expect(creds.keySource, endsWith('+ecb'));
      expect(creds.securityLabel, 'WPA2');
    });

    test('CBC(IV=0) 模式往返', () {
      final blob = craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: true);
      final creds = decodeWifiCredentials(blob);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Zf_80114411');
      expect(creds.password, 'wpa2pass99');
      expect(creds.keySource, endsWith('+cbc-iv0'));
      expect(creds.securityLabel, 'WPA3');
    });

    test('开放网络空密码接受(0x00=LSS 定案口径)', () {
      final blob = craftBlob('NikonAP', '', 0x00, cbc: false);
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

  group('LSS 会话密钥派生(0x2004 主路,2026-10-27)', () {
    LssHandshakeMaterial material() => LssHandshakeMaterial(
          key1: Uint8List.fromList(List<int>.generate(8, (i) => 0x41 + i)),
          key2: Uint8List.fromList(List<int>.generate(8, (i) => 0x61 + i)),
          saltIndex: 3,
          cameraNonce:
              Uint8List.fromList(List<int>.generate(8, (i) => i * 17 + 1)),
          phoneNonce:
              Uint8List.fromList(List<int>.generate(8, (i) => i * 29 + 5)),
        );

    test('主候选派生 K → CBC 往返命中,keySource 记录形态', () {
      final m = material();
      final (tag, k) = lssSessionKeyCandidates(m).first;
      final blob =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x02, cbc: true, key: k);
      final creds = decodeWifiCredentials(blob, lss: m);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Zf_80114411');
      expect(creds.password, 'wpa2pass99');
      expect(creds.keySource, startsWith('lss-kdf'));
      expect(creds.keySource, contains(tag));
    });

    test('非主候选(ctx/key1 变体)命中也被接住', () {
      final m = material();
      final candidates = lssSessionKeyCandidates(m);
      expect(candidates.length, 8);
      final (tag, k) = candidates[5]; // 非 0 号:ctx/key1 变体位
      final blob =
          craftBlob('NikonZfAp', 'pw123456', 0x02, cbc: true, key: k);
      final creds = decodeWifiCredentials(blob, lss: m);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'NikonZfAp');
      expect(creds.keySource, contains(tag));
    });

    test('开放网络空密码(security=0x00,LSS 口径)放行', () {
      final m = material();
      final (_, k) = lssSessionKeyCandidates(m).first;
      final blob = craftBlob('NikonAP', '', 0x00, cbc: true, key: k);
      final creds = decodeWifiCredentials(blob, lss: m);
      expect(creds, isNotNull);
      expect(creds!.password, isEmpty);
    });

    test('LSS 98B 布局(flag 前置)命中', () {
      final m = material();
      final (_, k) = lssSessionKeyCandidates(m).first;
      final body =
          craftBlob('Zf_80114411', 'wpa2pass99', 0x01, cbc: true, key: k);
      final blob = Uint8List.fromList([0x01, ...body]);
      final creds = decodeWifiCredentials(blob, lss: m);
      expect(creds, isNotNull);
      expect(creds!.ssid, 'Zf_80114411');
      expect(creds.keySource, contains('lay=l98'));
    });

    test('定键 blob 不被主路吞:回落 fixed 命中', () {
      final m = material();
      final blob =
          craftBlob('Z 50_2_ABC123', 'nk0399x8yz', 0x02, cbc: false);
      final creds = decodeWifiCredentials(blob, lss: m);
      expect(creds, isNotNull);
      expect(creds!.keySource, startsWith(kWifiKeyFixed));
    });

    test('全候选未中如实 null;材料字段非 8B 时候选为空', () {
      final m = material();
      final blob = Uint8List.fromList(
          List<int>.generate(97, (i) => (i * 7 + 3) & 0xFF));
      expect(decodeWifiCredentials(blob, lss: m), isNull);
      final bad = LssHandshakeMaterial(
        key1: Uint8List(7),
        key2: m.key2,
        saltIndex: 0,
        cameraNonce: m.cameraNonce,
        phoneNonce: m.phoneNonce,
      );
      expect(lssSessionKeyCandidates(bad), isEmpty);
    });
  });
}

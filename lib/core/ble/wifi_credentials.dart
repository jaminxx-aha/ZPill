/// 0x2004 CONNECTION_CONFIGURATION 相机 AP 凭据解密(97B 布局定案:
/// 32B 加密 SSID + 64B 加密密码 + 1B 安全模式;SnapBridge 侧经
/// libLsSec-jni 解,密钥会话化出 native —— 本地按协议密钥族试探,
/// 可打印性 oracle 判命中,全试未中如实返回 null 不臆造明文)。
///
/// 候选 = 定键 `FF FF AA 55 11 22 33 00`(握手 hash 同族密钥,nsg
/// 口径的协议定键);模式 = ECB 与 CBC(IV=0 —— 与会话 hash 的块链
/// 式同构,dec(c) ⊕ 前块密文)。两模式都未中则 blob 供诊断日志,
/// 等真机 trace 增补候选,勿扩臆造密钥。
library;

import 'dart:typed_data';

import 'blowfish_hasher.dart';

/// 命中的候选标识(诊断落 trace 用)。
const String kWifiKeyFixed = 'fixed-nikon-key';

/// 凭据解码产物;[keySource] 记录命中候选与模式(诊断)。
class WifiCredentials {
  const WifiCredentials({
    required this.ssid,
    required this.password,
    required this.security,
    required this.keySource,
  });

  final String ssid;
  final String password;

  /// 原始安全模式字节(0-4;smali 枚举 UNDEFINED/OPEN/WPA2/WPA3/
  /// WPA2_WPA3)。
  final int security;
  final String keySource;

  String get securityLabel => switch (security) {
        0x01 => '开放',
        0x02 => 'WPA2',
        0x03 => 'WPA3',
        0x04 => 'WPA2+WPA3',
        _ => '未知($security)',
      };
}

/// 解 97B 凭据 blob。返回 null = 长度/安全字节不合规或候选全试未中。
WifiCredentials? decodeWifiCredentials(
  Uint8List blob, {
  List<List<int>> extraKeys = const [],
}) {
  if (blob.length < 97) return null;
  final security = blob[96];
  if (security > 0x04) return null;
  final cipherSsid = blob.sublist(0, 32);
  final cipherPassword = blob.sublist(32, 96);
  for (final key in [BlowfishHasher.nikonKey, ...extraKeys]) {
    final hasher = BlowfishHasher(key: key);
    for (final cbc in const [false, true]) {
      final ssid = _decryptBytes(hasher, cipherSsid, cbc);
      final password = _decryptBytes(hasher, cipherPassword, cbc);
      if (!_isPaddedPrintable(ssid, allowEmpty: false)) continue;
      if (!_isPaddedPrintable(password,
          allowEmpty: security == 0x01)) {
        continue;
      }
      return WifiCredentials(
        ssid: _trimNul(ssid),
        password: _trimNul(password),
        security: security,
        keySource: '$kWifiKeyFixed${cbc ? '+cbc-iv0' : '+ecb'}',
      );
    }
  }
  return null;
}

/// 8B 块序解密:ECB 直解;CBC(IV=0) 与会话 hash 链同构 ——
/// 明文块 = dec(密文块) ⊕ 前块密文(块长 8B,大端)。
List<int> _decryptBytes(BlowfishHasher hasher, List<int> cipher, bool cbc) {
  var (prevL, prevR) = (0, 0);
  final out = <int>[];
  for (var i = 0; i + 8 <= cipher.length; i += 8) {
    final cl = _u32Be(cipher, i);
    final cr = _u32Be(cipher, i + 4);
    final (dl, dr) = hasher.decryptBlock(cl, cr);
    if (cbc) {
      out.addAll(_be32(dl ^ prevL));
      out.addAll(_be32(dr ^ prevR));
    } else {
      out.addAll(_be32(dl));
      out.addAll(_be32(dr));
    }
    (prevL, prevR) = (cl, cr);
  }
  return out;
}

int _u32Be(List<int> b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

List<int> _be32(int v) => <int>[
      (v >>> 24) & 0xFF,
      (v >>> 16) & 0xFF,
      (v >>> 8) & 0xFF,
      v & 0xFF,
    ];

/// 解出明文的可打印性 oracle:全部字节 ∈ 可打印 ASCII ∪ 0x00,且 0
/// 只作尾填充;[allowEmpty] = 全零也接受(开放网络空密码)。
bool _isPaddedPrintable(List<int> bytes, {required bool allowEmpty}) {
  var printable = 0;
  var seenZero = false;
  for (final b in bytes) {
    if (b == 0) {
      seenZero = true;
      continue;
    }
    if (seenZero) return false;
    if (b < 0x20 || b > 0x7E) return false;
    printable++;
  }
  return printable > 0 || allowEmpty;
}

String _trimNul(List<int> bytes) {
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  return String.fromCharCodes(bytes.sublist(0, end));
}

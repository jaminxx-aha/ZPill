/// 0x2004 CONNECTION_CONFIGURATION 相机 AP 凭据解密(97B 布局定案:
/// 32B 加密 SSID + 64B 加密密码 + 1B 安全模式)。两条解密路径,可打印
/// 性 oracle 统一裁决,全试未中如实返回 null 不臆造明文:
///
/// 1. **LSS 会话密钥派生(主路,2026-10-27 落码)**:握手材料按
///    libLsSec-jni.so 还原报告(Pixelshop docs/protocol-reports/
///    07-nikon-z.md §3.4)的结构派生 —— `ctx = idx‖N_A[1..3]‖X[0..3]`,
///    `K = MAC8(key1‖key2‖ctx)`,K 喂标准 Blowfish 密钥编排,字段解密
///    = CBC 每字段独立、IV 全零。Zf 方言适配:MAC 原语用握手同款标准
///    定键 CBC-MAC(Zf stage2/3 真机实证即此原语;libLsSec 的 1042 词
///    固定调度表属 Z5/Z8 方言,不搬专有表);ctx 字节序与 key1 语义
///    (报告 §3.3 未解项)留候选变体由 oracle 裁决,keySource 记录
///    命中形态供真机收口。
/// 2. **定键试探(兜底,2026-10-13 口径)**:握手定键直接 ECB 与
///    CBC(IV=0) 试解 —— 会话密钥派生未命中时兜住。
///
/// **2026-10-27 Zf 真机收口**:blob=102B —— LSS 布局全须:flag=0x03
/// (bit0 WiFi 块+bit1 蓝牙块→尾随 4B sppMaxDataLength,真机值 492),
/// security=0x00=开放网络(LSS 口径定案;smali 1..4 旧口径废弃)。
/// 命中形态=报告主候选一路命中:ctx=na1-3,x0-3 / k1=stage4(=序列号
/// ASCII+0x00)/ lay=l98。变体搜索保留作方言韧性,不再扩候选。
library;

import 'dart:typed_data';

import 'blowfish_hasher.dart';
import 'pairing_engine.dart';

/// 命中的候选标识(诊断落 trace 用)。
const String kWifiKeyFixed = 'fixed-nikon-key';

/// LSS 握手密钥材料(K 派生输入,字节一律线上原样序)。
class LssHandshakeMaterial {
  const LssHandshakeMaterial({
    required this.key1,
    required this.key2,
    required this.saltIndex,
    required this.cameraNonce,
    required this.phoneNonce,
  });

  /// stage4 帧 deviceId 字段原始 8B(帧字节 9..17,不做 NUL 截断 ——
  /// 与序列号展示是两回事,序列号是它的 ASCII 读法)。
  final Uint8List key1;

  /// 客户端身份 8B(stage1 帧字节 9..17 = device+nonce 线上序)。
  final Uint8List key2;

  /// stage2 命中的 salt 序号(0-7;ctx 的 idx 位)。
  final int saltIndex;

  /// 相机 8B nonce(stage2 帧字节 1..9,报告记 N_A)。
  final Uint8List cameraNonce;

  /// 手机 8B nonce(stage1 帧字节 1..9,报告记 X)。
  final Uint8List phoneNonce;
}

/// LSS 会话密钥 K 候选序列(每项 = keySource 片段 + 8B K)。材料字段
/// 非 8B 时返回空(调用方回落定键路径)。
List<(String, Uint8List)> lssSessionKeyCandidates(LssHandshakeMaterial m) {
  if (m.key1.length != 8 ||
      m.key2.length != 8 ||
      m.cameraNonce.length != 8 ||
      m.phoneNonce.length != 8) {
    return const [];
  }
  final mac = BlowfishHasher(); // 握手同款标准定键 CBC-MAC
  final nA = m.cameraNonce;
  final x = m.phoneNonce;
  // ctx 候选:报告主形 idx‖N_A[1..3]‖X[0..3];N_A 起点与 X 半字各留
  // 一个摇摆位(Zf 方言字节序漂移候选,oracle 裁决)。
  const ctxShapes = <(String, int, int)>[
    ('na1-3,x0-3', 1, 0),
    ('na0-2,x0-3', 0, 0),
    ('na1-3,x4-7', 1, 4),
    ('na0-2,x4-7', 0, 4),
  ];
  // key1 候选:stage4 原样(报告契约)与命中的 salt 对(报告 §3.3
  // 未解项「key1 是否等于根」的 Zf 对应形态)。
  final salt = NikonPairingEngine.salts[m.saltIndex.clamp(0, 7)];
  final key1s = <(String, List<int>)>[
    ('k1=stage4', m.key1),
    ('k1=salt', <int>[..._be32(salt[0]), ..._be32(salt[1])]),
  ];
  return [
    for (final (k1Tag, key1) in key1s)
      for (final (ctxTag, naOff, xOff) in ctxShapes)
        _deriveK(mac, k1Tag, ctxTag, key1, m.key2, nA, naOff, x, xOff,
            m.saltIndex),
  ];
}

(String, Uint8List) _deriveK(
  BlowfishHasher mac,
  String k1Tag,
  String ctxTag,
  List<int> key1,
  List<int> key2,
  List<int> nA,
  int naOff,
  List<int> x,
  int xOff,
  int saltIndex,
) {
  final ctx = <int>[
    saltIndex & 0xFF,
    nA[naOff],
    nA[naOff + 1],
    nA[naOff + 2],
    x[xOff],
    x[xOff + 1],
    x[xOff + 2],
    x[xOff + 3],
  ];
  final (l, r) = mac.hash([
    ..._u32BePair(key1),
    ..._u32BePair(key2),
    ..._u32BePair(ctx),
  ]);
  return (
    'ctx=$ctxTag $k1Tag',
    Uint8List.fromList(<int>[..._be32(l), ..._be32(r)]),
  );
}

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

  /// 原始安全模式字节。线上值=LSS 枚举(2026-10-27 Zf 真机收口:开放
  /// 网回 0x00,与还原报告 §4 一致;smali 1..4 旧口径废弃)。
  final int security;
  final String keySource;

  String get securityLabel => switch (security) {
        0x00 => '开放',
        0x01 => 'WPA2',
        0x02 => 'WPA3',
        0x03 => 'WPA2+WPA3',
        0xFF => '未定义',
        _ => '未知($security)',
      };
}

/// 解 97B(或 LSS 98B)凭据 blob。[lss] 给出握手材料时先走会话密钥
/// 派生主路,未中回落定键试探。返回 null = 长度/安全字节不合规或候选
/// 全试未中。
WifiCredentials? decodeWifiCredentials(
  Uint8List blob, {
  LssHandshakeMaterial? lss,
  List<List<int>> extraKeys = const [],
}) {
  if (blob.length < 97) return null;
  for (final (layName, ssidOff, pwOff, secOff) in _blobLayouts(blob)) {
    final security = blob[secOff];
    // security 定案=LSS 口径 0..3 + 0xFF(UNDEFINED);放宽闸保留方言
    // 韧性,界外即弃。
    if (security > 0x04 && security != 0xFF) continue;
    final cipherSsid = blob.sublist(ssidOff, ssidOff + 32);
    final cipherPassword = blob.sublist(pwOff, pwOff + 64);
    if (lss != null) {
      for (final (tag, k) in lssSessionKeyCandidates(lss)) {
        final fieldHasher = BlowfishHasher(key: k);
        // 每字段独立 CBC、IV 全零(还原报告 §3.4:库每次调用重读 IV
        // 不回写终链,SSID 与密码是两次独立解密)。
        final ssid = _decryptBytes(fieldHasher, cipherSsid, true);
        if (!_isPaddedPrintable(ssid, allowEmpty: false)) continue;
        final password = _decryptBytes(fieldHasher, cipherPassword, true);
        // 空密码:开放网络(0x00=LSS 定案口径;0x01 兼容放行作方言
        // 韧性)。
        if (!_isPaddedPrintable(password,
            allowEmpty: security == 0x00 || security == 0x01)) {
          continue;
        }
        return WifiCredentials(
          ssid: _trimNul(ssid),
          password: _trimNul(password),
          security: security,
          keySource: 'lss-kdf $tag lay=$layName',
        );
      }
    }
    if (layName == 'l97') {
      // 兜底:定键直接试解(2026-10-13 口径,只在主布局上)。
      for (final key in [BlowfishHasher.nikonKey, ...extraKeys]) {
        final hasher = BlowfishHasher(key: key);
        for (final cbc in const [false, true]) {
          final ssid = _decryptBytes(hasher, cipherSsid, cbc);
          if (!_isPaddedPrintable(ssid, allowEmpty: false)) continue;
          final password = _decryptBytes(hasher, cipherPassword, cbc);
          if (!_isPaddedPrintable(password,
              allowEmpty: security == 0x00 || security == 0x01)) {
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
    }
  }
  return null;
}

/// blob 布局候选:(名, SSID 偏移, 密码偏移, security 偏移)。
/// l97 = SnapBridge 口径 97B 无 flag(Zf 主候选);l98 = LSS 还原口径
/// flag 前置(bit0=WiFi 块,bit1=蓝牙块,bit1 置位还有 4B spp 尾)。
List<(String, int, int, int)> _blobLayouts(Uint8List blob) => [
      const ('l97', 0, 32, 96),
      if (blob.length >= 98) const ('l98', 1, 33, 97),
    ];

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

/// 8 字节 → 两个大端 u32(hash/MAC 的块装填口径)。
List<int> _u32BePair(List<int> b) => <int>[_u32Be(b, 0), _u32Be(b, 4)];

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

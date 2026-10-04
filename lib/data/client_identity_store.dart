/// 无线客户端身份:相机按 InitCommandRequest 载荷里的 16B UUID 识别并
/// 记忆已配对客户端(SnapBridge 持久化于 BonjourConnectGuid;NiConn_DEMO
/// 同款结论)。首次生成后跨启动复用;**换 UUID = 相机眼里的新客户端**,
/// 已配对记录全部失配,须重新走配对流程。
///
/// UUID 生成规则(NiConn generateClientUuid 约定):随机 16 字节 + 第
/// 5-6 字节(0 基下标 4/5)写入智能设备模式码 0x1E61(小端 61 1E)。
/// 该位置源于对 SnapBridge 抓包 UUID 的结构对照,相机是否强制校验未证
/// (本仓固定 GUID 第 5-6 字节 44 55 照样 13 步全过),带上无害。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

final class ClientIdentity {
  const ClientIdentity({required this.name, required this.uuid});

  /// Init 载荷主机名(相机记档展示用;内容不影响连接,真机已证)。
  final String name;

  /// 客户端 GUID(16B,InitCommandRequest 载荷)。
  final Uint8List uuid;
}

final class ClientIdentityStore {
  ClientIdentityStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  ClientIdentity? _cached;

  /// 取(必要时生成并落盘)本机身份;进程内缓存,重复调用零开销。
  Future<ClientIdentity> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final file = File('${await _dataDir()}/client_identity.json');
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString())
            as Map<String, Object?>;
        final hex = j['uuid'] as String?;
        final name = j['name'] as String?;
        if (hex != null && name != null && hex.length == 32) {
          final uuid = Uint8List(16);
          for (var i = 0; i < 16; i++) {
            uuid[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
          }
          return _cached = ClientIdentity(name: name, uuid: uuid);
        }
      } on FormatException {
        // 损坏文件:重新生成(代价只是相机侧多一条配对记录)
      }
    }

    final uuid = Uint8List(16);
    final rng = Random.secure();
    for (var i = 0; i < 16; i++) {
      uuid[i] = rng.nextInt(256);
    }
    uuid[4] = 0x61; // 智能设备模式码 0x1E61 小端(NiConn 约定,见库注)
    uuid[5] = 0x1E;
    final identity = ClientIdentity(name: 'NikonPill', uuid: uuid);
    await file.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'name': identity.name,
      'uuid': identity.uuid
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
    }));
    return _cached = identity;
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/data/client_identity_store.dart';

/// 每测一目录:互不污染,留在系统临时区由 OS 回收。
Future<String> _tempDataDir() async =>
    (await Directory.systemTemp.createTemp('nikonpill_identity_test_')).path;

void main() {
  test('首载生成:16B UUID + 智能设备模式码印记 + NikonPill 名,落盘', () async {
    final dir = await _tempDataDir();
    final identity = await ClientIdentityStore(dataDir: () async => dir).load();

    expect(identity.name, 'NikonPill');
    expect(identity.uuid, hasLength(16));
    expect(identity.uuid[4], 0x61, reason: 'NiConn 约定的模式码 0x1E61 小端');
    expect(identity.uuid[5], 0x1E);

    final file = File('$dir/client_identity.json');
    expect(await file.exists(), isTrue);
    final j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(j['name'], 'NikonPill');
    expect((j['uuid'] as String).length, 32); // 16B 十六进制
  });

  test('跨实例复用:同一目录第二个 store 读到相同身份(相机记忆键不漂移)',
      () async {
    final dir = await _tempDataDir();
    final first = await ClientIdentityStore(dataDir: () async => dir).load();
    final second = await ClientIdentityStore(dataDir: () async => dir).load();

    expect(second.name, first.name);
    expect(second.uuid, first.uuid);
  });

  test('损坏文件(非 JSON):重新生成并覆写', () async {
    final dir = await _tempDataDir();
    await File('$dir/client_identity.json').writeAsString('not json');
    final identity = await ClientIdentityStore(dataDir: () async => dir).load();
    expect(identity.uuid, hasLength(16));
    // 覆写后可正常复用
    final again = await ClientIdentityStore(dataDir: () async => dir).load();
    expect(again.uuid, identity.uuid);
  });

  test('畸形载荷(uuid 非 32 位十六进制):重新生成', () async {
    final dir = await _tempDataDir();
    await File('$dir/client_identity.json')
        .writeAsString('{"name":"x","uuid":"zz"}');
    final identity = await ClientIdentityStore(dataDir: () async => dir).load();
    expect(identity.name, 'NikonPill'); // 回落生成默认名
    expect(identity.uuid, hasLength(16));
  });
}

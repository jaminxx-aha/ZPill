import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_info.dart';
import 'package:nikon_pill/data/paired_cameras_store.dart';

Future<String> _tempDataDir() async =>
    (await Directory.systemTemp.createTemp('nikonpill_paired_test_')).path;

void main() {
  test('save/list 往返:全字段持久化(含 lastIp),最近连接排前', () async {
    final dir = await _tempDataDir();
    final store = FilePairedCamerasStore(dataDir: () async => dir);

    final jan = DateTime(2026, 1, 1);
    final feb = DateTime(2026, 2, 1);
    await store.save(CameraInfo(
        id: '8014411',
        name: 'Z_f_8014411',
        model: 'TestModel',
        lastIp: '192.168.0.104',
        lastConnectedAt: jan));
    await store.save(CameraInfo(
        id: '999',
        name: 'Other',
        model: 'M2',
        bleAddress: 'AA:BB',
        wifiSsid: 'ssid',
        lastIp: '10.0.0.9',
        lastConnectedAt: feb));

    final listed = await store.list();
    expect(listed.map((c) => c.id), ['999', '8014411']); // 2月 > 1月
    final zf = listed.singleWhere((c) => c.id == '8014411');
    expect(zf.name, 'Z_f_8014411');
    expect(zf.model, 'TestModel');
    expect(zf.lastIp, '192.168.0.104');
    expect(zf.lastConnectedAt, jan);
    expect(listed.first.bleAddress, 'AA:BB');
    expect(listed.first.wifiSsid, 'ssid');

    // 新实例(冷启动)读同一文件:内容一致
    final cold = await FilePairedCamerasStore(dataDir: () async => dir).list();
    expect(cold.map((c) => c.id), ['999', '8014411']);
    expect(cold.last.lastIp, '192.168.0.104');
  });

  test('save 同 id = 更新(重连刷新 IP/时间),不重复上榜', () async {
    final dir = await _tempDataDir();
    final store = FilePairedCamerasStore(dataDir: () async => dir);

    await store.save(const CameraInfo(id: '1', name: 'A', lastIp: '1.1.1.1'));
    await store.save(const CameraInfo(id: '1', name: 'A', lastIp: '2.2.2.2'));

    final listed = await store.list();
    expect(listed, hasLength(1));
    expect(listed.single.lastIp, '2.2.2.2');
  });

  test('remove:按 id 删除并持久化', () async {
    final dir = await _tempDataDir();
    final store = FilePairedCamerasStore(dataDir: () async => dir);
    await store.save(const CameraInfo(id: '1', name: 'A'));
    await store.save(const CameraInfo(id: '2', name: 'B'));

    await store.remove('1');

    expect((await store.list()).map((c) => c.id), ['2']);
    expect(
        (await FilePairedCamerasStore(dataDir: () async => dir).list())
            .map((c) => c.id),
        ['2']); // 冷启动同判
  });

  test('损坏 JSON:按空库重建(配对状态可重新走流程恢复)', () async {
    final dir = await _tempDataDir();
    await File('$dir/paired_cameras.json').writeAsString('{{{');
    final store = FilePairedCamerasStore(dataDir: () async => dir);

    expect(await store.list(), isEmpty);

    // 重建后可正常写入
    await store.save(const CameraInfo(id: '1', name: 'A'));
    expect((await store.list()).map((c) => c.id), ['1']);
  });

  test('JSON 形态:字段名稳定(lastIp 入库,便于人肉检视与迁移)', () async {
    final dir = await _tempDataDir();
    final store = FilePairedCamerasStore(dataDir: () async => dir);
    await store.save(CameraInfo(
        id: '1', name: 'A', model: 'M', lastIp: '1.2.3.4', lastConnectedAt: DateTime(2026, 10, 4)));

    final j = (jsonDecode(
            await File('$dir/paired_cameras.json').readAsString())
        as List)
        .single as Map<String, Object?>;
    expect(j['id'], '1');
    expect(j['name'], 'A');
    expect(j['model'], 'M');
    expect(j['lastIp'], '1.2.3.4');
    expect(j['lastConnectedAt'], startsWith('2026-10-04'));
  });
}

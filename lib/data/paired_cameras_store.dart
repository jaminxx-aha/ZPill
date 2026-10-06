/// 已配对相机持久化(TODO.md §五 P2)。
///
/// TODO(P2): 换成 drift(Room 等价,sqlite);字段见 CameraInfo:
/// 名称/型号/BLE 地址/WiFi 凭据/最后连接时间。
/// [FilePairedCamerasStore]:JSON 文件实现(无线配对流程在用);
/// [InMemoryPairedCamerasStore]:测试用。
library;

import 'dart:convert';
import 'dart:io';

import '../core/camera/camera_info.dart';

abstract interface class PairedCamerasStore {
  Future<List<CameraInfo>> list();
  Future<void> save(CameraInfo camera);
  Future<void> remove(String id);
}

/// JSON 文件实现:`<dataDir>/paired_cameras.json`,内存缓存 + 全量写回。
///
/// dataDir 注入(Future 形式方便测试换临时目录);生产接
/// GallerySaver.dataDir(applicationSupport,持久)。
final class FilePairedCamerasStore implements PairedCamerasStore {
  FilePairedCamerasStore({required Future<String> Function() dataDir})
      : _dataDir = dataDir;

  final Future<String> Function() _dataDir;
  List<CameraInfo>? _cache;

  Future<File> _file() async =>
      File('${await _dataDir()}/paired_cameras.json');

  @override
  Future<List<CameraInfo>> list() async {
    final cached = _cache;
    if (cached != null) {
      return _sorted(cached);
    }
    List<CameraInfo> loaded = [];
    final file = await _file();
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is List) {
          loaded = [for (final e in json) _fromJson(e as Map<String, Object?>)];
        }
      } on FormatException {
        // 损坏文件:按空库重建(配对状态可重新走流程恢复)
      }
    }
    _cache = loaded;
    return _sorted(loaded);
  }

  @override
  Future<void> save(CameraInfo camera) async {
    final cameras = [...await list()];
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].id == camera.id) {
        cameras[i] = camera;
        break;
      }
    }
    if (!cameras.any((c) => c.id == camera.id)) {
      cameras.add(camera);
    }
    await _flush(cameras);
  }

  @override
  Future<void> remove(String id) async {
    await _flush((await list()).where((c) => c.id != id).toList());
  }

  Future<void> _flush(List<CameraInfo> cameras) async {
    _cache = cameras;
    final file = await _file();
    await file.create(recursive: true);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
            [for (final c in cameras) _toJson(c)]));
  }

  static List<CameraInfo> _sorted(List<CameraInfo> cameras) => cameras
    ..sort((a, b) => (b.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));

  static Map<String, Object?> _toJson(CameraInfo c) => {
        'id': c.id,
        'name': c.name,
        if (c.model != null) 'model': c.model,
        if (c.bleAddress != null) 'bleAddress': c.bleAddress,
        if (c.wifiSsid != null) 'wifiSsid': c.wifiSsid,
        if (c.lastIp != null) 'lastIp': c.lastIp,
        if (c.lastConnectedAt != null)
          'lastConnectedAt': c.lastConnectedAt!.toIso8601String(),
        if (c.wirelessPaired) 'wirelessPaired': true,
      };

  static CameraInfo _fromJson(Map<String, Object?> j) => CameraInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        model: j['model'] as String?,
        bleAddress: j['bleAddress'] as String?,
        wifiSsid: j['wifiSsid'] as String?,
        lastIp: j['lastIp'] as String?,
        lastConnectedAt: j['lastConnectedAt'] == null
            ? null
            : DateTime.parse(j['lastConnectedAt'] as String),
        wirelessPaired: j['wirelessPaired'] == true, // 旧档案缺省 false
      );
}

final class InMemoryPairedCamerasStore implements PairedCamerasStore {
  final Map<String, CameraInfo> _byId = {};

  @override
  Future<List<CameraInfo>> list() async =>
      _byId.values.toList()..sort((a, b) =>
          (b.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(a.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));

  @override
  Future<void> save(CameraInfo camera) async => _byId[camera.id] = camera;

  @override
  Future<void> remove(String id) async => _byId.remove(id);
}

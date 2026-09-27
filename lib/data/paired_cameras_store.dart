/// 已配对相机持久化(TODO.md §五 P2)。
///
/// TODO(P2): 换成 drift(Room 等价,sqlite);字段见 CameraInfo:
/// 名称/型号/BLE 地址/WiFi 凭据/最后连接时间。
/// 当前内存实现仅用于骨架联调。
library;

import '../core/camera/camera_info.dart';

abstract interface class PairedCamerasStore {
  Future<List<CameraInfo>> list();
  Future<void> save(CameraInfo camera);
  Future<void> remove(String id);
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

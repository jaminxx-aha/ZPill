/// 已配对相机档案存取接口(相机域,core 零 IO):无线配对流程在
/// 连接沿读写档案;JSON 文件实现在 data 层(FilePairedCamerasStore),
/// 测试用内存版(InMemoryPairedCamerasStore)—— core 只认本接口。
library;

import 'camera_info.dart';

abstract interface class PairedCamerasStore {
  Future<List<CameraInfo>> list();
  Future<void> save(CameraInfo camera);
  Future<void> remove(String id);
}

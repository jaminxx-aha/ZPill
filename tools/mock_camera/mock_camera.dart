/// 假尼康相机(PTP-IP 对端模拟器)—— 库入口。
///
/// 无相机环境下的回归工具:e2e 连接(尼康方言握手)→ 相册 → 缩略/下载 →
/// 拍摄事件全链路,`test/e2e` 与 CLI(`bin/mock_camera.dart`)共用本实现。
/// 纯 Dart(dart:io ServerSocket),零 Flutter 依赖。
///
/// 用法(e2e):
/// ```dart
/// final camera = MockPtpIpCamera(device: MockNikonDevice());
/// await camera.start(); // 随机口
/// // 客户端连 127.0.0.1:camera.port
/// ```
library;

export 'src/mock_nikon_device.dart';
export 'src/mock_objects.dart';
export 'src/mock_ptpip_server.dart';

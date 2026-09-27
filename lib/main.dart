import 'package:flutter/material.dart';

import 'app.dart';
import 'platform/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 平台服务注册:三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)
  // 全部经 MethodChannel 注入,core 层不感知平台。
  // native 侧实现位置:android(Kotlin)/ ios(Swift)/ ohos(ArkTS),
  // 在各自平台工程生成后落地,channel 命名见 lib/platform/services.dart。
  PlatformServices.bootstrap();

  runApp(const NikonBridgeApp());
}

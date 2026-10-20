import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'app_services.dart';
import 'core/log/app_log.dart';
import 'platform/log_bridge.dart';
import 'platform/services.dart';

/// 系统内存警告取证(2026-10-20 图库「看大图返回后缩略图经常重新刷
/// 新」排查):框架收到 didHaveMemoryPressure 即 imageCache.clear()
/// 整锅端,已滚出视口的格滑回来全 miss 逐格重解。此处只记一条 ——
/// 看大图时多大位图驻留会触发警告,是后续分级解码(大图限宽解)的
/// 定价依据;网格缩略已改小档管线(见 [_cellBody] 所在的图库页),
/// 重解毫秒级,症状土壤已除,此日志只作机制观测。
class _MemoryPressureObserver extends WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    AppLog.w(AppLog.system, '系统内存警告:解码缓存已被框架整体清空');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 平台服务注册:三端差异能力(WiFi 检测 / 相册 / 后台任务 / BLE)
  // 全部经 MethodChannel 注入,core 层不感知平台。
  // native 侧实现位置:android(Kotlin)/ ios(Swift)/ ohos(ArkTS),
  // 在各自平台工程生成后落地,channel 命名见 lib/platform/services.dart。
  PlatformServices.bootstrap();

  // 原生日志合流(USB bulk 失败/BLE 状态沿等经 nikonpill/log 反向通道
  // 汇入 AppLog native 域;尽早 install,免 native 早期上报落空)。
  NativeLogBridge.install();

  // 内存警告取证(全生命周期,常驻):只记日志不动缓存 —— 清空是框
  // 架在 super.handleMemoryPressure 里已做的,不重不漏。
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  // 应用级单例:USB 主线对象图(通道 → 传输 → 会话 → 仓库 → 控制器)。
  AppServices.bootstrap();

  // 首帧后预热方向偏好:引擎未收过任何方向表时(iOS 侧
  // _orientationPreferences 默认 = All 掩码),进程的首个用户方向请求
  // 会走一条特有路径 —— 真机上表现为首次点方向钮「先按设备姿态转过去
  // 再 180° 拉回」的双旋,第二次起才正常(2026-10-08 实测)。此处先发
  // 一张全方向表(竖 + 双横,与 Info.plist 生效集一致,零旋转零可见
  // 变化),让引擎方向状态在用户点按前就收敛到与后续点按相同的路径。
  // Android 该表映射 SCREEN_ORIENTATION_USER(跟随传感器,不钉向);
  // OHOS fork 未实现此 method,异常被静默兜住。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]).catchError((Object _) {}),
    );
  });

  runApp(const NikonPillApp());
}

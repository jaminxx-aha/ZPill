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

  // 方向契约(2026-10-26 用户明示「禁止旋转」):默认钉竖屏,全 app
  // 无传感器自转 —— shell 无横屏布局,拍摄页竖排相机式排版同不受转。
  // 横屏只剩两处**显式动作**(拍摄页方向钮「横」锁、全屏视频,见
  // remote_page 方向锁与 viewer/library 全屏切换),退出各自钉回竖屏。
  // Info.plist/AndroidManifest 三向保留不掐:显式切横的引擎通路仍在。
  // 启动即钉(持有横放手机冷启,首帧不闪横屏外壳);竖拍值单发
  // portraitUp(iOS 未声明 UpsideDown,双值只留系统自选余地)。
  unawaited(
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]).catchError((Object _) {}),
  );

  // 内存警告取证(全生命周期,常驻):只记日志不动缓存 —— 清空是框
  // 架在 super.handleMemoryPressure 里已做的,不重不漏。
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());

  // 应用级单例:USB 主线对象图(通道 → 传输 → 会话 → 仓库 → 控制器)。
  AppServices.bootstrap();

  // 首帧后再发一次同表(竖)预热方向偏好:引擎未收过任何方向表时,
  // 进程的首个用户方向请求会走一条特有路径 —— 真机上表现为首次点
  // 方向钮「先按设备姿态转过去再 180° 拉回」的双旋,第二次起才正常
  // (2026-10-08 实测)。预热让引擎方向状态在用户点按前收敛到与后续
  // 点按相同的路径。Android 该表映射 SCREEN_ORIENTATION_PORTRAIT;
  // OHOS fork 未实现此 method,异常被静默兜住。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]).catchError((Object _) {}),
    );
  });

  runApp(const NikonPillApp());
}

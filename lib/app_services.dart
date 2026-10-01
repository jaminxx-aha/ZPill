/// 应用级单例定位器(TODO.md §三:连接是全局单例状态,引入 DI 前的收口点)。
///
/// 组装 USB 主线的唯一对象图:
/// UsbHostChannel → UsbPtpTransport → PtpSession → {ObjectRepositoryImpl,
/// ThumbnailCache, ObjectDownloader → TransferEngineImpl};
/// ConnectionController / BrowserController / TransfersController 从这里取。
/// PTP-IP 无线线接入时在此扩第二连接源(会话层已按链路无关设计)。
library;

import 'core/browser/object_repository.dart';
import 'core/browser/thumbnail_cache.dart';
import 'core/camera/camera_connection.dart';
import 'core/ptp/ptp_session.dart';
import 'core/ptpusb/usb_transport.dart';
import 'core/transfer/object_downloader.dart';
import 'core/transfer/transfer_engine.dart';
import 'debug/ptp_diagnostics.dart';
import 'features/browser/browser_controller.dart';
import 'features/connection/connection_page.dart';
import 'features/transfers/transfers_page.dart';
import 'platform/services.dart';
import 'platform/usb/usb_host.dart';
import 'platform/usb/watchdog_usb_host.dart';

final class AppServices {
  AppServices._() {
    // 幂等:测试直接 pumpWidget 不经 main(),这里保证平台服务就绪。
    PlatformServices.bootstrap();

    // 看门狗装饰器包住平台通道:相机拔出/挂死时 bulk 收发秒败 +
    // breakages 事件(连接层订阅转 failed)。裸通道无检测能力。
    usb = WatchdogUsbHostChannel(inner: PlatformServices.usb);
    transport = UsbPtpTransport(pipe: usb);
    session = PtpSession(transport: transport);
    connection = CameraConnectionImpl(usb: usb, session: session);
    repository = ObjectRepositoryImpl(session: session);
    thumbnails = ThumbnailCache(session: session, gallery: PlatformServices.gallery);
    downloader = ObjectDownloader(session: session);
    transferEngine = TransferEngineImpl(
      downloader: downloader,
      gallery: PlatformServices.gallery,
    );
    connectionController = ConnectionController(connection: connection);
    browserController = BrowserController(
      repository: repository,
      connection: connection,
      thumbnails: thumbnails,
    );
    transfersController = TransfersController(
      engine: transferEngine,
      gallery: PlatformServices.gallery,
    );

    // 断开/失败 → 对象缓存与缩略图内存索引失效(缩略图磁盘缓存是
    // 内容键,跨会话稳定,保留;重连后重新全量枚举)。
    // 连接成功 → debug 构建自动跑一次 PTP 诊断序列(结果进 hilog,
    // 见 debug/ptp_diagnostics.dart)。
    var diagRan = false;
    connection.states.listen((s) {
      if (s == CameraLinkState.connected && !diagRan) {
        diagRan = true;
        PtpDiagnostics.run(session: session, repository: repository);
      }
      if (s == CameraLinkState.disconnected || s == CameraLinkState.failed) {
        diagRan = false;
        repository.reset();
        thumbnails.reset();
      }
    });
  }

  static AppServices? _instance;

  /// 应用级单例;首次访问时构建(pumpWidget 的测试不经 main 也能跑)。
  static AppServices get instance => _instance ??= AppServices._();

  /// main() 中显式触发构建。
  static void bootstrap() => instance;

  late final UsbHostChannel usb;
  late final UsbPtpTransport transport;
  late final PtpSession session;
  late final CameraConnectionImpl connection;
  late final ObjectRepositoryImpl repository;
  late final ThumbnailCache thumbnails;
  late final ObjectDownloader downloader;
  late final TransferEngineImpl transferEngine;
  late final ConnectionController connectionController;
  late final BrowserController browserController;
  late final TransfersController transfersController;
}

/// 应用级单例定位器(TODO.md §三:连接是全局单例状态,引入 DI 前的收口点)。
///
/// 组装唯一对象图:USB / PTP-IP 无线双链路在 PtpLinkRouter 汇合后喂给
/// 单例 PtpSession,下游对象图不感知链路切换:
/// WatchdogUsbHostChannel → UsbPtpTransport ──┐
/// PtpIpTransport(无线,每连接新建)─────────┴→ PtpLinkRouter → PtpSession
/// → {ObjectRepositoryImpl, ThumbnailCache, ObjectDownloader → TransferEngineImpl};
/// ConnectionController / BrowserController / TransfersController 从这里取。
library;

import 'core/browser/object_repository.dart';
import 'core/browser/thumbnail_cache.dart';
import 'core/camera/camera_connection.dart';
import 'core/ptp/ptp_link_router.dart';
import 'core/ptp/ptp_session.dart';
import 'core/ptpip/transport.dart';
import 'core/ptpusb/usb_transport.dart';
import 'core/transfer/object_downloader.dart';
import 'core/transfer/transfer_engine.dart';
import 'data/client_identity_store.dart';
import 'data/paired_cameras_store.dart';
import 'debug/ptp_diagnostics.dart';
import 'features/browser/browser_controller.dart';
import 'features/connection/connection_page.dart';
import 'features/remote/remote_controller.dart';
import 'features/transfers/transfers_page.dart';
import 'platform/services.dart';
import 'platform/usb/usb_host.dart';
import 'platform/usb/watchdog_usb_host.dart';

final class AppServices {
  AppServices._() {
    // 幂等:测试直接 pumpWidget 不经 main(),这里保证平台服务就绪。
    PlatformServices.bootstrap();

    // 无线身份与配对档案(dataDir = applicationSupport,持久):
    // 客户端 GUID 跨启动复用,相机按它记忆已配对设备;换 GUID = 新客户端。
    identityStore =
        ClientIdentityStore(dataDir: PlatformServices.gallery.dataDir);
    pairedCameras =
        FilePairedCamerasStore(dataDir: PlatformServices.gallery.dataDir);

    // 看门狗装饰器包住平台通道:相机拔出/挂死时 bulk 收发秒败 +
    // breakages 事件(连接层订阅转 failed)。裸通道无检测能力。
    // probe:幽灵设备防线 —— usb_service 删除记录失败后 getDevices()
    // 会一直返回已拔出的设备(2026-10-03 真机实证),「设备还在」必须
    // 用链路上的真实事务复核(GetDeviceInfo 在会话内外都合法)。
    usb = WatchdogUsbHostChannel(
      inner: PlatformServices.usb,
      probe: () => session.getDeviceInfo(force: true),
    );
    usbTransport = UsbPtpTransport(pipe: usb);
    // 链路路由器:session 永远只见它;USB/无线由 CameraConnectionImpl
    // 在 connect/teardown 时 attach/detach(下游对象图不感知切换)。
    link = PtpLinkRouter();
    session = PtpSession(transport: link);
    connection = CameraConnectionImpl(
      usb: usb,
      usbTransport: usbTransport,
      link: link,
      session: session,
      pairedCameras: pairedCameras,
      // 每次无线连接一个新实例,Init 载荷带持久身份(相机记忆键)。
      createIpTransport: () async => PtpIpTransport(
        clientGuid: (await identityStore.load()).uuid,
        hostname: (await identityStore.load()).name,
      ),
    );
    repository = ObjectRepositoryImpl(session: session);
    thumbnails = ThumbnailCache(session: session, gallery: PlatformServices.gallery);
    downloader = ObjectDownloader(session: session);
    transferEngine = TransferEngineImpl(
      downloader: downloader,
      gallery: PlatformServices.gallery,
    );
    connectionController = ConnectionController(
      connection: connection,
      scanner: PlatformServices.nsd,
      pairedCameras: pairedCameras,
    );
    browserController = BrowserController(
      repository: repository,
      connection: connection,
      thumbnails: thumbnails,
    );
    remoteController = RemoteController(
      session: session,
      connection: connection,
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
  late final UsbPtpTransport usbTransport;
  late final PtpLinkRouter link;
  late final PtpSession session;
  late final ClientIdentityStore identityStore;
  late final FilePairedCamerasStore pairedCameras;
  late final CameraConnectionImpl connection;
  late final ObjectRepositoryImpl repository;
  late final ThumbnailCache thumbnails;
  late final ObjectDownloader downloader;
  late final TransferEngineImpl transferEngine;
  late final ConnectionController connectionController;
  late final BrowserController browserController;
  late final RemoteController remoteController;
  late final TransfersController transfersController;
}

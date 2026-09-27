/// 应用级单例定位器(TODO.md §三:连接是全局单例状态,引入 DI 前的收口点)。
///
/// 组装 USB 主线的唯一对象图:
/// UsbHostChannel → UsbPtpTransport → PtpSession → ObjectRepositoryImpl
/// → DirectoryNavigator;ConnectionController / BrowserController 与
/// ObjectDownloader 从这里取。PTP-IP 无线线接入时在此扩第二连接源
/// (会话层已按链路无关设计)。
library;

import 'core/browser/directory_navigator.dart';
import 'core/browser/object_repository.dart';
import 'core/camera/camera_connection.dart';
import 'core/ptp/ptp_session.dart';
import 'core/ptpusb/usb_transport.dart';
import 'core/transfer/object_downloader.dart';
import 'features/browser/browser_page.dart';
import 'features/connection/connection_page.dart';
import 'platform/services.dart';
import 'platform/usb/usb_host.dart';

final class AppServices {
  AppServices._() {
    // 幂等:测试直接 pumpWidget 不经 main(),这里保证平台服务就绪。
    PlatformServices.bootstrap();

    usb = PlatformServices.usb;
    transport = UsbPtpTransport(pipe: usb);
    session = PtpSession(transport: transport);
    connection = CameraConnectionImpl(usb: usb, session: session);
    repository = ObjectRepositoryImpl(session: session);
    navigator = DirectoryNavigator(repository: repository);
    downloader = ObjectDownloader(session: session, gallery: PlatformServices.gallery);
    connectionController = ConnectionController(connection: connection);
    browserController = BrowserController(
      navigator: navigator,
      connection: connection,
      downloader: downloader,
    );

    // 断开/失败 → 对象缓存失效(重连后首次浏览重新全量枚举)。
    connection.states.listen((s) {
      if (s == CameraLinkState.disconnected || s == CameraLinkState.failed) {
        repository.reset();
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
  late final DirectoryNavigator navigator;
  late final ObjectDownloader downloader;
  late final ConnectionController connectionController;
  late final BrowserController browserController;
}

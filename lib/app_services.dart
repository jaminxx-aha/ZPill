/// 应用级单例定位器(TODO.md §三:连接是全局单例状态,引入 DI 前的收口点)。
///
/// 组装唯一对象图:USB / PTP-IP 无线双链路在 PtpLinkRouter 汇合后喂给
/// 单例 PtpSession,下游对象图不感知链路切换:
/// WatchdogUsbHostChannel → UsbPtpTransport ──┐
/// PtpIpTransport(无线,每连接新建)─────────┴→ PtpLinkRouter → PtpSession
/// → {ObjectRepositoryImpl, ThumbnailCache, ObjectDownloader → TransferEngineImpl};
/// ConnectionController / BrowserController / TransfersController 从这里取。
library;

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'core/browser/camera_file_ops.dart';
import 'core/browser/object_repository.dart';
import 'core/browser/thumbnail_cache.dart';
import 'core/camera/camera_connection.dart';
import 'core/media/watermark.dart';
import 'core/media/xmp_metadata.dart';
import 'core/ptp/event_poller.dart';
import 'core/ptp/ptp_link_router.dart';
import 'core/ptp/ptp_session.dart';
import 'core/ptpip/transport.dart';
import 'core/ptpusb/usb_transport.dart';
import 'core/remote/live_view_engine.dart';
import 'core/transfer/auto_transfer.dart';
import 'core/transfer/object_downloader.dart';
import 'core/transfer/transfer_engine.dart';
import 'data/client_identity_store.dart';
import 'data/config_snapshot_store.dart';
import 'data/paired_cameras_store.dart';
import 'data/ratings_store.dart';
import 'data/settings_store.dart';
import 'debug/ptp_diagnostics.dart';
import 'features/browser/browser_controller.dart';
import 'features/browser/ratings_controller.dart';
import 'features/browser/storage_overview_controller.dart';
import 'features/connection/camera_overview_controller.dart';
import 'features/connection/connection_page.dart';
import 'features/remote/remote_controller.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/snapshot_controller.dart';
import 'features/transfers/transfers_page.dart';
import 'platform/location_host.dart';
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
    settingsStore =
        FileSettingsStore(dataDir: PlatformServices.gallery.dataDir);

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
      // 心跳打开:真发 ProbeRequest/收 ProbeResponse(Zf ~180s 空闲杀
      // command 通道,空闲期心跳把死链在 ~45s 内判明)。
      createIpTransport: () async => PtpIpTransport(
        clientGuid: (await identityStore.load()).uuid,
        hostname: (await identityStore.load()).name,
        enableKeepalive: true,
      ),
    );
    repository = ObjectRepositoryImpl(session: session);
    fileOps = CameraFileOps(session: session, repository: repository);
    ratingsStore = FileRatingsStore(
        dataDir: PlatformServices.gallery.dataDir);
    ratings = RatingsController(store: ratingsStore);
    // iOS 下载走 GetPartialObject 分块:IC 通道一次回调收整个数据相位,
    // 大档 GetObject 未验证且是断链主嫌疑(2026-10-09 真机);分块在
    // 无线(PTP/IP)上每块一个完整事务,小块的事务往返开销摊大 ——
    // 2026-10-09 复报「准备播放太长」起块升 1MB(单块仍在看门狗时限
    // 内)。其余平台通道内部本就流式,保持 GetObject 不降速。
    downloader = ObjectDownloader(
      session: session,
      partialChunkBytes: Platform.isIOS ? 1024 * 1024 : null,
    );
    thumbnails = ThumbnailCache(
      session: session,
      gallery: PlatformServices.gallery,
      downloader: downloader,
      rawDecoder: PlatformServices.rawDecoder,
    );
    transferEngine = TransferEngineImpl(
      downloader: downloader,
      gallery: PlatformServices.gallery,
      // 水印合成(TODO §五 T4):设置选模板;off / 异常 → 不处理。
      watermarkFor: (entry) async {
        try {
          final settings = await settingsStore.current();
          if (settings.watermarkStyle == WatermarkStyle.off) return null;
          return WatermarkOptions(
              style: settings.watermarkStyle, text: settings.watermarkText);
        } on Exception {
          return null;
        }
      },
      // XMP 元数据注入(TODO §四):设置开关 + 本地评分 + 定位快照。
      // 全部降级路径:设置读不到 → 只跳字段;仓库未加载(速传先于
      // 浏览)→ 跳评分;定位通道未实现/未授权 → 跳 GPS。任一异常
      // 返回 null,传输照常。
      metadataFor: (entry) async {
        try {
          final settings = await settingsStore.current();
          LocationFix? fix;
          if (settings.xmpInjectGps) {
            try {
              fix = await PlatformServices.location.current();
            } on Exception {
              fix = null;
            }
          }
          int? rating;
          if (settings.xmpInjectRating && repository.isLoaded) {
            try {
              // 句柄 → 所在组(评分以组为粒度,键 = 基名|组总字节)。
              outer:
              for (final album in await repository.loadAlbums()) {
                for (final group in album.items) {
                  if (group.members.any((m) => m.handle == entry.handle)) {
                    final stars = ratings.ratingOf(group);
                    if (stars >= 1) rating = stars;
                    break outer;
                  }
                }
              }
            } on Exception {
              rating = null;
            }
          }
          final meta = XmpMetadata(
            creator: settings.xmpCreator,
            rights: settings.xmpRights,
            rating: rating,
            latitude: fix?.latitude,
            longitude: fix?.longitude,
          );
          return meta.isEmpty ? null : meta;
        } on Exception {
          return null;
        }
      },
    );
    // 速传:ObjectAdded 事件驱动自动下载(开关/格式见设置页)。
    autoTransfer = AutoTransferService(
      session: session,
      engine: transferEngine,
      settings: settingsStore,
    );
    settingsController = SettingsController(store: settingsStore);
    configSnapshots = ConfigSnapshotStore(
        dataDir: PlatformServices.gallery.dataDir);
    snapshotController = SnapshotController(
      session: session,
      connection: connection,
      store: configSnapshots,
    );
    connectionController = ConnectionController(
      connection: connection,
      scanner: PlatformServices.nsd,
      pairedCameras: pairedCameras,
      identityStore: identityStore,
    );
    browserController = BrowserController(
      repository: repository,
      connection: connection,
      thumbnails: thumbnails,
    );
    // 相机页信息总览:机身/镜头/电池,连接成功即拉(能力门禁见类注;
    // 纯实时属性路,不读照片)。
    cameraOverview = CameraOverviewController(
      session: session,
      connection: connection,
    );
    // 双卡槽余量:连接成功即拉,相册页顶展示。
    storageOverview = StorageOverviewController(
      session: session,
      connection: connection,
    );
    // 取景引擎先行创建再注入控制器:看门狗重启预算耗尽时升级整链重连
    // (engine → connection.requestRecovery,恢复循环由连接层接管;
    // 引擎无连接引用,回调装配在此收口)。接口零新增 —— 此处持具体
    // 类型 CameraConnectionImpl。
    final lvEngine = LiveViewEngine(
      session: session,
      onEscalateToLinkRecovery: () =>
          connection.requestRecovery('取景流多次重启未恢复'),
    );
    remoteController = RemoteController(
      session: session,
      connection: connection,
      engine: lvEngine,
    );
    // 取景总开关(十二轮持久化):连接沿自动起景闸 —— 设置里关了
    // 取景,重连/冷启都不再自动 0x9201;拍摄页浮层「取景」钮改动
    // 即时同步到这里(页面自己也同步一份,双向不冲突,同值幂等)。
    remoteController.autoLiveViewEnabled = settingsController.value.liveViewOn;
    settingsController.addListener(() {
      remoteController.autoLiveViewEnabled =
          settingsController.value.liveViewOn;
    });
    transfersController = TransfersController(
      engine: transferEngine,
      gallery: PlatformServices.gallery,
    );

    // 后台传输保活:队列非空 → 申请后台执行权(iOS ~30s 宽限 /
    // Android 前台服务 / ohos 长时任务,各端 native 幂等);队列清空 →
    // 释放。native 未实现的端静默降级为仅前台传输。tasks 每个进度
    // 快照都发事件,只在 active 边沿上过通道。
    var bgHeld = false;
    transferEngine.tasks.listen((ts) {
      final active = ts.any((t) => !t.isTerminal);
      if (active == bgHeld) return;
      bgHeld = active;
      unawaited(active
          ? PlatformServices.background.ensureRunning()
          : PlatformServices.background.stop());
    });

    // 尼康事件轮询(GetEventEx 0x941C):重要事件走厂商轮询通道而非
    // 异步事件通道(OpenZCine/libgphoto2 口径)—— 连接期间定时拉取
    // 并入 session.events;不支持/连续失败自动停(回退异步通道)。
    eventPoller = NikonEventPoller(session: session);

    // 断开/失败 → 对象缓存与缩略图内存索引失效(缩略图磁盘缓存是
    // 内容键,跨会话稳定,保留;重连后重新全量枚举)。
    // 连接成功 → debug 构建自动跑一次 PTP 诊断序列(结果进 hilog,
    // 见 debug/ptp_diagnostics.dart)。
    var diagRan = false;
    connection.states.listen((s) {
      // 连接成功沿(含重连成功)每沿必启轮询器(start 幂等);诊断只
      // 跑一次。2026-10-10 修:旧结构把 start() 关在 !diagRan 门里,
      // 首连后重连成功的 connected 沿轮询器永远不再跑。
      if (s == CameraLinkState.connected) {
        if (!diagRan) {
          diagRan = true;
          PtpDiagnostics.run(session: session, repository: repository);
        }
        eventPoller.start();
        // 相机时钟校准(OpenZCine CameraClockSync 口径:漂移 > 5s 才写,
        // 尽力而为不影响连接)。
        unawaited(session.syncCameraClock());
      }
      if (s == CameraLinkState.disconnected || s == CameraLinkState.failed) {
        eventPoller.stop();
        diagRan = false;
        repository.reset();
        thumbnails.reset();
      }
      if (s == CameraLinkState.reconnecting) {
        // 自动重连期:停轮询、弃对象缓存(断连窗口里可能拍了新照,
        // 重连成功的 connected 沿 BrowserController.load() 会重枚举;
        // 浏览页的冻结靠控制器自持的列表,不靠仓库缓存);缩略图内存
        // 索引保留 —— 内容键跨会话稳定,冻结 UI 滚动照常出图。
        eventPoller.stop();
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
  late final UsbPtpTransport usbTransport;
  late final PtpLinkRouter link;
  late final PtpSession session;
  late final ClientIdentityStore identityStore;
  late final FilePairedCamerasStore pairedCameras;
  late final FileSettingsStore settingsStore;
  late final CameraConnectionImpl connection;
  late final NikonEventPoller eventPoller;
  late final ObjectRepositoryImpl repository;
  late final CameraFileOps fileOps;
  late final FileRatingsStore ratingsStore;
  late final RatingsController ratings;
  late final ThumbnailCache thumbnails;
  late final ObjectDownloader downloader;
  late final TransferEngineImpl transferEngine;
  late final AutoTransferService autoTransfer;
  late final SettingsController settingsController;
  late final ConfigSnapshotStore configSnapshots;
  late final SnapshotController snapshotController;
  late final ConnectionController connectionController;
  late final BrowserController browserController;
  late final CameraOverviewController cameraOverview;
  late final StorageOverviewController storageOverview;
  late final RemoteController remoteController;
  late final TransfersController transfersController;
}

/// 应用级单例定位器:连接是全局单例状态,引入 DI 前的收口点。
///
/// 组装唯一对象图:USB / PTP-IP 无线双链路在 PtpLinkRouter 汇合后喂给
/// 单例 PtpSession,下游对象图不感知链路切换:
/// WatchdogUsbHostChannel → UsbPtpTransport ──┐
/// PtpIpTransport(无线,每连接新建)─────────┴→ PtpLinkRouter → PtpSession
/// → {ObjectRepositoryImpl, ThumbnailCache, ObjectDownloader → TransferEngineImpl};
/// ConnectionController / BrowserController / TransfersController 从这里取。
library;

import 'dart:async';
import 'dart:io' show Directory, File, FileMode, Platform;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;

import 'core/ble/ble_camera_session.dart';
import 'core/log/app_log.dart';
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
import 'data/ble_identity_store.dart';
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
import 'features/connection/connection_controller.dart';
import 'features/remote/remote_controller.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/snapshot_controller.dart';
import 'features/transfers/transfers_page.dart';
import 'platform/ble_driver.dart';
import 'platform/background_transfer.dart';
import 'platform/session_lifecycle.dart';
import 'platform/location_host.dart';
import 'platform/services.dart';
import 'platform/usb/usb_host.dart';
import 'platform/usb/watchdog_usb_host.dart';

/// 连接沿侧链放行门兜底(2026-10-16 真机定案):概览/双卡槽/清事件/
/// 对时/事件轮询/相册预热与起景链(接管→模式→画质→0x9201)同在会话
/// 串行锁上轮转,曾把 0x9201 压到十几事务深 —— 拍摄页「取景未开启」
/// 卡好几秒。侧链整组等 RemoteController.connectedStartSettled(起景
/// 段落定,事件驱动 —— 起景快就早放行,相机页信息卡不再白扛固定让路
/// 窗);门含楔死自愈梯,正常 ~1-3s,超时兜底防押死。
const Duration kConnectStartGateTimeout = Duration(seconds: 3);

final class AppServices {
  AppServices._() {
    // 幂等:测试直接 pumpWidget 不经 main(),这里保证平台服务就绪。
    PlatformServices.bootstrap();
    _wireAppLog();
    _wireStores();
    _wireLinkAndSession();
    _wireBrowseAndTransfer();
    _wireBleSession();
    _wireControllers();
    _wireBleDriver();
    _wireBackgroundHolds();
    _wireSessionLifecycle();
  }

  /// 数据店装配(全部持久层,dataDir = applicationSupport)。
  void _wireStores() {

    // 无线身份与配对档案(dataDir = applicationSupport,持久):
    // 客户端 GUID 跨启动复用,相机按它记忆已配对设备;换 GUID = 新客户端。
    identityStore =
        ClientIdentityStore(dataDir: PlatformServices.gallery.dataDir);
    pairedCameras =
        FilePairedCamerasStore(dataDir: PlatformServices.gallery.dataDir);
    settingsStore =
        FileSettingsStore(dataDir: PlatformServices.gallery.dataDir);
    bleIdentityStore =
        BleIdentityStore(dataDir: PlatformServices.gallery.dataDir);
  }

  /// 链路与会话装配:USB 看门狗装饰 → USB 传输 → 链路路由器 → 会话
  /// → 连接层(路由器挂载由连接层在 connect/teardown 驱动)。
  void _wireLinkAndSession() {
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
  }

  /// 浏览/传输装配:仓库 → 文件操作 → 评分 → 下载器 → 缩略缓存 →
  /// 传输引擎(水印/XMP 注入闭包)→ 速传 → 设置与快照。
  void _wireBrowseAndTransfer() {
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
      // 水印合成:设置选模板;off / 异常 → 不处理。
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
      // XMP 元数据注入:设置开关 + 本地评分 + 定位快照。
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
      // 速传策略投影:core 不认 data 层设置店,回调从 current() 取二字段。
      policyFor: () async {
        final config = await settingsStore.current();
        return (
          enabled: config.autoTransfer,
          format: config.autoTransferFormat,
        );
      },
    );
    settingsController = SettingsController(store: settingsStore);
    configSnapshots = ConfigSnapshotStore(
        dataDir: PlatformServices.gallery.dataDir);
    snapshotController = SnapshotController(
      session: session,
      connection: connection,
      store: configSnapshots,
    );
  }

  /// BLE 会话装配(协议层周期驱动零 Timer,前台驱动见 [_wireBleDriver])。
  void _wireBleSession() {
    // BLE 相机会话先建(连接页「蓝牙」分段装配要引用;注入驱动挂接在
    // 其后 —— 协议层周期驱动零 Timer,前台驱动全收在这里:定位流 →
    // onFix;5s tick → 保活到点判定/缓存回补;退避重试一次性 Timer
    // 按 nextRetryDelay 定时。BLE 会话独立于 PTP 链接 —— 有身份即起
    // (链路层,GPS 开关只管注入层),app 存活期维持,不随 USB/无线
    // 断连拆)。
    bleSession = BleCameraSession(host: PlatformServices.ble);
    // 帧级 trace 常年接线进统一日志(ble 域,debug 级):不随配对面板
    // 开关断续,通用日志随时可查握手/注入帧时序(2026-10-17 面板日志
    // 框退役,日志并轨统一日志)。
    bleSession.onTrace = (line) => AppLog.d(AppLog.ble, line);
    // 前台/后台档位(BLE TIME 保活 45s/90s):生命周期观察在服务层就地
    // 接线,UI 零感知;resumed=前台档,其余态(含 inactive 瞬态)按
    // 后台档 —— 只影响下一拍到点判定,无副作用。监听器随
    // WidgetsBinding 强引用存活(单例 app 期不拆)。
    AppLifecycleListener(
      onStateChange: (s) {
        bleSession.setForeground(s == AppLifecycleState.resumed);
        // 回前台沿重申后台持有(ohos 系统静默吊销后的重申请路;
        // native 端「已申请」按成功收场,不会叠加 —— 幂等无害)。
        if (s == AppLifecycleState.resumed) {
          unawaited(PlatformServices.background.reassert());
        }
      },
    );
  }

  /// 控制器装配:连接/浏览/概览/双卡槽/取景引擎与拍摄控制器,设置
  /// 沿同步(自动起景/SDRAM 直拍/画质档)。
  void _wireControllers() {
    connectionController = ConnectionController(
      connection: connection,
      scanner: PlatformServices.nsd,
      pairedCameras: pairedCameras,
      identityStore: identityStore,
      // 蓝牙工具通道(连接页「蓝牙」分段):唤醒 WiFi(不建相机连接)。
      // GPS 注入开关在设置页 —— 落库沿经 settingsController 监听
      // (_updateBleInjection)刷新注入驱动,此处无需专钩。
      bleSession: bleSession,
      bleIdentityStore: bleIdentityStore,
      // 程序化加入相机热点(Android 落地;iOS/ohos 未装配自动回落
      // 手动指引)—— BLE→WiFi 交接最后一段,SnapBridge 全程。
      wifiJoiner: PlatformServices.wifiJoiner,
      settingsController: settingsController,
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
      connectRefreshGate: _connectSideChainGate,
    );
    // 双卡槽余量:连接成功即拉,相册页顶展示。
    storageOverview = StorageOverviewController(
      session: session,
      connection: connection,
      connectRefreshGate: _connectSideChainGate,
    );
    // 取景引擎先行创建再注入控制器:看门狗重启预算耗尽时升级整链重连
    // (engine → connection.requestRecovery,恢复循环由连接层接管;
    // 引擎无连接引用,回调装配在此收口)。接口零新增 —— 此处持具体
    // 类型 CameraConnectionImpl。
    final lvEngine = LiveViewEngine(
      session: session,
      onEscalateToLinkRecovery: () =>
          connection.requestRecovery('conn.errStreamRestart'),
    );
    remoteController = RemoteController(
      session: session,
      connection: connection,
      // AP 取景失败占位的接管引导门槛(STA 门天然开,USB 另有因)。
      isApMode: () => connectionController.method == ConnectionMethod.ap,
      engine: lvEngine,
      // SDRAM 直拍收尾的图库通道(0xC101 对象 → 图库目的地全链)。
      transferEngine: transferEngine,
    );
    // 取景总开关(十二轮持久化):连接沿自动起景闸 —— 设置里关了
    // 取景,重连/冷启都不再自动 0x9201;拍摄页浮层「取景」钮改动
    // 即时同步到这里(页面自己也同步一份,双向不冲突,同值幂等)。
    remoteController.autoLiveViewEnabled = settingsController.value.liveViewOn;
    // SDRAM 直拍开关同样双向不冲突(同值幂等):设置改动沿即时跟随。
    remoteController.sdramCapture = settingsController.value.sdramCapture;
    // 取景画质档(2026-10-13 默认 XGA/Fine):装配沿只对齐字段,连接沿
    // _applyLiveViewQuality 起景前写入(首帧即目标分辨率);相机写在
    // 拍摄页浮层收口,这里直赋不发写、不 notify(同 sdramCapture 款)。
    remoteController.liveViewImageSize =
        settingsController.value.liveViewImageSize;
    remoteController.liveViewImageCompression =
        settingsController.value.liveViewImageCompression;
    settingsController.addListener(() {
      remoteController.autoLiveViewEnabled =
          settingsController.value.liveViewOn;
      remoteController.sdramCapture = settingsController.value.sdramCapture;
      remoteController.liveViewImageSize =
          settingsController.value.liveViewImageSize;
      remoteController.liveViewImageCompression =
          settingsController.value.liveViewImageCompression;
    });
  }

  /// BLE 驱动装配:双层驱动实例化(平台面注入)+ 注入开关监听 +
  /// 盘载身份恢复(冷启直进重连,免重走相机菜单配对)。
  void _wireBleDriver() {
    bleDriver = BleDriver(
      session: bleSession,
      gpsInjectEnabled: () => settingsController.value.bleGpsInject,
      locationStream: PlatformServices.locationStream,
      background: PlatformServices.background,
      dataDir: () => PlatformServices.gallery.dataDir(),
    );
    settingsController.addListener(bleDriver.refresh);
    unawaited(() async {
      final saved = await bleIdentityStore.load();
      if (saved != null) {
        bleSession.identity = BleIdentity(
          peripheralUuid: saved.peripheralUuid,
          deviceId: saved.deviceId,
          nonce: saved.nonce,
          serial: saved.serial,
          name: saved.controllerName,
        );
      }
      bleDriver.refresh();
    }());
  }

  /// 传输控制器与后台保活装配(持有式,各业务按 tag 持有)。
  void _wireBackgroundHolds() {
    transfersController = TransfersController(
      engine: transferEngine,
      gallery: PlatformServices.gallery,
    );

    // 后台保活(持有式,2026-10-15 扩双模式动态切换):各业务按 tag
    // 持有,有效模式 = 全部持有者并集,并集变化沿才过通道(协调器与
    // 决策表见 background_transfer.dart;ohos native 按 modes 换装)。
    // 传输队列非空 → dataTransfer;BLE 会话就绪 → bluetoothInteraction
    // (GPS 注入采样期并 location,见 _syncBleBackgroundHold)。native
    // 未实现的端静默降级为仅前台传输。tasks 每个进度快照都发事件,
    // 只在 active 边沿上过通道。
    var bgHeld = false;
    transferEngine.tasks.listen((ts) {
      final active = ts.any((t) => !t.isTerminal);
      if (active == bgHeld) return;
      bgHeld = active;
      unawaited(
          active
              ? PlatformServices.background.ensureRunning(
                  'transfer', const <BgMode>{BgMode.dataTransfer})
              : PlatformServices.background.stop('transfer'));
    });
    // BLE 持有独立订阅(广播流;注入驱动的 _bleStateSub 只在驱动在跑
    // 期存活,配对页挂起期链路仍在 —— 持有须全程跟随会话状态)。
    bleSession.states.listen((s) {
      bleDriver.syncBackgroundHold();
      if (s == BleSessionState.ready) {
        // ready 沿旧档相机名回填(配对页挂起期的手动重连路也覆盖;
        // 幂等,新档同值即短路)。
        unawaited(connectionController.healCameraName());
      }
    });

    // 尼康事件轮询(GetEventEx 0x941C):重要事件走厂商轮询通道而非
    // 异步事件通道(OpenZCine/libgphoto2 口径)—— 连接期间定时拉取
    // 并入 session.events;不支持/连续失败自动停(回退异步通道)。
    eventPoller = NikonEventPoller(session: session);
  }

  /// 会话生命周期装配:连接沿协调器(轮询启停/缓存失效/诊断/侧链
  /// 让路)挂接,三沿语义见 SessionLifecycle。
  void _wireSessionLifecycle() {
    SessionLifecycle(
      connection: connection,
      session: session,
      repository: repository,
      thumbnails: thumbnails,
      eventPoller: eventPoller,
      startSettledGate: _connectSideChainGate,
      diagnosticsOnConnect: kPtpDiagnosticsOnConnect,
      runDiagnostics: () =>
          PtpDiagnostics.run(session: session, repository: repository),
    ).attach();

    // 断开/失败 → 对象缓存与缩略图内存索引失效(缩略图磁盘缓存是
    // 内容键,跨会话稳定,保留;重连后重新全量枚举)。
    // 连接成功 → PTP 诊断序列**显式开才跑**(kPtpDiagnosticsOnConnect,
    // --dart-define=PTP_DIAG=true):序列含全卡枚举×3 + 两次整图下载 +
    // 会话重开,全在串行锁上 —— 2026-10-16 真机定案收闸,Wi-Fi 下它
    // 把取景首帧/进页刷参/信息卡全部压到分钟级(拍摄页「进页卡很久、
    // 无实时取景」主因)。见 debug/ptp_diagnostics.dart。
  }

  // ------------------------------------------------------------------
  // 日志装配(AppLog 的出口注入面,core 零 IO 约定的另一半)
  // ------------------------------------------------------------------

  static const int _tailCapBytes = 256 * 1024;

  /// 控制台镜像(debug 构建接 debugPrint → hilog,release 无出口)+
  /// error 尾巴文件:环形缓冲之外的崩溃保险,error 级即时追加
  /// `dataDir/logs/tail.log`,超 256KB 裁半。dataDir 是异步通道调用:
  /// resolve 前的行先缓冲,到位后补落;通道不可用(测试/异端)置
  /// failed 放弃落盘,内存环照常兜底 —— 落盘永不反噬日志主链路。
  void _wireAppLog() {
    final buffered = <String>[];
    Directory? logsDir;
    var resolving = false;
    var failed = false;
    AppLog.configure(
      mirror: kDebugMode ? debugPrint : null,
      errorTail: (line) {
        if (failed) return;
        final dir = logsDir;
        if (dir != null) {
          unawaited(_appendTail(dir, line));
          return;
        }
        buffered.add(line);
        if (resolving) return;
        resolving = true;
        unawaited(() async {
          try {
            final dataDir = await PlatformServices.gallery.dataDir();
            final d = Directory('$dataDir/logs');
            await d.create(recursive: true);
            logsDir = d;
            final pending = buffered.toList();
            buffered.clear();
            for (final l in pending) {
              await _appendTail(d, l);
            }
          } on Object {
            failed = true;
            buffered.clear();
          } finally {
            resolving = false;
          }
        }());
      },
    );
  }

  Future<void> _appendTail(Directory logsDir, String line) async {
    try {
      final f = File('${logsDir.path}/tail.log');
      await f.writeAsString('$line\n', mode: FileMode.append);
      if (await f.length() > _tailCapBytes) {
        final bytes = await f.readAsBytes();
        await f.writeAsBytes(bytes.sublist(_tailCapBytes ~/ 2), flush: true);
      }
    } on Object {
      // 落盘失败(盘满等):静默,内存环仍是完整账本
    }
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

  /// 侧链放行门:等当前连接沿的起景段落定(超时兜底见
  /// kConnectStartGateTimeout)。概览/双卡槽/清事件/对时/轮询/相册预热
  /// 共此门。引用 late final 字段,连接沿才执行(装配早已收口),无
  /// 先序问题。
  Future<void> _connectSideChainGate() =>
      remoteController.connectedStartSettled
          .timeout(kConnectStartGateTimeout, onTimeout: () {});

  late final BleDriver bleDriver;

  // BLE 驱动门面(BleDriver 持全部状态;调用面与抽出前一致)。
  void suspendBleDriver() => bleDriver.suspend();
  void resumeBleDriver() => bleDriver.resume();
  bool get bleManualOff => bleDriver.manualOff;
  set bleManualOff(bool v) => bleDriver.manualOff = v;
  void refreshBleInjection() => bleDriver.refresh();
  bool get bleDriverRunning => bleDriver.running;
  void setPanelScanActive(bool active) => bleDriver.setPanelScanActive(active);

  late final TransfersController transfersController;
  late final BleIdentityStore bleIdentityStore;
  /// BLE 相机会话(构造沿即建 —— 连接页「蓝牙」分段装配要引用;
  /// 驱动挂接在其后)。
  late final BleCameraSession bleSession;
}

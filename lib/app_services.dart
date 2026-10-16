/// 应用级单例定位器(TODO.md §三:连接是全局单例状态,引入 DI 前的收口点)。
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
import 'core/ble/geo_payload.dart';
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
import 'features/connection/connection_page.dart';
import 'features/remote/remote_controller.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/snapshot_controller.dart';
import 'features/transfers/transfers_page.dart';
import 'platform/background_transfer.dart';
import 'platform/location_host.dart';
import 'platform/services.dart';
import 'platform/usb/usb_host.dart';
import 'platform/usb/watchdog_usb_host.dart';

/// 连接沿侧链让路窗(2026-10-16 真机定案):概览/双卡槽/清事件/对时/
/// 事件轮询与起景链(接管→模式→画质→0x9201)同在会话串行锁上轮转,
/// 曾把 0x9201 压到十几事务深 —— 拍摄页「取景未开启」卡好几秒。侧链
/// 整组延此窗再上路,起景链先独跑、首帧上屏;测试侧控制器默认零延迟。
const Duration kConnectSideChainYield = Duration(seconds: 2);

final class AppServices {
  AppServices._() {
    // 幂等:测试直接 pumpWidget 不经 main(),这里保证平台服务就绪。
    PlatformServices.bootstrap();
    _wireAppLog();

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
    // BLE 相机会话先建(连接页「蓝牙」分段装配要引用;GPS 注入驱动
    // 挂接在其后 —— 协议层周期驱动零 Timer,前台驱动全收在这里:定位流 →
    // onFix;5s tick → 保活到点判定/缓存回补;退避重试一次性 Timer
    // 按 nextRetryDelay 定时。BLE 会话独立于 PTP 链接 —— 开关开即起,
    // app 存活期维持,不随 USB/无线断连拆)。
    bleSession = BleCameraSession(host: PlatformServices.ble);
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
    connectionController = ConnectionController(
      connection: connection,
      scanner: PlatformServices.nsd,
      pairedCameras: pairedCameras,
      identityStore: identityStore,
      // 蓝牙工具通道(连接页「蓝牙」分段):GPS 注入 / 唤醒 WiFi;
      // 开关落库沿接注入驱动刷新(同 refreshBleInjection 收口)。
      bleSession: bleSession,
      bleIdentityStore: bleIdentityStore,
      // 程序化加入相机热点(Android 落地;iOS/ohos 未装配自动回落
      // 手动指引)—— BLE→WiFi 交接最后一段,SnapBridge 全程。
      wifiJoiner: PlatformServices.wifiJoiner,
      settingsController: settingsController,
      onBleInjectChanged: refreshBleInjection,
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
      connectRefreshDelay: kConnectSideChainYield,
    );
    // 双卡槽余量:连接成功即拉,相册页顶展示。
    storageOverview = StorageOverviewController(
      session: session,
      connection: connection,
      connectRefreshDelay: kConnectSideChainYield,
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
    // BLE 会话已提前创建(连接页装配沿);这里只挂驱动:注入开关监听
    // + 盘载身份恢复(冷启直进重连,免重走相机菜单配对)。
    settingsController.addListener(_updateBleInjection);
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
      _updateBleInjection();
    }());
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
    bleSession.states.listen((_) => _syncBleBackgroundHold());

    // 尼康事件轮询(GetEventEx 0x941C):重要事件走厂商轮询通道而非
    // 异步事件通道(OpenZCine/libgphoto2 口径)—— 连接期间定时拉取
    // 并入 session.events;不支持/连续失败自动停(回退异步通道)。
    eventPoller = NikonEventPoller(session: session);

    // 断开/失败 → 对象缓存与缩略图内存索引失效(缩略图磁盘缓存是
    // 内容键,跨会话稳定,保留;重连后重新全量枚举)。
    // 连接成功 → PTP 诊断序列**显式开才跑**(kPtpDiagnosticsOnConnect,
    // --dart-define=PTP_DIAG=true):序列含全卡枚举×3 + 两次整图下载 +
    // 会话重开,全在串行锁上 —— 2026-10-16 真机定案收闸,Wi-Fi 下它
    // 把取景首帧/进页刷参/信息卡全部压到分钟级(拍摄页「进页卡很久、
    // 无实时取景」主因)。见 debug/ptp_diagnostics.dart。
    var diagRan = false;
    connection.states.listen((s) {
      // 连接成功沿(含重连成功)每沿必启轮询器(start 幂等);诊断只
      // 跑一次。2026-10-10 修:旧结构把 start() 关在 !diagRan 门里,
      // 首连后重连成功的 connected 沿轮询器永远不再跑。
      if (s == CameraLinkState.connected) {
        if (kPtpDiagnosticsOnConnect && !diagRan) {
          diagRan = true;
          PtpDiagnostics.run(session: session, repository: repository);
        }
        // 侧链整组让路(kConnectSideChainYield):起景链先独跑,首帧
        // 上屏后再上路;先清再开轮询器的次序不变。轮询器周期 2s,让路
        // 窗内事件不丢(首拍顺延一并拉)。
        unawaited(Future<void>.delayed(kConnectSideChainYield, () {
          // 延迟窗里沿翻篇(断开/重连)不追;重连沿有自己的新定时。
          if (connection.state != CameraLinkState.connected) return;
          // 重连沿清相机事件队列残留(0x9461,官方候选;best-effort ——
          // 不支持/会话未开静默跳过,不挡连接)。先清再开轮询器,免得
          // 首拍把陈年事件当新鲜货推给 UI。
          unawaited(() async {
            try {
              await session.clearEvent();
            } on Exception {
              // 静默:候选码,机身不支持属常态
            }
          }());
          eventPoller.start();
          // 相机时钟校准(OpenZCine CameraClockSync 口径:漂移 > 5s 才写,
          // 尽力而为不影响连接)。
          unawaited(session.syncCameraClock());
        }));
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

  // ------------------------------------------------------------------
  // BLE GPS 注入驱动(M4/M5):开关开 + 已配对 → 起定位流 + tick +
  // 退避重连循环;关 → 全停。session 层零 Timer,前台驱动全收在这里。
  // ------------------------------------------------------------------

  Timer? _bleTick;
  Timer? _bleRetry;
  StreamSubscription<LocationSample>? _bleFixSub;
  StreamSubscription<BleSessionState>? _bleStateSub;
  bool _bleRunning = false;

  /// BLE 持有式后台保活同步(调用点:会话状态沿/设置沿/挂起沿,均
  /// 幂等):会话 ready → hold('ble', bluetoothInteraction);GPS 注入
  /// 驱动在跑(_bleRunning = 开关+已配对+未挂起)再并 location。
  /// 模式须有真实业务背书 —— location 挂着但 GPS 不采样,系统可能按
  /// 「未使用」吊销整个长时任务(HarmoNiLink 实证口径)。
  void _syncBleBackgroundHold() {
    if (bleSession.state != BleSessionState.ready) {
      unawaited(PlatformServices.background.stop('ble'));
      return;
    }
    final modes = <BgMode>{BgMode.bluetoothInteraction};
    if (_bleRunning) {
      modes.add(BgMode.location);
    }
    unawaited(PlatformServices.background.ensureRunning('ble', modes));
  }

  /// 配对页手动流程期间挂起(驱动自动重连/ GEO tick 会与手动配对撞车:
  /// 扫描互踩 + 拆链沿 GEO 写 notFound 污染 lastError —— 真机实证)。
  bool _bleSuspended = false;

  /// 配对页进入时挂驱动、离页恢复(见 _bleSuspended)。只停驱动循环
  /// (tick/重试/定位流/订阅),不动已建立的 BLE 链路 —— 管理页进出
  /// 不应拆链(真机 2026-10-14:挂起沿 disconnect 把 ready 链路也拆了,
  /// 连接页「配对管理」一点蓝牙就断)。
  void suspendBleDriver() {
    _bleSuspended = true;
    if (_bleRunning) {
      _bleRunning = false;
      _stopBleDriverLoop();
    }
    // 挂起期 GPS 不再采样:location 模式撤出(防系统按「location
    // 未使用」吊销整个长时任务)。
    _syncBleBackgroundHold();
  }

  void resumeBleDriver() {
    _bleSuspended = false;
    _updateBleInjection();
  }

  /// 配对页配对成功/解除后刷新(设置监听之外的显式入口)。
  void refreshBleInjection() => _updateBleInjection();

  void _updateBleInjection() {
    final enabled = !_bleSuspended &&
        settingsController.value.bleGpsInject &&
        bleSession.identity != null;
    if (enabled == _bleRunning) return;
    _bleRunning = enabled;
    // 翻面后再同步:_bleRunning 决定 location 是否并入并集(挂起恢复
    // 沿链路仍是 ready、无状态沿可蹭,必须在此对齐)。
    _syncBleBackgroundHold();
    if (enabled) {
      _startBleInjection();
    } else {
      _stopBleInjection();
    }
  }

  void _startBleInjection() {
    _bleStateSub = bleSession.states.listen((s) {
      if (s == BleSessionState.reconnecting) {
        _scheduleBleRetry();
      } else if (s == BleSessionState.ready) {
        // 就绪沿起定位流(断连重连沿天然复启;未授权/通道缺失时静默
        // 无坐标,TIME 心跳仍维持会话)。
        unawaited(_startLocationStream());
      } else if (s == BleSessionState.idle) {
        _bleRetry?.cancel();
      }
    });
    _bleFixSub = PlatformServices.locationStream.stream().listen(
          (s) => bleSession.onFix(GeoFix(
            latitude: s.latitude,
            longitude: s.longitude,
            altitude: s.altitude,
            // iOS 无卫星数 API。真机 2026-10-13:填 0 相机按「无定位」
            // 处理 —— EXIF 只落 GPS 空壳(仅 VersionID)不写坐标,故
            // 填常规可视卫星数(坐标本身是真实的,卫星数仅为修饰)。
            satellites: 8,
            utcTime: DateTime.now().toUtc(),
          )),
          onError: (Object e) => bleSession.lastError = '定位流失败:$e',
        );
    // 拍频 5s = 到点判定分辨率(首写门 2.5s/GEO 失败回补重闸 2.5s →
    // 实际首写 ≤7.5s);TIME 写本身由会话按 45s/90s 档位门控,拍频加密
    // 不抬 BLE 流量。
    _bleTick = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(bleSession.tick()));
    // 冷启恢复档:idle/reconnecting 且盘载身份在 → 直接进重试循环(免
    // 重走菜单配对;挂起恢复沿链路保留,可停在 reconnecting,同样续跑);
    // 已 ready(配对页「重连」按钮走的路)→ 定位流同样要起,不能只盯
    // 状态跃迁沿。
    if (bleSession.identity != null &&
        (bleSession.state == BleSessionState.idle ||
            bleSession.state == BleSessionState.reconnecting)) {
      _scheduleBleRetry();
    } else if (bleSession.state == BleSessionState.ready) {
      unawaited(_startLocationStream());
    }
  }

  void _scheduleBleRetry() {
    _bleRetry?.cancel();
    if (!_bleRunning) return;
    _bleRetry = Timer(bleSession.nextRetryDelay, () async {
      if (!_bleRunning) return;
      final ok = await bleSession.retryReconnect();
      if (!ok &&
          _bleRunning &&
          bleSession.state == BleSessionState.reconnecting) {
        _scheduleBleRetry();
      }
    });
  }

  /// 注入关停(开关关沿):驱动循环 + BLE 链路一起停(「关 → 全停」)。
  void _stopBleInjection() {
    _stopBleDriverLoop();
    unawaited(bleSession.disconnect());
  }

  /// 停驱动循环(tick/重试/订阅/定位流),保留 BLE 链路本身。恢复时
  /// [_startBleInjection] 按当前会话态续上(ready → 定位流;idle/
  /// reconnecting → 重试循环)。
  void _stopBleDriverLoop() {
    _bleRetry?.cancel();
    _bleRetry = null;
    _bleTick?.cancel();
    _bleTick = null;
    unawaited(_bleFixSub?.cancel());
    _bleFixSub = null;
    unawaited(_bleStateSub?.cancel());
    _bleStateSub = null;
    unawaited(() async {
      try {
        await PlatformServices.locationStream.stopStream();
      } on Exception {
        // 通道未实现(异端):流本就没起,无妨
      }
    }());
  }

  Future<void> _startLocationStream() async {
    try {
      await PlatformServices.locationStream.startStream();
    } on Exception {
      // 定位源不可用(未授权/通道缺失):会话 TIME 心跳照常,零坐标注入
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
  late final TransfersController transfersController;
  late final BleIdentityStore bleIdentityStore;
  /// BLE 相机会话(构造沿即建 —— 连接页「蓝牙」分段装配要引用;
  /// 驱动挂接在其后)。
  late final BleCameraSession bleSession;
}

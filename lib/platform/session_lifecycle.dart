/// 连接沿生命周期协调器:connected / disconnected·failed / reconnecting
/// 三沿的缓存失效、事件轮询启停、诊断与侧链让路(2026-10-22 自
/// AppServices 构造闭包迁出 —— 装配器回归纯装配,三沿语义独立可读)。
library;

import 'dart:async';

import '../core/browser/object_repository.dart';
import '../core/browser/thumbnail_cache.dart';
import '../core/camera/camera_connection.dart';
import '../core/ptp/event_poller.dart';
import '../core/ptp/ptp_session.dart';

final class SessionLifecycle {
  SessionLifecycle({
    required CameraConnection connection,
    required this.session,
    required this.repository,
    required this.thumbnails,
    required this.eventPoller,
    required this.startSettledGate,
    required this.diagnosticsOnConnect,
    required this.runDiagnostics,
  }) : _connection = connection;

  final CameraConnection _connection;
  final PtpSession session;
  final ObjectRepository repository;
  final ThumbnailCache thumbnails;
  final NikonEventPoller eventPoller;

  /// 侧链让路门:等当前连接沿的起景段落定(装配侧注入,拍页自动起景
  /// 开关等参与)。
  final Future<void> Function() startSettledGate;

  /// 连接成功沿诊断序列开关(--dart-define=PTP_DIAG);只跑一次。
  final bool diagnosticsOnConnect;
  final void Function() runDiagnostics;

  var _diagRan = false;

  /// 挂接状态监听(单例 app 期不拆)。
  void attach() {
    _connection.states.listen(_onState);
  }

  void _onState(CameraLinkState s) {
    // 连接成功沿(含重连成功)每沿必启轮询器(start 幂等);诊断只
    // 跑一次。2026-10-10 修:旧结构把 start() 关在 !diagRan 门里,
    // 首连后重连成功的 connected 沿轮询器永远不再跑。
    if (s == CameraLinkState.connected) {
      if (diagnosticsOnConnect && !_diagRan) {
        _diagRan = true;
        runDiagnostics();
      }
      // 侧链整组让路:等起景段落定门(事件驱动)再上路;先清再开轮
      // 询器的次序不变。轮询器周期 2s,等窗内事件不丢(首拍顺延一并
      // 拉)。
      unawaited(() async {
        await startSettledGate();
        // 门等窗里沿翻篇(断开/重连)不追;重连沿有自己的新定时。
        if (_connection.state != CameraLinkState.connected) return;
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
        // 相册预热:门放行后后台开枚举(分页快路 + 页间让路,与刷参
        // 链轮转)—— 进相册页时 _ensureLoaded 去重共享在途/已成缓存,
        // 免首屏等待。失败静默:进页时 _ensureLoaded 自然重开一轮。
        unawaited(() async {
          try {
            await repository.loadAlbums();
          } on Exception {
            // 静默:预热是尽力而为,失败语义归进页重试
          }
        }());
      }());
    }
    if (s == CameraLinkState.disconnected || s == CameraLinkState.failed) {
      eventPoller.stop();
      _diagRan = false;
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
  }
}

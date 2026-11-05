/// 尼康事件轮询引擎(GetEventEx 0x941C)。
///
/// 尼康机身把 ObjectAdded / CaptureComplete / DevicePropChanged(0x4006)
/// 等事件放在**厂商轮询队列**而非异步事件通道(USB interrupt / PTP-IP
/// 事件 socket)—— OpenZCine CameraAnnouncedPropertyQueue 与 libgphoto2
/// ptp_check_event 的实测口径。本引擎在连接期间定时拉取队列,取回的
/// 事件经 [PtpSession.emitPolledEvents] 并入 [PtpSession.events] 流
/// (与异步通道并存,消费端幂等)。
///
/// 相机不支持该 op(旧机身回 0x2005)或连续失败时自动停 —— 静默回退
/// 纯异步通道的现状,不算错误。
library;

import 'dart:async';

import '../log/app_log.dart';
import 'operation_codes.dart';
import 'ptp_session.dart';
import 'ptp_transport.dart';

final class NikonEventPoller {
  NikonEventPoller({
    required this.session,
    this.interval = const Duration(seconds: 2),
    this.maxConsecutiveFailures = 3,
  });

  final PtpSession session;

  /// 轮询节拍(OpenZCine 按帧节流,我们取保守 2s:事件延迟要求远低于
  /// 取景帧率,省下的链路留给帧流)。
  final Duration interval;

  /// 连续失败上限:达到即停(旧机身/链路将断)。
  final int maxConsecutiveFailures;

  Timer? _timer;
  int _failures = 0;
  bool _polling = false;

  /// 补册观测去重(每码每会话一条):0xC10B/0xC10F/0xC126 只走本通道;
  /// 0xC120-24/0xC128/0xC700 官方无条目 —— 真实事件到达即落 AppLog,
  /// 供后续补册,不改行为。

  /// 轮询是否在跑。
  bool get isRunning => _timer != null;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => _poll());
    // 新连接会话:观测去重表复位(每码每会话一条,重连后可重新留痕)。
    _observed.clear();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_polling) return; // 上一次还没回来(链路慢):跳过本拍
    _polling = true;
    try {
      final events = await session.getEventEx();
      _failures = 0;
      if (events.isNotEmpty) {
        _noteUncatalogued(events);
        session.emitPolledEvents(events);
      }
    } on Exception {
      if (++_failures >= maxConsecutiveFailures) {
        stop(); // 不支持/链路将断:静默回退异步通道
      }
    } finally {
      _polling = false;
    }
  }

  /// 补册观测:GetEventEx-only 三码 + 官方无条目六码,每码本会话只记
  /// 一次(参数一并留痕)。纯日志,不影响事件投递。
  void _noteUncatalogued(List<PtpEvent> events) {
    for (final e in events) {
      final code = e.code;
      final watch = code == NikonEventCode.pictureControlAdjustChanged ||
          code == NikonEventCode.openCaptureComplete ||
          code == NikonEventCode.portraitImpressionBalanceAdjustChanged ||
          (code >= 0xC120 && code <= 0xC124) ||
          code == 0xC128 ||
          code == 0xC700;
      if (!watch || !_observed.add(code)) continue;
      AppLog.i(
          AppLog.protocol,
          'GetEventEx 事件 0x${code.toRadixString(16).toUpperCase()}'
          ' 参数 ${e.params}');
    }
  }

  final Set<int> _observed = <int>{};

  void dispose() => stop();
}

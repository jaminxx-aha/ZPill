/// USB 链路看门狗装饰器(P1:相机拔出/无响应永不挂死)。
///
/// 为什么在管道层:ohos 的 bulkTransfer 超时参数**不会中止**已排队的读 ——
/// 相机中途物理拔出后,挂起的 bulkRead Future 永不完成(2026-10-01 真机:
/// 枚举卡 876/877,UI 永久「加载中」),任何一层的 try/catch 都等不到
/// 异常。本装饰器在 Dart 侧给每次收发兜一个不活动看门狗:
/// - bulkRead/bulkOut 超时窗 + 宽限仍未完成 → 判定链路死亡,抛
///   TimeoutException 并广播 [breakages];底层未完成的调用就地遗弃
///   (native 侧有会话轮换守卫,晚到的数据不会污染新会话);
/// - 断链后所有收发立刻抛错(下载重试等场景秒级失败,不再各等一遍
///   超时);open() 重建链路时自动解除;
/// - 拔出轮询:会话打开期间定期 listCameras,设备消失即刻广播
///   (不等下一次读触发的看门狗)。ohos 无热插拔事件 API,getDevices
///   是纯枚举,与在途传输互不干扰。
///
/// 断链异常统一用 TimeoutException(Exception):会话层的
/// `on Exception` 清理路径能接住。
library;

import 'dart:async';
import 'dart:typed_data';

import 'usb_host.dart';

/// bulkRead 看门狗在底层窗口超时之上的宽限:真机 bulkRead 传 15s 窗口,
/// 判定死亡留 6s 余量。相机忙时 native 超时先到(usb_timeout,可恢复的
/// 普通失败,不断链);只有连 native 超时都不生效的挂死才轮到看门狗。
const int kUsbWatchdogGraceMs = 6000;

/// bulk OUT 总兜底(native 内部 5s/块 + STALL 重试一次,整段给足)。
const int kUsbBulkOutWatchdogMs = 20000;

/// 拔出轮询缺省间隔。
const Duration kUsbDetachPollInterval = Duration(seconds: 2);

final class WatchdogUsbHostChannel implements UsbHostChannel {
  WatchdogUsbHostChannel({
    required this.inner,
    this.readGraceMs = kUsbWatchdogGraceMs,
    this.bulkOutWatchdogMs = kUsbBulkOutWatchdogMs,
    this.detachPollInterval = kUsbDetachPollInterval,
  });

  final UsbHostChannel inner;

  /// bulkRead 宽限(毫秒);测试可调小。
  final int readGraceMs;

  /// bulkOut 兜底(毫秒);测试可调小。
  final int bulkOutWatchdogMs;

  /// 拔出轮询间隔;null 关闭(单测用)。
  final Duration? detachPollInterval;

  final StreamController<String> _breakCtrl = StreamController.broadcast();

  bool _broken = false;
  String _lastReason = '';
  String? _openIdentifier;
  Timer? _pollTimer;
  bool _pollInFlight = false;

  @override
  Stream<String> get breakages => _breakCtrl.stream;

  @override
  Future<List<UsbDeviceHandle>> listCameras() => inner.listCameras();

  @override
  Future<void> open(UsbDeviceHandle device) async {
    await inner.open(device);
    // 新链路:解除断链毒化,重开拔出轮询。
    _broken = false;
    _openIdentifier = device.identifier;
    _startPoll();
  }

  @override
  Future<void> close() async {
    _stopPoll();
    _openIdentifier = null;
    await inner.close();
  }

  @override
  Future<void> bulkOut(Uint8List bytes) async {
    // async:毒化的同步抛也以失败 Future 交付,调用方统一 try/await。
    _ensureAlive();
    final reason =
        'bulk OUT ${bulkOutWatchdogMs}ms 无完成:相机已拔出或无响应';
    await inner.bulkOut(bytes).timeout(
      Duration(milliseconds: bulkOutWatchdogMs),
      onTimeout: () {
        _break(reason);
        throw TimeoutException(reason);
      },
    );
  }

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async {
    _ensureAlive();
    final limitMs = timeoutMs + readGraceMs;
    final reason = 'bulk IN ${limitMs}ms 无数据:相机已拔出或无响应';
    return inner.bulkRead(maxLen, timeoutMs: timeoutMs).timeout(
      Duration(milliseconds: limitMs),
      onTimeout: () {
        _break(reason);
        throw TimeoutException(reason);
      },
    );
  }

  @override
  Stream<Uint8List> get interruptEvents => inner.interruptEvents;

  /// 断链后收发入口秒抛(带原委,等重连);TimeoutException 保证会话层
  /// 的 `on Exception` 清理路径能接住。
  void _ensureAlive() {
    if (_broken) {
      throw TimeoutException('USB 链路已中断,等待重连($_lastReason)');
    }
  }

  void _break(String reason) {
    if (_broken) return;
    _broken = true;
    _lastReason = reason;
    _stopPoll();
    _breakCtrl.add(reason);
  }

  // ── 拔出轮询 ────────────────────────────────────────────────

  void _startPoll() {
    _stopPoll();
    final interval = detachPollInterval;
    if (interval == null) return;
    _pollTimer = Timer.periodic(interval, (_) => _pollOnce());
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    if (_pollInFlight || _openIdentifier == null) return;
    _pollInFlight = true;
    try {
      final cameras = await inner.listCameras();
      final id = _openIdentifier;
      if (id != null && !cameras.any((c) => c.identifier == id)) {
        _break('相机已断开(USB 连接消失)');
      }
    } on Exception {
      // 枚举瞬时失败(USB 服务忙)不计断链;看门狗仍兜底
    } finally {
      _pollInFlight = false;
    }
  }
}

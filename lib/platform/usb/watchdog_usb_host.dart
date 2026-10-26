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
/// - 拔出轮询 + 链路探测:会话打开期间定期 listCameras,设备从枚举中
///   消失即刻广播;枚举还报「设备在」时,用 [probe] 在链路上真发一次
///   事务复核存活。**纯枚举不可信**(2026-10-03 真机实证:ohos
///   usb_service 删除设备记录失败 `delete(dev, valid): -4` 后,
///   getDevices() 一直返回幽灵设备,「已连接」假象维持 30 分钟不倒;
///   同场景热插拔事件回调也报错,事件路同样不可靠)。探测挂死 → 底层
///   收发看门狗超时断链;快速失败 → 连续 2 次断链。空转期最坏
///   detection = 探测间隔 + 收发看门狗窗 ≈ 26s。
///
/// 迟到引爆防护:每个 open()/close() 轮换 epoch,挂死调用的看门狗
/// 计时器迟到触发时只向原调用者抛超时,不再毒化此后重建的新链路。
///
/// 断链异常统一用 TimeoutException(Exception):会话层的
/// `on Exception` 清理路径能接住。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'usb_host.dart';

/// bulkRead 看门狗在底层窗口超时之上的宽限:真机 bulkRead 传 15s 窗口,
/// 判定死亡留 6s 余量。相机忙时 native 超时先到(usb_timeout,可恢复的
/// 普通失败,不断链);只有连 native 超时都不生效的挂死才轮到看门狗。
const int kUsbWatchdogGraceMs = 6000;

/// bulk OUT 总兜底(native 内部 5s/块 + STALL 重试一次,整段给足)。
const int kUsbBulkOutWatchdogMs = 20000;

/// drainIn 兜底:native 自带有界(32 轮 × 300ms 静默窗 ≈ 最坏 9.6s),
/// 这里只兜「静默窗也挂死」的极端;超时静默返回 —— 排空失败不判链路
/// 死(死活由收发/探测路径判定),也不毒化(下一个事务还在它上面跑)。
const int kUsbDrainWatchdogMs = 15000;

/// 拔出轮询缺省间隔。
const Duration kUsbDetachPollInterval = Duration(seconds: 2);

/// 链路探测缺省间隔:getDevices 撒谎(幽灵设备)时的兜底节奏。
const Duration kUsbLinkProbeInterval = Duration(seconds: 5);

/// 探测快速失败多少次(连续)判死链:native 对幽灵管道多报错但存在
/// 瞬时失败可能,单次不判死。
const int kUsbLinkProbeFailureLimit = 2;

final class WatchdogUsbHostChannel implements UsbHostChannel {
  WatchdogUsbHostChannel({
    required this.inner,
    this.readGraceMs = kUsbWatchdogGraceMs,
    this.bulkOutWatchdogMs = kUsbBulkOutWatchdogMs,
    this.drainWatchdogMs = kUsbDrainWatchdogMs,
    this.detachPollInterval = kUsbDetachPollInterval,
    this.probeInterval = kUsbLinkProbeInterval,
    this.probe,
  });

  final UsbHostChannel inner;

  /// bulkRead 宽限(毫秒);测试可调小。
  final int readGraceMs;

  /// bulkOut 兜底(毫秒);测试可调小。
  final int bulkOutWatchdogMs;

  /// drainIn 兜底(毫秒);测试可调小。
  final int drainWatchdogMs;

  /// 拔出轮询间隔;null 关闭(单测用)。
  final Duration? detachPollInterval;

  /// 链路探测间隔:枚举报「设备还在」时,至少隔多久真发一次事务。
  final Duration probeInterval;

  /// 存活探测:一次真实链路事务(AppServices 注入 GetDeviceInfo)。
  /// null 时退化为纯枚举判定(旧行为,单测用)。
  final Future<Object?> Function()? probe;

  final StreamController<String> _breakCtrl = StreamController.broadcast();

  bool _broken = false;
  String _lastReason = '';
  String? _openIdentifier;
  Timer? _pollTimer;
  bool _pollInFlight = false;

  /// 链路世代:open()/close() 递增;挂死调用的迟到回调凭此认旧链路。
  int _epoch = 0;

  bool _probeInFlight = false;
  DateTime? _lastProbeAt;
  int _probeFailures = 0;

  @override
  Stream<String> get breakages => _breakCtrl.stream;

  @override
  Future<List<UsbDeviceHandle>> listCameras() => inner.listCameras();

  @override
  Future<void> open(UsbDeviceHandle device) async {
    await inner.open(device);
    // 新链路:解除断链毒化,重开拔出轮询,探测计数清零。
    _broken = false;
    _openIdentifier = device.identifier;
    _epoch++;
    _probeFailures = 0;
    _lastProbeAt = null;
    _startPoll();
  }

  @override
  Future<void> close() async {
    _epoch++;
    _stopPoll();
    _openIdentifier = null;
    await inner.close();
  }

  @override
  Future<bool> recoveryReset() async {
    // 程序化拔插:复位沿等同链路死亡 —— 推进 epoch,旧链路上的挂起
    // 看门狗不再毒化复位后重建的新链路。
    _epoch++;
    _stopPoll();
    _openIdentifier = null;
    return inner.recoveryReset();
  }

  @override
  Future<void> bulkOut(Uint8List bytes) async {
    // async:毒化的同步抛也以失败 Future 交付,调用方统一 try/await。
    _ensureAlive();
    final epoch = _epoch;
    final reason =
        'bulk OUT ${bulkOutWatchdogMs}ms 无完成:相机已拔出或无响应';
    await inner.bulkOut(bytes).timeout(
      Duration(milliseconds: bulkOutWatchdogMs),
      onTimeout: () {
        // 期间已重开新链路的话,只让原调用者超时,不毒化新链路。
        if (epoch == _epoch) _break(reason);
        throw TimeoutException(reason);
      },
    );
  }

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async {
    _ensureAlive();
    final epoch = _epoch;
    final limitMs = timeoutMs + readGraceMs;
    final reason = 'bulk IN ${limitMs}ms 无数据:相机已拔出或无响应';
    return inner.bulkRead(maxLen, timeoutMs: timeoutMs).timeout(
      Duration(milliseconds: limitMs),
      onTimeout: () {
        if (epoch == _epoch) _break(reason);
        throw TimeoutException(reason);
      },
    );
  }

  @override
  Stream<Uint8List> get interruptEvents => inner.interruptEvents;

  /// 中止后排空:转发内层并兜挂死(native 有界自不必说,防的是静默窗
  /// 本身挂死 —— 同 ohos bulkTransfer 不中止已排队读的旧坑)。超时静默
  /// 返回、不广播断链:排空是 best-effort 恢复动作,不是链路活性证据。
  @override
  Future<void> drainIn() async {
    _ensureAlive();
    await inner.drainIn().timeout(
          Duration(milliseconds: drainWatchdogMs),
          onTimeout: () {},
        );
  }

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
    debugPrint('[USB看门狗] 断链:$reason');
    _breakCtrl.add(reason);
  }

  // ── 拔出轮询 + 链路探测 ──────────────────────────────────────

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
      if (id == null) return;
      if (!cameras.any((c) => c.identifier == id)) {
        _break('相机已断开(USB 连接消失)');
        return;
      }
      // 枚举说「还在」——但服务层可能有删不掉的幽灵记录,真发一次事务
      // 复核(探测自带间隔与在途守卫,不与轮询互相阻塞)。
      unawaited(_probe());
    } on Exception {
      // 枚举瞬时失败(USB 服务忙)不计断链;看门狗仍兜底
    } finally {
      _pollInFlight = false;
    }
  }

  /// 存活探测:挂死(TimeoutException,含底层看门狗超时)立即断链;
  /// 其他失败连续 [kUsbLinkProbeFailureLimit] 次断链;成功清零计数。
  /// 探测在链路世代过期后的迟到失败不影响新链路。
  Future<void> _probe() async {
    final probeFn = probe;
    if (probeFn == null || _probeInFlight || _broken) return;
    final last = _lastProbeAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < probeInterval) return;
    _probeInFlight = true;
    _lastProbeAt = now;
    final epoch = _epoch;
    try {
      await probeFn();
      _probeFailures = 0;
    } on TimeoutException {
      if (epoch != _epoch) return;
      debugPrint('[USB看门狗] 链路探测超时');
      _break('链路探测超时:相机已拔出或无响应');
    } on Object {
      if (epoch != _epoch) return;
      _probeFailures++;
      debugPrint('[USB看门狗] 链路探测失败($_probeFailures/'
          '$kUsbLinkProbeFailureLimit)');
      if (_probeFailures >= kUsbLinkProbeFailureLimit) {
        _break('链路探测连续 $_probeFailures 次失败:相机已拔出或无响应');
      }
    } finally {
      _probeInFlight = false;
    }
  }
}

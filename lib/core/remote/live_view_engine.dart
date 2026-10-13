/// Live View 轮询引擎(链路无关、UI 无关)。
///
/// 生命周期:0x9201 StartLiveView(候选码)→ 轮询 0x9203 GetLiveViewImage
/// → 0x9202 EndLiveView。每帧一个短事务,与拍照/属性读在 PtpSession 的
/// 全局串行锁上自然交错;间隔从**上一帧完成时刻**起算。
///
/// 失败策略:指数退避(200ms 起步 ×2,封顶 2s),连续 5 帧失败转
/// failed 并停轮 —— 链路死亡(拔线/无线断)时 5s 内收口,不会无限
/// 打链路。健康路径帧间睡眠 50ms(2026-10-13:200ms 写死把吞吐钳在
/// ~4fps,是相对 SnapBridge 流畅度差距的主项;50ms + 事务耗时 ≈
/// USB 12fps / WiFi 5fps 起,真机再收)。
/// 0xC10C LiveViewStateChanged 事件**不参与启停**:引擎纯轮询自治
/// (事件语义未实证,待真机核对)。
///
/// pause/resume 供两类挂起:拍照/对焦期间(快门/DeviceReady 事务不被
/// 取帧挤占串行锁)与拍摄页不可见时(RemoteController.setViewerVisible,
/// 取景生命周期跟连接走,页面离台只停轮询不发 0x9202)。末帧保留
/// (pause 不闪黑,failed 后回到页面仍见最后画面)。
///
/// **帧签名看门狗**(2026-10-10,见 [LiveViewWatchdog]):只管「事务
/// 成功但内容冻结」(楔死机身持续回放同一张缓存 JPEG)—— 同帧重放
/// 超时 → 探测命令通道(0x90C8):忙(写卡/下载 flush)→ BUSY 保持
/// 不重启(重启会把机身菜单摔回拍摄屏),有界窗口;不忙 → 重启取景
/// (EndLiveView + 自愈梯);预算耗尽 → [onEscalateToLinkRecovery]
/// 升级整链重连(连接层接管)。「链路静默/坏帧连击」仍由本引擎既有
/// 失败退避(连续 5 帧失败转 failed)覆盖,不重复实现。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import 'live_view_header.dart';
import 'live_view_watchdog.dart';

enum LiveViewStatus { idle, running, failed }

/// 取景流健康度(看门狗产物,UI 横幅用):ok = 正常;busy = 机身忙
/// (写卡/下载 flush 中),画面保持不重启;frozen = 冻结判死重启中。
enum LiveViewHealth { ok, busy, frozen }

final class LiveViewEngine {
  LiveViewEngine({
    required this.session,
    this.interval = const Duration(milliseconds: 50),
    LiveViewWatchdog? watchdog,
    this.onEscalateToLinkRecovery,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  })  : _watchdog = watchdog ?? LiveViewWatchdog(),
        _delay = delay ?? Future<void>.delayed,
        _now = clock ?? (() => DateTime.now());

  final PtpSession session;

  /// 轮询基础间隔(健康路径帧间睡眠,从上一帧完成起算;失败退避基数
  /// 独立 [_backoffBase],不随它缩水)。
  final Duration interval;

  /// 帧签名看门狗:事务成功但内容冻结的检测与分级(纯值类,阈值全
  /// verify-on-HW;测试注入小窗)。
  final LiveViewWatchdog _watchdog;

  /// 看门狗重启预算耗尽时的升级回调(AppServices 装配 →
  /// CameraConnectionImpl.requestRecovery,整链重连由连接层接管)。
  final void Function()? onEscalateToLinkRecovery;

  final Future<void> Function(Duration) _delay;

  /// 看门狗喂入的时钟(测试注入合成时钟;生产墙钟)。
  final DateTime Function() _now;

  /// 0x90C2 remote 模式在位(控制器接管态同步而来)。true 时
  /// 0x9201 的 0xA004 自愈梯**不再碰 0x90C2** —— 梯的配对退闩
  /// (90C2(0))会杀掉仅持有期保值的会话写入(0xD1A6 模式覆写等,
  /// 2026-10-11 Zf 实证),改为瞬态忙退避重试。
  bool remoteHeld = false;

  /// 最近一帧(JPEG 字节,SOI 起);null = 尚未收到/从未开启。
  final frame = ValueNotifier<Uint8List?>(null);

  /// 最近一帧的 display-info 头(相机自报的 AF 框/水平仪/录制态;
  /// null = 裸 JPEG/头解析不出/尚未收到)。与 [frame] 同步发布。
  final header = ValueNotifier<LiveViewHeader?>(null);

  final status = ValueNotifier<LiveViewStatus>(LiveViewStatus.idle);

  /// 取景流健康度(帧签名看门狗驱动;UI 横幅「相机忙/画面保持」等)。
  final health = ValueNotifier<LiveViewHealth>(LiveViewHealth.ok);

  /// 转 failed 时的最后错误(展示用)。
  String? lastError;

  static const int _maxFailures = 5;
  static const Duration _maxBackoff = Duration(seconds: 2);

  /// 失败退避基数(200ms 起步 ×2,封顶 2s):与轮询间隔解耦 —— 帧间
  /// 睡眠降到 50ms 后,退避梯仍按真机定案的「5s 内收口」节奏走,链路
  /// 挣扎期不因高频重试提前判死,也不以 50ms 连拍式打垂死链路。
  static const Duration _backoffBase = Duration(milliseconds: 200);
  static const Duration _pausedTick = Duration(milliseconds: 50);

  /// start/stop 轮换世代:旧循环的迟到迭代不得触碰新状态。
  int _runId = 0;
  bool _paused = false;

  /// 看门狗处置在途(探测/重启):取帧循环挂起 tick 等待(仿 _paused),
  /// 不与新事务抢串行锁。
  bool _recovering = false;

  int _failures = 0;

  /// 取景是否已向相机开启(EndLiveView 只在开启过才发 —— 断连兜底的
  /// stop() 不得给从未开过取景的相机发多余命令)。
  bool _viewOn = false;

  /// 开启取景(幂等):StartLiveView 失败即转 failed,不进轮询。
  /// 0xA004(状态不允许)时先走**自愈阶梯**再判失败 —— 见
  /// [_startLiveViewHealing]。
  Future<void> start() async {
    if (status.value == LiveViewStatus.running) return;
    _failures = 0;
    _paused = false;
    _recovering = false;
    lastError = null;
    health.value = LiveViewHealth.ok;
    _watchdog.reset();
    try {
      await _startLiveViewHealing();
    } on Exception catch (e) {
      // 连接梯一并浮出(真机定案仪器:哪一级被拒一眼可读)。
      final ladder = session.connectLadder.join(' ');
      lastError = ladder.isEmpty
          ? '取景开启失败:$e'
          : '取景开启失败:$e〔梯:$ladder〕';
      status.value = LiveViewStatus.failed;
      return;
    }
    status.value = LiveViewStatus.running;
    _viewOn = true;
    final run = ++_runId;
    unawaited(_loop(run));
  }

  /// 0x9201 带 USB 模式门自愈:被拒 0xA004 = 相机仍在上传优先模式
  /// (USB 连接人设,0x9201 被拒)。自愈阶梯按真机实证强度排序,
  /// 每级(一把钥匙)成功后重试一次 0x9201,重试仍拒换下一级,
  /// 全败上抛**原始** 0xA004(不遮原语义);非 0xA004 拒 → 上抛
  /// 该次错误(不无限打)。每步(0x9201 各次/每把钥匙)记入
  /// [PtpSession.connectLadder],start() 失败时随 lastError 浮出:
  /// ① 0x90C2(1) 进 remote 模式 —— 上传优先门是单向闩,1 = 唯一
  ///   实证开闩钥匙(2026-10-07 真机对照;iOS IC 链上 ② 不生效);
  ///   **凡自愈进过 remote,收尾必配对 0x90C2(0) 还机身自由** ——
  ///   remote 持有态才是机身停「已连接到计算机」屏的元凶,而闩不因
  ///   退而关(v9 背靠背 1→0 后 0x9201 照通、帧照流)。
  /// ② 写会话发起者身份 0xD406 非 MTP 串 —— 直连 USB 主机(usbfs/
  ///   libusb 类:Android/ohos)实证有效(2026-10-07 探针);有屏显
  ///   人设副作用(机身把主机归类为计算机),只作末级兜底。
  Future<void> _startLiveViewHealing() async {
    try {
      await session.startLiveView();
      session.noteLadder('9201:OK');
    } on PtpResponseException catch (e) {
      session.noteLadder('9201:${PtpSession.ladderRc(e.responseCode)}');
      if (e.responseCode != NikonResponseCode.invalidStatus) rethrow;
      if (remoteHeld) {
        // 接管持有中:下面的自愈梯每把钥匙都配对 0x90C2(0) 还机身
        // 自由 —— 会连带杀掉仅持有期保值的会话写入(模式覆写)。而
        // 模式切换后的 0xA004 是瞬态忙(2026-10-11 Zf 实证:写后立即
        // 起景偶发被拒,稍候重试即过),退避重试,仍拒上抛原语义。
        for (var attempt = 0; attempt < 2; attempt++) {
          await _delay(const Duration(milliseconds: 400));
          try {
            await session.startLiveView();
            session.noteLadder('9201:OK(忙重试)');
            return;
          } on PtpResponseException catch (e2) {
            session.noteLadder('9201:${PtpSession.ladderRc(e2.responseCode)}');
            final rc = e2.responseCode;
            if (rc != NikonResponseCode.invalidStatus &&
                rc != PtpResponseCode.deviceBusy) {
              rethrow;
            }
          }
        }
        rethrow;
      }
      var remoteEntered = false;
      final keys = <Future<bool> Function()>[
        () async {
          try {
            await session.changeCameraMode(1);
            session.noteLadder('90C2:OK');
            remoteEntered = true;
            return true;
          } on Object {
            session.noteLadder('90C2:拒');
            return false; // op 缺席/被拒/链路类:换下一把钥匙
          }
        },
        () async {
          final ok = await session.writeInitiatorIdentity();
          session.noteLadder('D406:${ok ? 'OK' : '拒'}');
          return ok;
        },
      ];
      try {
        for (final key in keys) {
          if (!await key()) continue;
          try {
            await session.startLiveView();
            session.noteLadder('9201:OK');
            return;
          } on PtpResponseException catch (e2) {
            session.noteLadder('9201:${PtpSession.ladderRc(e2.responseCode)}');
            if (e2.responseCode != NikonResponseCode.invalidStatus) rethrow;
          }
        }
        rethrow; // 两把钥匙都试过仍拒:上抛原始 0xA004
      } finally {
        if (remoteEntered) {
          // 配对退闩:成功/全败路径都要还机身自由(失败时机身回自己的
          // 屏,比停已连接屏友好);尽力而为,不影响上抛语义。
          try {
            await session.changeCameraMode(0);
            session.noteLadder('90C2退:OK');
          } on Object {
            session.noteLadder('90C2退:拒');
          }
        }
      }
    }
  }

  /// 停止取景(幂等):立即废掉循环;开启过才发 EndLiveView,尽力而为
  /// (链路已死时它必然失败,吞掉)。
  Future<void> stop() async {
    _runId++;
    _paused = false;
    _recovering = false;
    _watchdog.reset();
    health.value = LiveViewHealth.ok;
    if (status.value != LiveViewStatus.failed) {
      status.value = LiveViewStatus.idle;
    }
    if (!_viewOn) return;
    _viewOn = false;
    try {
      await session.endLiveView();
    } on Object {
      // 链路已断/相机拒绝/transport 已关(StateError):本地循环已停,足够
    }
  }

  /// 挂起轮询(在途事务自然完成);不影响 Start/EndLiveView 状态。
  void pause() => _paused = true;

  void resume() => _paused = false;

  Future<void> _loop(int run) async {
    while (status.value == LiveViewStatus.running && run == _runId) {
      if (_paused || _recovering) {
        await _delay(_pausedTick);
        continue;
      }
      try {
        final raw = await session.getLiveViewObject();
        if (run != _runId) return; // 停止后的迟到结果不发布
        final jpeg = extractLiveViewJpeg(raw);
        header.value = parseLiveViewHeader(raw);
        frame.value = jpeg;
        _failures = 0;
        // 冻结检测(事务成功但内容冻结;静默/坏帧由下方退避覆盖):
        // 处置器入口同步置 _recovering,本循环下一拍起挂起取帧。
        final signal = _watchdog.inspect(jpeg, _now());
        if (signal != null) {
          unawaited(_handleWatchdogSignal(run, signal));
        } else if (health.value != LiveViewHealth.ok &&
            !_watchdog.frozen(_now())) {
          // BUSY 保持的自我恢复:新内容到达、冻结解除 —— 横幅撤下
          //(看门狗新签名即清零,无信号可发,由宿主就地收口)。
          health.value = LiveViewHealth.ok;
        }
        await _delay(interval);
      } on Object catch (e) {
        if (run != _runId) return;
        _failures++;
        if (_failures >= _maxFailures) {
          lastError = '取景中断:$e';
          status.value = LiveViewStatus.failed;
          _runId++; // 废掉本循环
          return;
        }
        await _delay(_backoff());
      }
    }
  }

  /// 看门狗信号处置(世代门:每步查 run == _runId,stop/升级即废)。
  /// 处置全程挂起取帧(_recovering),完成后恢复;health 随阶段更新。
  Future<void> _handleWatchdogSignal(
      int run, LiveViewWatchdogSignal signal) async {
    _recovering = true;
    try {
      switch (signal) {
        case LiveViewWatchdogSignal.probe:
          bool busy;
          try {
            busy = !(await session.deviceReady());
          } on Object {
            // 命令通道异常:按不忙走重启(重启失败自然转 failed 路径)。
            busy = false;
          }
          if (run != _runId) return;
          switch (_watchdog.noteProbeResult(busy: busy, now: _now())) {
            case LiveViewWatchdogSignal.busyHold:
              // 机身忙(写卡/下载 flush):保持不重启,取帧照旧等自我恢复
              //(重启会把机身菜单摔回拍摄屏);有界窗口由看门狗把守。
              health.value = LiveViewHealth.busy;
            case LiveViewWatchdogSignal.restart:
              await _restartLiveViewOrGiveUp(run);
            case null:
              // 不忙但冻结未满礼让窗:多为操作员在机身菜单/回放,
              // 礼让等待 —— 下一帧按节拍复查,新帧到达即自我纠错。
              break;
            case LiveViewWatchdogSignal.probe:
            case LiveViewWatchdogSignal.busyHoldExpired:
              // 不会从 noteProbeResult 到达(防御空处理)。
              break;
          }
        case LiveViewWatchdogSignal.restart:
        case LiveViewWatchdogSignal.busyHoldExpired:
          await _restartLiveViewOrGiveUp(run);
        case LiveViewWatchdogSignal.busyHold:
          // 不会从 inspect 到达(仅 noteProbeResult 返回,已在上面内联
          // 处理);防御空处理。
          break;
      }
    } finally {
      _recovering = false;
    }
  }

  /// 冻结判死后的处置:预算耗尽 → 升级整链重连(不再重启取景,防无限
  /// 重启风暴);否则 EndLiveView(尽力)→ 自愈梯重启 → 记账 + health
  /// 回 ok。自愈梯抛错 → 既有 failed 路径(lastError 带梯)。
  Future<void> _restartLiveViewOrGiveUp(int run) async {
    if (_watchdog.restartBudgetExhausted) {
      // 废本循环(不发 0x9202 —— 拆链是连接层的事)、回 idle 待重连
      // 成功后由 autoLiveViewOnConnect 重新起景;升级回调最后发。
      _watchdog.reset();
      _runId++;
      status.value = LiveViewStatus.idle;
      health.value = LiveViewHealth.ok;
      onEscalateToLinkRecovery?.call();
      return;
    }
    health.value = LiveViewHealth.frozen;
    try {
      await session.endLiveView();
    } on Object {
      // 尽力而为:楔死机身的 0x9202 可能被拒/链路异常,重启序列照走
    }
    try {
      await _startLiveViewHealing();
    } on Exception catch (e) {
      if (run != _runId) return;
      final ladder = session.connectLadder.join(' ');
      lastError = ladder.isEmpty
          ? '取景流冻结,重启失败:$e'
          : '取景流冻结,重启失败:$e〔梯:$ladder〕';
      status.value = LiveViewStatus.failed;
      _runId++;
      return;
    }
    if (run != _runId) return;
    _watchdog.noteRestarted(_now());
    _failures = 0;
    health.value = LiveViewHealth.ok;
  }

  Duration _backoff() {
    final ms = _backoffBase.inMilliseconds * (1 << (_failures - 1));
    final capped = ms < _maxBackoff.inMilliseconds ? ms : _maxBackoff.inMilliseconds;
    return Duration(milliseconds: capped);
  }
}

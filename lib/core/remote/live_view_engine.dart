/// Live View 轮询引擎(链路无关、UI 无关)。
///
/// 生命周期:0x9201 StartLiveView(候选码)→ 轮询 0x9203 GetLiveViewImage
/// → 0x9202 EndLiveView。每帧一个短事务,与拍照/属性读在 PtpSession 的
/// 全局串行锁上自然交错;间隔从**上一帧完成时刻**起算。
///
/// 失败策略:指数退避(间隔 ×2,封顶 2s),连续 5 帧失败转 failed 并停轮
/// —— 链路死亡(拔线/无线断)时 5s 内收口,不会无限打链路。
/// 0xC10C LiveViewStateChanged 事件**不参与启停**:引擎纯轮询自治
/// (事件语义未实证,待真机核对)。
///
/// pause/resume 供两类挂起:拍照/对焦期间(快门/DeviceReady 事务不被
/// 取帧挤占串行锁)与拍摄页不可见时(RemoteController.setViewerVisible,
/// 取景生命周期跟连接走,页面离台只停轮询不发 0x9202)。末帧保留
/// (pause 不闪黑,failed 后回到页面仍见最后画面)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import 'live_view_header.dart';

enum LiveViewStatus { idle, running, failed }

final class LiveViewEngine {
  LiveViewEngine({
    required this.session,
    this.interval = const Duration(milliseconds: 200),
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final PtpSession session;

  /// 轮询基础间隔(失败退避从它翻倍)。
  final Duration interval;

  final Future<void> Function(Duration) _delay;

  /// 最近一帧(JPEG 字节,SOI 起);null = 尚未收到/从未开启。
  final frame = ValueNotifier<Uint8List?>(null);

  /// 最近一帧的 display-info 头(相机自报的 AF 框/水平仪/录制态;
  /// null = 裸 JPEG/头解析不出/尚未收到)。与 [frame] 同步发布。
  final header = ValueNotifier<LiveViewHeader?>(null);

  final status = ValueNotifier<LiveViewStatus>(LiveViewStatus.idle);

  /// 转 failed 时的最后错误(展示用)。
  String? lastError;

  static const int _maxFailures = 5;
  static const Duration _maxBackoff = Duration(seconds: 2);
  static const Duration _pausedTick = Duration(milliseconds: 50);

  /// start/stop 轮换世代:旧循环的迟到迭代不得触碰新状态。
  int _runId = 0;
  bool _paused = false;
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
    lastError = null;
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
      if (_paused) {
        await _delay(_pausedTick);
        continue;
      }
      try {
        final raw = await session.getLiveViewObject();
        if (run != _runId) return; // 停止后的迟到结果不发布
        header.value = parseLiveViewHeader(raw);
        frame.value = extractLiveViewJpeg(raw);
        _failures = 0;
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

  Duration _backoff() {
    final ms = interval.inMilliseconds * (1 << (_failures - 1));
    final capped = ms < _maxBackoff.inMilliseconds ? ms : _maxBackoff.inMilliseconds;
    return Duration(milliseconds: capped);
  }
}

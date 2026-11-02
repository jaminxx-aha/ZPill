/// 域内实现四分(2026-10-22,同库私有 mixin,门面公开 API 与行为不变;
/// 2026-10-29 按域拆入 part 文件,保持同一 library):
/// [_RemoteCore] on ChangeNotifier 持全部状态字段 + 事件/生命周期机制 +
/// 模式镜像 + 跨域钩子(抽象声明,域实现);[_RemoteLvOps] 取景域;
/// [_RemotePropOps] 参数域;[_RemoteCaptureOps] 拍摄域;[_RemoteAfOps]
/// 对焦域。原文件 `// ---- 官方 §x.x` 分节即缝逐段平移;跨域共享的静态
/// 表/提示构造提为文件级(静态不随 mixin 继承)。

library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/object_repository.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/log/app_log.dart';
import '../../core/ptp/device_prop.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/frame_analyzer.dart';
import '../../core/remote/live_view_engine.dart';
import '../../core/remote/intervalometer.dart';
import '../../core/remote/mf_travel_ends.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../debug/ptp_diagnostics.dart';
import '../../l10n/message.dart';
import '../common/format.dart';
import 'bulb_close_policy.dart';
import 'shooting_param_catalog.dart';

part 'remote_controller_af_ops.dart';
part 'remote_controller_capture_ops.dart';
part 'remote_controller_core.dart';
part 'remote_controller_lv_ops.dart';
part 'remote_controller_prop_ops.dart';

final class Exposure {
  const Exposure({this.fNumber, this.shutterRaw, this.iso});

  /// 光圈值 ×100(u16;280 = f/2.8,ISO 15740 定点)。
  final int? fNumber;

  /// 快门 0xD100 打包分数(num<<16|den;哨兵 0xFFFFFFFF=Bulb /
  /// 0xFFFFFFFE=X 同步 / 0xFFFFFFFD=Time;展示经目录 format)。
  final int? shutterRaw;

  /// ISO(u32;0xD0B5 有效 ISO,Auto ISO 时 = 机身当前应用值)。
  final int? iso;
}

/// 单个拍摄属性的 UI 状态:PropDesc(可写性/取值域)+ 当前值。
final class PropState {
  const PropState({this.desc, this.value});

  /// 0x1014 全描述;null = PropDesc 不可用(裸值回读,取值域未知)。
  final PtpDevicePropDesc? desc;

  /// 当前值(拍摄域属性全为整型;null = 读取失败)。
  final int? value;
}

/// 触控对焦框:归一化坐标(0..1,取景图像坐标系;页面按 BoxFit.contain
/// 映射回屏幕)。[focused] 由 0x90C1 应答推得:null = 对焦中/未知,
/// true = 合焦,false = 未合焦(0xA002)—— 框色跟机身屏对齐只有红绿
/// 两色(2026-10-12 用户定案:合焦绿、其余红);纯位置仍由点按替换、
/// 停取景/断连清除。
final class AfBox {
  const AfBox({required this.nx, required this.ny, this.focused});
  final double nx;
  final double ny;
  final bool? focused;
}

/// 拍摄模式 = 相机真状态(0xD1A6 镜像:0=照片 / 1=视频)。跟随与切换
/// 都在控制器([cameraMode] / [switchMode]):拨杆翻转经 0x4006 事件
/// 实时跟随;接管持有下**两方向都可远程覆写**(2026-10-11 Zf 实证:
/// 写 0xD1A6 被接受、拍照门跟软件态),唯独录像门跟物理拨杆硬互锁
/// (照片档覆写视频后开录仍 0xA004)—— 录像按钮的拨杆提示在开录被拒
/// 时弹出。读不到 0xD1A6 的机身 [cameraMode] 为 null —— 页面回落本地
/// 模式条(纯 UI 行为选择,现状)。
enum CaptureMode { photo, video }

/// 视频档实际工作 ISO(0xD0B5)轮询周期:1s 轻读,远低于取景帧流量。
const Duration _kActualIsoPollInterval = Duration(seconds: 1);

/// 视频 ISO 复合文案:设定值与机身实际工作值(0xD0B5,视频 auto 增益)
/// 分叉时并列「{v}(实际 {a})」;同值/缺任一返回 null(单值照旧)。
/// 2026-10-26 真机:视频档 auto 增益拥有实际曝光(设定 100 实际 720),
/// 单值显示会被读成「改了没效果」。
L10nMessage? isoWithActualValue(int? set, int? actual) {
  if (set == null || actual == null || actual == set) return null;
  final p = shootingParamByCode[PtpDevicePropCode.movieExposureIndex]!;
  return (
    key: 'param.isoWithActual',
    args: {'v': p.display(set), 'a': p.display(actual)},
  );
}

// ---- 跨域共享的文件级私有常量/构造(原类内静态)------------------------

L10nMessage? _nikonHint(int code) {
  switch (code) {
    case NikonResponseCode.hardwareError:
      return (key: 'remote.hintHardwareError', args: null);
    case NikonResponseCode.outOfFocus:
      return (key: 'remote.hintOutOfFocus', args: null);
    case NikonResponseCode.changeCameraModeFailed:
      return (key: 'remote.hintModeSwitchFailed', args: null);
    case NikonResponseCode.cameraModeNotAdjustFnumber:
      return (key: 'remote.hintApertureLocked', args: null);
    case NikonResponseCode.invalidStatus:
      return (key: 'remote.hintInvalidStatus', args: null);
    case NikonResponseCode.notLiveView:
      return (key: 'remote.hintNotLiveView', args: null);
    case NikonResponseCode.movieFrameReleaseBusy:
      return (key: 'remote.hintRecStillBusy', args: null);
    default:
      return null;
  }
}

const _selfTimerTick = Duration(seconds: 1);

/// 0x9207 首参 CaptureSort 候选序:0xFFFFFFFF 直接释放(OpenZCine
/// preserveFocus 形态)→ 0x00000000 旧实证形(2026-10-05 Zf 真机过,
/// 2026-10-06 应用模式/接管态被 0x201D 拒)→ 0xFFFFFFFE 先 AF 后
/// 释放(OpenZCine 默认形态,兜底)。0x201D(InvalidParameter)按序
/// 换形重试,成功形缓存。
const _captureSortCandidates = <int>[0xFFFFFFFF, 0x00000000, 0xFFFFFFFE];

/// 链发上限(OpenZCine chainedBurstFrames < 30 同款,防失控)。
const int _burstFrameCap = 30;

/// 步进标定:24px 拖动 = 300 脉冲。**真机定案(2026-10-17 Zf + 24-120
/// ƒ4 S)**:300 是唯一实证可见量(MF 步进按钮单发),60 脉冲/步弱到
/// 看不见(拉焦轮「拉了没动」主因);等比标定天然带速度曲线 —— 慢拖
/// 24px/s ≈ 300 脉冲/s,快甩十倍 ≈ 3000/s(OpenZCine 2 脉冲/dp 量级
/// 偏弱,其「pulse feel per lens」本就标 verify-on-HW)。换算随机身
/// /镜头,手感出入再调。
const double _dialStepPx = 24.0;
const int _dialStepPulses = 300;

/// 失败墙钟预算:8s 窗口内 3 次失败 → 暂停滚轮(提示),窗口滑出
/// 后再拖自动恢复。失败多为链路/状态类,无脑重试只会堵命令通道。
const _dialFailureWindow = Duration(seconds: 8);
const int _dialFailureLimit = 3;

/// 拒答重试(0x9204 refused):瞬时拒答(AF 收敛/STM 镜头初始化/激活
/// 瞬时忙)是常态,退避 [_dialRetryBackoff] 静默续发;同一拒答连跑超
/// [_dialRefusalGrace] 墙钟(镜头拨杆 MF / 持续忙)才暂停出提示
/// (OpenZCine wall-clock 预算同款口径)。
const _dialRetryBackoff = Duration(milliseconds: 150);
const _dialRefusalGrace = Duration(seconds: 4);

/// DeviceReady 轮询兜底:300ms × 10(CaptureComplete 事件先到则提前)。
const _capturePollInterval = Duration(milliseconds: 300);
const int _capturePolls = 10;

/// MF 门闩的提示文案(触控对焦/AF 钮/MF 步进共用)。
const _focusModeMfHint = (key: 'remote.errMfMode', args: null);

/// 对焦链忙(0x2019)重试(0x9205 挪框 / 0x90C1 驱动共用):瞬时忙是
/// 常态 —— 在途 0x9204 滚轮驱动物理拉镜可达 2s+、AF 收敛、机身自忙,
/// 对焦操作即撞忙窗(2026-10-17 真机:旧预算 3 次×200ms 耗不尽忙窗 →
/// 假失败「对焦区域移动失败」)。按拉焦轮同款口径退避静默重试,宽限
/// 墙钟(与 [_dialRefusalGrace] 同 4s)内不报错,超宽限才如实报。
const _afBusyBackoff = Duration(milliseconds: 150);
const _afBusyGrace = Duration(seconds: 4);

/// 「同点再点」判定半径(画面归一化,约半指节):指头点按有精度,
/// 落点在上次框位容差内即视为同一处 —— 不重发 0x9205,直接驱动 AF。
const _afBoxTapRadius = 0.05;

/// A/P/S + 自动 ISO 下机身持续重算快门/光圈/ISO,而多数机身不发
/// DevicePropChanged(0x4006)—— 必须主动轮询(OpenZCine
/// CameraAutoExposureReadouts 实测口径;它轮厂商码 0xD0B5/0xD100/
/// 0x5007,值回读路由后我们同款)。只在取景运行期间跑,拍照/写参数
/// 时跳过(事务在会话串行锁上自然交错,不与取帧抢锁)。
const _aePollInterval = Duration(seconds: 2);

/// 0x4006 定向刷新的合并窗:拨杆转动连发的通知攒一波一次刷。
const _propRefreshDebounce = Duration(milliseconds: 150);

bool _isOpenShutterSentinel(int v) => v == 0xFFFFFFFF || v == 0xFFFFFFFD;

/// 核心域:全部状态字段、引擎/事件/连接沿机制、模式镜像、跨域钩子。
final class RemoteController extends ChangeNotifier
    with
        _RemoteCore,
        _RemoteLvOps,
        _RemotePropOps,
        _RemoteCaptureOps,
        _RemoteAfOps {
  RemoteController({
    required this.session,
    this.connection,
    this.transferEngine,
    LiveViewEngine? engine,
    Future<void> Function(Duration)? delay,
    Future<void> Function(Duration)? aeDelay,
    bool Function()? setPropGate,
    this.isApMode,
  })  : engine = engine ?? LiveViewEngine(session: session),
        _delay = delay ?? Future<void>.delayed,
        _aeDelay = aeDelay ?? delay ?? Future<void>.delayed,
        _setPropEnabled = setPropGate ?? _sessionSetPropGate {
    this.engine.status.addListener(_onEngineStatus);
    this.engine.health.addListener(_onEngineHealth);
    this.engine.frame.addListener(_onFrame);
    this.engine.header.addListener(_onHeader);
    _statesSub = connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _reconnecting = false;
        final wasUp = _linkUp;
        _linkUp = true;
        if (!wasUp) {
          // 新连接(状态未离开的重复 connected 沿不重置):优化校准真名
          // 缓存与旗标重建;模式写拒缓存随会话死亡 —— 新会话再试一次。
          picCtrlNames.clear();
          _picCtrlNamesFetched = false;
          _picCtrlNamesBroken = false;
          _modeWriteRejected = false;
        }
        if (session.remoteModeActive) {
          // 连接流的开闩括号(0x90C2(1)→(0),enableAppControl)正常
          // 已退 remote:接管从 OFF 起步,机身回自己的取景屏。落到本
          // 分支 = 括号的退步被拒、remote 仍持有(拨盘锁定)—— 静默
          // 对齐接管态,芯片如实显示;可随时解除。门不会因此丢(单向
          // 闩,2026-10-07 v9 定案:退 remote 不关已开的 0x9201 门)。
          _takeoverDangling = false;
          _takeoverActive = true;
          this.engine.remoteHeld = true; // 取景自愈梯不得再碰 0x90C2(会杀会话写入)
        } else if (_takeoverDangling) {
          // 上次断链时还持有 remote 模式:防御性解除(机身拨盘可能仍
          // 锁定,OpenZCine 同款「photo 模式重入先复位」口径)。
          _takeoverDangling = false;
          unawaited(_endRemoteModeQuietly());
        }
        unawaited(_onConnectedChain());
      } else if (s == CameraLinkState.reconnecting) {
        // 断链自动恢复期:按断连收口门闩(停引擎/清态,迟到的参数值/
        // 事件被挡),但**不弹页** —— 页面保留冻结帧等重连成功;横幅由
        // reconnecting getter 驱动。
        _reconnecting = true;
        _invalidate();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _reconnecting = false;
        _invalidate();
      }
    });
    _eventsSub = session.events.listen(_onEvent);
    // 监看辅助:帧分析挂引擎帧通知(禁用时零开销,开关由页面拨)。
    analyzer.attach(this.engine.frame);
  }

  static bool _sessionSetPropGate() => PtpSession.kSetPropEnabled;

  @override
  final PtpSession session;
  @override
  final CameraConnection? connection;

  /// 当前连接是否 AP 方式(装配沿接 ConnectionController.method;取景
  /// 失败引导的门槛 —— AP 人设取景门随接管开,STA 门天然开不出此引导,
  /// USB 另有因;测试注入可空 = 非 AP)。
  @override
  final bool Function()? isApMode;

  /// 便捷判定(装配缺失按非 AP)。
  @override
  bool get apMode => isApMode?.call() ?? false;
  @override
  final LiveViewEngine engine;

  /// 图库导入通道(SDRAM 直拍收尾用):生产装配 [TransferEngineImpl],
  /// null = 未接(直拍对象停在「已取回句柄」提示)。接口类型 —— 测试
  /// 注假实现。
  @override
  final TransferEngine? transferEngine;

  /// 监看辅助帧分析(直方图/斑马纹)。
  @override
  final FrameAnalyzer analyzer = FrameAnalyzer();
  @override
  final Future<void> Function(Duration) _delay;

  /// AE 轮询节拍(测试注入独立门控,与 [_delay] 分离 —— 共享门控时
  /// AE 拍与忙退避会互抢放行次序);默认与 [_delay] 同源。
  @override
  final Future<void> Function(Duration) _aeDelay;

  /// 写门禁:生产恒取 [PtpSession.kSetPropEnabled](真机实证已开,
  /// 紧急关断时这里同步收口);测试注入覆写以覆盖写路径。
  @override
  final bool Function() _setPropEnabled;

  @override
  @override
  void dispose() {
    _disposed = true;
    _actualIsoRun++; // 实际值轮询环到点自退
    _interval.stop();
    _interval.removeListener(_onIntervalChanged);
    _interval.dispose();
    _aePolling = false;
    _aeRun++;
    _reviewTimer?.cancel();
    _eventsSub?.cancel();
    _statesSub?.cancel();
    engine.status.removeListener(_onEngineStatus);
    engine.health.removeListener(_onEngineHealth);
    engine.frame.removeListener(_onFrame);
    engine.header.removeListener(_onHeader);
    frameSize.dispose();
    analyzer.dispose();
    dialNetPulses.dispose();
    super.dispose();
  }
}

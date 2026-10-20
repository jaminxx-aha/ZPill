/// 后台保活调度(2026-10-15 扩持有式申请)。
///
/// 模型:调用方按业务身份(tag)持有后台保活请求,各自声明所需的
/// 后台模式;**有效模式 = 全部持有者并集**。[BackgroundLeaseCoordinator]
/// (纯 Dart,单测覆盖)把持有表变化折算成对 native 的 reconcile 决策:
/// 无→申请 / 集变→换装 / 最后释放→stop / 不变→跳过(native 不叠加)。
/// 逻辑都在协调器,native 侧只做薄执行。
///
/// 三端语义(`nikonpill/bg` channel,方法名不变):
/// - ohos:长时任务(ContinuousTask)。`ensureRunning` 携
///   `modes: string[]`(backgroundTaskManager 的 string[] 重载,API 12+),
///   已在运行则 in-place 换装(updateBackgroundRunning);
/// - Android:前台服务(模式并集不识别,单任务模型);
/// - iOS:beginBackgroundTask 宽限窗口(同上)。
/// 三端 native 幂等、失败降级「仅前台传输」不报错给 Dart;旧端抛
/// MissingPluginException 同样静默降级。
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/services.dart';

/// ohos backgroundModes 口径的后台模式(枚举名即通道字符串)。
enum BgMode {
  /// 数据传输(下载队列非空期)。
  dataTransfer,

  /// 蓝牙交互(BLE 相机会话期)。
  bluetoothInteraction,

  /// 定位(BLE GPS 注入采样期)。
  location,
}

/// 协调器输出的 reconcile 决策(native 执行器消费)。
enum BackgroundTaskAction {
  /// 申请或换装到 [BackgroundTaskPlan.modes]。
  apply,

  /// 最后一个持有者已释放。
  stop,

  /// 持有表未变出有效集变化,不过通道。
  none,
}

final class BackgroundTaskPlan {
  const BackgroundTaskPlan(this.action, this.modes);

  const BackgroundTaskPlan.none()
      : this(BackgroundTaskAction.none, const <BgMode>{});

  final BackgroundTaskAction action;

  /// apply 时的目标模式集;其余动作恒为空集。
  final Set<BgMode> modes;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTaskPlan &&
      other.action == action &&
      setEquals(other.modes, modes);

  @override
  int get hashCode => Object.hash(action, Object.hashAllUnordered(modes));

  @override
  String toString() => 'BackgroundTaskPlan($action, $modes)';
}

/// 持有式后台保活协调器(纯 Dart,无平台依赖)。
///
/// hold/release 维护持有表(tag → 模式集),输出 [BackgroundTaskPlan]。
/// 幂等:重复 hold 同集 / 释放未持有者均不产生通道动作。
final class BackgroundLeaseCoordinator {
  final Map<String, Set<BgMode>> _holders = {};
  Set<BgMode> _applied = const <BgMode>{};
  bool _holding = false;

  /// 当前有效模式(全部持有者并集;快照拷贝)。
  Set<BgMode> get effectiveModes =>
      _holders.values.expand((m) => m).toSet();

  /// 本地视角是否有未释放的申请。
  bool get isHolding => _holding;

  /// 持有/更新一个持有者的模式集;空集等价于释放。
  BackgroundTaskPlan hold(String tag, Set<BgMode> modes) {
    if (modes.isEmpty) {
      return release(tag);
    }
    _holders[tag] = Set.of(modes);
    return _reconcile();
  }

  /// 释放一个持有者;最后一个释放沿输出 stop。
  BackgroundTaskPlan release(String tag) {
    if (_holders.remove(tag) == null) {
      return const BackgroundTaskPlan.none();
    }
    return _reconcile();
  }

  /// 回前台沿兜底:本地认为持有但系统可能已静默吊销(ohos 冻结期
  /// cancel 回调可能永远不送达)。清空「已下发」认知,之后 [reconcile]
  /// 会对仍持有的申请重新 apply —— native 端「已申请」错码按成功收场,
  /// 不会叠加任务。
  void invalidate() {
    _applied = const <BgMode>{};
    _holding = false;
  }

  /// 按当前持有表重算决策([invalidate] 后的重申入口)。
  BackgroundTaskPlan reconcile() => _reconcile();

  BackgroundTaskPlan _reconcile() {
    final want = effectiveModes;
    if (want.isEmpty) {
      if (!_holding) {
        return const BackgroundTaskPlan.none();
      }
      _holding = false;
      _applied = const <BgMode>{};
      return const BackgroundTaskPlan(
          BackgroundTaskAction.stop, <BgMode>{});
    }
    if (_holding && setEquals(want, _applied)) {
      return const BackgroundTaskPlan.none();
    }
    _holding = true;
    _applied = want;
    return BackgroundTaskPlan(BackgroundTaskAction.apply, want);
  }
}

abstract interface class BackgroundTransferScheduler {
  /// 持有式申请:tag 声明需要 [modes];有效模式 = 全部持有者并集。
  /// 并集变化沿才过通道(无→申请 / 集变→换装);重复申请幂等。
  Future<void> ensureRunning(String tag, Set<BgMode> modes);

  /// 释放一个持有者;最后一个释放沿才真正 stop(native 幂等)。
  Future<void> stop(String tag);

  /// 回前台沿兜底:弃信本地持有认知,按当前持有者重新下发申请
  /// (ohos 系统静默吊销后的重申请路;其他端幂等无害)。
  Future<void> reassert();
}

/// 经 `nikonpill/bg` channel:方法 `ensureRunning`(携 modes 数组)/
/// `stop`。协调器决策 none 时不过通道;旧 native(Android/iOS 不读
/// 参数)与未实现端(MissingPluginException)均静默降级。
final class MethodChannelBackgroundScheduler
    implements BackgroundTransferScheduler {
  static const MethodChannel channel = MethodChannel('nikonpill/bg');

  final BackgroundLeaseCoordinator coordinator =
      BackgroundLeaseCoordinator();

  @override
  Future<void> ensureRunning(String tag, Set<BgMode> modes) =>
      _execute(coordinator.hold(tag, modes));

  @override
  Future<void> stop(String tag) => _execute(coordinator.release(tag));

  @override
  Future<void> reassert() {
    coordinator.invalidate();
    return _execute(coordinator.reconcile());
  }

  Future<void> _execute(BackgroundTaskPlan plan) async {
    switch (plan.action) {
      case BackgroundTaskAction.none:
        return;
      case BackgroundTaskAction.apply:
        try {
          await channel.invokeMethod<void>('ensureRunning', <String, Object>{
            'modes': plan.modes.map((m) => m.name).toList(),
          });
        } on MissingPluginException {
          // 旧 native:仅前台传输
        }
      case BackgroundTaskAction.stop:
        try {
          await channel.invokeMethod<void>('stop');
        } on MissingPluginException {
          // 旧 native:本来就没开
        }
    }
  }
}

/// AIMD 保守自适应分块策略(纯策略类,零 IO/时钟依赖)。
///
/// 背景:GetPartialObject(0x101B)分块下载的单块大小此前是定值(iOS
/// 初版 64KB → 2026-10-09 因无线事务往返开销手工升 1MB)。定值两头不
/// 哄好:快链路(USB-IC)小块摊大每块事务开销,慢 WiFi 上大块又会撞
/// 读超时/看门狗。本类把那次手工定值自动化 —— 类 TCP AIMD:
///
/// - 起步 [minChunkBytes] = 64KB(初版分块粒度,IC 链已验证);
/// - 成功且快(单块耗时 ≤ [fastChunkThreshold])→ **加性增长**
///   +[additiveStepBytes]/次(保守档;参考仓 camera-bridge 的
///   AdaptiveChunkController 是连成 2 次翻倍 + 1-8MB 激进档 —— 无
///   LICENSE 只借思路,激进档无真机 A/B 不做);
/// - 成功但慢(> 阈值)→ 不动(链路在喘,别加压);
/// - 超时/传输错误 → **乘性减半**,下限 [minChunkBytes] 不降穿;
/// - 封顶 ≤ [hardMaxChunkBytes] = 1MB(0x101B 单块上限,勿越);
/// - **取消不惩罚**:用户取消 ≠ 链路差 —— 协议上就没有 report 取消
///   的方法,调用方对取消路径不喂任何信号,块大小原样带入下次传输。
///
/// 零时钟依赖:耗时由调用方测量后传入([reportSuccess] 的 [Duration]),
/// 本类不碰 Stopwatch/DateTime —— 单测无需 fake 时钟,直接喂时长。
///
/// 生命周期:每传输会话一个实例(下载器级,随下载器生灭;不跨会话共享
/// —— 无静态/全局状态,新会话从 64KB 重新学起)。会话内要交接状态用
/// [snapshot]/[restore](可序列化,不持久化)。
///
/// 全部常量集中在此留账,真机 A/B 标定后再调。
library;

import 'dart:math' as math;

/// 策略快照:会话内序列化传递(如下载器中途重建续用),不持久化。
final class AimdChunkSnapshot {
  const AimdChunkSnapshot(this.currentBytes);

  final int currentBytes;

  Map<String, Object?> toJson() => {'currentBytes': currentBytes};

  factory AimdChunkSnapshot.fromJson(Map<String, Object?> json) =>
      AimdChunkSnapshot(json['currentBytes'] as int);

  @override
  bool operator ==(Object other) =>
      other is AimdChunkSnapshot && other.currentBytes == currentBytes;

  @override
  int get hashCode => currentBytes;

  @override
  String toString() => 'AimdChunkSnapshot(${currentBytes}B)';
}

/// GetPartialObject 单块大小的 AIMD 演化策略(见库注释的口径全图)。
final class AimdChunkPolicy {
  /// 保守档定值:起步 = 下限(64KB)。
  static const int minChunkBytes = 64 * 1024;

  /// 0x101B 单块上限(勿越):默认封顶,显式更大的 [maxBytes] 也被钳回。
  static const int hardMaxChunkBytes = 1024 * 1024;

  /// 加性增长步长(+32KB/次)。
  static const int additiveStepBytes = 32 * 1024;

  /// 「成功快」判定阈值:单块耗时 ≤ 400ms 算快(留账真机标定)。
  static const Duration fastChunkThreshold = Duration(milliseconds: 400);

  /// 全参可注入(测试用小数值小周期;生产走默认定值)。
  ///
  /// 界内钳制规则:
  /// - [maxBytes] 上限 [hardMaxChunkBytes](显式传更大也钳回,协议上限);
  /// - [minBytes] 高于上界时随上界收缩(退化但自洽 —— 定值小粒度
  ///   分块的小于 64KB 上界照样工作,块大小恒等于上界);
  /// - [initialBytes](缺省 = 下限)钳入 [下限, 上界]。
  factory AimdChunkPolicy({
    int? minBytes,
    int? maxBytes,
    int? initialBytes,
    int? stepBytes,
    Duration? fastThreshold,
  }) {
    final max = math.min(maxBytes ?? hardMaxChunkBytes, hardMaxChunkBytes);
    final min = math.min(minBytes ?? minChunkBytes, max);
    final step = stepBytes ?? additiveStepBytes;
    final threshold = fastThreshold ?? fastChunkThreshold;
    final initial = _clamp(initialBytes ?? min, min, max);
    return AimdChunkPolicy._(
        min: min, max: max, step: step, threshold: threshold, current: initial);
  }

  AimdChunkPolicy._({
    required int min,
    required int max,
    required int step,
    required Duration threshold,
    required int current,
  })  : _min = min,
        _max = max,
        _step = step,
        _fastThreshold = threshold,
        _current = current;

  final int _min;
  final int _max;
  final int _step;
  final Duration _fastThreshold;
  int _current;

  /// 当前单块大小(下一块请求的 maxBytes)。
  int get currentBytes => _current;

  int get minBytes => _min;
  int get maxBytes => _max;
  int get stepBytes => _step;
  Duration get fastThreshold => _fastThreshold;

  /// 一块成功:[elapsed] = 该块全程耗时(调用方测量)。
  /// ≤ 阈值 → 加性 +step(封顶);> 阈值 → 不动(成功但慢,链路在喘)。
  void reportSuccess(Duration elapsed) {
    if (elapsed > _fastThreshold) return;
    _current = math.min(_current + _step, _max);
  }

  /// 一块超时(USB 单事务读超时等):乘性减半,下限不降穿。
  void reportTimeout() => _decrease();

  /// 一块传输错误(相机拒绝应答 / PTP-IP 断链等):乘性减半,下限不降穿。
  void reportError() => _decrease();

  /// (取消没有对应方法 —— 刻意的:取消不惩罚,见库注释。)
  void _decrease() {
    _current = math.max(_current ~/ 2, _min);
  }

  /// 当前状态快照(会话内序列化传递,见 [AimdChunkSnapshot])。
  AimdChunkSnapshot get snapshot => AimdChunkSnapshot(_current);

  /// 从快照恢复:钳回本实例的 [下限, 上界](防御旧快照越界)。
  void restore(AimdChunkSnapshot snapshot) {
    _current = _clamp(snapshot.currentBytes, _min, _max);
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
}

/// 速度与剩余时间估算:按字节增量真实计算(TODO.md §四 P2)。
///
/// 滑动窗口内(最近 [window])的 (时间, 累计字节) 样本做差;
/// 禁止用 totalBytes/elapsed 的全量平均 —— 起步阶段严重失真。
library;

import 'dart:collection';

final class SpeedEstimator {
  SpeedEstimator({this.window = const Duration(seconds: 8)});

  final Duration window;
  final Queue<(DateTime, int)> _samples = Queue(); // (时间点, 该时刻累计字节)
  int _total = 0;

  /// 收到新数据块时调用;[cumulativeBytes] 为该任务累计已收字节。
  void add(DateTime at, int cumulativeBytes) {
    _samples.addLast((at, cumulativeBytes));
    _total = cumulativeBytes;
    _evict(at);
  }

  /// 窗口内平均速度(bytes/s);样本不足(首块未到)返回 null。
  double? bytesPerSecond({DateTime? now}) {
    final at = now ?? DateTime.now();
    _evict(at);
    if (_samples.length < 2) return null;
    final (t0, b0) = _samples.first;
    final (t1, b1) = _samples.last;
    final seconds = t1.difference(t0).inMicroseconds / 1e6;
    if (seconds <= 0) return null;
    return (b1 - b0) / seconds;
  }

  /// 剩余时间;速度未知或已传完返回 null。
  Duration? etaFor(int remainingBytes, {DateTime? now}) {
    if (remainingBytes <= 0) return null;
    final bps = bytesPerSecond(now: now);
    if (bps == null || bps <= 0) return null;
    return Duration(microseconds: (remainingBytes / bps * 1e6).round());
  }

  void _evict(DateTime now) {
    final cutoff = now.subtract(window);
    while (_samples.length > 2 && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeFirst();
    }
  }

  /// 任务切换时重置。
  void reset() {
    _samples.clear();
    _total = 0;
  }

  int get totalSeen => _total;
}

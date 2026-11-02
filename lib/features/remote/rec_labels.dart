/// 拍摄页/连接页共用的时间标签(纯函数,无 Flutter 依赖)。
///
/// 原先与已废弃的 RemoteInfoPill 组件同文件 —— 组件删掉后只留这两个
/// 标签,单列成文件免「为一个纯函数引整棵 widget 树」。
library;

/// 录制时长标签(m:ss;展示就近取值,事件/交互驱动刷新)。REC 前缀在
/// 胶囊里经 remote.recPrefix 键化(zh/en 同值「REC」:录制指示通用
/// 记号,键化为闸门完整与未来可调);拍摄页唯一直接消费方
/// (2026-10-10 录制钮并入快门后)。
String recDurationLabel(int? seconds) {
  final s = seconds ?? 0;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// 剩余可录时长标签(帧头 @816 毫秒 → h:mm:ss / m:ss;官方上限
/// 7500000ms ≈ 2 小时,超小时补位避免 125:00 式怪读)。公开给连接页
/// 存储卡脚注复用(2026-10-17 视频档「可录」同源同口径)。
String recRemainingLabel(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
}

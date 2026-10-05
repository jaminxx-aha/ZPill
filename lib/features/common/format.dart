/// 展示格式化(文件大小 / 日期),浏览/预览/下载各页共用。
library;

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '${bytes}B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 本地时区 'yyyy-MM-dd HH:mm';null 原样返回 null。
String? formatDateTime(DateTime? d) {
  if (d == null) {
    return null;
  }
  final local = d.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

/// 'MM-dd'–'MM-dd'(同一天只显示一个);无时间信息返回 null。
String? formatDateRange(DateTime? newest, DateTime? oldest) {
  if (newest == null || oldest == null) {
    return null;
  }
  final a = newest.toLocal();
  final b = oldest.toLocal();
  final one = '${_two(a.month)}-${_two(a.day)}';
  if (a.year == b.year && a.month == b.month && a.day == b.day) {
    return one;
  }
  return '$one – ${_two(b.month)}-${_two(b.day)}';
}

const List<String> _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 本地日期分段头(相册网格按日分段):'今天' / '昨天' /
/// '10月2日 周五' / 跨年补年份 '2025年12月30日 周二'。
String sectionDateLabel(DateTime d) {
  final local = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  if (diffDays == 0 && today.day == local.day) return '今天';
  if (diffDays == 1) return '昨天';
  final year = local.year == now.year ? '' : '${local.year}年';
  return '$year${local.month}月${local.day}日 ${_weekdays[local.weekday - 1]}';
}

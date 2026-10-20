/// 展示格式化(文件大小 / 日期),浏览/预览/下载各页共用。
library;

import '../../l10n/message.dart';

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

/// 本地日期分段头(相册网格按日分段,键+参记录,显示点 tm() 落地):
/// 'date.today' / 'date.yesterday' / 同年 'date.day'{m,d,w} /
/// 跨年 'date.dayYear'{y,m,d,w}(w = 'date.weekdayN' 嵌套记录,tMsg
/// 递归解析)。
L10nMessage sectionDateLabel(DateTime d) {
  final local = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  if (diffDays == 0 && today.day == local.day) {
    return (key: 'date.today', args: null);
  }
  if (diffDays == 1) return (key: 'date.yesterday', args: null);
  final L10nMessage w = (key: 'date.weekday${local.weekday}', args: null);
  if (local.year == now.year) {
    return (
      key: 'date.day',
      args: {'m': local.month, 'd': local.day, 'w': w},
    );
  }
  return (
    key: 'date.dayYear',
    args: {'y': local.year, 'm': local.month, 'd': local.day, 'w': w},
  );
}

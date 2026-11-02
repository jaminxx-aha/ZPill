/// JSON 持久化的统一落盘出口:同目录写临时档 → 原子 rename。
///
/// 旧各处直接 `file.writeAsString` 覆盖原档:写到一半进程崩溃/被杀 →
/// 盘上是半截 JSON,下次冷启只能按默认值重建(设置/评级/配对档案全丢,
/// 且**静默** —— `FormatException` 被 catch 成默认值)。tmp + rename 在
/// 同目录同文件系统内是原子的,读侧永远看到「旧档」或「新档」。
///
/// 只服务于 data/ 层的 JSON 档;二进制媒体落盘不走这里。
library;

import 'dart:io';

/// 原子写 [file](UTF-8 文本)。
///
/// - `flush: true` 是刻意的:用户数据(设置/配对/评级)值得一次 fsync;
/// - 临时档固定 `<path>.tmp`:崩溃残留的 tmp 下次写会被覆盖,读侧只用
///   正式档,不会读到半截内容;
/// - rename 失败(跨设备等异常场景)时 tmp 留在原地,由调用方按原有
///   `on Object` 兜底(本函数不吞异常)。
Future<void> writeJsonAtomic(File file, String contents) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(file.path);
}

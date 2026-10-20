/// 统一日志入口(纯 Dart:零 Flutter 依赖、零 IO —— 落盘与控制台镜像
/// 均经 [configure] 由装配层注入,core 不感知平台)。
///
/// 三条设计主线:
/// 1. **内存环形缓冲**:固定容量(默认 5000 条)先进先出滚动,常态零
///    IO;导出/查看走 [dump],app 一崩最多丢环形窗外最老的记录,新近
///    日志(含 error 尾巴文件)保得住。
/// 2. **error 级双写**:[errorTail] 回调由装配层接小文件即时追加,崩溃
///    前最后几条 error 不随进程消失;其余级别只进内存。
/// 3. **verbose 闸门**:协议字节转储等高频大体积输出经 [isVerbose] 门,
///    默认全关(release/debug 一致),临时排查再开 —— 不闸会把环形窗
///    冲成单一种类的流水。
///
/// 分域走 String(原生日志 tag 透传,枚举会封死扩展);已知域常量见
/// [protocol] 等。所有调用点零成本:未 configure 时亦安全(仅进内存)。
library;

/// 日志级别(符号 D/I/W/E 见 [AppLogEntry.line])。
enum AppLogLevel { debug, info, warn, error }

/// 一条日志记录。
final class AppLogEntry {
  AppLogEntry({
    required this.time,
    required this.level,
    required this.domain,
    required this.message,
  });

  final DateTime time;
  final AppLogLevel level;
  final String domain;
  final String message;

  /// 单行格式:`14:23:45.678 [E/protocol] 发送失败(tid=3)`。
  String get line {
    final l = level.index;
    final sym = const ['D', 'I', 'W', 'E'][l];
    return '${_two(time.hour)}:${_two(time.minute)}:'
        '${_two(time.second)}.${_three(time.millisecond)} '
        '[$sym/$domain] $message';
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
String _three(int v) => v.toString().padLeft(3, '0');

/// 统一日志门面。
///
/// ```dart
/// AppLog.i(AppLog.protocol, '→ GetDeviceInfo tid=0');
/// if (AppLog.isVerbose(AppLog.protocol)) {
///   AppLog.d(AppLog.protocol, '字节 ${AppLog.hex(bytes)}');
/// }
/// ```
final class AppLog {
  AppLog._();

  // ---- 已知域(原生日志 tag 可透传任意字符串,不限于这些) ----
  static const protocol = 'protocol'; // PTP/IP 收发沿
  static const connection = 'connection'; // 连接状态机/发现
  static const usb = 'usb'; // USB 链路(含原生命道)
  static const ble = 'ble'; // BLE 会话/GPS 注入
  static const browser = 'browser'; // 对象仓库/缩略图
  static const transfer = 'transfer'; // 下载/速传队列
  static const native = 'native'; // 三端原生日志合流
  static const live = 'live'; // 取景/监看链(帧尺寸/画质档/变换取证)

  static const int defaultCapacity = 5000;

  // ---- 装配层注入(core 零 IO 的边界) ----
  /// 每条日志的镜像出口(装配层接 debugPrint/hilog;接不接、按什么
  /// 构建 gating 由注入方决定 —— core 不感知 debug/release)。
  static void Function(String line)? mirror;

  /// error 级即时落盘出口(装配层接崩溃尾巴文件;缓冲行、目录解析
  /// 等时序问题都归注入方,这里只保证「每条 error 恰好回调一次」)。
  static void Function(String line)? errorTail;

  static List<AppLogEntry?> _buf = List.filled(defaultCapacity, null);
  static int _head = 0; // 下一写入位
  static int _count = 0;

  static final Set<String> _verbose = {};

  /// 装配点:容量与出口一次定齐(可重复调用,重置缓冲)。
  static void configure({
    int capacity = defaultCapacity,
    void Function(String line)? mirror,
    void Function(String line)? errorTail,
  }) {
    AppLog.mirror = mirror;
    AppLog.errorTail = errorTail;
    _buf = List.filled(capacity < 1 ? 1 : capacity, null);
    _head = 0;
    _count = 0;
  }

  // ---- 记录入口 ----
  static void log(AppLogLevel level, String domain, String message) {
    final entry = AppLogEntry(
      time: DateTime.now(),
      level: level,
      domain: domain,
      message: message,
    );
    _buf[_head] = entry;
    _head = (_head + 1) % _buf.length;
    if (_count < _buf.length) _count++;
    final line = entry.line;
    if (mirror != null) mirror!(line);
    if (level == AppLogLevel.error && errorTail != null) errorTail!(line);
  }

  static void d(String domain, String message) =>
      log(AppLogLevel.debug, domain, message);
  static void i(String domain, String message) =>
      log(AppLogLevel.info, domain, message);
  static void w(String domain, String message) =>
      log(AppLogLevel.warn, domain, message);
  static void e(String domain, String message) =>
      log(AppLogLevel.error, domain, message);

  // ---- verbose 闸门 ----
  static bool isVerbose(String domain) => _verbose.contains(domain);

  static void setVerbose(String domain, {bool on = true}) {
    if (on) {
      _verbose.add(domain);
    } else {
      _verbose.remove(domain);
    }
  }

  // ---- 读取 / 导出 ----
  /// 时间序快照(最老在前)。
  static List<AppLogEntry> get entries => [
        for (var i = 0; i < _count; i++)
          _buf[(_head - _count + i) % _buf.length]!,
      ];

  /// 文本导出(minLevel 之下的级别、指定域之外的记录都滤掉)。
  static String dump({AppLogLevel? minLevel, String? domain}) {
    final b = StringBuffer();
    for (final e in entries) {
      if (minLevel != null && e.level.index < minLevel.index) continue;
      if (domain != null && e.domain != domain) continue;
      b.writeln(e.line);
    }
    return b.toString();
  }

  /// 字节转储辅助:小端十六进制(与 ptp_diagnostics 口径一致,大写)。
  ///
  /// [max] 截断尾部;[sensitive] 凭据/密钥类:≤16B 整体打码,更长只露
  /// 前后 8B(加密 blob 的方言对拍仍可比头尾),中段一律 `…(脱敏 nB)`。
  static String hex(List<int> bytes, {int max = 32, bool sensitive = false}) {
    if (bytes.isEmpty) return '(空)';
    if (sensitive) {
      if (bytes.length <= 16) return '<脱敏 ${bytes.length}B>';
      return '${_row(bytes.sublist(0, 8))} '
          '…(脱敏 ${bytes.length - 16}B) '
          '${_row(bytes.sublist(bytes.length - 8))}';
    }
    final take = bytes.length < max ? bytes.length : max;
    final row = _row(bytes.sublist(0, take));
    return bytes.length > take ? '$row …+${bytes.length - take}B' : row;
  }

  static String _row(List<int> bytes) => [
        for (final b in bytes) b.toRadixString(16).padLeft(2, '0').toUpperCase(),
      ].join(' ');

  /// 测试隔离:全量还原到未装配态(静态单例,测试间必须先调这个)。
  static void resetForTest() {
    _buf = List.filled(defaultCapacity, null);
    _head = 0;
    _count = 0;
    _verbose.clear();
    mirror = null;
    errorTail = null;
  }
}

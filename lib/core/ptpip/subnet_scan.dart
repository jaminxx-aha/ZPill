/// /24 网段扫描(STA 发现兜底):mDNS 无结果时,对本机各 IPv4 接口
/// 所在 /24 做端口检查(15740 开放者收集)+ InitCommandRequest 轻探测。
///
/// 形态(并行端口扫描思路借 nikon-image-transmission 的
/// NikonCameraPlugin(/24 候选 + 24 线程池 + 每连接短超时),轻探测
/// 思路借 nikon-snaplink;协议字节与安全阀全按本仓):
/// 1. 候选生成([subnetCandidates],纯函数):每个本机 IPv4 地址展开
///    同 /24 的主机位 1..254,去网络位(.0)/广播位(.255)/本机自身,
///    跨接口去重;
/// 2. 端口检查:并发池(默认 [SubnetCameraScanner.concurrency] = 24)
///    逐个 TCP connect(默认 800ms 超时),开放者收集 —— 只 connect 即
///    关,**不发任何字节**;
/// 3. 轻探测:开放者**串行**逐个 [probeCamera](InitCommandRequest →
///    InitCommandResponse/InitFail → 关 socket),应答者入榜。
///
/// **真机教训硬约束**(详见 probe.dart 库注;tools/ptpip_probe 实证):
/// 相机对静默 TCP 连接会「呛住」一段时间不接新 SYN —— 阶段 2 对相机
/// 主机的裸 connect 可能吃掉紧随的探测窗口(探测 connect 被拒 →
/// null,不重试)。下一轮(用户手动再扫)自然恢复;真机标定见
/// TODO 留账(探测后紧跟真连接是否被 InitFail 0x1 拒、全网段一轮
/// 耗时)。因此:探测阶段严格串行(同一主机绝不双探测),失败主机
/// 绝不重试;扫描入口的重入/活跃会话门在 ConnectionController。
library;

import 'dart:io';
import 'dart:typed_data';

import 'probe.dart';
import 'transport.dart';

/// 端口检查注入:对 `host:port` 发起一次 TCP connect(预算 [timeout]),
/// true = 开放。生产默认 [tcpPortOpen](真 socket);测试注入记账 fake。
typedef TcpConnectCheck =
    Future<bool> Function(String host, int port, Duration timeout);

/// 生产端口检查:真 socket connect,成败即返回;即开即关(destroy,
/// 不做优雅 FIN 握手,把半开窗口压到最短)。
Future<bool> tcpPortOpen(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on Object {
    // 连不上(拒绝/超时/无路由):该主机 15740 不开放
    return false;
  }
}

/// /24 候选生成(纯函数):输入本机 IPv4 接口地址(点分),输出各
/// 所在 /24 的其余可用主机位。
///
/// 边界:非法/非点分四段跳过;回环(127/8)与链路本地(169.254/16)
/// 跳过(不在其上找相机);网络位(.0)/广播位(.255)不生成(循环域
/// 1..254 天然排除);**全部**本机地址统一剔除(同 /24 双接口时,任一
/// 接口的本机位都不入候选);跨接口同 /24 去重(保插入序)。
List<String> subnetCandidates(Iterable<String> interfaceIps) {
  final own = <String>{};
  final prefixes = <String>[];
  for (final raw in interfaceIps) {
    final ip = raw.trim();
    if (ip.isEmpty) continue;
    final parts = ip.split('.');
    if (parts.length != 4) continue; // IPv6 等:无 /24 可言
    final octets = <int>[];
    var ok = true;
    for (final part in parts) {
      final v = int.tryParse(part);
      if (v == null || v < 0 || v > 255) {
        ok = false;
        break;
      }
      octets.add(v);
    }
    if (!ok) continue;
    if (octets[0] == 127) continue; // 回环
    if (octets[0] == 169 && octets[1] == 254) continue; // 链路本地
    own.add(ip);
    prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
  }
  final out = <String>{};
  for (final prefix in prefixes) {
    for (var last = 1; last <= 254; last++) {
      final candidate = '$prefix.$last';
      if (own.contains(candidate)) continue; // 任一接口的本机位
      out.add(candidate);
    }
  }
  return out.toList(growable: false);
}

/// /24 网段扫描器(一次性:每轮 [scan] 新结果,实例可复用)。
///
/// 全部 IO 经构造注入(端口检查/探测/接口地址),单测零真 socket;
/// 生产默认 = 真 socket + [probeCamera]。接口地址取用 glue 在
/// platform/interface_addresses.dart(core 不反向依赖 platform,故
/// [interfaceIps] 为必填 —— 构造点显式选真取用或测试 fake)。
final class SubnetCameraScanner {
  SubnetCameraScanner({
    required Future<List<String>> Function() interfaceIps,
    this.port = kPtpIpPort,
    this.connectTimeout = const Duration(milliseconds: 800),
    this.responseTimeout = const Duration(milliseconds: 1200),
    this.concurrency = 24,
    TcpConnectCheck? connectCheck,
    Future<ProbedCamera?> Function(String host)? probe,
    this.clientGuid,
    this.hostname = 'Android Device',
  })  : _interfaceIps = interfaceIps,
        _connectCheck = connectCheck ?? tcpPortOpen,
        _probe = probe;

  /// 相机 PTP-IP 服务端口。
  final int port;

  /// 端口检查的单连接预算(死主机占满即弃,24 并发 × ~10 批 ≈ 全网段
  /// 一轮最坏 ~8s)。
  final Duration connectTimeout;

  /// 轻探测的响应窗(透传 [probeCamera];含 connect 共 ≤ 2s)。
  final Duration responseTimeout;

  /// 并发池上限(nikon-image-transmission 同款 24;Dart async 足够,
  /// 不上 isolate)。
  final int concurrency;

  /// 端口检查(注入)。
  final TcpConnectCheck _connectCheck;

  /// 轻探测(注入;null = [probeCamera] 真方言探测)。
  final Future<ProbedCamera?> Function(String host)? _probe;

  /// 本机接口地址取用(必填注入:生产 = platform/interface_addresses
  /// 的 glue;测试 = fake)。
  final Future<List<String>> Function() _interfaceIps;

  /// InitCommandRequest 的客户端身份(沿用既有连接流,见 probe.dart)。
  final Uint8List? clientGuid;
  final String hostname;

  /// 扫一轮:候选 → 并发端口检查 → 开放者串行轻探测。
  ///
  /// 任一 IO 失败都被注入件吞成「该主机不开放/无相机」,本方法不抛
  /// (接口地址取用 glue 同样吞错:取不到 = 无候选 = 空结果)。
  Future<List<ProbedCamera>> scan() async {
    final ips = await _interfaceIps();
    final candidates = subnetCandidates(ips);
    if (candidates.isEmpty) return const [];

    // 阶段 1:并发端口检查(池上限 = concurrency;取号在同步段完成,
    // Dart 单线程事件模型下无竞态)。
    final open = <String>[];
    var next = 0;
    final workerCount =
        candidates.length < concurrency ? candidates.length : concurrency;
    await Future.wait(List.generate(workerCount, (_) async {
      for (;;) {
        final i = next++;
        if (i >= candidates.length) return;
        final host = candidates[i];
        if (await _connectCheck(host, port, connectTimeout)) {
          open.add(host);
        }
      }
    }));

    // 阶段 2:开放者串行轻探测 —— 同一主机绝不并发双探测(硬约束③),
    // 失败(null)不重试(硬约束②)。按末段数值排序保证探测次序确定。
    open.sort((a, b) {
      final la = int.parse(a.split('.').last);
      final lb = int.parse(b.split('.').last);
      return la.compareTo(lb);
    });
    final found = <ProbedCamera>[];
    for (final host in open) {
      final result = await (_probe?.call(host) ??
          probeCamera(
            host,
            port: port,
            connectTimeout: connectTimeout,
            responseTimeout: responseTimeout,
            clientGuid: clientGuid,
            hostname: hostname,
          ));
      if (result != null) found.add(result);
    }
    return found;
  }
}

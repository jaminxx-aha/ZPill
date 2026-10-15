/// PTP-IP 轻探测器:InitCommandRequest 单包问路,读 InitCommandResponse
/// 得相机名 + 相机 GUID 即收线(mDNS 无结果时 /24 网段扫描的第二阶段,
/// 思路借 nikon-snaplink probeHost;协议字节全按本仓尼康方言)。
///
/// **真机教训硬约束(Zf 单连接服务器,违反即可能占槽/呛住相机):**
/// ① 探测 socket 即开即关:连 15740 → 发 InitCommandRequest → 读
///    InitCommandResponse(或 InitFail)→ 立即关。**绝不走 13 步方言的
///    任何后续包**(InitEventRequest 也不发)—— 未完成方言的连接可能
///    占配对槽,相机一次只认一个会话(InitFail 0x1,2026-10-04 真机)。
/// ② 失败不重试同一主机:连不上/超时/断链 = 该主机无相机(或已被
///    呛住),下一轮由用户手动再扫。tools/ptpip_probe 实证:静默连接
///    被相机保持(等 Init),本端关闭后相机「呛住」一段时间不接新 SYN
///    —— 勿发探测性连接,失败重试要有间隔。
/// ③ 绝不并发对同一主机双探测:本函数无内部重试;并发约束由调用方
///    (SubnetCameraScanner 串行探测 + ConnectionController 重入门)保证。
/// ④ 只有 mDNS 结果为空、且会话不活跃(未连接/未在连接)时才允许
///    触发扫描 —— 门在 ConnectionController.scanSubnet(见
///    features/connection/connection_page.dart)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'channels.dart';
import 'codec.dart';
import 'packet.dart';
import 'transport.dart';

/// 探测命中:InitCommandResponse 原文节选(相机名 + 16B 相机 GUID)。
final class ProbedCamera {
  const ProbedCamera({
    required this.host,
    required this.name,
    required this.cameraGuid,
    this.initFailReason,
  });

  /// 被探测主机(点分 IPv4)。
  final String host;

  /// 相机名(InitCommandResponse 原文,如「NIKON Z f」);被拒(InitFail)
  /// 时为空串 —— UI 以 IP 兜底展示。
  final String name;

  /// 相机 GUID(16B;InitFail 时为空表)。
  final Uint8List cameraGuid;

  /// 非空 = 相机在 15740 应答了 InitFail(相机在此,但拒绝了 Init;
  /// reason=0x1 = 单连接槽位被占,2026-10-04 真机)。相机是真实的,
  /// 照样入扫描结果榜,点选连接走真方言,占用指引由连接层给出。
  final int? initFailReason;

  /// 相机明确拒绝过探测(InitFail)。
  bool get rejected => initFailReason != null;
}

/// 轻探测一个主机:新 socket 连 [port] → 发 InitCommandRequest(尼康
/// 方言:GUID + UTF-16LE 主机名,布局见 codec.dart)→ 等
/// InitCommandResponse / InitFail → 关 socket。
///
/// 返回 null = 无相机/超时/连不上/断链(不区分,调用方一律跳过;
/// **绝不重试**,硬约束②)。返回 [ProbedCamera] = 相机应答(含被拒
/// InitFail 形态,见类注)。
///
/// [createChannel] 注入测试 fake;生产默认 [TcpPtpIpChannel](connect
/// 超时 [connectTimeout])。[clientGuid]/[hostname] 沿用既有连接流的
/// 身份(相机按 GUID 识别客户端;探测与真连接用同一 GUID,相机眼里
/// 是同一客户端重连,比陌生 GUID 的半开会话更安全)。
Future<ProbedCamera?> probeCamera(
  String host, {
  int port = kPtpIpPort,
  Duration connectTimeout = const Duration(milliseconds: 800),
  Duration responseTimeout = const Duration(milliseconds: 1200),
  PtpIpChannel Function()? createChannel,
  Uint8List? clientGuid,
  String hostname = 'Android Device',
}) async {
  final channel =
      createChannel?.call() ?? TcpPtpIpChannel(connectTimeout: connectTimeout);
  final codec = PtpIpCodecImpl();
  StreamSubscription<PtpIpFrame>? sub;
  try {
    await channel.connect(host, port);
    // 先挂订阅再发,无收包竞态(同 PtpIpTransport.connect 手法)。
    final response = Completer<PtpIpFrame>();
    sub = channel.frames.listen(
      (frame) {
        if (!response.isCompleted) response.complete(frame);
      },
      onError: (Object e) {
        if (!response.isCompleted) response.completeError(e);
      },
      onDone: () {
        if (!response.isCompleted) {
          response.completeError(
              const PtpLinkException('探测通道在响应前被关闭'));
        }
      },
    );
    final bytes = codec.encode(InitCommandRequestPacket(
      guid: clientGuid ?? Uint8List.fromList(kNikonAndroidGuid),
      hostname: hostname,
    ));
    // 探测只发这一个包,后续方言一个字节都不发(硬约束①)。
    await channel.sendFrame(PtpIpFrame(
      type: PtpIpPacketType.initCommandRequest,
      body: Uint8List.sublistView(bytes, kPtpIpHeaderLength),
    ));
    final frame = await response.future.timeout(responseTimeout);
    final packet = codec.decode(frame);
    return switch (packet) {
      InitCommandResponsePacket p => ProbedCamera(
          host: host,
          name: p.cameraName,
          cameraGuid: p.cameraGuid,
        ),
      InitFailPacket p => ProbedCamera(
          host: host,
          name: '',
          cameraGuid: Uint8List(0),
          initFailReason: p.reason,
        ),
      _ => null, // 应答不是 Init 系:方言不符,不算相机
    };
  } on Object {
    // SocketException(连不上)/ TimeoutException(超时)/ 断链 / 解析
    // 失败:一律 null,不重试(硬约束②)。
    return null;
  } finally {
    // 即开即关:无论成败,探测 socket 都在本函数内收口(硬约束①)。
    await sub?.cancel();
    await channel.close();
  }
}

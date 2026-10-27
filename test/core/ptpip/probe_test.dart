import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptpip/channels.dart';
import 'package:z_pill/core/ptpip/codec.dart';
import 'package:z_pill/core/ptpip/packet.dart';
import 'package:z_pill/core/ptpip/probe.dart';

/// 探测用假通道(仿 transport_test 的 FakePtpIpChannel):记录已发帧
/// 与关闭态,emit* 模拟相机。
final class FakeProbeChannel implements PtpIpChannel {
  final sent = <PtpIpFrame>[];
  final _frames = StreamController<PtpIpFrame>();
  String? host;
  int? port;
  bool connected = false;
  bool closed = false;

  @override
  bool get isOpen => connected && !closed;

  @override
  Stream<PtpIpFrame> get frames => _frames.stream;

  @override
  Future<void> connect(String host, int port) async {
    this.host = host;
    this.port = port;
    connected = true;
  }

  @override
  Future<void> sendFrame(PtpIpFrame frame) async {
    sent.add(frame);
  }

  @override
  Future<void> close() async {
    closed = true;
    unawaited(_frames.close());
  }

  void emit(PtpIpFrame frame) => _frames.add(frame);
  void emitClosed() => unawaited(_frames.close());
}

void main() {
  final codec = PtpIpCodecImpl();

  PtpIpFrame frameOf(PtpIpPacket packet) {
    final bytes = codec.encode(packet);
    return PtpIpFrame(
        type: packet.type,
        body: Uint8List.sublistView(bytes, kPtpIpHeaderLength));
  }

  Future<ProbedCamera?> probe(
    FakeProbeChannel channel, {
    Uint8List? clientGuid,
    String hostname = 'Android Device',
    Duration responseTimeout = const Duration(milliseconds: 300),
  }) {
    return probeCamera(
      '192.168.0.104',
      createChannel: () => channel,
      clientGuid: clientGuid,
      hostname: hostname,
      responseTimeout: responseTimeout,
    );
  }

  test('正常:InitCommandResponse 解析出相机名 + GUID,socket 即开即关', () async {
    final channel = FakeProbeChannel();
    final guid = Uint8List.fromList(List.generate(16, (i) => i));
    final probing = probe(channel);
    await pumpEventQueue();
    // 只发一个 InitCommandRequest(尼康方言:GUID + UTF-16LE 主机名,
    // 无长度前缀),绝无后续方言包。
    expect(channel.sent, hasLength(1));
    final sentPacket =
        codec.decode(channel.sent.single) as InitCommandRequestPacket;
    expect(sentPacket.guid, Uint8List.fromList(kNikonAndroidGuid));
    expect(sentPacket.hostname, 'Android Device');
    expect(channel.host, '192.168.0.104');
    expect(channel.port, 15740);

    channel.emit(frameOf(InitCommandResponsePacket(
      connectionNumber: 0xC0DE,
      cameraGuid: guid,
      cameraName: 'NIKON Z f',
      protocolVersion: kPtpIpProtocolVersion,
    )));
    final result = await probing;
    expect(result, isNotNull);
    expect(result!.host, '192.168.0.104');
    expect(result.name, 'NIKON Z f');
    expect(result.cameraGuid, guid);
    expect(result.rejected, isFalse);
    // 干净关 socket(硬约束①:即开即关)
    expect(channel.closed, isTrue);
    // 应答已收,不再多发一个包
    expect(channel.sent, hasLength(1));
  });

  test('InitFail:相机在但被拒(reason 透传,name 空)—— 照样入榜', () async {
    final channel = FakeProbeChannel();
    final probing = probe(channel);
    await pumpEventQueue();
    channel.emit(frameOf(const InitFailPacket(reason: 0x00000001)));
    final result = await probing;
    expect(result, isNotNull);
    expect(result!.rejected, isTrue);
    expect(result.initFailReason, 0x00000001);
    expect(result.name, isEmpty);
    expect(result.cameraGuid, isEmpty);
    expect(channel.closed, isTrue);
  });

  test('超时:相机不答 → null,不发第二包,socket 关', () async {
    final channel = FakeProbeChannel();
    final result = await probe(channel,
        responseTimeout: const Duration(milliseconds: 30));
    expect(result, isNull);
    expect(channel.sent, hasLength(1), reason: '超时绝不重试(硬约束②)');
    expect(channel.closed, isTrue);
  });

  test('连接失败:connect 即抛 → null,socket 仍关', () async {
    final channel = _FailingConnectChannel();
    final result = await probeCamera('192.168.0.104',
        createChannel: () => channel,
        responseTimeout: const Duration(milliseconds: 50));
    expect(result, isNull);
    expect(channel.closed, isTrue);
  });

  test('通道在应答前被关闭 → null(呛住形态),不重试', () async {
    final channel = FakeProbeChannel();
    final probing = probe(channel);
    await pumpEventQueue();
    channel.emitClosed();
    expect(await probing, isNull);
    expect(channel.sent, hasLength(1));
    expect(channel.closed, isTrue);
  });

  test('应答不是 Init 系(方言不符)→ null', () async {
    final channel = FakeProbeChannel();
    final probing = probe(channel);
    await pumpEventQueue();
    channel.emit(frameOf(const InitEventResponsePacket()));
    expect(await probing, isNull);
    expect(channel.closed, isTrue);
  });

  test('客户端身份透传:自定义 GUID/主机名进 InitCommandRequest', () async {
    final channel = FakeProbeChannel();
    final customGuid = Uint8List.fromList(List.filled(16, 0xAB));
    final probing =
        probe(channel, clientGuid: customGuid, hostname: 'ZPill');
    await pumpEventQueue();
    final sentPacket =
        codec.decode(channel.sent.single) as InitCommandRequestPacket;
    expect(sentPacket.guid, customGuid);
    expect(sentPacket.hostname, 'ZPill');
    channel.emit(frameOf(InitCommandResponsePacket(
      connectionNumber: 1,
      cameraGuid: Uint8List(16),
      cameraName: 'X',
      protocolVersion: kPtpIpProtocolVersion,
    )));
    expect(await probing, isNotNull);
  });
}

/// connect 即抛的通道(连不上形态)。
final class _FailingConnectChannel extends FakeProbeChannel {
  @override
  Future<void> connect(String host, int port) async {
    throw StateError('connect refused');
  }
}

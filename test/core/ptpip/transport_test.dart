import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/channels.dart';
import 'package:nikon_pill/core/ptpip/codec.dart';
import 'package:nikon_pill/core/ptpip/packet.dart';
import 'package:nikon_pill/core/ptpip/transport.dart';

/// 回放用假通道:记录已发帧,测试脚本用 emit* 模拟相机行为。
final class FakePtpIpChannel implements PtpIpChannel {
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
    // 单订阅控制器无人监听时 close future 永不完成(同 TcpPtpIpChannel)
    unawaited(_frames.close());
  }

  void emit(PtpIpFrame frame) => _frames.add(frame);
  void emitError(Object error) => _frames.addError(error);
  void emitClosed() => unawaited(_frames.close());
}

void main() {
  final codec = PtpIpCodecImpl();

  /// 包 → 帧(测试模拟相机推包时构造线上形态)。
  PtpIpFrame frameOf(PtpIpPacket packet) {
    final bytes = codec.encode(packet);
    return PtpIpFrame(
        type: packet.type,
        body: Uint8List.sublistView(bytes, kPtpIpHeaderLength));
  }

  /// 走完双通道握手,返回 (transport, command, event);
  /// 通道的 sent 已清空(握手断言由专门的握手测试负责)。
  Future<(PtpIpTransport, FakePtpIpChannel, FakePtpIpChannel)>
      connectTransport({
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    final command = FakePtpIpChannel();
    final event = FakePtpIpChannel();
    final channels = <PtpIpChannel>[command, event];
    final transport = PtpIpTransport(
      createChannel: () => channels.removeAt(0),
      transactionTimeout: timeout,
    );
    final connecting = transport.connect('192.168.1.1');
    await pumpEventQueue();
    command.emit(frameOf(InitCommandResponsePacket(
      connectionNumber: 0xC0DE,
      cameraGuid: Uint8List(16),
      cameraName: 'NIKON Z f',
      protocolVersion: kPtpIpProtocolVersion,
    )));
    await pumpEventQueue();
    event.emit(frameOf(const InitEventResponsePacket()));
    await pumpEventQueue();
    await connecting;
    command.sent.clear();
    event.sent.clear();
    return (transport, command, event);
  }

  /// 等请求落进 command.sent,按其 tid 回一个 OK 响应。
  Future<(OperationRequestPacket, PtpResult)> replyOk(
    FakePtpIpChannel command,
    Future<PtpResult> future,
  ) async {
    await pumpEventQueue();
    final req = codec.decode(command.sent.last) as OperationRequestPacket;
    command.emit(frameOf(OperationResponsePacket(
        responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
    return (req, await future);
  }

  test('PtpLinkException 是 Exception(清理路径 on Exception 接得住)', () {
    expect(const PtpLinkException('x'), isA<Exception>());
  });

  group('connect:双通道握手', () {
    test('command 方言 Init → event 连接号接力', () async {
      final command = FakePtpIpChannel();
      final event = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, event];
      final t = PtpIpTransport(
        createChannel: () => channels.removeAt(0),
        transactionTimeout: const Duration(milliseconds: 300),
      );
      final connecting = t.connect('192.168.1.1', port: 15740);
      await pumpEventQueue();

      // command:尼康方言 InitCommandRequest(GUID + "Android Device"+NUL + 版本)
      expect(command.host, '192.168.1.1');
      expect(command.port, 15740);
      expect(command.sent, hasLength(1));
      expect(command.sent[0].type, PtpIpPacketType.initCommandRequest);
      expect(command.sent[0].body.sublist(0, 16), kNikonAndroidGuid);
      expect(command.sent[0].body.length, 16 + (14 + 1) * 2 + 4);
      expect(
          (codec.decode(command.sent[0]) as InitCommandRequestPacket).hostname,
          'Android Device');

      command.emit(frameOf(InitCommandResponsePacket(
        connectionNumber: 0xC0DE,
        cameraGuid: Uint8List(16),
        cameraName: 'NIKON Z f',
        protocolVersion: kPtpIpProtocolVersion,
      )));
      await pumpEventQueue();

      // event:带着 command 握手拿到的连接号
      expect(event.sent, hasLength(1));
      expect(event.sent[0].type, PtpIpPacketType.initEventRequest);
      expect(
          (codec.decode(event.sent[0]) as InitEventRequestPacket)
              .connectionNumber,
          0xC0DE);

      event.emit(frameOf(const InitEventResponsePacket()));
      await pumpEventQueue();
      await connecting;
    });

    test('注入身份:clientGuid + hostname 进 InitCommandRequest 载荷'
        '(相机按 GUID 记忆已配对设备)', () async {
      final command = FakePtpIpChannel();
      final event = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, event];
      final guid = Uint8List.fromList(List.generate(16, (i) => i));
      guid[4] = 0x61; // 智能设备模式码 0x1E61 小端(NiConn 约定)
      guid[5] = 0x1E;
      final t = PtpIpTransport(
        createChannel: () => channels.removeAt(0),
        clientGuid: guid,
        hostname: 'NikonPill',
      );
      final connecting = t.connect('192.168.1.1');
      await pumpEventQueue();
      expect(command.sent[0].body.sublist(0, 16), guid);
      expect(
          (codec.decode(command.sent[0]) as InitCommandRequestPacket).hostname,
          'NikonPill');
      command.emit(frameOf(InitCommandResponsePacket(
        connectionNumber: 1,
        cameraGuid: Uint8List(16),
        cameraName: 'NIKON Z f',
        protocolVersion: kPtpIpProtocolVersion,
      )));
      await pumpEventQueue();
      event.emit(frameOf(const InitEventResponsePacket()));
      await pumpEventQueue();
      await connecting;
    });

    test('相机拒绝(InitFail)→ PtpInitRejectException(reason),两条通道都回收',
        () async {
      final command = FakePtpIpChannel();
      final event = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, event];
      final t = PtpIpTransport(createChannel: () => channels.removeAt(0));
      final connecting = t.connect('192.168.1.1');
      await pumpEventQueue();
      command.emit(frameOf(const InitFailPacket(reason: 0x1234)));
      await expectLater(
          connecting,
          throwsA(isA<PtpInitRejectException>()
              .having((e) => e.reason, 'reason', 0x1234)));
      expect(command.closed, isTrue);
      expect(event.closed, isTrue);
    });

    test('握手超时 → TimeoutException', () async {
      final command = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, FakePtpIpChannel()];
      final t = PtpIpTransport(
        createChannel: () => channels.removeAt(0),
        transactionTimeout: const Duration(milliseconds: 50),
      );
      final connecting = t.connect('192.168.1.1');
      await expectLater(connecting, throwsA(isA<TimeoutException>()));
      expect(command.closed, isTrue);
    });

    test('握手期通道被关闭 → PtpLinkException', () async {
      final command = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, FakePtpIpChannel()];
      final t = PtpIpTransport(createChannel: () => channels.removeAt(0));
      final connecting = t.connect('192.168.1.1');
      await pumpEventQueue();
      command.emitClosed();
      await expectLater(connecting, throwsA(isA<PtpLinkException>()));
    });

    test('未连接 execute 抛 StateError;已连接再 connect 抛 StateError',
        () async {
      final t = PtpIpTransport(createChannel: FakePtpIpChannel.new);
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsStateError);
      final (connected, _, _) = await connectTransport();
      await expectLater(connected.connect('192.168.1.1'), throwsStateError);
    });
  });

  group('execute:事务与 tid', () {
    test('数据入 happy path:StartData + EndData 尾块承载全部负载(真机形态)',
        () async {
      final (t, command, _) = await connectTransport();
      final payload = Uint8List.fromList(List.generate(10, (i) => i));
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getObjectHandles,
          params: [0xFFFFFFFF, 0, 0]));
      await pumpEventQueue();

      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      expect(req.opcode, PtpOperationCode.getObjectHandles);
      expect(req.params, [0xFFFFFFFF, 0, 0]);

      command.emit(frameOf(StartDataPacket(
          transactionId: req.transactionId, totalLength: payload.length)));
      command.emit(frameOf(EndDataPacket(
          transactionId: req.transactionId, payload: payload)));
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok,
          transactionId: req.transactionId)));

      final result = await future;
      expect(result.responseCode, PtpResponseCode.ok);
      expect(result.data, payload);
    });

    test('流式 onData:Data 分块透传,空尾 EndData 不回调,data 为 null',
        () async {
      final (t, command, _) = await connectTransport();
      final chunks = <Uint8List>[];
      final future = t.execute(
        const PtpRequest(opcode: PtpOperationCode.getObject, params: [42]),
        onData: chunks.add,
      );
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      final tid = req.transactionId;

      final c1 = Uint8List.fromList([1, 2, 3, 4]);
      final c2 = Uint8List.fromList([5, 6, 7, 8]);
      command.emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 8)));
      command.emit(frameOf(DataPacket(transactionId: tid, payload: c1)));
      command.emit(frameOf(DataPacket(transactionId: tid, payload: c2)));
      command.emit(
          frameOf(EndDataPacket(transactionId: tid, payload: Uint8List(0))));
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: tid)));

      final result = await future;
      expect(chunks, [c1, c2]);
      expect(result.data, isNull);
    });

    test('tid 方言:首事务 0、其后递增、OpenSession 重置(0x201E 自愈适配)',
        () async {
      final (t, command, _) = await connectTransport();
      final (req1, _) = await replyOk(
          command,
          t.execute(
              const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)));
      expect(req1.transactionId, 0);

      final (req2, _) = await replyOk(
          command,
          t.execute(const PtpRequest(
              opcode: PtpOperationCode.getObjectHandles,
              params: [0xFFFFFFFF, 0, 0])));
      expect(req2.transactionId, 1);

      final (req3, _) = await replyOk(
          command,
          t.execute(const PtpRequest(
              opcode: PtpOperationCode.openSession, params: [1])));
      expect(req3.transactionId, 0);

      final (req4, _) = await replyOk(
          command,
          t.execute(const PtpRequest(opcode: PtpOperationCode.closeSession)));
      expect(req4.transactionId, 1);
    });

    test('DataPhaseInfo 私表覆盖 PtpSession 全部操作码', () async {
      final (t, command, _) = await connectTransport();
      const dataInOps = <int>{
        PtpOperationCode.getDeviceInfo,
        PtpOperationCode.getObjectHandles,
        PtpOperationCode.getObjectInfo,
        PtpOperationCode.getObject,
        PtpOperationCode.getThumb,
        PtpOperationCode.getPartialObject,
        NikonOperationCode.getLargeThumb,
      };
      for (final op in dataInOps) {
        final (req, _) =
            await replyOk(command, t.execute(PtpRequest(opcode: op, params: const [1])));
        expect(req.dataPhaseInfo, 3,
            reason: '数据入操作 0x${op.toRadixString(16)} 应标 3');
      }
      for (final op in [
        PtpOperationCode.openSession,
        PtpOperationCode.closeSession,
      ]) {
        final (req, _) =
            await replyOk(command, t.execute(PtpRequest(opcode: op, params: const [1])));
        expect(req.dataPhaseInfo, 1,
            reason: '无数据相操作 0x${op.toRadixString(16)} 应标 1');
      }
      // 未收录码保守按 1(真机已证相机忽略该值)
      final (unknown, _) =
          await replyOk(command, t.execute(const PtpRequest(opcode: 0x9999)));
      expect(unknown.dataPhaseInfo, 1);
    });

    test('数据出相:dp=2 + StartData + EndData 携带全部负载(布局待真机核对)',
        () async {
      final (t, command, _) = await connectTransport();
      final payload = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2]);
      final future = t.execute(PtpRequest(
        opcode: PtpOperationCode.setDevicePropValue,
        params: const [0xD406],
        dataOut: payload,
      ));
      await pumpEventQueue();

      expect(command.sent, hasLength(3));
      final req = codec.decode(command.sent[0]) as OperationRequestPacket;
      expect(req.dataPhaseInfo, 2);
      expect(req.opcode, PtpOperationCode.setDevicePropValue);
      expect(req.params, [0xD406]);
      final start = codec.decode(command.sent[1]) as StartDataPacket;
      expect(start.transactionId, req.transactionId);
      expect(start.totalLength, payload.length);
      final end = codec.decode(command.sent[2]) as EndDataPacket;
      expect(end.payload, payload);

      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
      expect((await future).responseCode, PtpResponseCode.ok);
    });

    test('迟到的心跳/握手包无害,事务照常完成', () async {
      final (t, command, _) = await connectTransport();
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      command.emit(frameOf(const ProbeResponsePacket()));
      command.emit(frameOf(const InitEventResponsePacket()));
      await pumpEventQueue();
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok,
          transactionId: req.transactionId)));
      expect((await future).responseCode, PtpResponseCode.ok);
    });
  });

  group('毒化语义(四条不变量)', () {
    test('数据相对账失败:声明 10B 实收 4B → fail + 毒化', () async {
      final (t, command, _) = await connectTransport();
      final future = t.execute(
          const PtpRequest(opcode: PtpOperationCode.getObject, params: [7]));
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      final tid = req.transactionId;
      command
          ..emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 10)))
          ..emit(frameOf(EndDataPacket(
              transactionId: tid,
              payload: Uint8List.fromList([1, 2, 3, 4]))))
          ..emit(frameOf(OperationResponsePacket(
              responseCode: PtpResponseCode.ok, transactionId: tid)));
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
    });

    test('整事务超时:fail + 毒化 + 广播 breakage,后续 execute 秒败', () async {
      final (t, command, _) =
          await connectTransport(timeout: const Duration(milliseconds: 80));
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue(); // 请求已发出,相机不回

      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue(); // breakage 广播派发慢一拍
      expect(broke.single, contains('超时'));
      expect(command.closed, isTrue);
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
    });

    test('close 中断 in-flight:以 Exception 失败,不广播 breakage,幂等',
        () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future = t.execute(
          const PtpRequest(opcode: PtpOperationCode.getObjectHandles));
      await pumpEventQueue();

      // 先挂期望再 close:close 同步完成 pending,晚挂会变 unhandled error
      final expectClosed = expectLater(future, throwsA(isA<Exception>()));
      await t.close();
      await expectClosed;
      expect(broke, isEmpty); // 主动关闭不算意外断链
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
      await t.close(); // 幂等
    });

    test('command 通道被相机断开:在途失败 + breakage + 整链回收', () async {
      final (t, command, event) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue();

      command.emitClosed();
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue(); // breakage 广播派发慢一拍
      expect(broke.single, contains('command 通道'));
      expect(event.closed, isTrue);
    });

    test('command 通道报错(socket 异常)同样毒化', () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue();

      command.emitError(const SocketException('connection reset'));
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue();
      expect(broke, isNotEmpty);
    });

    test('响应事务号错位 → 毒化 + breakage(流错位不得污染下一事务)', () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue();

      command.emit(frameOf(
          const OperationResponsePacket(responseCode: 0x2001, transactionId: 99)));
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue();
      expect(broke.single, contains('错位'));
    });
  });

  group('事件通道', () {
    test('event 通道 Event 包 → events 广播;通道死亡 → breakage 毒化整链',
        () async {
      final (t, _, event) = await connectTransport();
      final events = <PtpEvent>[];
      t.events.listen(events.add);

      event.emit(frameOf(const EventPacket(
          eventCode: PtpEventCode.objectAdded,
          transactionId: 0xFFFFFFFF,
          params: [42])));
      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.single.code, PtpEventCode.objectAdded);
      expect(events.single.transactionId, 0xFFFFFFFF);
      expect(events.single.params, [42]);

      event.emitClosed();
      await pumpEventQueue();
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
    });

    test('command 通道上的 Event 包转投 events(个别固件行为)', () async {
      final (t, command, _) = await connectTransport();
      final events = <PtpEvent>[];
      t.events.listen(events.add);

      command.emit(frameOf(const EventPacket(
          eventCode: PtpEventCode.captureComplete,
          transactionId: 0xFFFFFFFF)));
      await pumpEventQueue();
      expect(events.single.code, PtpEventCode.captureComplete);
    });
  });
}

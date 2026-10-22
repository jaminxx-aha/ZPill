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

/// 心跳节拍驱动:每次 delay 记一个 Completer,pump 按序解决。
final class FakeDelay {
  final pending = <Completer<void>>[];

  Future<void> call(Duration d) {
    final c = Completer<void>();
    pending.add(c);
    return c.future;
  }

  Future<void> pump() async {
    expect(pending, isNotEmpty, reason: '心跳未在等待 delay(已停?)');
    pending.removeAt(0).complete();
    await Future<void>.value();
    await Future<void>.value();
    await Future<void>.value(); // 容纳 _send→pong 的异步链
  }

  Future<void> drain() async {
    while (pending.isNotEmpty) {
      await pump();
    }
  }
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
    Duration? drainLimit,
  }) async {
    final command = FakePtpIpChannel();
    final event = FakePtpIpChannel();
    final channels = <PtpIpChannel>[command, event];
    final transport = PtpIpTransport(
      createChannel: () => channels.removeAt(0),
      transactionTimeout: timeout,
      drainTimeout: drainLimit,
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

    test('数据入预分配:Data 多块入槽,声明收满数据完整(取景帧形态)',
        () async {
      final (t, command, _) = await connectTransport();
      final c1 = Uint8List.fromList(List.generate(6, (i) => i));
      final c2 = Uint8List.fromList(List.generate(6, (i) => 10 + i));
      final c3 = Uint8List.fromList(List.generate(4, (i) => 20 + i));
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getObjectHandles,
          params: [0xFFFFFFFF, 0, 0]));
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      final tid = req.transactionId;

      command.emit(frameOf(
          StartDataPacket(transactionId: tid, totalLength: c1.length + c2.length + c3.length)));
      command.emit(frameOf(DataPacket(transactionId: tid, payload: c1)));
      command.emit(frameOf(DataPacket(transactionId: tid, payload: c2)));
      command.emit(frameOf(EndDataPacket(transactionId: tid, payload: c3)));
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: tid)));

      final result = await future;
      expect(result.responseCode, PtpResponseCode.ok);
      // 预分配槽位:长度恰为声明值,三块顺序入槽无缝拼接。
      expect(result.data, hasLength(16));
      expect(result.data, [...c1, ...c2, ...c3]);
    });

    test('数据入实收超声明:回落聚合不炸,响应沿对账断链(病态流)',
        () async {
      final (t, command, _) = await connectTransport();
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getObjectHandles,
          params: [0xFFFFFFFF, 0, 0]));
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      final tid = req.transactionId;

      command.emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 4)));
      command.emit(
          frameOf(DataPacket(transactionId: tid, payload: Uint8List.fromList([1, 2, 3, 4]))));
      // 超声明续流:预分配槽位装不下,回落聚合保完整;响应沿对账断链。
      command.emit(frameOf(
          DataPacket(transactionId: tid, payload: Uint8List.fromList([5, 6, 7, 8, 9, 10]))));
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: tid)));

      await expectLater(future, throwsA(isA<PtpLinkException>()));
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

  group('取消-排水(Cancel-Drain)', () {
    /// 已发出请求数里 Cancel 包的个数。
    int cancelPackets(List<PtpIpFrame> sent) => sent
        .where((f) => f.type == PtpIpPacketType.cancel)
        .length;

    test('数据相中途取消:发 Cancel 包、吸干到响应、PtpCancelledException、'
        '会话不脱同步', () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final chunks = <Uint8List>[];
      final future = t.execute(
        const PtpRequest(
            opcode: PtpOperationCode.getPartialObject, params: [42, 0, 10]),
        onData: chunks.add,
      );
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      final tid = req.transactionId;

      // 数据相中途:StartData(10B) + Data(4B) 已到,取消前正常交付
      command.emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 10)));
      command.emit(frameOf(
          DataPacket(transactionId: tid, payload: Uint8List.fromList([1, 2, 3, 4]))));
      await pumpEventQueue();
      expect(chunks, hasLength(1));

      // 取消:Cancel 包带在途 tid;重复调用幂等(不重复发、不重置墙钟)
      expect(await t.cancelInFlight(), isTrue);
      expect(cancelPackets(command.sent), 1);
      expect((codec.decode(command.sent.last) as CancelPacket).transactionId,
          tid);
      expect(await t.cancelInFlight(), isFalse);
      expect(cancelPackets(command.sent), 1);

      // 相机不理 Cancel 继续吐:吸干只记账,不再交付
      command.emit(frameOf(DataPacket(
          transactionId: tid,
          payload: Uint8List.fromList([5, 6, 7, 8, 9, 10]))));
      await pumpEventQueue();
      expect(chunks, hasLength(1));

      // OperationResponse 一到:以 PtpCancelledException 干净收口
      // (不对账、不毒化、通道不关)
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: tid)));
      await expectLater(future, throwsA(isA<PtpCancelledException>()));
      await pumpEventQueue();
      expect(broke, isEmpty);
      expect(command.closed, isFalse);

      // 会话不脱同步:下一事务照常(tid 递增、正常收发)
      final (req2, _) = await replyOk(
          command,
          t.execute(
              const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)));
      expect(req2.transactionId, tid + 1);
    });

    test('空闲取消:no-op(false),无包发出,不毒化', () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      expect(await t.cancelInFlight(), isFalse);
      expect(command.sent, isEmpty);
      final (req, _) = await replyOk(
          command,
          t.execute(
              const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)));
      expect(req.transactionId, 0);
      expect(broke, isEmpty);
    });

    test('响应先到竞态:execute 正常完成,迟到的 Cancel 变 no-op 不悬挂',
        () async {
      final (t, command, _) = await connectTransport();
      final payload = Uint8List.fromList([1, 2, 3]);
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getPartialObject, params: [42, 0, 3]));
      await pumpEventQueue();
      final tid =
          (codec.decode(command.sent.last) as OperationRequestPacket)
              .transactionId;
      command
        ..emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 3)))
        ..emit(frameOf(EndDataPacket(transactionId: tid, payload: payload)))
        ..emit(frameOf(OperationResponsePacket(
            responseCode: PtpResponseCode.ok, transactionId: tid)));

      final result = await future; // 正常完成(响应已被 dispatcher 处理)
      expect(result.data, payload);

      // Cancel 迟到:无在途事务 → 无包可发、立即返回,不得悬挂
      expect(await t.cancelInFlight(), isFalse);
      expect(cancelPackets(command.sent), 0);
      final (_, r2) = await replyOk(
          command,
          t.execute(
              const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)));
      expect(r2.responseCode, PtpResponseCode.ok);
    });

    test('排水墙钟超时(无帧):相机不理 Cancel 也不收口 → 断链路径', () async {
      // 看门狗 5s 长于排水阀 60ms:证明收口的是排水阀而非看门狗
      final (t, command, event) = await connectTransport(
        timeout: const Duration(seconds: 5),
        drainLimit: const Duration(milliseconds: 60),
      );
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getPartialObject, params: [42, 0, 10]));
      await pumpEventQueue();

      expect(await t.cancelInFlight(), isTrue);
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue();
      expect(broke.single, contains('取消排水超时'));
      expect(command.closed, isTrue);
      expect(event.closed, isTrue);
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
    });

    test('排水墙钟阀一次性计时:数据帧一直来但响应永不收口 → 阀先于看门狗断链',
        () async {
      // 看门狗 500ms(每帧重置),排水阀 120ms(一次性):帧在 0/30/60/90ms
      // 持续到达,看门狗永不触发,断链必须来自排水阀。
      final (t, command, _) = await connectTransport(
        timeout: const Duration(milliseconds: 500),
        drainLimit: const Duration(milliseconds: 120),
      );
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getPartialObject, params: [42, 0, 1024]));
      await pumpEventQueue();
      final tid =
          (codec.decode(command.sent.last) as OperationRequestPacket)
              .transactionId;

      expect(await t.cancelInFlight(), isTrue);
      // 绝对时刻 0/30/60/90ms 各吐一帧(全在 120ms 阀内,不会打到已关通道)
      for (final ms in [0, 30, 60, 90]) {
        unawaited(Future<void>.delayed(Duration(milliseconds: ms)).then((_) {
          command.emit(frameOf(
              DataPacket(transactionId: tid, payload: Uint8List(1))));
        }));
      }
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue();
      expect(broke.single, contains('取消排水超时'));
      expect(command.closed, isTrue);
    });

    test('排水字节阀:排水期实收越过 StartData 声明 → 断链', () async {
      final (t, command, _) = await connectTransport();
      final broke = <String>[];
      t.breakages.listen(broke.add);
      final future = t.execute(const PtpRequest(
          opcode: PtpOperationCode.getPartialObject, params: [42, 0, 4]));
      await pumpEventQueue();
      final tid =
          (codec.decode(command.sent.last) as OperationRequestPacket)
              .transactionId;
      command.emit(frameOf(StartDataPacket(transactionId: tid, totalLength: 4)));
      command.emit(frameOf(
          DataPacket(transactionId: tid, payload: Uint8List.fromList([1, 2]))));
      await pumpEventQueue();
      expect(await t.cancelInFlight(), isTrue);

      // 排水期吐 10B(> 声明 4B)= 流失序 → 断链(不留死等)
      command.emit(
          frameOf(DataPacket(transactionId: tid, payload: Uint8List(10))));
      await expectLater(future, throwsA(isA<PtpLinkException>()));
      await pumpEventQueue();
      expect(broke.single, contains('取消排水超量'));
      expect(command.closed, isTrue);
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

  group('心跳保活(真发真收)', () {
    /// 心跳版握手:delay 注入驱动节拍,回声窗口 50ms(真实超时)。
    Future<(PtpIpTransport, FakePtpIpChannel, FakePtpIpChannel, FakeDelay)>
        connectKeepalive() async {
      final command = FakePtpIpChannel();
      final event = FakePtpIpChannel();
      final channels = <PtpIpChannel>[command, event];
      final delay = FakeDelay();
      final transport = PtpIpTransport(
        createChannel: () => channels.removeAt(0),
        transactionTimeout: const Duration(milliseconds: 300),
        enableKeepalive: true,
        keepaliveInterval: const Duration(seconds: 15),
        keepaliveMaxMissed: 3,
        probeTimeout: const Duration(milliseconds: 50),
        keepaliveDelay: delay.call,
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
      return (transport, command, event, delay);
    }

    test('握手后周期在 event 通道发 ProbeRequest;回声即活,不断链', () async {
      final (t, command, event, delay) = await connectKeepalive();
      final broke = <String>[];
      t.breakages.listen(broke.add);

      await delay.pump();
      expect(event.sent, hasLength(1));
      expect(event.sent.single.type, PtpIpPacketType.probeRequest);
      event.emit(frameOf(const ProbeResponsePacket()));
      await pumpEventQueue();
      await Future<void>.delayed(
          const Duration(milliseconds: 20)); // pong 到达窗口内

      await delay.pump(); // 第二拍
      expect(event.sent, hasLength(2));
      event.emit(frameOf(const ProbeResponsePacket()));
      await pumpEventQueue();

      expect(broke, isEmpty);
      // 心跳之外,事务照常
      final future =
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await pumpEventQueue();
      final req = codec.decode(command.sent.last) as OperationRequestPacket;
      command.emit(frameOf(OperationResponsePacket(
          responseCode: PtpResponseCode.ok, transactionId: req.transactionId)));
      expect((await future).responseCode, PtpResponseCode.ok);

      await t.close();
      await delay.drain();
    });

    test('连续 3 拍无回声 → breakage 广播 + 毒化', () async {
      final (t, _, event, delay) = await connectKeepalive();
      final broke = <String>[];
      t.breakages.listen(broke.add);

      for (var i = 0; i < 3; i++) {
        await delay.pump();
        expect(event.sent, hasLength(i + 1));
        // 不回 ProbeResponse:等真实 50ms 超时把本拍判为无响应
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
      await pumpEventQueue();
      expect(broke, hasLength(1));
      expect(broke.single, contains('心跳'));
      await expectLater(
          t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
          throwsA(isA<PtpLinkException>()));
      expect(event.closed, isTrue);
      await delay.drain();
    });

    test('默认关:握手后 event 通道无心跳包(既有回放脚本不受扰)', () async {
      final (t, _, event) = await connectTransport();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(event.sent, isEmpty);
      await t.close();
    });

    test('close 停心跳:不再发 ProbeRequest', () async {
      final (t, _, event, delay) = await connectKeepalive();
      await delay.pump();
      expect(event.sent, hasLength(1));
      event.emit(frameOf(const ProbeResponsePacket()));
      await pumpEventQueue();

      await t.close();
      await delay.drain();
      final sent = event.sent.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(event.sent.length, sent, reason: 'close 后不得再发心跳');
    });
  });
}

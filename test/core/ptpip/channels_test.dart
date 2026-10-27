import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptpip/channels.dart';
import 'package:nikon_pill/core/ptpip/packet.dart';

/// golden 十六进制 → 字节。
Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

/// 一个 EndData 帧:tid=2 + 载荷 AB(总长 14)。
final Uint8List _endDataFrame = _hex('0E000000 0C000000 02000000 41 42');

void main() {
  group('PtpIpFrameSplitter(纯逻辑:半包/粘包/逐字节)', () {
    test('整包一次喂入', () {
      final s = PtpIpFrameSplitter();
      final frames = s.feed(_endDataFrame);
      expect(frames, hasLength(1));
      expect(frames[0].type, PtpIpPacketType.endData);
      expect(frames[0].body, [0x02, 0x00, 0x00, 0x00, 0x41, 0x42]);
    });

    test('整帧随块到:body 是来块的视图(零拷贝路径)', () {
      final s = PtpIpFrameSplitter();
      final input = Uint8List.fromList(_endDataFrame);
      final frames = s.feed(input);
      expect(frames, hasLength(1));
      // 共享缓冲断言:原地改来块,视图同步可见(若实现退回整帧拷贝即翻;
      // buffer getter 每次访问返回新包装,identical 断言不可用)。
      input[8] = 0x7E;
      expect(frames[0].body[0], 0x7E);
    });

    test('半包:先 4B 头、再 4B 头、再体分两截', () {
      final s = PtpIpFrameSplitter();
      final f = _endDataFrame;
      expect(s.feed(Uint8List.sublistView(f, 0, 4)), isEmpty);
      expect(s.feed(Uint8List.sublistView(f, 4, 8)), isEmpty);
      expect(s.feed(Uint8List.sublistView(f, 8, 10)), isEmpty);
      final frames = s.feed(Uint8List.sublistView(f, 10));
      expect(frames, hasLength(1));
      expect(frames[0].body, [0x02, 0x00, 0x00, 0x00, 0x41, 0x42]);
    });

    test('粘包:两帧一次喂入,依次吐出', () {
      final s = PtpIpFrameSplitter();
      final init = _hex('0C000000 03000000 CDAB0000'); // InitEventRequest
      final both = Uint8List.fromList([...init, ..._endDataFrame]);
      final frames = s.feed(both);
      expect(frames, hasLength(2));
      expect(frames[0].type, PtpIpPacketType.initEventRequest);
      expect(frames[1].type, PtpIpPacketType.endData);
    });

    test('逐字节喂入也能拼出完整帧', () {
      final s = PtpIpFrameSplitter();
      var count = 0;
      for (final b in _endDataFrame) {
        count += s.feed(Uint8List.fromList([b])).length;
      }
      expect(count, 1);
    });

    test('空体帧(length == 8)', () {
      final s = PtpIpFrameSplitter();
      final frames = s.feed(_hex('08000000 04000000'));
      expect(frames, hasLength(1));
      expect(frames[0].type, PtpIpPacketType.initEventResponse);
      expect(frames[0].body, isEmpty);
    });

    test('帧 body 是视图但不因后续 feed 失效', () {
      final s = PtpIpFrameSplitter();
      final first = s.feed(_endDataFrame)[0];
      final bodySnapshot = Uint8List.fromList(first.body);
      // 再喂一帧,内部缓冲重排 —— 已吐出的帧不得被污染
      s.feed(_hex('0C000000 03000000 CDAB0000'));
      expect(first.body, bodySnapshot);
    });

    test('空喂入无帧无异常', () {
      final s = PtpIpFrameSplitter();
      expect(s.feed(Uint8List(0)), isEmpty);
    });

    test('长度 < 8 抛 FormatException(流错位毒化依据)', () {
      final s = PtpIpFrameSplitter();
      expect(() => s.feed(_hex('07000000 01000000')), throwsFormatException);
    });

    test('巨值长度先校验后分配,直接抛 FormatException', () {
      final s = PtpIpFrameSplitter();
      expect(() => s.feed(_hex('FFFFFF7F 01000000')), throwsFormatException);
    });

    test('控制帧超过 1MiB:在完整 body 到齐前拒绝', () {
      final s = PtpIpFrameSplitter();
      final header = Uint8List(kPtpIpHeaderLength);
      ByteData.sublistView(header)
        ..setUint32(0, kMaxPtpIpControlFrameLength + 1, Endian.little)
        ..setUint32(4, PtpIpPacketType.operationResponse, Endian.little);
      expect(() => s.feed(header), throwsFormatException);
    });

    test('Data/EndData 不受 1MiB 控制帧上限误伤', () {
      final s = PtpIpFrameSplitter();
      final header = Uint8List(kPtpIpHeaderLength);
      ByteData.sublistView(header)
        ..setUint32(0, 2 * 1024 * 1024, Endian.little)
        ..setUint32(4, PtpIpPacketType.data, Endian.little);
      expect(s.feed(header), isEmpty);
    });
  });

  group('TcpPtpIpChannel(回环 socket)', () {
    test('发送 → 对端回显 → frames 流吐出同一帧', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final serverSub = server.listen((client) {
        client.listen(
          (data) => client.add(data), // 回显服务器
          onDone: () => client.destroy(),
          onError: (_) => client.destroy(),
        );
      });
      final ch = TcpPtpIpChannel();
      await ch.connect('127.0.0.1', server.port);
      expect(ch.isOpen, isTrue);

      final first = ch.frames.first; // 先订阅(单订阅流)
      await ch.sendFrame(PtpIpFrame(
          type: PtpIpPacketType.operationRequest,
          body: Uint8List.fromList([1, 2, 3])));
      final frame = await first.timeout(const Duration(seconds: 5));
      expect(frame.type, PtpIpPacketType.operationRequest);
      expect(frame.body, [1, 2, 3]);

      await ch.close();
      await ch.close(); // 幂等
      expect(ch.isOpen, isFalse);
      await serverSub.cancel();
      await server.close();
    });

    test('未连接发送抛 StateError', () {
      final ch = TcpPtpIpChannel();
      expect(
        () => ch.sendFrame(PtpIpFrame(type: 1, body: Uint8List(0))),
        throwsStateError,
      );
    });

    test('端口无人监听:SocketException 快速失败(非挂起)', () async {
      // 占一个端口再关掉,保证连接被拒
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final ch = TcpPtpIpChannel();
      await expectLater(
        ch.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
    });

    test('close 后 connect 抛 StateError', () async {
      final ch = TcpPtpIpChannel();
      await ch.close();
      await expectLater(ch.connect('127.0.0.1', 1), throwsStateError);
    });
  });
}

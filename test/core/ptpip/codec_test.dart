import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptpip/codec.dart';
import 'package:nikon_pill/core/ptpip/packet.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

/// golden 十六进制 → 字节(测试专用,断言线上真值而非回环)。
Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

/// 与 encode 输出对拍:剥掉包头得到 (type, body),供 decode 回环。
(PtpIpFrame, Uint8List) _wire(PtpIpCodec codec, PtpIpPacket packet) {
  final bytes = codec.encode(packet);
  final type = ByteData.sublistView(bytes).getUint32(4, Endian.little);
  final body = Uint8List.sublistView(bytes, 8);
  return (PtpIpFrame(type: type, body: body), bytes);
}

void main() {
  final codec = PtpIpCodecImpl();

  group('包头:长度(u32)在前、类型(u32)在后', () {
    test('ProbeRequest 空负载,包头即全部', () {
      // 长度 8 在前、类型 13 在后 —— 顺序曾是类型在前,2026-10-04 订正
      expect(codec.encode(const ProbeRequestPacket()),
          _hex('08000000 0D000000'));
    });

    test('尼康方言 InitCommandRequest 的线上真值(Camera_Bridge 实证)', () {
      // GUID 固定 00112233…EEFF + "Android Device"(NUL 结尾,无长度前缀)
      // + u32 版本 0x00010000;总长 58。
      // 与 tools/ptpip_probe/probe.py 输出逐字节一致。
      final bytes = codec.encode(InitCommandRequestPacket(
        guid: Uint8List.fromList(kNikonAndroidGuid),
        hostname: 'Android Device',
      ));
      expect(
        bytes,
        _hex(
          '3A000000 01000000'
          '00112233445566778899AABBCCDDEEFF'
          '41006E00640072006F00690064002000440065007600690063006500'
          '0000'
          '00000100',
        ),
      );
    });
  });

  group('encode:主机 → 相机方向', () {
    test('InitEventRequest:连接号', () {
      expect(
        codec.encode(const InitEventRequestPacket(connectionNumber: 0xABCD)),
        _hex('0C000000 03000000 CDAB0000'),
      );
    });

    test('OperationRequest:GetObjectHandles 全存储哨兵(Camera_Bridge 同款)', () {
      // dp=1(尼康客户端恒发 1)+ 0x1007 + tid=1 + [0xFFFFFFFF, 0, 0]
      expect(
        codec.encode(const OperationRequestPacket(
          dataPhaseInfo: 1,
          opcode: 0x1007,
          transactionId: 1,
          params: [0xFFFFFFFF, 0, 0],
        )),
        _hex('1E000000 06000000'
            '01000000 0710 01000000 FFFFFFFF 00000000 00000000'),
      );
    });

    test('OperationRequest:OpenSession(tid=0,session=1,尼康方言首事务)', () {
      expect(
        codec.encode(const OperationRequestPacket(
          dataPhaseInfo: 1,
          opcode: 0x1002,
          transactionId: 0,
          params: [1],
        )),
        _hex('16000000 06000000 01000000 0210 00000000 01000000'),
      );
    });

    test('StartData:tid(u32) + 总长(u64)', () {
      expect(
        codec.encode(
            const StartDataPacket(transactionId: 1, totalLength: 0x123456789A)),
        _hex('14000000 09000000 01000000 9A78563412000000'),
      );
    });

    test('Data / EndData:tid + 负载(EndData 携带尾段)', () {
      expect(
        codec.encode(DataPacket(
            transactionId: 7, payload: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]))),
        _hex('10000000 0A000000 07000000 DEADBEEF'),
      );
      expect(
        codec.encode(EndDataPacket(
            transactionId: 2, payload: Uint8List.fromList([0x41, 0x42]))),
        _hex('0E000000 0C000000 02000000 4142'),
      );
    });

    test('Cancel:tid', () {
      expect(
        codec.encode(const CancelPacket(transactionId: 3)),
        _hex('0C000000 0B000000 03000000'),
      );
    });

    test('相机 → 主机方向的包同样可 encode(测试回放脚本构造用)', () {
      // 真值 = decode 测试同一布局的小端镜像:u16 码 + u32 tid + params
      expect(
        codec.encode(const OperationResponsePacket(
            responseCode: 0x2001, transactionId: 1, params: [0x2A])),
        _hex('12000000 07000000 0120 01000000 2A000000'),
      );
      expect(
        codec.encode(const EventPacket(
            eventCode: 0x4002, transactionId: 0xFFFFFFFF, params: [0x123])),
        _hex('12000000 08000000 0240 FFFFFFFF 23010000'),
      );
    });
  });

  group('decode:相机 → 主机方向', () {
    test('InitCommandResponse(尼康方言四段)', () {
      final body = (ByteWriter()
            ..u32(0x0000ABCD)
            ..raw(const [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
            ..utf16le('NIKON Z f')
            ..u16(0)
            ..u32(kPtpIpProtocolVersion))
          .takeBytes();
      final pkt = codec.decode(
          PtpIpFrame(type: PtpIpPacketType.initCommandResponse, body: body));
      final resp = pkt as InitCommandResponsePacket;
      expect(resp.connectionNumber, 0xABCD);
      expect(resp.cameraName, 'NIKON Z f');
      expect(resp.cameraGuid, kNikonAndroidGuid);
      expect(resp.protocolVersion, 0x00010000);
    });

    test('InitEventResponse:空负载', () {
      final pkt = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.initEventResponse, body: Uint8List(0)));
      expect(pkt, isA<InitEventResponsePacket>());
    });

    test('InitFail:原因码', () {
      final pkt = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.initFail,
          body: (ByteWriter()..u32(0x00001234)).takeBytes()));
      expect((pkt as InitFailPacket).reason, 0x1234);
    });

    test('OperationResponse:响应码 + tid + params(变长)', () {
      final body = (ByteWriter()
            ..u16(0x2001)
            ..u32(5)
            ..u32(1))
          .takeBytes();
      final pkt = codec.decode(
          PtpIpFrame(type: PtpIpPacketType.operationResponse, body: body));
      final resp = pkt as OperationResponsePacket;
      expect(resp.responseCode, 0x2001);
      expect(resp.transactionId, 5);
      expect(resp.params, [1]);

      final noParams = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.operationResponse,
          body: (ByteWriter()..u16(0x2019)..u32(9)).takeBytes()));
      expect((noParams as OperationResponsePacket).params, isEmpty);
    });

    test('Event:事件码 + tid(异步事件 tid=0xFFFFFFFF)+ params', () {
      final body = (ByteWriter()
            ..u16(0x4002) // ObjectAdded
            ..u32(0xFFFFFFFF)
            ..u32(0x00000123))
          .takeBytes();
      final pkt =
          codec.decode(PtpIpFrame(type: PtpIpPacketType.event, body: body));
      final ev = pkt as EventPacket;
      expect(ev.eventCode, 0x4002);
      expect(ev.transactionId, 0xFFFFFFFF);
      expect(ev.params, [0x123]);
    });

    test('StartData / Data / EndData / Cancel', () {
      final start = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.startData,
          body: (ByteWriter()..u32(1)..u64(0x123456789A)).takeBytes()));
      expect((start as StartDataPacket).totalLength, 0x123456789A);
      expect(start.transactionId, 1);

      final data = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.data,
          body: (ByteWriter()..u32(7)..raw([0xDE, 0xAD])).takeBytes()));
      expect((data as DataPacket).payload, [0xDE, 0xAD]);

      final end = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.endData,
          body: (ByteWriter()..u32(2)..raw([0x41, 0x42])).takeBytes()));
      expect((end as EndDataPacket).payload, [0x41, 0x42]);
      // EndData 携带尾段负载(小数据集可能 StartData+EndData 零 Data 包)
      expect(end.payload, isNotEmpty);

      final cancel = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.cancel,
          body: (ByteWriter()..u32(3)).takeBytes()));
      expect((cancel as CancelPacket).transactionId, 3);
    });

    test('主机 → 相机方向也可 decode(transport 测试解析已发帧用)', () {
      final req = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.operationRequest,
          body: (ByteWriter()
                ..u32(3) // dp
                ..u16(0x1009) // GetObject
                ..u32(4) // tid
                ..u32(0x55))
              .takeBytes())) as OperationRequestPacket;
      expect(req.dataPhaseInfo, 3);
      expect(req.opcode, 0x1009);
      expect(req.transactionId, 4);
      expect(req.params, [0x55]);

      final initReq = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.initCommandRequest,
          body: (ByteWriter()
                ..raw(kNikonAndroidGuid)
                ..utf16le('Android Device')
                ..u16(0)
                ..u32(kPtpIpProtocolVersion))
              .takeBytes())) as InitCommandRequestPacket;
      expect(initReq.hostname, 'Android Device');
      expect(initReq.guid, kNikonAndroidGuid);

      final evtReq = codec.decode(PtpIpFrame(
          type: PtpIpPacketType.initEventRequest,
          body: (ByteWriter()..u32(0xC0DE)).takeBytes())) as InitEventRequestPacket;
      expect(evtReq.connectionNumber, 0xC0DE);
    });

    test('未知类型抛 FormatException', () {
      expect(
        () => codec.decode(PtpIpFrame(type: 99, body: Uint8List(0))),
        throwsFormatException,
      );
    });
  });

  group('回环:encode → 剥包头 → decode 字段无损', () {
    test('OperationRequest 5 参数上限内的回环', () {
      const pkt = OperationRequestPacket(
        dataPhaseInfo: 3,
        opcode: 0x1009,
        transactionId: 0x7FFFFFFF,
        params: [1, 2, 3, 4, 5],
      );
      final (frame, bytes) = _wire(codec, pkt);
      final back = codec.decode(frame) as OperationRequestPacket;
      expect(frame.type, PtpIpPacketType.operationRequest);
      expect(back.dataPhaseInfo, 3);
      expect(back.opcode, 0x1009);
      expect(back.transactionId, 0x7FFFFFFF);
      expect(back.params, [1, 2, 3, 4, 5]);
      expect(ByteData.sublistView(bytes).getUint32(0, Endian.little),
          bytes.length);
    });
  });
}

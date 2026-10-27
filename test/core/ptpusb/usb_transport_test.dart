import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/ptpusb/containers.dart';
import 'package:z_pill/core/ptpusb/usb_transport.dart';

import 'fake_usb_byte_pipe.dart';

void main() {
  group('命令/数据出相位(bulk OUT)', () {
    test('命令容器字节手算核对(OpenSession,txid 从 0 起)', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      await t.execute(const PtpRequest(
        opcode: PtpOperationCode.openSession,
        params: [1],
      ));
      // len=16 | type=1 | opcode=0x1002 | txid=0 | sessionId=1
      expect(pipe.outWrites.single, [
        0x10, 0x00, 0x00, 0x00, //
        0x01, 0x00, //
        0x02, 0x10, //
        0x00, 0x00, 0x00, 0x00, //
        0x01, 0x00, 0x00, 0x00, //
      ]);
    });

    test('dataOut 相位:命令 + 数据两个容器先后发出', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      await t.execute(PtpRequest(
        opcode: 0x1016, // SetDevicePropValue(数据出相位的典型操作)
        params: [0x5001],
        dataOut: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
      ));
      expect(pipe.outWrites.length, 2);
      // 第二个:数据容器 len=15 | type=2 | opcode=0x1016 | txid=0 | payload
      expect(pipe.outWrites[1], [
        0x0F, 0x00, 0x00, 0x00, //
        0x02, 0x00, //
        0x16, 0x10, //
        0x00, 0x00, 0x00, 0x00, //
        0xAA, 0xBB, 0xCC, //
      ]);
    });

    test('txid 随事务递增', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 1));
      await t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      await t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      // 命令容器 txid 字段在偏移 8(u32)
      expect(pipe.outWrites[0][8], 0);
      expect(pipe.outWrites[1][8], 1);
    });
  });

  group('数据入相位(bulk IN)', () {
    test('DATA + RESPONSE 双序:小容器整体返回', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      pipe.enqueue(encodeUsbData(
        opcode: PtpOperationCode.getStorageIds,
        transactionId: 0,
        payload: payload,
      ));
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      final result = await t.execute(
        const PtpRequest(opcode: PtpOperationCode.getStorageIds),
      );
      expect(result.responseCode, PtpResponseCode.ok);
      expect(result.data, payload);
    });

    test('错误序:无 DATA 直接回错误响应', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
        responseCode: PtpResponseCode.operationNotSupported,
        transactionId: 0,
      ));
      final result = await t.execute(
        const PtpRequest(opcode: PtpOperationCode.getObject, params: [42]),
      );
      expect(result.responseCode, PtpResponseCode.operationNotSupported);
      expect(result.data, isNull);
    });

    test('响应参数(u32)透传', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
        responseCode: PtpResponseCode.ok,
        transactionId: 0,
        params: [0x12345678],
      ));
      final result = await t.execute(
        const PtpRequest(
            opcode: PtpOperationCode.getNumObjects, params: [0xFFFFFFFF, 0]),
      );
      expect(result.params, [0x12345678]);
    });

    test('短读跨容器头边界仍能拼齐(5+7 分片)', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final data = encodeUsbData(
        opcode: PtpOperationCode.getObjectInfo,
        transactionId: 0,
        payload: payload,
      );
      pipe.enqueueSplit(data, [5, 7]);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      final result = await t.execute(
        const PtpRequest(opcode: PtpOperationCode.getObjectInfo, params: [1]),
      );
      expect(result.data, payload);
    });

    test('非流式数据超过 64MiB:读头后立即拒绝,不整体分配', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final header = Uint8List(kUsbContainerHeaderLength);
      ByteData.sublistView(header)
        ..setUint32(0, kUsbContainerHeaderLength + kMaxUsbBufferedDataBytes + 1,
            Endian.little)
        ..setUint16(4, UsbContainerType.data, Endian.little)
        ..setUint16(6, PtpOperationCode.getObject, Endian.little)
        ..setUint32(8, 0, Endian.little);
      pipe.enqueue(header);

      await expectLater(
        t.execute(
            const PtpRequest(opcode: PtpOperationCode.getObject, params: [42])),
        throwsFormatException,
      );
      expect(pipe.drainCalls, 1);
    });
  });

  group('流式 onData(GetObject 大容器)', () {
    test('不规则短读分片:块边界跟随分片,内容不丢不重', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      // payload 100000B:分片 5+7(头)+ 30000+30000+40000(体)
      final payload =
          Uint8List.fromList(List.generate(100000, (i) => i & 0xFF));
      final data = encodeUsbData(
        opcode: PtpOperationCode.getObject,
        transactionId: 0,
        payload: payload,
      );
      pipe.enqueueSplit(data, [5, 7, 30000, 30000, 40000]);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));

      final chunks = <Uint8List>[];
      final result = await t.execute(
        const PtpRequest(opcode: PtpOperationCode.getObject, params: [42]),
        onData: chunks.add,
      );
      expect(chunks.map((c) => c.length), [30000, 30000, 40000]);
      expect(concat(chunks), payload);
      // 流式模式不整体驻留:data 为 null
      expect(result.data, isNull);
    });

    test('单分片超过 1MB 上限被切块', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final payload = Uint8List.fromList(
          List.generate(kUsbStreamChunkBytes + 70000, (i) => (i * 7) & 0xFF));
      pipe.enqueue(encodeUsbData(
        opcode: PtpOperationCode.getObject,
        transactionId: 0,
        payload: payload,
      ));
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));

      final chunks = <Uint8List>[];
      await t.execute(
        const PtpRequest(opcode: PtpOperationCode.getObject, params: [42]),
        onData: chunks.add,
      );
      expect(chunks.map((c) => c.length),
          [kUsbStreamChunkBytes, payload.length - kUsbStreamChunkBytes]);
      expect(concat(chunks), payload);
    });
  });

  group('事件流(interrupt IN)', () {
    test('16B ObjectAdded:code/txid=0xFFFFFFFF/参数', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final received = <PtpEvent>[];
      final sub = t.events.listen(received.add);
      // Zf 真机形态:len=16, type=4, 0x4002, txid=0xFFFFFFFF, 1 个 u32 参数
      pipe.emitEvent(Uint8List.fromList([
        0x10, 0x00, 0x00, 0x00, //
        0x04, 0x00, //
        0x02, 0x40, //
        0xFF, 0xFF, 0xFF, 0xFF, //
        0x05, 0x00, 0x00, 0x00, //
      ]));
      await pumpEventQueue();
      expect(received.single.code, PtpEventCode.objectAdded);
      expect(received.single.transactionId, 0xFFFFFFFF);
      expect(received.single.params, [5]);
      await sub.cancel();
    });

    test('畸形事件丢弃,不断流', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final received = <PtpEvent>[];
      final sub = t.events.listen(received.add);
      pipe.emitEvent(Uint8List.fromList([1, 2, 3])); // 不足 12B 头
      pipe.emitEvent(encodeUsbEvent(
        eventCode: PtpEventCode.captureComplete,
        transactionId: 0xFFFFFFFF,
      ));
      await pumpEventQueue();
      expect(received.map((e) => e.code), [PtpEventCode.captureComplete]);
      await sub.cancel();
    });
  });

  group('异常与关闭', () {
    test('窗口内无数据:TimeoutException 向上抛', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('响应 txid 与事务不符抛 FormatException', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 7));
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsFormatException,
      );
    });

    test('txid 不符报错带头 12B 十六进制(真机日志可判错位成因)', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 7));
      // 头 12B:len=0x0C 00 00 00 | type=03 00 | code=01 20(0x2001 OK) | txid=07 00 00 00
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('头:0c 00 00 00 03 00 01 20 07 00 00 00'),
        )),
      );
    });

    test('close 后拒绝新事务', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      await t.close();
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsStateError,
      );
    });

    test('bulkRead 空块不无限循环,按超时收口并排空', () async {
      final pipe = _BadUsbPipe(returnEmpty: true);
      final t = UsbPtpTransport(pipe: pipe);
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsA(isA<TimeoutException>()),
      );
      expect(pipe.drainCalls, 1);
    });

    test('bulkRead 超过请求长度立即按格式错误收口并排空', () async {
      final pipe = _BadUsbPipe(returnEmpty: false);
      final t = UsbPtpTransport(pipe: pipe);
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsFormatException,
      );
      expect(pipe.drainCalls, 1);
    });
  });

  group('中止后排空(drainIn,nico 三件套之三)', () {
    /// 数据容器头(声明 [bodyLen] 字节体)+ 只到 [partialLen] 字节体:
    /// 相机半途断流,数据相位收不齐 → 超时中止。
    void enqueueStarvedData(
      FakeUsbBytePipe pipe, {
      required int bodyLen,
      required int partialLen,
    }) {
      final data = encodeUsbData(
        opcode: PtpOperationCode.getObject,
        transactionId: 0,
        payload: Uint8List(bodyLen),
      );
      pipe.enqueue(Uint8List.fromList(data.sublist(0, 12))); // 头
      pipe.enqueue(Uint8List(partialLen)); // 体(内容无关)
    }

    test('数据相位超时中止:先排空再抛 TimeoutException', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      enqueueStarvedData(pipe, bodyLen: 100, partialLen: 40);
      await expectLater(
        t.execute(
            const PtpRequest(opcode: PtpOperationCode.getObject, params: [1])),
        throwsA(isA<TimeoutException>()),
      );
      expect(pipe.drainCalls, 1);
    });

    test('txid 错位中止(FormatException):同样排空', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 7));
      await expectLater(
        t.execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo)),
        throwsFormatException,
      );
      expect(pipe.drainCalls, 1);
    });

    test('成功事务不排空', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      pipe.enqueue(encodeUsbData(
        opcode: PtpOperationCode.getStorageIds,
        transactionId: 0,
        payload: Uint8List(4),
      ));
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
      await t.execute(const PtpRequest(opcode: PtpOperationCode.getStorageIds));
      expect(pipe.drainCalls, 0);
    });

    test('流式 onData 中止:已到块不回吐,管道排空', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      final data = encodeUsbData(
        opcode: PtpOperationCode.getObject,
        transactionId: 0,
        payload: Uint8List.fromList(List.generate(100000, (i) => i & 0xFF)),
      );
      pipe.enqueue(Uint8List.fromList(data.sublist(0, 12))); // 头
      pipe.enqueue(Uint8List.fromList(data.sublist(12, 12 + 30000))); // 30KB
      final chunks = <Uint8List>[];
      await expectLater(
        t.execute(
          const PtpRequest(opcode: PtpOperationCode.getObject, params: [42]),
          onData: chunks.add,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(chunks.map((c) => c.length), [30000]); // 已到块已交付
      expect(pipe.drainCalls, 1);
    });

    test('排空自身失败不掩盖原始异常', () async {
      final pipe = FakeUsbBytePipe();
      pipe.drainImpl = () async => throw Exception('链路已死');
      final t = UsbPtpTransport(pipe: pipe);
      enqueueStarvedData(pipe, bodyLen: 100, partialLen: 40);
      await expectLater(
        t.execute(
            const PtpRequest(opcode: PtpOperationCode.getObject, params: [1])),
        throwsA(isA<TimeoutException>()), // 原始异常,不是排空的 Exception
      );
      expect(pipe.drainCalls, 1);
    });

    test('中止排空吸掉迟到尾包:下一事务拿到自己的字节', () async {
      final pipe = FakeUsbBytePipe();
      final t = UsbPtpTransport(pipe: pipe);
      // 排空期间相机还在吐被中止事务的尾包(native 吸干的对象;
      // 无排空接线时这 12B 会被下一事务当容器头吃掉 → 错位)
      pipe.drainImpl = () async {
        pipe.enqueue(Uint8List.fromList(List.filled(12, 9)));
      };
      enqueueStarvedData(pipe, bodyLen: 100, partialLen: 40);
      await expectLater(
        t.execute(
            const PtpRequest(opcode: PtpOperationCode.getObject, params: [1])),
        throwsA(isA<TimeoutException>()),
      );
      expect(pipe.drainCalls, 1);
      // tx1(txid=1)的响应容器不被污染
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 1));
      final result = await t
          .execute(const PtpRequest(opcode: PtpOperationCode.getDeviceInfo));
      expect(result.responseCode, PtpResponseCode.ok);
    });

    test('drainIn 语义:丢弃超读余量与待读队列(fake 对齐 native)', () async {
      final pipe = FakeUsbBytePipe();
      // 制造超读余量:读 4B,余 28B 留在 fake 的 leftover
      pipe.enqueue(Uint8List(32));
      await pipe.bulkRead(4, timeoutMs: 100);
      pipe.enqueue(Uint8List(16)); // 队列再压一段待读残余
      await pipe.drainIn();
      await expectLater(
        pipe.bulkRead(16, timeoutMs: 100),
        throwsA(isA<TimeoutException>()), // 全空:残余确被丢弃
      );
      expect(pipe.drainCalls, 1);
    });
  });
}

final class _BadUsbPipe implements UsbBytePipe {
  _BadUsbPipe({required this.returnEmpty});

  final bool returnEmpty;
  int drainCalls = 0;

  @override
  Future<void> bulkOut(Uint8List bytes) async {}

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async =>
      returnEmpty ? Uint8List(0) : Uint8List(maxLen + 1);

  @override
  Future<void> drainIn() async => drainCalls++;

  @override
  Stream<Uint8List> get interruptEvents => const Stream.empty();
}

Uint8List concat(Iterable<Uint8List> chunks) {
  final b = BytesBuilder(copy: false);
  for (final c in chunks) {
    b.add(c);
  }
  return b.toBytes();
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptpusb/containers.dart';

/// 期望字节全部手算(小端),与实现独立 —— 同 test/core/utils 的纪律。
void main() {
  group('encodeUsbCommand', () {
    test('OpenSession + 1 参数', () {
      final b = encodeUsbCommand(
        opcode: PtpOperationCode.openSession,
        transactionId: 0,
        params: [1],
      );
      // len=16 | type=1 | opcode=0x1002 | txid=0 | sessionId=1
      expect(b, [
        0x10, 0x00, 0x00, 0x00, //
        0x01, 0x00, //
        0x02, 0x10, //
        0x00, 0x00, 0x00, 0x00, //
        0x01, 0x00, 0x00, 0x00, //
      ]);
    });

    test('GetObjectHandles 3 参数', () {
      final b = encodeUsbCommand(
        opcode: PtpOperationCode.getObjectHandles,
        transactionId: 7,
        params: [
          GetObjectHandlesParams.storageAll,
          GetObjectHandlesParams.formatAll,
          GetObjectHandlesParams.parentAll,
        ],
      );
      // len=12+12=24 | type=1 | opcode=0x1007 | txid=7 | 0xFFFFFFFF 0 0xFFFFFFFF
      expect(b, [
        0x18, 0x00, 0x00, 0x00, //
        0x01, 0x00, //
        0x07, 0x10, //
        0x07, 0x00, 0x00, 0x00, //
        0xFF, 0xFF, 0xFF, 0xFF, //
        0x00, 0x00, 0x00, 0x00, //
        0xFF, 0xFF, 0xFF, 0xFF, //
      ]);
    });

    test('无参数时长度恰为 12', () {
      final b = encodeUsbCommand(
        opcode: PtpOperationCode.getDeviceInfo,
        transactionId: 1,
      );
      expect(b.length, kUsbContainerHeaderLength);
      expect(b.sublist(0, 4), [0x0C, 0x00, 0x00, 0x00]);
    });

    test('超过 5 个参数抛 ArgumentError', () {
      expect(
        () => encodeUsbCommand(opcode: 0x1002, transactionId: 0, params: [1, 2, 3, 4, 5, 6]),
        throwsArgumentError,
      );
    });
  });

  group('encodeUsbData / encodeUsbResponse', () {
    test('数据容器:头 12 + payload', () {
      final b = encodeUsbData(
        opcode: PtpOperationCode.getObjectInfo,
        transactionId: 1,
        payload: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
      );
      expect(b, [
        0x0F, 0x00, 0x00, 0x00, //
        0x02, 0x00, //
        0x08, 0x10, //
        0x01, 0x00, 0x00, 0x00, //
        0xAA, 0xBB, 0xCC, //
      ]);
    });

    test('响应容器 OK 无参数', () {
      final b = encodeUsbResponse(responseCode: PtpResponseCode.ok, transactionId: 0);
      expect(b, [
        0x0C, 0x00, 0x00, 0x00, //
        0x03, 0x00, //
        0x01, 0x20, //
        0x00, 0x00, 0x00, 0x00, //
      ]);
    });
  });

  group('decodeUsbContainer', () {
    test('命令往返', () {
      final b = encodeUsbCommand(
        opcode: PtpOperationCode.getObject,
        transactionId: 42,
        params: [0x12345678],
      );
      final c = decodeUsbContainer(b) as UsbCommandContainer;
      expect(c.opcode, PtpOperationCode.getObject);
      expect(c.transactionId, 42);
      expect(c.params, [0x12345678]);
    });

    test('数据往返', () {
      final b = encodeUsbData(
        opcode: PtpOperationCode.getObjectHandles,
        transactionId: 3,
        payload: Uint8List.fromList(List.generate(64, (i) => i)),
      );
      final c = decodeUsbContainer(b) as UsbDataContainer;
      expect(c.opcode, PtpOperationCode.getObjectHandles);
      expect(c.transactionId, 3);
      expect(c.payload, List.generate(64, (i) => i));
    });

    test('响应往返', () {
      final b = encodeUsbResponse(
        responseCode: PtpResponseCode.operationNotSupported,
        transactionId: 9,
      );
      final c = decodeUsbContainer(b) as UsbResponseContainer;
      expect(c.responseCode, PtpResponseCode.operationNotSupported);
      expect(c.transactionId, 9);
      expect(c.params, isEmpty);
    });

    test('长度字段与实际不符抛 FormatException', () {
      final b = encodeUsbCommand(opcode: 0x1002, transactionId: 0, params: [1]);
      expect(
        () => decodeUsbContainer(Uint8List.fromList(b.sublist(0, b.length - 1))),
        throwsFormatException,
      );
    });

    test('不足头部长度抛 FormatException', () {
      expect(
        () => decodeUsbContainer(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });

    test('未知类型抛 FormatException', () {
      // len=12 | type=9(非法)
      final b = Uint8List.fromList([
        0x0C, 0x00, 0x00, 0x00, //
        0x09, 0x00, 0x01, 0x20, //
        0x00, 0x00, 0x00, 0x00, //
      ]);
      expect(() => decodeUsbContainer(b), throwsFormatException);
    });

    test('参数区非 4 对齐抛 FormatException', () {
      // len=13 → 参数区 1 字节
      final b = Uint8List.fromList([
        0x0D, 0x00, 0x00, 0x00, //
        0x01, 0x00, 0x02, 0x10, //
        0x00, 0x00, 0x00, 0x00, //
        0x01, //
      ]);
      expect(() => decodeUsbContainer(b), throwsFormatException);
    });
  });

  group('事件容器(interrupt IN,头 12 字节 + u32 长度)', () {
    test('ObjectAdded:编码布局手算核对', () {
      final b = encodeUsbEvent(
        eventCode: PtpEventCode.objectAdded,
        transactionId: 0,
        params: [5],
      );
      // len=16(u32) | type=4 | eventCode=0x4002 | txid=0 | handle=5
      expect(b, [
        0x10, 0x00, 0x00, 0x00, //
        0x04, 0x00, //
        0x02, 0x40, //
        0x00, 0x00, 0x00, 0x00, //
        0x05, 0x00, 0x00, 0x00, //
      ]);
    });

    test('解码往返', () {
      final b = encodeUsbEvent(
        eventCode: PtpEventCode.devicePropChanged,
        transactionId: 2,
        params: [0x5005],
      );
      final c = decodeUsbEvent(b);
      expect(c.eventCode, PtpEventCode.devicePropChanged);
      expect(c.transactionId, 2);
      expect(c.params, [0x5005]);
    });

    test('无参数事件', () {
      final b = encodeUsbEvent(eventCode: PtpEventCode.captureComplete, transactionId: 4);
      expect(b.length, kUsbEventHeaderLength);
      final c = decodeUsbEvent(b);
      expect(c.eventCode, PtpEventCode.captureComplete);
      expect(c.params, isEmpty);
    });

    test('类型不为 4 抛 FormatException', () {
      final b = encodeUsbEvent(eventCode: PtpEventCode.objectAdded, transactionId: 0);
      b[4] = 0x03; // 篡改 type 字段(u32 长度之后)
      expect(() => decodeUsbEvent(b), throwsFormatException);
    });

    test('不足事件头长度抛 FormatException', () {
      expect(
        () => decodeUsbEvent(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsFormatException,
      );
    });
  });
}

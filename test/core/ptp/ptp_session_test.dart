import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_bridge/core/ptp/operation_codes.dart';
import 'package:nikon_bridge/core/ptp/ptp_session.dart';
import 'package:nikon_bridge/core/ptp/ptp_transport.dart';
import 'package:nikon_bridge/core/ptpusb/containers.dart';
import 'package:nikon_bridge/core/ptpusb/usb_transport.dart';
import 'package:nikon_bridge/core/utils/byte_writer.dart';

import '../ptpusb/fake_usb_byte_pipe.dart';

/// 假传输层:按序回放预置结果(PtpResult)或异常。
final class FakePtpTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final StreamController<PtpEvent> _eventCtrl = StreamController.broadcast();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 ${request.opcode.toRadixString(16)} 的响应');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    var result = next as PtpResult;
    if (onData != null && result.data != null) {
      // 模拟流式:数据切成两块回调,模拟大文件分块
      final d = result.data!;
      final mid = d.length ~/ 2;
      if (mid > 0) {
        onData(Uint8List.sublistView(d, 0, mid));
        onData(Uint8List.sublistView(d, mid));
        result = PtpResult(responseCode: result.responseCode, params: result.params);
      }
    }
    return result;
  }

  @override
  Stream<PtpEvent> get events => _eventCtrl.stream;

  @override
  Future<void> close() async {}
}

/// 手搓 GetDeviceInfo 数据集(ByteWriter;字段布局独立于被测代码)。
Uint8List buildDeviceInfoDataset() {
  final w = ByteWriter()
    ..u16(0x0100) // StandardVersion = 100(PTP/1.0)
    ..u32(0x0000000A) // VendorExtensionId(尼康)
    ..u16(0x0064); // VendorExtensionVersion
  putPtpString(w, 'Nikon'); // VendorExtensionDesc
  w.u16(0x0000); // FunctionalMode 标准
  // 五组 u32 计数 + u16 数组
  w
    ..u32(3)..u16(0x1001)..u16(0x1007)..u16(0x9431) // operations
    ..u32(1)..u16(0x4002) // events
    ..u32(2)..u16(0x5001)..u16(0x5007) // deviceProps
    ..u32(0) // captureFormats
    ..u32(2)..u16(0x3000)..u16(0x3801); // imageFormats
  putPtpString(w, 'Nikon Corp'); // manufacturer
  putPtpString(w, 'TestModel'); // model
  putPtpString(w, 'V1.00'); // deviceVersion
  putPtpString(w, '012345678901'); // serialNumber
  return w.takeBytes();
}

/// PTP STRING 数据集类型:u8 字符数 + UTF-16LE + 结尾 NUL(Zf 真机带 NUL)。
void putPtpString(ByteWriter w, String s) {
  w.u8(s.length + 1);
  w.utf16le(s);
  w.u16(0);
}

void main() {
  group('PtpDeviceInfo.parse', () {
    test('字段与五组数组完整解析,NUL 剥离', () {
      final info = PtpDeviceInfo.parse(buildDeviceInfoDataset());
      expect(info.standardVersion, 0x0100);
      expect(info.vendorExtensionId, 0x0000000A);
      expect(info.functionalMode, 0);
      expect(info.operationsSupported, [0x1001, 0x1007, 0x9431]);
      expect(info.eventsSupported, [0x4002]);
      expect(info.devicePropsSupported, [0x5001, 0x5007]);
      expect(info.captureFormats, isEmpty);
      expect(info.imageFormats, [0x3000, 0x3801]);
      expect(info.manufacturer, 'Nikon Corp');
      expect(info.model, 'TestModel');
      expect(info.deviceVersion, 'V1.00');
      expect(info.serialNumber, '012345678901');
      expect(info.supportsOperation(0x9431), isTrue);
      expect(info.supportsOperation(0x90C8), isFalse);
    });
  });

  group('会话生命周期', () {
    test('正常打开:一次 OpenSession 即成', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
      expect(fake.requests.map((r) => r.opcode),
          [PtpOperationCode.openSession]);
      expect(fake.requests.single.params, [1]);
    });

    test('0x201E 自动恢复:CloseSession 后重开(probe ensure_session 同款)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // CloseSession 的响应(内容不查)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        PtpOperationCode.openSession,
        PtpOperationCode.closeSession,
        PtpOperationCode.openSession,
      ]);
    });

    test('恢复中 CloseSession 抛异常也不阻断重开', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
        ..fail(TimeoutException('链路抖动'))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
    });

    test('打开失败抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      await expectLater(session.open(), throwsA(isA<PtpResponseException>()));
      expect(session.isSessionOpen, isFalse);
    });

    test('close 幂等且拔线不报错', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..fail(TimeoutException('相机已拔出'));
      final session = PtpSession(transport: fake);
      await session.open();
      await session.close(); // CloseSession 超时,但清理不抛
      await session.close(); // 未开会话,直接返回
      expect(session.isSessionOpen, isFalse);
    });
  });

  group('浏览/下载操作', () {
    test('getObjectHandles:u32 计数 + N 个 u32', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count=2
            0x11, 0x00, 0x00, 0x00, // 0x11
            0x22, 0x00, 0x00, 0x00, // 0x22
          ]),
        ));
      final session = PtpSession(transport: fake);
      final handles = await session.getObjectHandles();
      expect(handles, [0x11, 0x22]);
      // 默认参数 = Zf 语义全量枚举:storageAll / formatAll / parent=0
      final req = fake.requests.single;
      expect(req.params, [
        GetObjectHandlesParams.storageAll,
        GetObjectHandlesParams.formatAll,
        GetObjectHandlesParams.parentRoot,
      ]);
    });

    test('getObjectInfo:错误码抛 PtpResponseException 并带操作码', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)); // ObjectNotOpen-ish 非法态
      final session = PtpSession(transport: fake);
      try {
        await session.getObjectInfo(42);
        fail('应抛 PtpResponseException');
      } on PtpResponseException catch (e) {
        expect(e.opcode, PtpOperationCode.getObjectInfo);
        expect(e.responseCode, 0x2009);
      }
    });

    test('getObject:流式回调,错误码照样校验', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList(List.generate(10, (i) => i)),
        ));
      final session = PtpSession(transport: fake);
      final chunks = <Uint8List>[];
      await session.getObject(7, onData: chunks.add);
      expect(chunks.length, 2); // 假传输层切成两块
      expect(chunks.expand((c) => c), List.generate(10, (i) => i));
      expect(fake.requests.single.opcode, PtpOperationCode.getObject);
      expect(fake.requests.single.params, [7]);
    });

    test('getDeviceInfo 缓存:第二次不发请求', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      final info = await session.getDeviceInfo();
      expect(info.model, 'TestModel');
      await session.getDeviceInfo();
      expect(fake.requests.length, 1);
    });
  });

  group('字节级端到端:PtpSession over UsbPtpTransport over FakeUsbBytePipe', () {
    test('open → getObjectHandles 全链容器字节', () async {
      final pipe = FakeUsbBytePipe();
      final session = PtpSession(transport: UsbPtpTransport(pipe: pipe));

      // 相机脚本:OpenSession 响应 OK
      pipe.enqueue(encodeUsbResponse(responseCode: PtpResponseCode.ok, transactionId: 0));
      await session.open();

      // GetObjectHandles:DATA(count=2) + RESPONSE OK
      pipe.enqueue(encodeUsbData(
        opcode: PtpOperationCode.getObjectHandles,
        transactionId: 1,
        payload: Uint8List.fromList([
          0x02, 0x00, 0x00, 0x00, //
          0x11, 0x00, 0x00, 0x00, //
          0x22, 0x00, 0x00, 0x00, //
        ]),
      ));
      pipe.enqueue(encodeUsbResponse(responseCode: PtpResponseCode.ok, transactionId: 1));
      final handles = await session.getObjectHandles();
      expect(handles, [0x11, 0x22]);

      // 发出的两个命令容器:opcode 与 txid 递增
      expect(pipe.outWrites.length, 2);
      expect(pipe.outWrites[0][6], 0x02); // OpenSession 低字节
      expect(pipe.outWrites[0][8], 0); // txid=0
      expect(pipe.outWrites[1][6], 0x07); // GetObjectHandles 低字节
      expect(pipe.outWrites[1][8], 1); // txid=1
    });
  });
}

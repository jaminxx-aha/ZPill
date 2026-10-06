import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpusb/containers.dart';
import 'package:nikon_pill/core/ptpusb/usb_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

import '../ptpusb/fake_usb_byte_pipe.dart';

/// 门控应答:先等 [gate] 完成再回放(测「枚举途中」时序用)。
final class _GatedReply {
  const _GatedReply(this.gate, this.result);
  final Future<void> gate;
  final Object result; // PtpResult 或 Exception(延迟失败)
}

/// 假传输层:按序回放预置结果(PtpResult)或异常。
final class FakePtpTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();
  final StreamController<PtpEvent> _eventCtrl = StreamController.broadcast();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  /// 预置一个延迟应答:execute 在 [gate] 完成前挂起。
  void replyAfter(Future<void> gate, PtpResult result) =>
      script.add(_GatedReply(gate, result));

  /// 预置一个延迟失败:execute 在 [gate] 完成前挂起,然后抛 [e]。
  void failAfter(Future<void> gate, Exception e) =>
      script.add(_GatedReply(gate, e));

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 ${request.opcode.toRadixString(16)} 的响应');
    }
    var next = script.removeFirst();
    if (next is _GatedReply) {
      await next.gate;
      next = next.result;
    }
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

/// 首次 execute 挂在 [gate] 上不放行(验证串行锁排队的探针传输层)。
final class LockProbeTransport implements PtpTransport {
  LockProbeTransport(this.gate);

  final Completer<void> gate;
  final List<int> startedHandles = [];
  var _calls = 0;

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    startedHandles.add(request.params.single);
    if (_calls++ == 0) {
      await gate.future;
    }
    return PtpResult(
      responseCode: PtpResponseCode.ok,
      data: Uint8List.fromList([0xFF, 0xD8]),
    );
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

/// 手搓 GetDeviceInfo 数据集(ByteWriter;字段布局独立于被测代码)。
/// [operations] 可覆盖操作码表(默认不含 0x90C4,测「不在册」路径用)。
/// 默认操作码表 = 「正常相机」基线:GetDeviceInfo/OpenSession/GetObject/
/// GetPartialObjectEx(连接层的受限画像检查以 GetObject 在册为准,
/// 2026-10-01 真机受限态就是缺它)。
Uint8List buildDeviceInfoDataset(
    {List<int> operations = const [0x1001, 0x1007, 0x1009, 0x9431]}) {
  final w = ByteWriter()
    ..u16(0x0100) // StandardVersion = 100(PTP/1.0)
    ..u32(0x0000000A) // VendorExtensionId(尼康)
    ..u16(0x0064); // VendorExtensionVersion
  putPtpString(w, 'Nikon'); // VendorExtensionDesc
  w.u16(0x0000); // FunctionalMode 标准
  // 五组 u32 计数 + N 个 u16(计数与元素必须相邻)
  w.u32(operations.length);
  for (final op in operations) {
    w.u16(op);
  }
  w
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
      expect(info.operationsSupported, [0x1001, 0x1007, 0x1009, 0x9431]);
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

    test('getThumb:数据整体返回,参数为 handle', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
        ));
      final session = PtpSession(transport: fake);
      final data = await session.getThumb(0x11);
      expect(data, [0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);
      expect(fake.requests.single.opcode, PtpOperationCode.getThumb);
      expect(fake.requests.single.params, [0x11]);
    });

    test('getThumb:相机非 OK 响应抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getThumb(0x11), throwsA(isA<PtpResponseException>()));
    });

    test('deleteObject:params=[handle],OK 即成;非 OK 抛异常带操作码',
        () async {
      final ok = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: ok);
      await session.deleteObject(0x33);
      final req = ok.requests.single;
      expect(req.opcode, PtpOperationCode.deleteObject);
      expect(req.params, [0x33]);

      final denied = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)); // 非法态
      final session2 = PtpSession(transport: denied);
      try {
        await session2.deleteObject(0x33);
        fail('应抛 PtpResponseException');
      } on PtpResponseException catch (e) {
        expect(e.opcode, PtpOperationCode.deleteObject);
        expect(e.responseCode, 0x2009);
      }
    });

    test('getLargeThumb:在册即发 0x90C4,前置杂字节剥到 SOI', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: buildDeviceInfoDataset(
                operations: [0x1001, NikonOperationCode.getLargeThumb])))
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          // 3 字节尼康头 + JPEG SOI:防御「头 + JPEG」形态
          data: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xFF, 0xD8, 0xFF, 0xE2]),
        ));
      final session = PtpSession(transport: fake);
      final data = await session.getLargeThumb(0x22);
      expect(data, [0xFF, 0xD8, 0xFF, 0xE2]);
      expect(fake.requests[1].opcode, NikonOperationCode.getLargeThumb);
      expect(fake.requests[1].params, [0x22]);
    });

    test('getLargeThumb:码表不在册抛 UnsupportedError,不发操作', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      // buildDeviceInfoDataset 的操作码表不含 0x90C4
      await expectLater(
          session.getLargeThumb(0x22), throwsA(isA<UnsupportedError>()));
      expect(fake.requests.length, 1); // 只有 GetDeviceInfo
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

    test('getStorageIds:u32 计数 + N 个 u32(双卡槽)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, // 0x00010001
            0x01, 0x00, 0x02, 0x00, // 0x00020001
          ]),
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getStorageIds(), [0x00010001, 0x00020001]);
      expect(fake.requests.single.opcode, PtpOperationCode.getStorageIds);
    });

    test('getStorageInfo:params=[storageId],数据集完整解析', () async {
      final w = ByteWriter()
        ..u16(0x0004) // removableRAM
        ..u16(0x0002)
        ..u16(0x0000)
        ..u64(64000000000)
        ..u64(21000000000)
        ..u32(480)
        ..u8(7)..utf16le('Slot 1')..u16(0)
        ..u8(1)..u16(0); // volumeLabel 空串
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final storage = await session.getStorageInfo(0x00010001);
      expect(fake.requests.single.params, [0x00010001]);
      expect(storage.id, 0x00010001);
      expect(storage.isRemovable, isTrue);
      expect(storage.freeSpaceBytes, 21000000000);
      expect(storage.description, 'Slot 1');
    });

    test('getStorageInfo:相机非 OK(卡槽空)抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getStorageInfo(0x00010001), throwsA(isA<PtpResponseException>()));
    });
  });

  group('无线配对操作', () {
    test('getPairingCode:u32 计数 + 数字字节拼接成验证码(NiConn 抓包形态)',
        () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          // count=4 + 05 00 07 07 → "5077"(Zf STA op 表 0x952B)
          data: Uint8List.fromList([4, 0, 0, 0, 0x05, 0x00, 0x07, 0x07]),
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), '5077');
      expect(fake.requests.single.opcode, NikonOperationCode.getPtpIpPairingCode);
      expect(fake.requests.single.params, isEmpty);
    });

    test('getPairingCode:相机非 OK 响应 → null(多数 = 本客户端已配对)',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), isNull);
    });

    test('getPairingCode:载荷畸形(计数超长)→ null,不抛', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([9, 0, 0, 0, 1]), // count=9 但只有 1 字节
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), isNull);
    });

    test('completePairing:发 0x935A + param 0x2001,OK 即成', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.completePairing();
      expect(fake.requests.single.opcode, NikonOperationCode.completePairing);
      expect(fake.requests.single.params, [0x2001]);
    });

    test('completePairing:非 OK 抛 PtpResponseException', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.completePairing(), throwsA(isA<PtpResponseException>()));
    });
  });

  group('遥控操作', () {
    test('getDevicePropValue:fNumber 按 u16 解码,params=[propCode]', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([18, 0]), // u16 裸值
        ));
      final session = PtpSession(transport: fake);
      final v = await session.getDevicePropValue(PtpDevicePropCode.fNumber);
      expect(v.dataType, PtpDataType.uint16);
      expect(v.value, 18);
      expect(fake.requests.single.opcode, PtpOperationCode.getDevicePropValue);
      expect(fake.requests.single.params, [PtpDevicePropCode.fNumber]);
    });

    test('getDevicePropDesc:数据集字段完整解析', () async {
      final w = ByteWriter()
        ..u16(PtpDevicePropCode.exposureIndex)
        ..u16(PtpDataType.uint16.code)
        ..u8(1)
        ..u16(200)
        ..u8(0x02) // FORM 枚举
        ..u16(2)
        ..u16(100)..u16(6400);
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final d = await session.getDevicePropDesc(PtpDevicePropCode.exposureIndex);
      expect(d.currentValue, 200);
      expect(d.enumValues, [100, 6400]);
      expect(d.getSet, isTrue);
    });

    test('enableAppControl:0x9435 ok → true,单发无属性回退', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.single.opcode,
          NikonOperationCode.changeApplicationMode);
      expect(fake.requests.single.params, [1]);
    });

    test('enableAppControl:0x9435 被拒 → 回退写 ApplicationMode 0xD1F0=1',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(
          fake.requests[1].params, [PtpDevicePropCode.applicationMode]);
      expect(fake.requests[1].dataOut, Uint8List.fromList([1]));
    });

    test('enableAppControl:双拒 → false 不抛;不受拍摄参数总闸约束',
        () async {
      PtpSession.kSetPropEnabled = false; // 应用模式切换非拍摄参数写
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isFalse);
    });

    test('setDevicePropValue:总闸紧急关断抛 UnsupportedError 且不发请求',
        () async {
      PtpSession.kSetPropEnabled = false; // 生产已开,这里显式关断走分支
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final v = PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 18);
      await expectLater(
          session.setDevicePropValue(v), throwsA(isA<UnsupportedError>()));
      expect(fake.requests, isEmpty);
    });

    test('setDevicePropValue:总闸开(生产默认)→ 0x1016 带码参数与裸值数据',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final v = PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 320);
      await session.setDevicePropValue(v);
      expect(fake.requests, hasLength(1));
      expect(fake.requests.single.opcode,
          PtpOperationCode.setDevicePropValue);
      expect(fake.requests.single.params, [PtpDevicePropCode.fNumber]);
      expect(fake.requests.single.dataOut, Uint8List.fromList([0x40, 0x01]));
    });

    test('startLiveView/endLiveView:候选码直发,无参数', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.startLiveView();
      await session.endLiveView();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.startLiveView,
        NikonOperationCode.endLiveView,
      ]);
      expect(fake.requests.every((r) => r.params.isEmpty), isTrue);
    });

    test('getLiveViewImage:前置杂字节剥到 SOI(防御「头+JPEG」形态)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList(
              [0x01, 0x02, 0x03, 0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
        ));
      final session = PtpSession(transport: fake);
      final frame = await session.getLiveViewImage();
      expect(frame, [0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      expect(fake.requests.single.opcode, NikonOperationCode.getLiveViewImage);
    });

    test('initiateCapture:params 恒 [0, 0];0x2019 忙按异常上抛', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.initiateCapture(), throwsA(isA<PtpResponseException>()));
      expect(fake.requests.single.opcode, PtpOperationCode.initiateCapture);
      expect(fake.requests.single.params, [0, 0]);
    });

    test('无卡拍/落卡拍候选码直发;CaptureSort 首参(语义待真机核对)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.initiateCaptureRecInSdram();
      await session.initiateCaptureRecInMedia();
      await session.initiateCaptureRecInMedia(focusBeforeCapture: true);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.initiateCaptureRecInSdram,
        NikonOperationCode.initiateCaptureRecInMedia,
        NikonOperationCode.initiateCaptureRecInMedia,
      ]);
      // 默认保持 Zf 真机已实证的 [0,0];对焦后拍换 CaptureSort 首参
      expect(fake.requests[1].params, [0, 0]);
      expect(fake.requests[2].params, [0xFFFFFFFE, 0]);
    });

    test('对焦三 op:0x9205 双参直发 / 0x90C1、0x9206 无参(候选码)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.changeAfArea(320, 240);
      await session.afDrive();
      await session.afDriveCancel();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeAfArea,
        NikonOperationCode.afDrive,
        NikonOperationCode.afDriveCancel,
      ]);
      expect(fake.requests[0].params, [320, 240]);
      expect(fake.requests[1].params, isEmpty);
      expect(fake.requests[2].params, isEmpty);
    });

    test('deviceReady:0x2019 忙 → false(语义不是错误)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(transport: fake);
      expect(await session.deviceReady(), isFalse);
    });

    test('deviceReady:OK → true;其余响应码照常抛', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.deviceReady(), isTrue);
      await expectLater(
          session.deviceReady(), throwsA(isA<PtpResponseException>()));
    });
  });

  group('全局串行锁', () {
    test('并发操作排队:第二个不进传输层直到第一个完成', () async {
      final gate = Completer<void>();
      final fake = LockProbeTransport(gate);
      final session = PtpSession(transport: fake);

      final first = session.getThumb(1);
      final second = session.getThumb(2);
      await pumpEventQueue();
      expect(fake.startedHandles, [1]); // 第二个仍被锁挡在门外

      gate.complete();
      await Future.wait([first, second]);
      expect(fake.startedHandles, [1, 2]);
    });

    test('前一个失败不断链:后续操作照常执行', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: 0x2009)) // 第一次失败
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0xFF, 0xD8])));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getThumb(1), throwsA(isA<PtpResponseException>()));
      final data = await session.getThumb(2);
      expect(data, [0xFF, 0xD8]);
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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpusb/containers.dart';
import 'package:nikon_pill/core/ptpusb/usb_transport.dart';

import '../ptpusb/fake_usb_byte_pipe.dart';

import 'ptp_session_harness.dart';

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
      expect(info.serialNumber, '12345678901'); // 前导零剥除(方言归一)
      expect(info.supportsOperation(0x9431), isTrue);
      expect(info.supportsOperation(0x90C8), isFalse);
    });

    test('序列号 Zf 方言:定宽 32 左补零剥前导零;全零占位 → null', () {
      // 真机实测(2026-10-09 定案):Zf 回 25 个 '0' + 8014411,
      // 尾段与 mDNS 实例名 Z_f_8014411 同源。
      expect(
          PtpDeviceInfo.parse(buildDeviceInfoDataset(
                  serial: '00000000000000000000000008014411'))
              .serialNumber,
          '8014411');
      expect(
          PtpDeviceInfo.parse(buildDeviceInfoDataset(serial: '000000000000'))
              .serialNumber,
          isNull,
          reason: '全零占位视为未提供');
    });
  });
  group('会话生命周期', () {
    test('正常打开:一次 OpenSession 即成', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.open();
      expect(session.isSessionOpen, isTrue);
      expect(
          fake.requests.map((r) => r.opcode), [PtpOperationCode.openSession]);
      expect(fake.requests.single.params, [1]);
    });

    test('0x201E 自动恢复:CloseSession 后重开(probe ensure_session 同款)', () async {
      final fake = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.ok)) // CloseSession 的响应(内容不查)
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
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.sessionAlreadyOpen))
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
  group('无线配对操作', () {
    test('getPairingCode:u32 计数 + 数字字节拼接成验证码(NiConn 抓包形态)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          // count=4 + 05 00 07 07 → "5077"(Zf STA op 表 0x952B)
          data: Uint8List.fromList([4, 0, 0, 0, 0x05, 0x00, 0x07, 0x07]),
        ));
      final session = PtpSession(transport: fake);
      expect(await session.getPairingCode(), '5077');
      expect(
          fake.requests.single.opcode, NikonOperationCode.getPtpIpPairingCode);
      expect(fake.requests.single.params, isEmpty);
    });

    test('getPairingCode:相机非 OK 响应 → null(多数 = 本客户端已配对)', () async {
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
  group('取消-排水透传(cancelInFlight)', () {
    test('在途事务持锁时绕过串行锁立即返回(不排队死等)', () async {
      final gate = Completer<void>();
      final fake = FakePtpTransport()
        ..replyAfter(
            gate.future,
            PtpResult(
                responseCode: PtpResponseCode.ok,
                data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      final exec = session.getDeviceInfo(); // 持锁挂在相机闸上
      await pumpEventQueue();

      // 若 cancelInFlight 排队等锁,timeout 先到 → 失败可见
      final cancelled = await session
          .cancelInFlight()
          .timeout(const Duration(milliseconds: 200));
      expect(cancelled, isTrue);
      expect(fake.cancelInFlightCalls, 1);

      gate.complete();
      await exec; // 原事务不受牵连,照常完成(假件不真取消)
    });

    test('链路不支持(USB / 未实现能力)→ false no-op', () async {
      final session = PtpSession(transport: LockProbeTransport(Completer<void>()));
      expect(await session.cancelInFlight(), isFalse);
    });

    test('取消通道异常 → false 落回旧路径(取消不当失败放大)', () async {
      final session = PtpSession(transport: CancelFailingTransport());
      expect(await session.cancelInFlight(), isFalse);
    });
  });
  group('字节级端到端:PtpSession over UsbPtpTransport over FakeUsbBytePipe', () {
    test('open → getObjectHandles 全链容器字节', () async {
      final pipe = FakeUsbBytePipe();
      final session = PtpSession(transport: UsbPtpTransport(pipe: pipe));

      // 相机脚本:OpenSession 响应 OK
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 0));
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
      pipe.enqueue(encodeUsbResponse(
          responseCode: PtpResponseCode.ok, transactionId: 1));
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

  group('GetPartialObjectEx(0x9431)', () {
    test('u64 偏移/长度低高拆参,数据相原样返回', () async {
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      fake.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: payload,
        params: const [4, 0], // 实发字节数低/高(规格 §6.2.3.4 应答参数)
      ));

      // 偏移跨 4GB 边界(0x1_0000_0004)+ 长度 8MB:u64 拆分对账。
      final out =
          await session.getPartialObjectEx(0x1234, 0x100000004, 8 * 1024 * 1024);

      expect(out, payload);
      expect(
          fake.requests.single.opcode, NikonOperationCode.getPartialObjectEx);
      expect(fake.requests.single.params, [
        0x1234, // ObjectHandle
        4, 1, // Offset 低/高 32 位
        0x800000, 0, // MaxSize 低/高 32 位
      ]);
    });
  });

  group('GetPartialObjectHighSpeed(0x9400)', () {
    test('三参打包(handle/块长/终止位),应答游标低高拼合', () async {
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final payload = Uint8List.fromList([9, 8, 7]);
      fake.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: payload,
        // 实发字节数 + 执行前游标 offset 低/高(规格 §6.2.3.5 应答参数)
        params: const [3, 4, 1], // offset = 0x1_0000_0004
      ));

      final r = await session
          .getPartialObjectHighSpeed(0x1234, maxBytes: 16 * 1024 * 1024);

      expect(r.data, payload);
      expect(r.sentBytes, 3);
      expect(r.cursorOffset, 0x100000004);
      expect(fake.requests.single.opcode,
          NikonOperationCode.getPartialObjectHiSpeed);
      // 无 offset 参:游标在相机侧;Terminate 缺省 0。
      expect(fake.requests.single.params, [0x1234, 0x1000000, 0]);
    });

    test('Terminate=1 收态:终止位入参(规格:数据相恒 0 字节)', () async {
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      fake.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List(0),
        params: const [0, 0x800000, 0],
      ));

      await session.getPartialObjectHighSpeed(0x1234,
          maxBytes: 16 * 1024 * 1024, terminate: true);

      expect(fake.requests.single.params, [0x1234, 0x1000000, 1]);
    });
  });
}

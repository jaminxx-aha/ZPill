import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';


import 'ptp_session_harness.dart';

void main() {
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

    test('deleteObject:params=[handle],OK 即成;非 OK 抛异常带操作码', () async {
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

    test('getLargeThumb:非 JPEG 载荷(无 SOI)→ UnsupportedError + 会话降级秒拒', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            // NEF 压缩条带形态:整段无 FFD8
            data: Uint8List.fromList(List.filled(64, 0x55))));
      final session = PtpSession(transport: fake);
      await expectLater(session.getLargeThumb(0x22, force: true),
          throwsA(isA<UnsupportedError>()));
      expect(session.largeThumbDegraded, isTrue);
      // 降级后:force 直发秒拒(不再上链浪费 RTT)
      await expectLater(session.getLargeThumb(0x23, force: true),
          throwsA(isA<UnsupportedError>()));
      expect(fake.requests.length, 1);
    });

    test('getLargeThumb:超时 → 会话降级;open() 开新会话复位重探', () async {
      final fake = FakePtpTransport()
        ..fail(TimeoutException('bulkRead 窗口内未收到数据'))
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)) // openSession
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])));
      final session = PtpSession(transport: fake);
      await expectLater(session.getLargeThumb(0x22, force: true),
          throwsA(isA<TimeoutException>()));
      expect(session.largeThumbDegraded, isTrue);

      // 新会话:降级旗标复位,重新真发并成功
      await session.open();
      expect(session.largeThumbDegraded, isFalse);
      expect(await session.getLargeThumb(0x22, force: true),
          [0xFF, 0xD8, 0xFF, 0xD9]);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLargeThumb, // 首试(超时,置旗标)
        PtpOperationCode.openSession, // 新会话
        NikonOperationCode.getLargeThumb, // 复位后重探
      ]);
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

    test('cachedDeviceInfo:未取为 null,取后可读(纯读零流量)', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: buildDeviceInfoDataset()));
      final session = PtpSession(transport: fake);
      expect(session.cachedDeviceInfo, isNull);
      await session.getDeviceInfo();
      expect(session.cachedDeviceInfo?.model, 'TestModel');
      expect(fake.requests.length, 1, reason: 'cachedDeviceInfo 不发事务');
    });

    test('getEventEx:0x941C 事件列表解析(u32 计数 + N×(u16 码 + u16 参数数 + 参数))',
        () async {
      final w = ByteWriter()
        ..u32(2)
        // 0x4006 DevicePropChanged,1 参数(0x5007)
        ..u16(PtpEventCode.devicePropChanged)
        ..u16(1)
        ..u32(PtpDevicePropCode.fNumber)
        // 0x4002 ObjectAdded,1 参数(handle)
        ..u16(PtpEventCode.objectAdded)
        ..u16(1)
        ..u32(0x1234);
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final events = await session.getEventEx();
      expect(fake.requests.single.opcode, NikonOperationCode.getEventEx);
      expect(events, hasLength(2));
      expect(events[0].code, PtpEventCode.devicePropChanged);
      expect(events[0].params, [PtpDevicePropCode.fNumber]);
      expect(events[1].code, PtpEventCode.objectAdded);
      expect(events[1].params, [0x1234]);
    });

    test('事件并流:轮询注入与异步通道同时可达消费者', () async {
      final fake = FakePtpTransport();
      final session = PtpSession(transport: fake);
      final seen = <int>[];
      final sub = session.events.listen((e) => seen.add(e.code));
      fake.emitEvent(const PtpEvent(
          code: PtpEventCode.captureComplete, transactionId: 0xFFFFFFFF));
      session.emitPolledEvents([
        const PtpEvent(
            code: PtpEventCode.objectAdded,
            transactionId: 0xFFFFFFFF,
            params: [1]),
      ]);
      await pumpEventQueue();
      expect(
          seen,
          containsAll(
              [PtpEventCode.captureComplete, PtpEventCode.objectAdded]));
      await sub.cancel();
    });

    test('mfDrive:0x9204 params [方向, 脉冲](钳 1..32767);结果分类', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.ok)) // 0x90C8 就绪探:完成
        ..reply(const PtpResult(responseCode: NikonResponseCode.mfDriveStepEnd))
        ..reply(const PtpResult(
            responseCode: NikonResponseCode.mfDriveStepInsufficiency))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.mfDrive(towardNear: true, pulses: 999999),
          MfDriveOutcome.complete,
          reason: '激活 OK + 就绪探 OK:完成');
      expect(fake.requests.first.params, [1, 32767], reason: '钳到上限');
      expect(await session.mfDrive(towardNear: false, pulses: 300),
          MfDriveOutcome.endOfTravel,
          reason: '激活即回 0xA00C(他机身方言兼容路径),无需就绪探');
      expect(fake.requests.last.params, [2, 300], reason: '向远 = 2');
      expect(await session.mfDrive(towardNear: true, pulses: 1),
          MfDriveOutcome.stepTooSmall);
      expect(await session.mfDrive(towardNear: true, pulses: 0),
          MfDriveOutcome.refused,
          reason: '0 钳到 1,但响应 invalidStatus → refused');
    });

    test('mfDrive 收尾:激活 OK 后完成态经 0x90C8 就绪轮询读回(§6.2.5.3)',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 激活:已开始
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.deviceBusy)) // 驱动中
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.deviceBusy)) // 驱动中
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 完成
      final session = PtpSession(
          transport: fake, mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.complete);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.mfDrive,
        NikonOperationCode.deviceReady,
        NikonOperationCode.deviceReady,
        NikonOperationCode.deviceReady,
      ], reason: '首探立即,忙两拍后完成');
    });

    test('mfDrive 收尾:就绪探回 0xA00C 尽头 / 0xA00E 过小,按结果归因',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: NikonResponseCode.mfDriveStepEnd))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(
            responseCode: NikonResponseCode.mfDriveStepInsufficiency));
      final session = PtpSession(
          transport: fake, mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.endOfTravel, reason: '就绪探 0xA00C = 行程尽头');
      expect(await session.mfDrive(towardNear: false, pulses: 300),
          MfDriveOutcome.stepTooSmall, reason: '就绪探 0xA00E = 步进过小');
    });

    test('mfDrive 收尾:就绪轮询拍数用尽 → 乐观按已派出(complete)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy))
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      final session = PtpSession(
          transport: fake,
          mfReadyPolls: 2,
          mfReadyPollInterval: Duration.zero);
      expect(await session.mfDrive(towardNear: true, pulses: 300),
          MfDriveOutcome.complete,
          reason: '超时不判失败:驱动已接受,端点归因下一拍自愈');
      expect(
          fake.requests
              .where((r) => r.opcode == NikonOperationCode.deviceReady),
          hasLength(2));
    });

    test('录制双 op:0x920A 无参起录 / 0x920B 无参停录', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.startMovieRec();
      await session.endMovieRec();
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.startMovieRecInCard,
        NikonOperationCode.endMovieRec,
      ]);
      expect(fake.requests.first.params, isEmpty);
    });

    test('Ex 属性码路由:>0xFFFF 读走 0x943B / 写走 0x943C,标准码不变', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([2]))) // 主体检测读:u8 = 2(人)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final v = await session.getDevicePropValue(0x0001D006);
      expect(v.value, 2);
      expect(
          fake.requests.first.opcode, NikonOperationCode.getDevicePropValueEx);
      expect(fake.requests.first.params, [0x0001D006]);
      await session.setDevicePropValue(PtpDevicePropValue(
          code: 0x0001D006, dataType: PtpDataType.uint8, value: 3));
      expect(
          fake.requests.last.opcode, NikonOperationCode.setDevicePropValueEx);
      // 标准码不受影响
      fake.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 280));
      expect(fake.requests.last.opcode, PtpOperationCode.setDevicePropValue);
    });

    test('相机时钟:读 0x5011(PTP STR);漂移 > 5s 写回,≤ 5s 不写', () async {
      String strOf(DateTime t) {
        String two(int v) => v.toString().padLeft(2, '0');
        return '${t.year}${two(t.month)}${two(t.day)}T'
            '${two(t.hour)}${two(t.minute)}${two(t.second)}';
      }

      final now = DateTime(2026, 10, 6, 12, 0, 0);
      // PTP 字符串数据集:u8 字符数(含结尾 NUL)+ UTF16LE + NUL
      ByteWriter clockBytes(DateTime t) {
        final w = ByteWriter()..u8(16); // 15 字符 + NUL
        for (final c in strOf(t).codeUnits) {
          w.u16(c);
        }
        w.u16(0);
        return w;
      }

      // 相机慢 10 秒:测试自读一次 + sync 内部再读一次 + 写
      final slowBytes =
          clockBytes(now.subtract(const Duration(seconds: 10))).takeBytes();
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: slowBytes))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: slowBytes))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final read = await session.getCameraClock();
      expect(read, DateTime(2026, 10, 6, 11, 59, 50));
      await session.syncCameraClock(now: now);
      expect(fake.requests, hasLength(3), reason: '自读 + sync 读 + 写');
      expect(fake.requests.last.opcode, PtpOperationCode.setDevicePropValue);
      expect(fake.requests.last.params, [PtpDevicePropCode.dateTime]);

      // 相机只慢 2 秒:读后不写
      final fake2 = FakePtpTransport()
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: clockBytes(now.subtract(const Duration(seconds: 2)))
                .takeBytes()));
      final session2 = PtpSession(transport: fake2);
      await session2.syncCameraClock(now: now);
      expect(fake2.requests, hasLength(1), reason: '漂移在阈内:只读不写');
    });

    test(
        'changeCameraMode:0x90C2 params=[mode](APP 接管控制);非 OK 抛异常;'
        'remoteModeActive 随成功应答同步、被拒不翻', () async {
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.changeCameraMode(1);
      expect(fake.requests.single.opcode, NikonOperationCode.changeCameraMode);
      expect(fake.requests.single.params, [1]);
      expect(session.remoteModeActive, isTrue, reason: '0x90C2(1) 成功即置位');

      fake.reply(
          PtpResult(responseCode: NikonResponseCode.changeCameraModeFailed));
      await expectLater(
          session.changeCameraMode(0), throwsA(isA<PtpResponseException>()));
      expect(fake.requests.last.params, [0]);
      expect(session.remoteModeActive, isTrue, reason: '解除被拒不翻旗(相机侧模式未变)');

      fake.reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeCameraMode(0);
      expect(session.remoteModeActive, isFalse, reason: '解除成功即熄');
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
        ..u8(7)
        ..utf16le('Slot 1')
        ..u16(0)
        ..u8(1)
        ..u16(0); // volumeLabel 空串
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
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
      await expectLater(session.getStorageInfo(0x00010001),
          throwsA(isA<PtpResponseException>()));
    });
  });
}

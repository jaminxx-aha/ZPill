import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';


import 'ptp_session_harness.dart';

void main() {
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
        ..u16(100) // 出厂默认值(值区第一个,gphoto2 权威顺序)
        ..u16(200) // 当前值(值区第二个)
        ..u8(0x02) // FORM 枚举
        ..u16(2)
        ..u16(100)
        ..u16(6400);
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      final session = PtpSession(transport: fake);
      final d =
          await session.getDevicePropDesc(PtpDevicePropCode.exposureIndex);
      expect(d.currentValue, 200);
      expect(d.factoryValue, 100);
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

    test('enableAppControl:0x9435 拒 → 直落 0xD1F0 兜底(不写身份、不重试)', () async {
      // OpenZCine 全程不写 0xD406 身份(写身份会让机身把主机按新身份
      // 归类、停「已连接到计算机」屏),连接链因此没有身份段。
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
      expect(fake.requests[1].params, [PtpDevicePropCode.applicationMode]);
      expect(fake.requests[1].dataOut, Uint8List.fromList([1]));
    });

    test(
        'enableAppControl:0x9435 回 0x200F(USB 人设)→ 同样直落 0xD1F0'
        '(拒绝码不分支,非 OK 一律走兜底)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.accessDenied))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(fake.requests[1].params, [PtpDevicePropCode.applicationMode]);
    });

    test('enableAppControl:全拒 → false 不抛;不受拍摄参数总闸约束', () async {
      PtpSession.kSetPropEnabled = false; // 应用模式切换非拍摄参数写
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported))
        ..reply(const PtpResult(responseCode: PtpResponseCode.generalError));
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isFalse);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        PtpOperationCode.setDevicePropValue, // 0xD1F0 兜底(仍拒)
      ]);
    });

    test('writeInitiatorIdentity:载荷 = PTP 串(u8 字符数 + UTF-16LE 无终止符)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      expect(await session.writeInitiatorIdentity(), isTrue);
      final req = fake.requests.single;
      expect(req.opcode, PtpOperationCode.setDevicePropValue);
      expect(req.params, [PtpDevicePropCode.sessionInitiatorInfo]);
      // 'NikonPill' PTP 字符串:u8 计数(字符数,不含 NUL)+ UTF-16LE,
      // 无终止符 —— 与探针 ptp_str 同款(Zf USB 实证载荷,2026-10-07)。
      final expected = <int>[9];
      for (final cu in 'NikonPill'.codeUnits) {
        expected.addAll([cu & 0xFF, cu >> 8]);
      }
      expect(req.dataOut, Uint8List.fromList(expected));
    });

    test('writeInitiatorIdentity:被拒/链路异常 → false 不抛', () async {
      final rejected = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported));
      expect(await PtpSession(transport: rejected).writeInitiatorIdentity(),
          isFalse);
      // 脚本耗尽(execute 抛 StateError)也兜住:尽力而为语义。
      final dead = FakePtpTransport();
      expect(
          await PtpSession(transport: dead).writeInitiatorIdentity(), isFalse);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 拒(USB 人设)→ '
        '0x90C2(1)→(0) 开闩括号 → true,remoteModeActive 归 false(2026-10-07 '
        'v8/v9 定案:上传优先门单向闩,开了不因退而关;remote 持有态才是'
        '「已连接到计算机」屏元凶,开闩即还身,机身直回取景屏)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(fake.requests[1].params, [1]);
      expect(fake.requests[2].params, [0], reason: '开闩即还身:1→0 背靠背');
      expect(session.remoteModeActive, isFalse, reason: '括号已退 remote');
    });

    test(
        'enableAppControl(remoteLatch):0x9435 回 OK(IC 假钥匙)→ '
        '仍走 0x90C2(1)→(0) 括号(2026-10-07 归因梯定案:0x9435 接受 ≠ '
        '解锁 0x9201,唯一实证开闩钥匙 = 0x90C2(1)),梯记三步', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(fake.requests[1].params, [1]);
      expect(fake.requests[2].params, [0]);
      expect(session.remoteModeActive, isFalse);
      expect(session.connectLadder, ['9435:OK', '90C2:OK', '90C2退:OK']);
    });

    test(
        'enableAppControl(remoteLatch):0x90C2(0) 退步被拒 → 仍 true '
        '(闩已开,流不受影响),remoteModeActive 保持 true(接管侧如实对齐,'
        '退由 teardown 兜底)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)); // 0x90C2(0) 拒
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(session.remoteModeActive, isTrue, reason: '退被拒 = remote 仍持有');
      expect(session.connectLadder, ['9435:OK', '90C2:OK', '90C2退:拒']);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 OK + 0x90C2 拒 → '
        '仍 true(应用模式已接受,不发 0xD1F0),梯记拒码;open() 清梯', () async {
      final fake = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)) // OpenSession
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x9435
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)); // 0x90C2(1) 拒
      final session = PtpSession(transport: fake);
      session.noteLadder('旧账');
      await session.open();
      expect(session.connectLadder, isEmpty, reason: 'open() 一连接一账');
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        PtpOperationCode.openSession,
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
      ]);
      expect(session.remoteModeActive, isFalse, reason: '0x90C2 被拒不置位');
      expect(session.connectLadder, ['9435:OK', '90C2:0x2005']);
    });

    test(
        'enableAppControl(remoteLatch):0x9435 链路异常 → '
        '0x90C2 兜底照走(尽力而为,异常不得拦连接主流程)', () async {
      // 首发传输层异常(execute 抛)也落兜底:on Object 兜底语义。
      final fake = FakePtpTransport()
        ..fail(Exception('链路异常')) // 0x9435 抛
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0x90C2(0)
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        NikonOperationCode.changeCameraMode,
      ]);
    });

    test(
        'enableAppControl(remoteLatch):0x90C2 也拒 → 0xD1F0 兜底 → '
        'true,remoteModeActive 不置位', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(
            responseCode:
                PtpResponseCode.operationNotSupported)) // 0x90C2 op 缺席
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0xD1F0
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(remoteLatch: true), isTrue);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        PtpOperationCode.setDevicePropValue,
      ]);
      expect(fake.requests[2].params, [PtpDevicePropCode.applicationMode]);
      expect(fake.requests[2].dataOut, Uint8List.fromList([1]));
      expect(session.remoteModeActive, isFalse, reason: '0x90C2 被拒不置位');
    });

    test('enableAppControl(remoteLatch):三段全拒 → false 不抛', () async {
      final allRejected = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x90C2 拒
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.generalError)); // 0xD1F0 拒
      final session2 = PtpSession(transport: allRejected);
      expect(await session2.enableAppControl(remoteLatch: true), isFalse);
      expect(allRejected.requests.map((r) => r.opcode), [
        NikonOperationCode.changeApplicationMode,
        NikonOperationCode.changeCameraMode,
        PtpOperationCode.setDevicePropValue,
      ]);
    });

    test(
        'enableAppControl:不带 usbRemoteFallback(无线调用形态)→ '
        '0x90C2 不发,链与旧版一致', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported)) // 0x9435
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)); // 0xD1F0
      final session = PtpSession(transport: fake);
      expect(await session.enableAppControl(), isTrue);
      expect(
          fake.requests
              .where((r) => r.opcode == NikonOperationCode.changeCameraMode),
          isEmpty,
          reason: 'latch 不开就不发 0x90C2(接口默认语义;连接流两路现在都开)');
    });

    test('remoteModeActive 生命周期:close()/open() 复位(旧链持有态不带到新链)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // 0x90C2(1)
        ..reply(
            const PtpResult(responseCode: PtpResponseCode.ok)); // openSession
      final session = PtpSession(transport: fake);
      await session.changeCameraMode(1);
      expect(session.remoteModeActive, isTrue);
      await session.close();
      expect(session.remoteModeActive, isFalse, reason: 'close 即复位');
      await session.open();
      expect(session.remoteModeActive, isFalse, reason: 'open 新链仍为空');
    });

    test('setDevicePropValue:总闸紧急关断抛 UnsupportedError 且不发请求', () async {
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

    test('setDevicePropValue:总闸开(生产默认)→ 0x1016 带码参数与裸值数据', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      final v = PtpDevicePropValue(
          code: PtpDevicePropCode.fNumber,
          dataType: PtpDataType.uint16,
          value: 320);
      await session.setDevicePropValue(v);
      expect(fake.requests, hasLength(1));
      expect(fake.requests.single.opcode, PtpOperationCode.setDevicePropValue);
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

    test('getLiveViewObject:默认 0x9428 取帧,原样返回(帧头解析留给上层)', () async {
      final raw = Uint8List.fromList(
          [0x00, 0x64, 0x00, 0x00, 0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      final object = await session.getLiveViewObject();
      expect(object, same(raw));
      expect(
          fake.requests.single.opcode, NikonOperationCode.getLiveViewImageEx);
    });

    test('getLiveViewObject:0x9428 被拒 → 本拍抛错,下一拍起走 0x9203', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.getLiveViewImageEx,
            responseCode: 0x2005)) // OperationNotSupported
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      final object = await session.getLiveViewObject();
      expect(object, same(raw));
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImage,
      ]);
    });

    test('getLiveViewObject:0x2019 忙不置回退旗标(继续 0x9428 重试)', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw));
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      await session.getLiveViewObject();
      // 忙是瞬时态,两次都必须是 Ex 码(忙即降级会永久锁死旧码)
      expect(
          fake.requests
              .every((r) => r.opcode == NikonOperationCode.getLiveViewImageEx),
          isTrue);
    });

    test('getLiveViewObject:startLiveView 重置回退旗标(换机自愈)', () async {
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final fake = FakePtpTransport()
        ..fail(const PtpResponseException(
            opcode: NikonOperationCode.getLiveViewImageEx,
            responseCode: 0x2005))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: raw)) // 0x9203
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok)) // start
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: raw)); // Ex
      final session = PtpSession(transport: fake);
      await expectLater(
          session.getLiveViewObject(), throwsA(isA<PtpResponseException>()));
      await session.getLiveViewObject(); // 走 0x9203
      await session.startLiveView(); // 重置旗标
      await session.getLiveViewObject(); // 回到 0x9428
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.getLiveViewImageEx,
        NikonOperationCode.getLiveViewImage,
        NikonOperationCode.startLiveView,
        NikonOperationCode.getLiveViewImageEx,
      ]);
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

    test('无卡拍/落卡拍候选码直发;CaptureSort 首参(OpenZCine 形态)', () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(const PtpResult(responseCode: PtpResponseCode.ok));
      final session = PtpSession(transport: fake);
      await session.initiateCaptureRecInSdram();
      await session.initiateCaptureRecInMedia();
      await session.initiateCaptureRecInMedia(captureSort: 0xFFFFFFFE);
      expect(fake.requests.map((r) => r.opcode), [
        NikonOperationCode.initiateCaptureRecInSdram,
        NikonOperationCode.initiateCaptureRecInMedia,
        NikonOperationCode.initiateCaptureRecInMedia,
      ]);
      // 默认 0xFFFFFFFF 直接释放(preserveFocus 形态);显式 0xFFFFFFFE 先 AF
      expect(fake.requests[1].params, [0xFFFFFFFF, 0]);
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

    test(
        'deviceReady:0xA200/0xA201(Bulb/Silent_Release_Busy,官方'
        ' §2.8.4 步 5 / §6.3.2.15-16)→ false 继续等,不抛', () async {
      // B 门曝光进行中 DeviceReady 即回 0xA200(官方 B 门序列步 5);
      // 0xA201 静音快门同族 —— 收门/落定等待据此继续等。
      final bulb = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: NikonResponseCode.bulbReleaseBusy));
      expect(await PtpSession(transport: bulb).deviceReady(), isFalse);
      final silent = FakePtpTransport()
        ..reply(
            const PtpResult(responseCode: NikonResponseCode.silentReleaseBusy));
      expect(await PtpSession(transport: silent).deviceReady(), isFalse);
    });

    test(
        'getPictureControlName:0x90CC params=[槽位,0],name=数据[3..23) NUL 截断'
        '(digiCamControl 布局)', () async {
      final data = Uint8List(40); // [3..23) 名区,余 NUL 填充
      data[1] = 1; // 单色标志
      data[2] = 1; // 自定义标志
      const name = 'My Landscape';
      for (var i = 0; i < name.length; i++) {
        data[3 + i] = name.codeUnitAt(i);
      }
      final fake = FakePtpTransport()
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: data));
      final session = PtpSession(transport: fake);
      expect(await session.getPictureControlName(201), 'My Landscape');
      final req = fake.requests.single;
      expect(req.opcode, NikonOperationCode.getPictCtrlData);
      expect(req.params, [201, 0]);
    });

    test('getPictureControlName:短数据(<23B)/ 空名 / 纯空白 → null 不抛', () async {
      final blanks = Uint8List(32);
      for (var i = 3; i < 8; i++) {
        blanks[i] = 0x20; // 空格,trim 后为空
      }
      final fake = FakePtpTransport()
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(10)))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(32)))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: blanks));
      final session = PtpSession(transport: fake);
      expect(await session.getPictureControlName(201), isNull, reason: '短数据');
      expect(await session.getPictureControlName(202), isNull,
          reason: '名区全 NUL');
      expect(await session.getPictureControlName(203), isNull,
          reason: '纯空白 trim 后为空');
    });

    test('getPictureControlName:非 OK 抛 PtpResponseException(控制器首异常即停)',
        () async {
      final fake = FakePtpTransport()
        ..reply(const PtpResult(
            responseCode: PtpResponseCode.operationNotSupported));
      final session = PtpSession(transport: fake);
      await expectLater(session.getPictureControlName(301),
          throwsA(isA<PtpResponseException>()));
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
  group('官方指令书扩展通道(2026-10-12):保护标记 / 厂商码表 / 4 字节包装 op', () {
    late FakePtpTransport t;
    late PtpSession session;
    setUp(() {
      t = FakePtpTransport();
      session = PtpSession(transport: t);
    });

    test('setObjectProtection:params=[句柄, 0x0000/0x0001](§6.2.1.14)', () async {
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.setObjectProtection(0x1234, protect: true);
      await session.setObjectProtection(0x1234, protect: false);
      expect(t.requests.map((r) => r.opcode), [
        PtpOperationCode.setObjectProtection,
        PtpOperationCode.setObjectProtection
      ]);
      expect(t.requests.first.params, [0x1234, 0x0001]);
      expect(t.requests.last.params, [0x1234, 0x0000]);
    });

    test('getVendorCodes:u32 计数 + N×u32 码;0x09=操作码表 / 0x0D=属性码表', () async {
      final table = Uint8List.fromList([
        0x03, 0x00, 0x00, 0x00, //
        0x39, 0x94, 0x00, 0x00, //
        0x01, 0xD0, 0x01, 0x00, // 0x0001D001(4 字节扩展形态)
        0x28, 0x94, 0x00, 0x00,
      ]);
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: table))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok, data: table));
      final ops = await session.getVendorCodes(deviceProps: false);
      final props = await session.getVendorCodes(deviceProps: true);
      expect(t.requests.first.params, [0x09]);
      expect(t.requests.last.params, [0x0D]);
      expect(ops, [0x9439, 0x0001D001, 0x9428]);
      expect(props, ops);
    });

    test('getVendorCodes:空表 / 数据不足 4B → 空列表不炸', () async {
      t
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok,
            data: Uint8List.fromList([0, 0, 0, 0])))
        ..reply(
            PtpResult(responseCode: PtpResponseCode.ok, data: Uint8List(2)));
      expect(await session.getVendorCodes(deviceProps: false), isEmpty);
      expect(await session.getVendorCodes(deviceProps: true), isEmpty);
    });

    test('extendedOperationNone/Receive/Send:P1=扩展码,参数透传', () async {
      t
        ..reply(PtpResult(responseCode: PtpResponseCode.ok))
        ..reply(PtpResult(
            responseCode: PtpResponseCode.ok, data: Uint8List.fromList([7])))
        ..reply(PtpResult(responseCode: PtpResponseCode.ok));
      await session.extendedOperationNone(0x0001D006, params: [1, 2]);
      final got = await session.extendedOperationReceive(0x0001D001);
      await session.extendedOperationSend(0x0001D048,
          params: [3], data: Uint8List.fromList([9]));
      expect(t.requests.map((r) => r.opcode).toList(), [
        NikonOperationCode.operationDataNone,
        NikonOperationCode.operationReceiveData,
        NikonOperationCode.operationSendData,
      ]);
      expect(t.requests[0].params, [0x0001D006, 1, 2]);
      expect(t.requests[1].params, [0x0001D001]);
      expect(t.requests[2].params, [0x0001D048, 3]);
      expect(t.requests[2].dataOut, [9]);
      expect(got.data, [7]);
    });

    test(
        'getDevicePropDesc:Ex 码(>0xFFFF)路由 0x943A,u32 码定宽解析'
        '(2026-10-13 USB 探针实证 0x0001D001 色调)', () async {
      // 探针实录数据集:code u32 + u8 型 + getSet + 出厂 + 当前 + 枚举{0,1,2}
      final exDesc = Uint8List.fromList([
        0x01, 0xD0, 0x01, 0x00, // 0x0001D001(u32 LE)
        0x02, 0x00, // UINT8
        0x01, // getSet = 可写
        0x00, // 出厂 = 0(SDR,官方默认)
        0x02, // 当前 = 2(HLG,相机实际值)
        0x02, 0x03, 0x00, 0x00, 0x01, 0x02, // 枚举 3 值 {0,1,2}
      ]);
      t.reply(PtpResult(responseCode: PtpResponseCode.ok, data: exDesc));
      final d = await session.getDevicePropDesc(0x0001D001);
      expect(t.requests.single.opcode, NikonOperationCode.getDevicePropDescEx);
      expect(t.requests.single.params, [0x0001D001]);
      expect(d.dataType, PtpDataType.uint8);
      expect(d.getSet, isTrue);
      expect(d.factoryValue, 0);
      expect(d.currentValue, 2);
      expect(d.enumValues, [0, 1, 2]);
    });
  });
  group('官方指令书候选区接线(2026-10-13 探针批 + §6.2 规格比对)', () {
    late FakePtpTransport t;
    late PtpSession session;
    setUp(() {
      t = FakePtpTransport();
      session = PtpSession(transport: t);
    });

    test(
        'getFhdPicture:params=[句柄],JPEG SOI 嗅探;0xA00F 无 FHD 抛'
        'PtpResponseException', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0xFF, 0xD8, 1, 2, 3])));
      final jpeg = await session.getFhdPicture(0x1234);
      final req = t.requests.single;
      expect(req.opcode, NikonOperationCode.getFhdPicture);
      expect(req.params, [0x1234]);
      expect(jpeg, [0xFF, 0xD8, 1, 2, 3]);

      // 「头 + JPEG」形态:SOI 嗅探剥头
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([3, 0, 0, 0, 0xFF, 0xD8, 9])));
      expect(await session.getFhdPicture(1), [0xFF, 0xD8, 9]);

      t.reply(const PtpResult(responseCode: NikonResponseCode.noFullHdPresent));
      await expectLater(
          session.getFhdPicture(1), throwsA(isA<PtpResponseException>()));
    });

    test(
        'changeAELock:params=[1,2] 锁 / [0,2] 解锁(探针双 OK 形),'
        'type 可指定', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: true);
      expect(t.requests.single.opcode, NikonOperationCode.changeAELock);
      expect(t.requests.single.params, [1, 2]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: false);
      expect(t.requests.last.params, [0, 2]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeAELock(lock: true, type: 0);
      expect(t.requests.last.params, [1, 0]);
    });

    test('startTracking/endTracking:参数同 0x9205 两参 / 无参', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.startTracking(3024, 2016);
      expect(t.requests.single.opcode, NikonOperationCode.startTracking);
      expect(t.requests.single.params, [3024, 2016]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.endTracking();
      expect(t.requests.last.opcode, NikonOperationCode.endTracking);
      expect(t.requests.last.params, isEmpty);
    });

    test('clearEvent/afAndCaptureRecInSdram/saveCameraSetting:无参直发', () async {
      for (final _ in [
        NikonOperationCode.clearEvent,
        NikonOperationCode.afAndCaptureRecInSdram,
        NikonOperationCode.saveCameraSetting,
      ]) {
        t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      }
      await session.clearEvent();
      await session.afAndCaptureRecInSdram();
      await session.saveCameraSetting();
      expect(t.requests.map((r) => r.opcode).toList(), [
        NikonOperationCode.clearEvent,
        NikonOperationCode.afAndCaptureRecInSdram,
        NikonOperationCode.saveCameraSetting,
      ]);
      expect(t.requests.every((r) => r.params.isEmpty), isTrue);
    });

    test('changeMonitorOff:params=[1] 强制关 / [0] 取消(§6.2.2.17)', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeMonitorOff(off: true);
      expect(t.requests.single.opcode, NikonOperationCode.changeMonitorOff);
      expect(t.requests.single.params, [1]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.changeMonitorOff(off: false);
      expect(t.requests.last.params, [0]);
    });

    test('getCameraSettingData:64B 文件名(63+NUL)+ 文件体拆分', () async {
      final name = 'Z7_2_01012026.NCSETUTF8'.codeUnits;
      final dataset = <int>[
        ...name,
        ...List.filled(64 - name.length, 0), // NUL 填充到 64B
        0xDE, 0xAD, 0xBE, 0xEF, // 文件体
      ];
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok, data: Uint8List.fromList(dataset)));
      final setting = await session.getCameraSettingData();
      expect(t.requests.single.opcode, NikonOperationCode.getCameraSettingData);
      expect(setting.name, 'Z7_2_01012026.NCSETUTF8');
      expect(setting.data, [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('sendCameraSettingData:dataOut = 64B 文件名 + 文件体', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.sendCameraSettingData('AB', Uint8List.fromList([1, 2, 3]));
      final out = t.requests.single.dataOut!;
      expect(out.length, 67);
      expect(out.sublist(0, 2), 'AB'.codeUnits);
      expect(out.sublist(2, 64), List.filled(62, 0));
      expect(out.sublist(64), [1, 2, 3]);
    });

    test('getObjectPropsSupported:u32 计数 + N×u16 解析', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count = 2
            0x04, 0x00, // 0x0004 ProtectionStatus
            0x08, 0x00, // 0x0008 ObjectSize
          ])));
      final props = await session.getObjectPropsSupported();
      expect(
          t.requests.single.opcode, NikonOperationCode.getObjectPropsSupported);
      expect(props, [0x0004, 0x0008]);
    });

    test(
        'getObjectPropDesc:参数 [句柄, 属性码],数据集裸透传(无消费方,'
        '定宽解留接线时)', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x06, 0x00, 0x00, 0x00])));
      final desc = await session.getObjectPropDesc(0x1234, 0x0004);
      expect(t.requests.single.opcode, NikonOperationCode.getObjectPropDesc);
      expect(t.requests.single.params, [0x1234, 0x0004]);
      expect(desc, [0x06, 0x00, 0x00, 0x00]);
    });

    test(
        'getObjectPropValue/setObjectPropValue:参数 [句柄, 属性码],'
        '裸值透传', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0x01, 0x00])));
      final value = await session.getObjectPropValue(0x1234, 0x0004);
      expect(t.requests.single.params, [0x1234, 0x0004]);
      expect(value, [0x01, 0x00]);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok));
      await session.setObjectPropValue(
          0x1234, 0x0004, Uint8List.fromList([0x00, 0x00]));
      expect(t.requests.last.opcode, NikonOperationCode.setObjectPropValue);
      expect(t.requests.last.params, [0x1234, 0x0004]);
      expect(t.requests.last.dataOut, [0x00, 0x00]);
    });

    test('getObjectPropList:u32 计数 + N×(句柄+码+类型+DTS 值)解析', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([
            0x02, 0x00, 0x00, 0x00, // count = 2
            0x34, 0x12, 0x00, 0x00, // 句柄 0x1234
            0x04, 0x00, // 属性 0x0004 ProtectionStatus
            0x06, 0x00, // UINT32
            0x01, 0x00, 0x00, 0x00, // 值 1(只读)
            0x35, 0x12, 0x00, 0x00, // 句柄 0x1235
            0x08, 0x00, // 属性 0x0008 ObjectSize
            0x04, 0x00, // UINT16
            0xF4, 0x01, // 值 500
          ])));
      final props =
          await session.getObjectPropList(0x1234, propCode: 0xFFFFFFFF);
      expect(t.requests.single.params, [0x1234, 0x00000000, 0xFFFFFFFF]);
      expect(props, hasLength(2));
      expect(props[0].handle, 0x1234);
      expect(props[0].code, 0x0004);
      expect(props[0].dataType, PtpDataType.uint32.code);
      expect(props[0].value, 1);
      expect(props[1].handle, 0x1235);
      expect(props[1].code, 0x0008);
      expect(props[1].value, 500);
    });

    test('getObjectPropList:depth 省略时 3 参;给了 P5 组码补位 P4', () async {
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10, propCode: 0x0004);
      expect(t.requests.single.params, [0x10, 0, 0x0004]);

      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10,
          propCode: 0x0004, depth: 0xFFFFFFFF);
      // P4/P5 按位序不可跳:给了 depth 而未给组码,P4 补 0x00000000。
      expect(
          t.requests.last.params, [0x10, 0, 0x0004, 0x00000000, 0xFFFFFFFF]);

      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: Uint8List.fromList([0, 0, 0, 0])));
      await session.getObjectPropList(0x10,
          propCode: 0x00000000, groupCode: 0x00000001);
      // P3=0 按 P4 组码取(官方 §6.2.11.5:Zf §6.6 信息组 = 0x00000001)。
      expect(t.requests.last.params, [0x10, 0, 0x00000000, 0x00000001]);
    });

    test(
        'getObjectPropList 批量解析:多对象多属性(含变长串),'
        '首屏五参全量形 = n-link 生产同款', () async {
      final ds = PropListDataset()
        ..u16(0x13, PtpObjectPropCode.objectFormat, 0x3801)
        ..str(0x13, PtpObjectPropCode.objectFilename, 'DSC_0002.JPG')
        ..u64(0x13, PtpObjectPropCode.objectSize, 8400000)
        ..u32(0x13, PtpObjectPropCode.parentObject, 0x11)
        ..str(0x13, PtpObjectPropCode.dateCreated, '20260926T090000')
        ..u16(0x10, PtpObjectPropCode.objectFormat, 0x3001)
        ..str(0x10, PtpObjectPropCode.objectFilename, 'DCIM');
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props = await session.getObjectPropList(0xFFFFFFFF,
          formatCode: 0x00000000, propCode: 0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(t.requests.single.opcode, NikonOperationCode.getObjectPropList);
      expect(t.requests.single.params,
          [0xFFFFFFFF, 0x00000000, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]);
      expect(props, hasLength(7));
      Object? val(int h, int c) =>
          props.firstWhere((p) => p.handle == h && p.code == c).value;
      expect(val(0x13, PtpObjectPropCode.objectFilename), 'DSC_0002.JPG');
      expect(val(0x13, PtpObjectPropCode.objectSize), 8400000);
      expect(val(0x13, PtpObjectPropCode.parentObject), 0x11);
      expect(val(0x13, PtpObjectPropCode.dateCreated), '20260926T090000');
      expect(val(0x10, PtpObjectPropCode.objectFormat), 0x3001);
      expect(session.objectPropListDegraded, isFalse);
    });

    test(
        'getObjectPropList:未知 DataType 整体弃(FormatException)'
        '+ 本会话降级秒拒不再发', () async {
      final ds = PropListDataset()
        ..u16(0x13, PtpObjectPropCode.objectFormat, 0x3801) // 首条正常
        ..raw(0x13, 0xDC41, 0x5555, [1, 2, 3, 4]); // 表外类型 → 整体弃
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(session.objectPropListDegraded, isTrue);
      // 秒拒:本会话后续调用直接 UnsupportedError,不再消耗往返。
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<UnsupportedError>()));
      expect(t.requests, hasLength(1));
    });

    test(
        'getObjectPropList:相机拒(错误应答)→ 降级 → 秒拒 → '
        '回退 GetObjectInfo 仍可用', () async {
      t.reply(
          const PtpResult(responseCode: PtpResponseCode.operationNotSupported));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<PtpResponseException>()));
      expect(session.objectPropListDegraded, isTrue);
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<UnsupportedError>()));
      expect(t.requests, hasLength(1)); // 拒答只发生一次

      // 降级不连坐:逐对象 GetObjectInfo 路径照常(仓库回退的根基)。
      t.reply(PtpResult(
          responseCode: PtpResponseCode.ok,
          data: minimalObjectInfoDataset('DSC_0002.JPG')));
      final info = await session.getObjectInfo(0x13);
      expect(info.filename, 'DSC_0002.JPG');
    });

    test('getObjectPropList:open() 复位降级旗标,新会话重新探测', () async {
      t.reply(
          const PtpResult(responseCode: PtpResponseCode.operationNotSupported));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<PtpResponseException>()));
      expect(session.objectPropListDegraded, isTrue);

      t.reply(const PtpResult(responseCode: PtpResponseCode.ok)); // OpenSession
      await session.open();
      expect(session.objectPropListDegraded, isFalse);

      final ds = PropListDataset()
        ..str(0x13, PtpObjectPropCode.objectFilename, 'DSC_0002.JPG');
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props =
          await session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(props.single.value, 'DSC_0002.JPG');
    });

    test(
        'getObjectPropList:INT128/数组型按已知宽跳过不弃解析'
        '(Zf §6.6 实型:PersistentUID / RepresentativeSampleData)', () async {
      final ds = PropListDataset()
        ..raw(0x12, 0xDC41, 0x000A, List.filled(16, 0xAB)) // UINT128
        ..raw(0x12, 0xDC86, 0x4002, [3, 0, 0, 0, 9, 9, 9]) // AUINT8×3
        ..u64(0x12, PtpObjectPropCode.objectSize, 26843545);
      t.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: ds.build()));
      final props =
          await session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF);
      expect(props, hasLength(3));
      // 128 位/数组:值不解(null),rawValue 按实宽留档;后续条目不错位。
      expect(props[0].value, isNull);
      expect(props[0].rawValue, hasLength(16));
      expect(props[1].value, isNull);
      expect(props[1].rawValue, hasLength(7)); // u32 元素数 + 3 字节
      expect(props[2].value, 26843545);
      expect(session.objectPropListDegraded, isFalse);
    });

    test('getObjectPropList:计数与字节流不符(尾巴/提前耗尽)判不可信降级',
        () async {
      // 尾巴:count=1 但流内还有第二条的字节。
      final w = ByteWriter()
        ..u32(1)
        ..u32(0x13)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3801)
        ..u32(0x10)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3001);
      t.reply(PtpResult(responseCode: PtpResponseCode.ok, data: w.takeBytes()));
      await expectLater(session.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(session.objectPropListDegraded, isTrue);

      // 提前耗尽:count=2 只有一条(另起会话验证)。
      final t2 = FakePtpTransport();
      final s2 = PtpSession(transport: t2);
      final w2 = ByteWriter()
        ..u32(2)
        ..u32(0x13)
        ..u16(PtpObjectPropCode.objectFormat)
        ..u16(0x0004)
        ..u16(0x3801);
      t2.reply(
          PtpResult(responseCode: PtpResponseCode.ok, data: w2.takeBytes()));
      await expectLater(
          s2.getObjectPropList(0xFFFFFFFF, depth: 0xFFFFFFFF),
          throwsA(isA<FormatException>()));
      expect(s2.objectPropListDegraded, isTrue);
    });

    test('非 OK 响应统一抛 PtpResponseException(clearEvent 例)', () async {
      t.reply(const PtpResult(responseCode: PtpResponseCode.deviceBusy));
      await expectLater(
          session.clearEvent(), throwsA(isA<PtpResponseException>()));
    });
  });
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/remote/config_snapshot.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

final class _ScriptTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final script = <Object>[];
  final eventsCtrl = StreamController<PtpEvent>.broadcast();

  void ok({Uint8List? data}) =>
      script.add(PtpResult(responseCode: PtpResponseCode.ok, data: data));
  void reply(int responseCode) =>
      script.add(PtpResult(responseCode: responseCode));

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)}');
    }
    final next = script.removeAt(0);
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventsCtrl.stream;

  @override
  Future<void> close() async {}
}

void _ptpString(ByteWriter w, String s) {
  w
    ..u8(s.length + 1)
    ..utf16le(s)
    ..u16(0);
}

/// 0x946D 设定文件数据集:64B ASCII 文件名(63+NUL)+ 文件体。
Uint8List _settingDataDataset(String name, List<int> body) {
  final w = ByteWriter();
  final nameUnits = name.codeUnits;
  for (var i = 0; i < 64; i++) {
    w.u8(i < nameUnits.length ? nameUnits[i] : 0);
  }
  w.raw(Uint8List.fromList(body));
  return w.takeBytes();
}

/// DeviceInfo 数据集(布局抄 ptp_session_test 的手搓版,deviceProps 参数化)。
Uint8List _deviceInfoDataset(List<int> deviceProps) {
  final w = ByteWriter()
    ..u16(0x0100)
    ..u32(0x0000000A)
    ..u16(0x0064);
  _ptpString(w, 'Nikon');
  w.u16(0x0000);
  w
    ..u32(2)..u16(0x1001)..u16(0x1014) // operations
    ..u32(0) // events
    ..u32(deviceProps.length);
  for (final p in deviceProps) {
    w.u16(p);
  }
  w
    ..u32(0) // captureFormats
    ..u32(0); // imageFormats
  _ptpString(w, 'Nikon Corp');
  _ptpString(w, 'TestModel');
  _ptpString(w, 'V1.00');
  _ptpString(w, '012345678901');
  return w.takeBytes();
}

Uint8List _propDescDataset(int code, PtpDataType type, int current,
    {bool getSet = true, bool truncateValue = false}) {
  final w = ByteWriter()
    ..u16(code)
    ..u16(type.code)
    ..u8(getSet ? 1 : 0);
  if (!truncateValue) {
    // 值区顺序(gphoto2 权威):出厂默认值在前,当前值在后 —— 不同值
    // 锁死顺序(读反立刻炸)。
    type.write(w, current + 1); // 出厂默认值
    type.write(w, current); // 当前值
  }
  w.u8(0x00); // 无 FORM
  return w.takeBytes();
}

void main() {
  late _ScriptTransport transport;
  late PtpSession session;

  setUp(() {
    transport = _ScriptTransport();
    session = PtpSession(transport: transport);
  });

  group('capture', () {
    test('遍历 devicePropsSupported:逐属性 PropDesc 入快照', () async {
      transport
        ..ok(data: _deviceInfoDataset([0x5001, 0x5007, 0x500F]))
        ..ok(data: _propDescDataset(
            0x5001, PtpDataType.uint8, 80)) // batteryLevel
        ..ok(data: _propDescDataset(
            0x5007, PtpDataType.uint16, 28, getSet: false))
        ..ok(data: _propDescDataset(
            0x500F, PtpDataType.uint16, 200))
        ..ok(); // 0x946D 设定文件:数据空 → blob 缺席
      final snap = await CameraConfigSnapshotter.capture(session);

      expect(snap.model, 'TestModel');
      expect(snap.deviceVersion, 'V1.00');
      expect(snap.serialNumber, '12345678901');
      expect(snap.props, hasLength(3));
      expect(snap.props[0].code, 0x5001);
      expect(snap.props[0].value, 80);
      expect(snap.props[0].writable, isTrue);
      expect(snap.props[1].code, 0x5007);
      expect(snap.props[1].writable, isFalse);
      expect(snap.settingsBlob, isNull);
      expect(transport.requests.map((r) => r.opcode), [
        PtpOperationCode.getDeviceInfo,
        ...List.filled(3, PtpOperationCode.getDevicePropDesc),
        NikonOperationCode.getCameraSettingData,
      ]);
    });

    test('单属性失败/值区截断:跳过该属性,整体不失败', () async {
      transport
        ..ok(data: _deviceInfoDataset([0x5001, 0x5007, 0x500F]))
        ..reply(PtpResponseCode.operationNotSupported) // 0x5001 拒
        ..ok(data: _propDescDataset(
            0x5007, PtpDataType.uint16, 28, truncateValue: true)) // 值区截断
        ..ok(data: _propDescDataset(0x500F, PtpDataType.uint16, 200))
        ..ok(); // 0x946D:数据空 → blob 缺席
      final snap = await CameraConfigSnapshotter.capture(session);
      expect(snap.props.map((p) => p.code), [0x500F],
          reason: '失败与值截断的属性均不入快照');
    });

    test('一个属性都拿不到 → FormatException', () async {
      transport
        ..ok(data: _deviceInfoDataset([0x5001]))
        ..reply(PtpResponseCode.deviceBusy)
        ..ok(); // 0x946D:数据空,blob 也救不了场
      expect(() => CameraConfigSnapshotter.capture(session),
          throwsA(isA<FormatException>()));
    });

    test('JSON 往返:类型/值/可写性无损', () async {
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        serialNumber: 'SN',
        capturedAt: DateTime.utc(2026, 10, 5, 12),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
          ConfigPropSnapshot(
              code: 0x5001, type: 'uint8', value: 80, writable: false),
        ],
      );
      final back =
          CameraConfigSnapshot.fromJson(snap.toJson()..cast<String, Object?>());
      expect(back.model, 'TestModel');
      expect(back.capturedAt, snap.capturedAt);
      expect(back.props, hasLength(2));
      expect(back.props[0].code, 0x5007);
      expect(back.props[0].value, 28);
      expect(back.props[1].writable, isFalse);
    });
  });

  group('blob 轨道(0x946D 读卡设定文件 / 0x946E 回写)', () {
    test('capture:设定文件读得 → 名字与体入快照;JSON 往返无损', () async {
      transport
        ..ok(data: _deviceInfoDataset([0x5001]))
        ..ok(data: _propDescDataset(0x5001, PtpDataType.uint8, 80))
        ..ok(data: _settingDataDataset('NCSET011.BIN', [1, 2, 3, 4]));
      final snap = await CameraConfigSnapshotter.capture(session);
      expect(snap.settingsBlobName, 'NCSET011.BIN');
      expect(snap.settingsBlob, [1, 2, 3, 4]);

      final back = CameraConfigSnapshot.fromJson(
          snap.toJson()..cast<String, Object?>());
      expect(back.settingsBlobName, 'NCSET011.BIN');
      expect(back.settingsBlob, [1, 2, 3, 4],
          reason: 'base64 往返字节无损');
    });

    test('capture:0x946D 拒答(无卡等)→ blob 缺席,逐属性快照照常', () async {
      transport
        ..ok(data: _deviceInfoDataset([0x5001]))
        ..ok(data: _propDescDataset(0x5001, PtpDataType.uint8, 80))
        ..reply(PtpResponseCode.storeNotAvailable);
      final snap = await CameraConfigSnapshotter.capture(session);
      expect(snap.settingsBlob, isNull);
      expect(snap.props, hasLength(1));
    });

    test('restore:blob 先行 —— 0x946E 单事务整档写卡,不走逐属性', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      transport
        ..ok(data: _deviceInfoDataset([])) // 型号比对
        ..ok(); // 0x946E 收下
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
        ],
        settingsBlobName: 'NCSET011.BIN',
        settingsBlob: Uint8List.fromList([9, 8, 7]),
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);

      expect(report.blobSaved, isTrue);
      expect(report.applied, 0, reason: 'blob 轨道成功,属性未逐个写');
      final send = transport.requests
          .where((r) => r.opcode == NikonOperationCode.sendCameraSettingData)
          .single;
      expect(send.dataOut, hasLength(64 + 3));
      expect(send.dataOut!.sublist(0, 12),
          Uint8List.fromList('NCSET011.BIN'.codeUnits));
      expect(send.dataOut!.sublist(64), [9, 8, 7]);
      expect(
          transport.requests
              .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
          isEmpty,
          reason: 'blob 成功不再逐属性写');
    });

    test('restore:0x946E 拒答 → 回落逐属性', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      transport
        ..ok(data: _deviceInfoDataset([]))
        ..reply(PtpResponseCode.storeNotAvailable) // 0x946E 拒(无卡)
        ..ok(data: _propDescDataset(0x5007, PtpDataType.uint16, 28))
        ..ok(); // 0x1016 写成功
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
        ],
        settingsBlobName: 'NCSET011.BIN',
        settingsBlob: Uint8List.fromList([9, 8, 7]),
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);
      expect(report.blobSaved, isFalse);
      expect(report.applied, 1, reason: '逐属性兜底照常写');
    });

    test('restore:blob 无名字(截断档/旧档)→ 不盲写卡,直接逐属性', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      transport
        ..ok(data: _deviceInfoDataset([]))
        ..ok(data: _propDescDataset(0x5007, PtpDataType.uint16, 28))
        ..ok(); // 0x1016
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
        ],
        settingsBlob: Uint8List.fromList([9, 8, 7]),
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);
      expect(report.blobSaved, isFalse);
      expect(report.applied, 1);
      expect(
          transport.requests
              .where(
                  (r) => r.opcode == NikonOperationCode.sendCameraSettingData),
          isEmpty,
          reason: '无名不写卡');
    });
  });

  group('restore', () {
    test('总闸紧急关断 → UnsupportedError,零流量', () async {
      PtpSession.kSetPropEnabled = false; // 生产已开,显式关断走分支
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
        ],
      );
      await expectLater(CameraConfigSnapshotter.restore(session, snap),
          throwsA(isA<UnsupportedError>()));
      expect(transport.requests, isEmpty);
    });

    test('可写写入;当下只读/类型漂移跳过;写失败计入且继续', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);

      transport
        ..ok(data: _deviceInfoDataset([])) // 型号比对(getDeviceInfo 缓存空)
        ..ok(data: _propDescDataset(
            0x5007, PtpDataType.uint16, 28)) // 仍可写 → 写
        ..ok() // 0x1016 写成功
        ..ok(data: _propDescDataset(
            0x5001, PtpDataType.uint8, 80, getSet: false)) // 当下只读 → 跳
        ..ok(data: _propDescDataset(
            0x500F, PtpDataType.uint16, 200)) // 快照 uint32 ≠ 当下 u16 → 跳
        ..ok(data: _propDescDataset(
            0x5010, PtpDataType.uint16, 100)) // 仍可写 → 写
        ..reply(PtpResponseCode.deviceBusy); // 0x1016 忙 → failed

      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
          ConfigPropSnapshot(
              code: 0x5001, type: 'uint8', value: 80, writable: true),
          ConfigPropSnapshot(
              code: 0x500F, type: 'uint32', value: 200, writable: true),
          ConfigPropSnapshot(
              code: 0x5010, type: 'uint16', value: 100, writable: true),
        ],
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);

      expect(report.applied, 1);
      expect(report.skipped, 2, reason: '当下只读 + 类型漂移各计一跳');
      expect(report.failed, 1);
      expect(report.modelMismatch, isFalse, reason: '型号一致');
      final writes = transport.requests
          .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
          .toList();
      expect(writes, hasLength(2), reason: '跳过的属性不发 0x1016');
      expect(writes.first.params, [0x5007]);
      expect(writes.first.dataOut, Uint8List.fromList([28, 0]));
      expect(writes.last.params, [0x5010]);
      expect(writes.last.dataOut, Uint8List.fromList([100, 0]));
    });

    test('型号不一致:不拦截,报告标记', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);

      transport
        ..ok(data: _deviceInfoDataset([])) // model = TestModel
        ..ok(data: _propDescDataset(0x5007, PtpDataType.uint16, 28))
        ..ok(); // 0x1016
      final snap = CameraConfigSnapshot(
        model: 'OtherModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5007, type: 'uint16', value: 28, writable: true),
        ],
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);
      expect(report.applied, 1);
      expect(report.modelMismatch, isTrue);
    });

    test('快照时只读的属性:预过滤跳过,零流量', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);

      transport.ok(data: _deviceInfoDataset([]));
      final snap = CameraConfigSnapshot(
        model: 'TestModel',
        deviceVersion: 'V1.00',
        capturedAt: DateTime.now(),
        props: const [
          ConfigPropSnapshot(
              code: 0x5001, type: 'uint8', value: 80, writable: false),
        ],
      );
      final report = await CameraConfigSnapshotter.restore(session, snap);
      expect(report.skipped, 1);
      expect(report.applied, 0);
      expect(
          transport.requests
              .where((r) => r.opcode == PtpOperationCode.getDevicePropDesc),
          isEmpty);
    });
  });
}

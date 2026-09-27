import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/platform/usb/usb_host.dart';

import '../ptp/ptp_session_test.dart' show FakePtpTransport, buildDeviceInfoDataset;

/// 假 USB 主机通道:记录生命周期调用,字节管道不参与(传输层已另行单测)。
final class FakeUsbHostChannel implements UsbHostChannel {
  FakeUsbHostChannel(this.devices);

  final List<UsbDeviceHandle> devices;
  final List<String> openedIdentifiers = [];
  int closeCalls = 0;
  final StreamController<Uint8List> _eventCtrl =
      StreamController<Uint8List>.broadcast();

  @override
  Future<List<UsbDeviceHandle>> listCameras() async => devices;

  @override
  Future<void> open(UsbDeviceHandle device) async =>
      openedIdentifiers.add(device.identifier);

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> bulkOut(Uint8List bytes) async {}

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async =>
      Uint8List(0);

  @override
  Stream<Uint8List> get interruptEvents => _eventCtrl.stream;
}

const _zf = UsbDeviceHandle(
  vendorId: 0x04B0,
  productId: 0x0453,
  identifier: '1-2',
);

PtpResult _ok({Uint8List? data}) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

void main() {
  test('connect:listCameras → open → GetDeviceInfo → OpenSession → connected',
      () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final conn =
        CameraConnectionImpl(usb: usb, session: PtpSession(transport: fake));
    final states = <CameraLinkState>[];
    conn.states.listen(states.add);

    fake.reply(_ok(data: buildDeviceInfoDataset())); // GetDeviceInfo
    fake.reply(_ok()); // OpenSession

    await conn.connect();

    expect(conn.state, CameraLinkState.connected);
    expect(conn.deviceName, 'TestModel');
    expect(conn.error, isNull);
    expect(usb.openedIdentifiers, ['1-2']);
    // 状态序:connecting → connected(detecting 属 WiFi 线,跳过)
    await Future<void>.delayed(Duration.zero);
    expect(states, [
      CameraLinkState.connecting,
      CameraLinkState.connected,
    ]);
  });

  test('无相机:failed + 插线/解锁引导,不动 USB 会话', () async {
    final usb = FakeUsbHostChannel(const []);
    final fake = FakePtpTransport();
    final conn =
        CameraConnectionImpl(usb: usb, session: PtpSession(transport: fake));

    await conn.connect();

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error, contains('未发现尼康相机'));
    expect(usb.openedIdentifiers, isEmpty);
    expect(fake.requests, isEmpty);
  });

  test('0x201E 残留会话:自动 CloseSession 后重开仍连上', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final conn =
        CameraConnectionImpl(usb: usb, session: PtpSession(transport: fake));

    fake.reply(_ok(data: buildDeviceInfoDataset())); // GetDeviceInfo
    fake.reply(const PtpResult(
        responseCode: PtpResponseCode.sessionAlreadyOpen)); // OpenSession ①
    fake.reply(_ok()); // CloseSession(残留)
    fake.reply(_ok()); // OpenSession ②

    await conn.connect();

    expect(conn.state, CameraLinkState.connected);
    expect(
      fake.requests.map((r) => r.opcode),
      [
        PtpOperationCode.getDeviceInfo,
        PtpOperationCode.openSession,
        PtpOperationCode.closeSession,
        PtpOperationCode.openSession,
      ],
    );
  });

  test('disconnect:CloseSession + usb.close,状态回 disconnected', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final session = PtpSession(transport: fake);
    final conn = CameraConnectionImpl(usb: usb, session: session);

    fake.reply(_ok(data: buildDeviceInfoDataset()));
    fake.reply(_ok());
    await conn.connect();

    fake.reply(_ok()); // CloseSession
    await conn.disconnect();

    expect(conn.state, CameraLinkState.disconnected);
    expect(conn.deviceName, isNull);
    expect(session.isSessionOpen, isFalse);
    expect(usb.closeCalls, 1);
  });

  test('OpenSession 被拒:failed + 清理(close 会话与 USB)', () async {
    final usb = FakeUsbHostChannel(const [_zf]);
    final fake = FakePtpTransport();
    final conn =
        CameraConnectionImpl(usb: usb, session: PtpSession(transport: fake));

    fake.reply(_ok(data: buildDeviceInfoDataset()));
    // 拒绝码用表内在册的 generalError:本测试验证传播与清理,不针对特定码。
    fake.reply(const PtpResult(responseCode: PtpResponseCode.generalError));

    await conn.connect();

    expect(conn.state, CameraLinkState.failed);
    expect(conn.error, isNotNull);
    expect(usb.closeCalls, 1);
  });
}

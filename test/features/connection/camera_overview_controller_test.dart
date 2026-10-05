import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/album.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/camera/camera_connection.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart' show ObjectKind;
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/features/connection/camera_overview_controller.dart';

/// 按序回放的假传输层(session 方法测试模板,见 ptp_session_test)。
final class FakePtpTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final Queue<Object> script = Queue();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    requests.add(request);
    if (script.isEmpty) {
      throw StateError('脚本耗尽:未预置 0x${request.opcode.toRadixString(16)} 的响应');
    }
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}

/// 手搓 GetDeviceInfo 数据集(布局独立于被测代码;操作码表与属性表
/// 均可覆盖 —— 能力门禁测试的正反两组件)。
Uint8List buildDataset(
    {List<int> operations = const [0x1001, 0x1007, 0x1009],
    List<int> deviceProps = const [0x5001, 0x5007]}) {
  final w = ByteWriter()
    ..u16(0x0100)
    ..u32(0x0000000A)
    ..u16(0x0064);
  void str(String s) {
    w
      ..u8(s.length + 1)
      ..utf16le(s)
      ..u16(0);
  }

  str('Nikon');
  w.u16(0x0000);
  w.u32(operations.length);
  for (final op in operations) {
    w.u16(op);
  }
  w.u32(1); // events
  w.u16(0x4002);
  w.u32(deviceProps.length);
  for (final p in deviceProps) {
    w.u16(p);
  }
  w
    ..u32(0) // captureFormats
    ..u32(2) // imageFormats
    ..u16(0x3000)
    ..u16(0x3801);
  str('Nikon Corp');
  str('TestModel');
  str('V1.00');
  str('012345678901');
  return w.takeBytes();
}

/// 带 LensModel(0xA434)的 EXIF APP1 载荷(手算偏移,布局独立于被测
/// 代码;watermark_test 的 _exifPayload 无镜头字段,此处为 5 条目变体)。
Uint8List exifPayloadWithLens() {
  const ascii = 2, short = 3, long = 4, rational = 5;
  const makeOff = 128, modelOff = 146, dateOff = 156;
  const fNumOff = 176, expOff = 184, focalOff = 192, lensOff = 200;
  const exifIfdOff = 62; // IFD0(4 条目)后紧随
  final w = ByteWriter()
    ..u16(0x4949) // 'II'
    ..u16(42)
    ..u32(8)
    // IFD0:Make / Model / DateTime / ExifIFD 指针
    ..u16(4)
    ..u16(0x010F)..u16(ascii)..u32(18)..u32(makeOff)
    ..u16(0x0110)..u16(ascii)..u32(10)..u32(modelOff)
    ..u16(0x0132)..u16(ascii)..u32(20)..u32(dateOff)
    ..u16(0x8769)..u16(long)..u32(1)..u32(exifIfdOff)
    ..u32(0)
    // Exif 子表:光圈 / 快门 / ISO / 焦距 / 镜头型号
    ..u16(5)
    ..u16(0x829D)..u16(rational)..u32(1)..u32(fNumOff)
    ..u16(0x829A)..u16(rational)..u32(1)..u32(expOff)
    ..u16(0x8827)..u16(short)..u32(1)..u16(100)..u16(0)
    ..u16(0x920A)..u16(rational)..u32(1)..u32(focalOff)
    ..u16(0xA434)..u16(ascii)..u32(18)..u32(lensOff)
    ..u32(0)
    // 数据区(18 + 10 + 20 + 8×3 + 18 = 90B)
    ..raw('NIKON CORPORATION'.codeUnits)..u8(0)
    ..raw('NIKON Z f'.codeUnits)..u8(0)
    ..raw('2026:10:02 09:05:33'.codeUnits)..u8(0)
    ..u32(18)..u32(10) // ƒ/1.8
    ..u32(1)..u32(250) // 1/250s
    ..u32(85)..u32(1) // 85mm
    ..raw('NIKKOR Z 40mm f/2'.codeUnits)..u8(0);
  return w.takeBytes();
}

/// 「JPEG」= SOI + Exif APP1 + EOI(readJpegExif 只扫 APP1,无需真解码)。
Uint8List lensJpeg() {
  final payload = exifPayloadWithLens();
  final segLen = 2 + 6 + payload.length;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF,
    ...'Exif'.codeUnits, 0, 0,
    ...payload,
    0xFF, 0xD9,
  ]);
}

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  String? get error => null;

  @override
  String? get deviceName => null;

  @override
  bool get isWireless => false;

  @override
  String? get pairingCode => null;

  @override
  CameraLinkState get state => CameraLinkState.disconnected;

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;

  @override
  Future<void> connect({String? ip, String? instanceName}) async {}

  @override
  Future<void> confirmPairing() async {}

  @override
  Future<void> cancelPairing() async {}

  @override
  Future<void> disconnect() async {}
}

/// 只会发块事件的伪仓库。
final class _FakeRepo implements ObjectRepository {
  final updatesCtrl = StreamController<AlbumsUpdate>.broadcast(sync: true);

  @override
  Stream<AlbumsUpdate> get updates => updatesCtrl.stream;

  @override
  Future<List<CameraAlbum>> loadAlbums() async => const [];

  @override
  Future<ObjectEntry> entryFor(int handle) async => throw UnimplementedError();

  @override
  void reset() {}

  @override
  void removeHandles(Iterable<int> handles) {}
}

/// 单 JPG 组(仓库渐进块的最小载荷)。
PhotoGroup _jpgGroup(int handle) => PhotoGroup([
      ObjectEntry(
        handle: handle,
        name: 'DSC_0001.JPG',
        sizeInBytes: 8,
        kind: ObjectKind.image,
        parentHandle: 0x11,
        capturedAt: DateTime.utc(2026, 10, 2, 9, 5, 33),
        formatCode: 0x3801,
      ),
    ]);

void _emitJpgChunk(_FakeRepo repo, int handle) {
  repo.updatesCtrl.add(AlbumsUpdate(
      albums: [CameraAlbum.allPhotos([_jpgGroup(handle)])],
      loaded: 1,
      total: 1,
      complete: true));
}

void main() {
  test('属性在册才读:电池/焦距/光圈逐码 0x1015,裸值解码', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(
            deviceProps: const [0x5001, 0x5008, 0x5007])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 u8
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([0x90, 0x01]))); // 焦距 u16 LE = 400
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([28, 0]))); // 光圈 u16 LE = 28

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.deviceInfo?.model, 'TestModel');
    expect(controller.batteryPercent, 80);
    expect(controller.focalLengthMm, 400);
    expect(controller.fNumber, 28);
    // 请求序:GetDeviceInfo + 三次属性(声明表外的码不发)
    expect(transport.requests.map((r) => r.opcode),
        [0x1001, 0x1015, 0x1015, 0x1015]);
    expect(transport.requests.skip(1).map((r) => r.params.single),
        [0x5001, 0x5008, 0x5007]);
  });

  test('属性全不在册:只发 GetDeviceInfo,字段保持缺省', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final controller = CameraOverviewController(
        session: session, connection: conn);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    expect(controller.deviceInfo?.model, 'TestModel');
    expect(controller.batteryPercent, isNull);
    expect(controller.focalLengthMm, isNull);
    expect(controller.fNumber, isNull);
    expect(transport.requests, hasLength(1));
  });

  test('镜头型号:首个含 JPG 的块 → GetPartialObject 头 64KB → EXIF LensModel;'
      ' 属性缺读时焦距/光圈 EXIF 兜底,一次连接只读一次', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final repo = _FakeRepo();
    final controller = CameraOverviewController(
        session: session, connection: conn, repository: repo);

    // 0x101B 在册(能力门禁放行);电池在册(混合验证:属性优先,
    // EXIF 只兜焦距/光圈)。
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(
            operations: const [0x1001, 0x1007, 0x1009, 0x101B],
            deviceProps: const [0x5001])));
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([80]))); // 电池 80%
    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok, data: lensJpeg())); // 部分读回 EXIF

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue(); // refresh 完成(deviceInfo 就位)

    _emitJpgChunk(repo, 0x9001);
    await pumpEventQueue();

    expect(controller.lens, 'NIKKOR Z 40mm f/2');
    expect(controller.batteryPercent, 80); // 属性路径
    expect(controller.focalLengthMm, 85); // EXIF 兜底
    expect(controller.fNumber, 18); // ƒ/1.8 ×10
    // 部分读只取头部 64KB,从 0 起
    final partial = transport.requests.last;
    expect(partial.opcode, PtpOperationCode.getPartialObject);
    expect(partial.params, [0x9001, 0, 64 * 1024]);

    // 二次块不重读(一次连接一次)
    _emitJpgChunk(repo, 0x9002);
    await pumpEventQueue();
    expect(transport.requests, hasLength(3));
  });

  test('0x101B 不在册:块到达也不发部分读,镜头行留空', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final repo = _FakeRepo();
    final controller = CameraOverviewController(
        session: session, connection: conn, repository: repo);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));

    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();

    _emitJpgChunk(repo, 0x9001);
    await pumpEventQueue();

    expect(controller.lens, isNull);
    expect(transport.requests, hasLength(1)); // 只有 GetDeviceInfo
  });

  test('断连清态;门闩挡住迟到的块(不再发请求)', () async {
    final transport = FakePtpTransport();
    final session = PtpSession(transport: transport);
    final conn = _FakeConnection();
    final repo = _FakeRepo();
    final controller = CameraOverviewController(
        session: session, connection: conn, repository: repo);

    transport.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: buildDataset(deviceProps: const [])));
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    expect(controller.deviceInfo, isNotNull);

    conn.statesCtrl.add(CameraLinkState.disconnected);
    await pumpEventQueue();
    expect(controller.deviceInfo, isNull);
    expect(controller.batteryPercent, isNull);
    expect(controller.lens, isNull);

    // 迟到的仓库块:_linkUp 门闩,静默丢弃
    _emitJpgChunk(repo, 0x9001);
    await pumpEventQueue();
    expect(transport.requests, hasLength(1));
  });
}

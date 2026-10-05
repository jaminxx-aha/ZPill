import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/photo_group.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/transfer/auto_transfer.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';
import 'package:nikon_pill/data/settings_store.dart';

/// 事件可控的最小假传输(script 队列 + events 控制器)。
final class FakeTransport implements PtpTransport {
  final requests = <PtpRequest>[];
  final script = <Object>[];
  final eventsCtrl = StreamController<PtpEvent>.broadcast();

  void reply(PtpResult result) => script.add(result);
  void fail(Exception e) => script.add(e);

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

/// 入队记录器(速传只用到 enqueue)。
final class FakeEngine implements TransferEngine {
  final enqueued = <(List<ObjectEntry>, TransferDestination)>[];

  @override
  Stream<List<TransferTask>> get tasks => const Stream.empty();

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {
    enqueued.add((entries.toList(), destination));
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

/// ObjectInfo 数据集(布局同 object_repository_test,浏览所需字段参数化)。
Uint8List _infoDataset({
  required int format,
  required int parent,
  required int size,
  required String name,
}) {
  final w = ByteWriter()
    ..u32(0x00010001) // StorageID
    ..u16(format)
    ..u16(0) // ProtectionStatus
    ..u32(size)
    ..u16(0x3808) // ThumbFormat
    ..u32(50000)
    ..u32(640)
    ..u32(424)
    ..u32(3968)
    ..u32(2624)
    ..u32(24)
    ..u32(parent)
    ..u16(0)
    ..u32(0)
    ..u32(0);
  w
    ..u8(name.length + 1)
    ..utf16le(name)
    ..u16(0)
    ..u8(0) // captureDate:空
    ..u8(0); // modificationDate:空
  return w.takeBytes();
}

PtpResult _ok(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

void main() {
  late FakeTransport transport;
  late PtpSession session;
  late FakeEngine engine;
  late InMemorySettingsStore store;
  late AutoTransferService service;
  late List<Object> skipped;

  setUp(() async {
    transport = FakeTransport();
    session = PtpSession(transport: transport);
    engine = FakeEngine();
    store = InMemorySettingsStore();
    skipped = [];
    service = AutoTransferService(
      session: session,
      engine: engine,
      settings: store,
      onSkip: skipped.add,
    );
    await store.update(
        const AppSettings().copyWith(autoTransfer: true));
  });

  test('ObjectAdded → getObjectInfo → 入队 gallery', () async {
    transport.reply(_ok(_infoDataset(
        format: 0x3801, parent: 0x11, size: 8400000, name: 'DSC_6160.JPG')));
    transport.eventsCtrl.add(const PtpEvent(
        code: PtpEventCode.objectAdded,
        transactionId: 0xFFFFFFFF,
        params: [0x291A9827]));
    await pumpEventQueue();

    expect(engine.enqueued, hasLength(1));
    final (entries, destination) = engine.enqueued.single;
    expect(destination, TransferDestination.gallery);
    expect(entries.single.handle, 0x291A9827);
    expect(entries.single.name, 'DSC_6160.JPG');
    expect(entries.single.sizeInBytes, 8400000);
    expect(transport.requests.single.params, [0x291A9827]);
  });

  test('尼康 SDRAM 码 0xC101 同样触发(无卡拍速传)', () async {
    transport.reply(_ok(_infoDataset(
        format: 0x3801, parent: 0x11, size: 1000, name: 'DSC_6161.JPG')));
    transport.eventsCtrl.add(const PtpEvent(
        code: NikonEventCode.objectAddedInSdram,
        transactionId: 0xFFFFFFFF,
        params: [7]));
    await pumpEventQueue();
    expect(engine.enqueued, hasLength(1));
  });

  test('开关关闭:事件到、不取 Info、不入队', () async {
    await store.update(const AppSettings());
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [7]));
    await pumpEventQueue();
    expect(transport.requests, isEmpty);
    expect(engine.enqueued, isEmpty);
  });

  test('格式过滤:仅 JPG 时 NEF 跳过、JPG 放行;视频不受限', () async {
    await store.update(const AppSettings()
        .copyWith(autoTransfer: true, autoTransferFormat: PhotoDownloadFormat.jpg));
    transport.reply(_ok(_infoDataset(
        format: 0x3000, parent: 0x11, size: 26843545, name: 'DSC_6162.NEF')));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [8]));
    await pumpEventQueue();
    expect(engine.enqueued, isEmpty, reason: 'NEF 应被仅 JPG 过滤');

    transport.reply(_ok(_infoDataset(
        format: 0x3801, parent: 0x11, size: 900, name: 'DSC_6163.JPG')));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [9]));
    await pumpEventQueue();
    expect(engine.enqueued, hasLength(1));

    transport.reply(_ok(_infoDataset(
        format: 0x300D, parent: 0x11, size: 5000000, name: 'DSC_6164.MOV')));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [10]));
    await pumpEventQueue();
    expect(engine.enqueued, hasLength(2), reason: '视频不受格式选择影响');
  });

  test('无关事件(ObjectAdded 之外)忽略', () async {
    transport.eventsCtrl.add(const PtpEvent(
        code: PtpEventCode.captureComplete,
        transactionId: 0xFFFFFFFF,
        params: [1]));
    transport.eventsCtrl.add(const PtpEvent(
        code: NikonEventCode.captureCompleteRecInSdram,
        transactionId: 0xFFFFFFFF));
    await pumpEventQueue();
    expect(transport.requests, isEmpty);
    expect(engine.enqueued, isEmpty);
  });

  test('getObjectInfo 失败:丢当张、记 onSkip、服务继续', () async {
    transport.fail(const PtpResponseException(
        opcode: PtpOperationCode.getObjectInfo, responseCode: 0x200F));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [11]));
    await pumpEventQueue();
    expect(skipped, hasLength(1));
    expect(engine.enqueued, isEmpty);

    transport.reply(_ok(_infoDataset(
        format: 0x3801, parent: 0x11, size: 10, name: 'DSC_6165.JPG')));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [12]));
    await pumpEventQueue();
    expect(engine.enqueued, hasLength(1), reason: '失败后服务不得中断');
  });

  test('transferred 流广播已入队句柄', () async {
    final seen = <int>[];
    service.transferred.listen(seen.add);
    transport.reply(_ok(_infoDataset(
        format: 0x3801, parent: 0x11, size: 10, name: 'DSC_6166.JPG')));
    transport.eventsCtrl.add(
        const PtpEvent(transactionId: 0xFFFFFFFF, code: PtpEventCode.objectAdded, params: [13]));
    await pumpEventQueue();
    expect(seen, [13]);
  });
}

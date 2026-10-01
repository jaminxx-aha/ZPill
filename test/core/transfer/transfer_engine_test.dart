import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

import '../ptp/ptp_session_test.dart' show FakePtpTransport;

/// 假相册:目录落在真实临时目录(验证落盘/清理),导入行为可配置。
final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver()
      : root = Directory.systemTemp.createTempSync('nikonpill_engine_test');

  final Directory root;

  /// 每次 importFiles 的请求快照。
  final List<List<GalleryImportRequest>> importCalls = [];

  /// importFiles 的应答(默认空列表 = 用户取消对话框)。
  List<Uri> importResult = const [];

  @override
  Future<String> tempDir() async => _ensure('${root.path}/temp');

  @override
  Future<String> thumbsDir() async => _ensure('${root.path}/thumbs');

  @override
  Future<String> previewsDir() async => _ensure('${root.path}/previews');

  @override
  Future<String> downloadsDir() async => _ensure('${root.path}/downloads');

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) async {
    importCalls.add(List.of(requests));
    return importResult;
  }

  static Future<String> _ensure(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return path;
  }
}

ObjectEntry _entry(int handle, String name, int size,
        {ObjectKind kind = ObjectKind.image}) =>
    ObjectEntry(handle: handle, name: name, sizeInBytes: size, kind: kind);

PtpResult _okData(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

PtpResult _okBytes(int n) =>
    _okData(Uint8List.fromList(List.generate(n, (i) => i & 0xFF)));

/// 等快照流上出现满足 [test] 的快照(须在 enqueue 之前订阅)。
Future<List<TransferTask>> waitUntil(TransferEngine engine,
    bool Function(List<TransferTask>) test) {
  return engine.tasks
      .firstWhere(test)
      .timeout(const Duration(seconds: 5));
}

/// 引擎(重试零退避,测试不等)。
(TransferEngineImpl, FakePtpTransport, FakeGallerySaver) _engine() {
  final fake = FakePtpTransport();
  final gallery = FakeGallerySaver();
  final engine = TransferEngineImpl(
    downloader: ObjectDownloader(session: PtpSession(transport: fake)),
    gallery: gallery,
    backoffFor: (_) => Duration.zero,
  );
  return (engine, fake, gallery);
}

void main() {
  test('FIFO 顺序执行,同一时刻至多一个 running;文件落 downloadsDir', () async {
    final (engine, fake, gallery) = _engine();
    final payloads = {1: 10, 2: 20, 3: 30};
    for (final n in payloads.values) {
      fake.reply(_okBytes(n));
    }

    final runningOrder = <String>[];
    engine.tasks.listen((ts) {
      expect(ts.where((t) => t.state == TransferState.running), hasLength(lessThanOrEqualTo(1)));
      for (final t in ts) {
        if (t.state == TransferState.running && !runningOrder.contains(t.id)) {
          runningOrder.add(t.id);
        }
      }
    });

    final done = waitUntil(
        engine, (ts) => ts.length == 3 && ts.every((t) => t.isTerminal));
    await engine.enqueue(
      [1, 2, 3].map((h) => _entry(h, 'IMG_$h.NEF', payloads[h]!)),
      destination: TransferDestination.app,
    );
    final tasks = await done;

    // 执行顺序 = 入队顺序
    final byId = {for (final t in tasks) t.id: t};
    expect(runningOrder.map((id) => byId[id]!.filename),
        ['IMG_1.NEF', 'IMG_2.NEF', 'IMG_3.NEF']);
    for (final t in tasks) {
      expect(t.state, TransferState.completed);
      expect(t.receivedBytes, byId[t.id]!.totalBytes);
      final file = File('${gallery.root.path}/downloads/${t.filename}');
      expect(await file.readAsBytes(),
          List.generate(payloads[t.handle]!, (i) => i & 0xFF));
    }
  });

  test('gallery 两段式:先全部落 tempDir,再一次性导入,回填 Uri、删临时', () async {
    final (engine, fake, gallery) = _engine();
    fake..reply(_okBytes(11))..reply(_okBytes(22));
    gallery.importResult = [
      Uri.parse('content://media/1'),
      Uri.parse('content://media/2'),
    ];

    final done = waitUntil(engine, (ts) =>
        ts.length == 2 &&
        ts.every((t) => t.state == TransferState.completed) &&
        ts.every((t) => t.galleryUri != null));
    await engine.enqueue([
      _entry(1, 'DSC_1.JPG', 11, kind: ObjectKind.image),
      _entry(2, 'DSC_2.MOV', 22, kind: ObjectKind.video),
    ], destination: TransferDestination.gallery);
    final tasks = await done;

    // 一次对话框,两个请求按序,kind 透传
    expect(gallery.importCalls, hasLength(1));
    expect(gallery.importCalls.single.map((r) => r.filename),
        ['DSC_1.JPG', 'DSC_2.MOV']);
    expect(gallery.importCalls.single.map((r) => r.kind),
        [ObjectKind.image, ObjectKind.video]);
    expect(tasks.map((t) => t.galleryUri),
        [Uri.parse('content://media/1'), Uri.parse('content://media/2')]);
    // 临时文件已清理(目录保留、内容为空);downloadsDir 未被触碰
    // (gallery 批次不调 downloadsDir,目录因此不存在,先确保建好再查空)。
    await gallery.downloadsDir();
    expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty);
    expect(Directory('${gallery.root.path}/downloads').listSync(), isEmpty);
  });

  test('gallery 用户取消对话框:任务完成、galleryUri=null、临时文件照删', () async {
    final (engine, fake, gallery) = _engine();
    fake.reply(_okBytes(5));
    gallery.importResult = const []; // 取消

    // 终态事件的派发是微任务,晚于 fake importFiles 体内同步的
    // importCalls.add —— 单查 importCalls==1 会在删除临时文件前就满足。
    // 加上「临时目录已清空」:它只在收尾(导入+回填+删临时)后的
    // 最终通知上成立。
    bool tempEmpty() =>
        Directory('${gallery.root.path}/temp').existsSync() &&
        Directory('${gallery.root.path}/temp').listSync().isEmpty;
    final done = waitUntil(engine, (ts) =>
        ts.length == 1 &&
        ts.single.state == TransferState.completed &&
        ts.single.galleryUri == null &&
        gallery.importCalls.length == 1 &&
        tempEmpty());
    await engine.enqueue([_entry(1, 'DSC_1.JPG', 5)],
        destination: TransferDestination.gallery);
    await done;

    expect(gallery.importCalls, hasLength(1)); // 对话框确实弹过
    expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty);
  });

  test('取消 queued:立即落定;其余任务照常', () async {
    final (engine, fake, _) = _engine();
    final stall = Completer<void>();
    fake.replyAfter(stall.future, _okBytes(7)); // A 卡在相机侧
    fake.reply(_okBytes(9)); // B

    var sawBCancelled = false;
    var bId = '';
    engine.tasks.listen((ts) {
      final b = ts.where((t) => t.filename == 'B.NEF').singleOrNull;
      if (b != null) {
        bId = b.id;
        if (b.state == TransferState.cancelled) sawBCancelled = true;
      }
    });
    final done = waitUntil(engine, (ts) =>
        ts.length == 2 && ts.every((t) => t.isTerminal) && sawBCancelled);
    await engine.enqueue(
      [_entry(1, 'A.NEF', 7), _entry(2, 'B.NEF', 9)],
      destination: TransferDestination.app,
    );
    await pumpEventQueue();
    // A 卡在传输层(running)时取消 B(queued)
    await engine.cancel(bId);
    stall.complete();
    await done;

    expect(sawBCancelled, isTrue);
  });

  test('取消 running:排空数据流、删半成品、任务落定 cancelled', () async {
    final (engine, fake, gallery) = _engine();
    final stall = Completer<void>();
    fake.replyAfter(stall.future, _okBytes(100));

    var aId = '';
    engine.tasks.listen((ts) {
      if (aId.isEmpty) aId = ts.single.id; // 首个快照(全 queued)即带 id
    });
    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.state == TransferState.cancelled);
    final enqueue = engine.enqueue([_entry(1, 'A.NEF', 100)],
        destination: TransferDestination.app);
    await pumpEventQueue();
    // A 正卡在相机数据流上(running)→ 取消
    await engine.cancel(aId);
    stall.complete();
    await enqueue;
    await done;

    expect(Directory('${gallery.root.path}/downloads').listSync(), isEmpty);
  });

  test('去重:进行中同 handle 同目的地只留一个;完成后可重新入队', () async {
    final (engine, fake, gallery) = _engine();
    fake..reply(_okBytes(10))..reply(_okBytes(10));

    var done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'A.NEF', 10)],
        destination: TransferDestination.app);
    // 第一个还在跑:同 handle 再入队应被吞掉(脚本只备了一份应答)
    await engine.enqueue([_entry(1, 'A.NEF', 10)],
        destination: TransferDestination.app);
    var tasks = await done;
    expect(tasks, hasLength(1));

    // 完成后重新入队 → 新任务、重新下载(第二份应答)
    done = waitUntil(
        engine, (ts) => ts.length == 2 && ts.every((t) => t.isTerminal));
    await engine.enqueue([_entry(1, 'A.NEF', 10)],
        destination: TransferDestination.app);
    tasks = await done;
    expect(tasks, hasLength(2));
    // 文件名冲突自动加序号
    final names = Directory('${gallery.root.path}/downloads')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    expect(names, containsAll(['A.NEF', 'A (1).NEF']));
  });

  test('失败重试:两次失败后第三次成功;attempts 累计', () async {
    final (engine, fake, gallery) = _engine();
    fake
      ..fail(const PtpResponseException(
          opcode: PtpOperationCode.getObject,
          responseCode: PtpResponseCode.generalError))
      ..fail(const PtpResponseException(
          opcode: PtpOperationCode.getObject,
          responseCode: PtpResponseCode.generalError))
      ..reply(_okBytes(8));

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.state == TransferState.completed);
    await engine.enqueue([_entry(1, 'A.NEF', 8)],
        destination: TransferDestination.app);
    final tasks = await done;

    expect(tasks.single.attempts, 2);
    expect(File('${gallery.root.path}/downloads/A.NEF').existsSync(), isTrue);
  });

  test('重试耗尽:failed,attempts 封顶,错误信息保留', () async {
    final (engine, fake, gallery) = _engine();
    for (var i = 0; i < 4; i++) {
      fake.fail(const PtpResponseException(
          opcode: PtpOperationCode.getObject,
          responseCode: PtpResponseCode.generalError));
    }

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.state == TransferState.failed);
    await engine.enqueue([_entry(1, 'A.NEF', 8)],
        destination: TransferDestination.app);
    final tasks = await done;

    expect(tasks.single.attempts, 3);
    expect(tasks.single.error, contains('0x2002')); // generalError
    expect(Directory('${gallery.root.path}/downloads').listSync(), isEmpty);
  });

  test('clearHistory:清掉终态任务', () async {
    final (engine, fake, gallery) = _engine();
    fake.reply(_okBytes(4));

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'A.NEF', 4)],
        destination: TransferDestination.app);
    await done;

    final emptied = engine.tasks.firstWhere((ts) => ts.isEmpty);
    await engine.clearHistory();
    await emptied;
  });

  test('批次部分取消:仅对已完成者发起导入', () async {
    final (engine, fake, gallery) = _engine();
    final stall = Completer<void>();
    fake.replyAfter(stall.future, _okBytes(6)); // A
    gallery.importResult = [Uri.parse('content://media/9')];

    var bId = '';
    engine.tasks.listen((ts) {
      final b = ts.where((t) => t.filename == 'B.JPG').singleOrNull;
      if (b != null) bId = b.id;
    });
    var done = waitUntil(engine, (ts) =>
        ts.length == 2 &&
        ts.every((t) => t.isTerminal) &&
        gallery.importCalls.length == 1);
    final enqueue = engine.enqueue(
      [_entry(1, 'A.JPG', 6), _entry(2, 'B.JPG', 6)],
      destination: TransferDestination.gallery,
    );
    await pumpEventQueue();
    // A 卡在数据流上(running)时取消 B(queued)
    await engine.cancel(bId);
    stall.complete();
    await enqueue;
    await done;

    expect(gallery.importCalls.single.map((r) => r.filename), ['A.JPG']);
    expect(gallery.importCalls.single.single.path, contains('temp')); // 导入前落临时目录
  });
}

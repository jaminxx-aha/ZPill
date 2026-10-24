import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/features/transfers/transfers_page.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

/// downloadsDir 逐次取用预置的 Completer:两次并发刷新各挂一扇门,门后
/// 给不同目录 —— 旧刷新若未被纪元闸拦下,晚到结果必覆盖新结果,断言即
/// 翻;其余目录方法给无害兜底路径。
final class _GateGallery implements GallerySaver {
  _GateGallery(this.fallbackPath);

  final String fallbackPath;
  final Queue<Completer<String>> gates = Queue();

  @override
  Future<String> downloadsDir() => gates.removeFirst().future;

  @override
  Future<String> tempDir() async => fallbackPath;

  @override
  Future<String> thumbsDir() async => fallbackPath;

  @override
  Future<String> previewsDir() async => fallbackPath;

  @override
  Future<String> dataDir() async => fallbackPath;

  @override
  Future<List<Uri>> importFiles(List<GalleryImportRequest> requests) =>
      Future.value(const []);
}

final class _BareEngine implements TransferEngine {
  @override
  Stream<List<TransferTask>> get tasks => const Stream.empty();

  @override
  Future<void> enqueue(Iterable<ObjectEntry> entries,
      {required TransferDestination destination}) async {}

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> removeRecord(String taskId) async {}

  @override
  Future<void> clearHistory() async {}
}

/// TransfersController.refreshAppFiles 的纪元闸与落空旗标(2026-10-22
/// 列目录异步化随批):并发在途的旧刷新不得覆盖新刷新的结果;通道失败
/// 也算「已扫描」,图库页据此区分扫描窗与真空库。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nikonpill_transfers');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> drain() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('纪元闸:并发在途的旧刷新晚到不覆盖新刷新结果', () async {
    final dirOld = Directory('${root.path}/old')..createSync();
    File('${dirOld.path}/old.jpg').writeAsBytesSync(const [1]);
    final dirNew = Directory('${root.path}/new')..createSync();
    File('${dirNew.path}/new.jpg').writeAsBytesSync(const [1]);

    final gate = _GateGallery(root.path);
    final gateOld = Completer<String>(); // 旧刷新(r1)的门
    final gateNew = Completer<String>(); // 新刷新(r2)的门
    gate.gates.addAll([gateOld, gateNew]);
    final controller =
        TransfersController(engine: _BareEngine(), gallery: gate);
    addTearDown(controller.dispose);

    final r1 = controller.refreshAppFiles();
    await drain(); // r1 已挂在自己的门上
    final r2 = controller.refreshAppFiles();
    await drain(); // r2 已挂在自己的门上(纪元已推进)

    gateNew.complete(dirNew.path); // 先放新刷新
    await r2;
    expect(controller.appFiles.map((f) => f.path.split('/').last), ['new.jpg']);
    expect(controller.appFilesScanned, isTrue);

    gateOld.complete(dirOld.path); // 再放旧刷新(晚到)
    await r1;
    expect(controller.appFiles.map((f) => f.path.split('/').last), ['new.jpg'],
        reason: '旧纪元结果必须被弃,不得覆盖新结果');
  });

  test('通道失败落空:appFiles 清空且 appFilesScanned 置位(真空库可分)', () async {
    final gate = _GateGallery(root.path);
    final gateFail = Completer<String>();
    gate.gates.add(gateFail);
    final controller =
        TransfersController(engine: _BareEngine(), gallery: gate);
    addTearDown(controller.dispose);

    final refreshing = controller.refreshAppFiles();
    await drain();
    gateFail.completeError(const FileSystemException('无通道'));
    await refreshing;

    expect(controller.appFiles, isEmpty);
    expect(controller.appFilesScanned, isTrue, reason: '失败也算扫描已收口');
  });
}

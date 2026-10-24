import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/media/motion_photo.dart' show injectXmpApp1;
import 'package:nikon_pill/core/media/watermark.dart';
import 'package:nikon_pill/core/media/xmp_metadata.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';
import 'package:nikon_pill/core/transfer/transfer_engine.dart';
import 'package:nikon_pill/core/transfer/transfer_task.dart';
import 'package:nikon_pill/platform/gallery_saver.dart';

import '../ptp/ptp_session_harness.dart'
    show FakePtpTransport, buildDeviceInfoDataset;

/// 假相册:目录落在真实临时目录(验证落盘/清理),导入行为可配置。
final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver()
      : root = Directory.systemTemp.createTempSync('nikonpill_engine_test');

  final Directory root;

  /// 每次 importFiles 的请求快照。
  final List<List<GalleryImportRequest>> importCalls = [];

  /// 导入时刻各请求文件的 mtime 快照(gallery 不回写拍摄时刻的用例:
  /// 临时文件收尾即删,mtime 断言只能落在导入时刻)。
  final List<List<DateTime>> importMtimes = [];

  /// 导入时刻各请求的 (path 字节, videoPath 字节) 快照;[captureBytes]
  /// 开启时取样 —— 收尾后临时文件即删,断言只能落在导入时刻。
  final List<List<(Uint8List?, Uint8List?)>> importSnapshots = [];
  var captureBytes = false;

  /// importFiles 的应答(默认空列表 = 用户取消对话框)。
  List<Uri> importResult = const [];

  @override
  Future<String> dataDir() async => _ensure('${root.path}/data');

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
    importMtimes.add([
      for (final r in requests) File(r.path).statSync().modified,
    ]);
    if (captureBytes) {
      importSnapshots.add([
        for (final r in requests)
          (_readIfExists(r.path),
              r.videoPath == null ? null : _readIfExists(r.videoPath!)),
      ]);
    }
    return importResult;
  }

  static Uint8List? _readIfExists(String path) {
    final f = File(path);
    return f.existsSync() ? f.readAsBytesSync() : null;
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
        {ObjectKind kind = ObjectKind.image, DateTime? capturedAt}) =>
    ObjectEntry(
        handle: handle,
        name: name,
        sizeInBytes: size,
        kind: kind,
        capturedAt: capturedAt);

PtpResult _okData(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

PtpResult _okBytes(int n) =>
    _okData(Uint8List.fromList(List.generate(n, (i) => i & 0xFF)));

/// 最小 JPEG 载荷(SOI + APP0 + SOS + 数据 + EOI):注入路径用真图。
Uint8List _jpegPayload() => Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE0, 0x00, 0x10,
      ...'JFIF'.codeUnits, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xFF, 0xDA, 0x00, 0x02,
      0x12, 0x34, 0x56, 0x78,
      0xFF, 0xD9,
    ]);

/// 等快照流上出现满足 [test] 的快照(须在 enqueue 之前订阅)。
Future<List<TransferTask>> waitUntil(TransferEngine engine,
    bool Function(List<TransferTask>) test) {
  return engine.tasks
      .firstWhere(test)
      .timeout(const Duration(seconds: 5));
}

/// 引擎(重试零退避,测试不等)。
(TransferEngineImpl, FakePtpTransport, FakeGallerySaver) _engine(
    {Future<XmpMetadata?> Function(ObjectEntry entry)? metadataFor,
    Future<WatermarkOptions?> Function(ObjectEntry entry)? watermarkFor,
    TextRaster? watermarkRaster,
    Future<void> Function(ObjectEntry entry, String path)? onAppFileSaved}) {
  final fake = FakePtpTransport();
  final gallery = FakeGallerySaver();
  final engine = TransferEngineImpl(
    downloader: ObjectDownloader(session: PtpSession(transport: fake)),
    gallery: gallery,
    metadataFor: metadataFor,
    watermarkFor: watermarkFor,
    watermarkRaster: watermarkRaster,
    onAppFileSaved: onAppFileSaved,
    backoffFor: (_) => Duration.zero,
  );
  return (engine, fake, gallery);
}

/// 60×40 渐变 JPEG:水印用真图(解码 → 叠字 → 重编码)。
Uint8List _gradientJpeg() {
  final photo = img.Image(width: 60, height: 40);
  for (final p in photo) {
    p
      ..r = (p.x * 4) & 0xFF
      ..g = (p.y * 6) & 0xFF
      ..b = 128
      ..a = 255;
  }
  return Uint8List.fromList(img.encodeJpg(photo));
}

/// 假文本光栅:红色实心块(watermark_test 同款,免 dart:ui)。
Future<img.Image> _fakeRaster(String text, double fontSizePx, int color) async {
  final h = fontSizePx.round();
  final image = img.Image(width: h * text.length ~/ 2 + 4, height: h);
  img.fillRect(image,
      x1: 0, y1: 0, x2: image.width - 1, y2: image.height - 1,
      color: img.ColorRgba8(200, 30, 30, 255));
  return image;
}

/// 最小 MP4(ftyp box,16 字节):运动照片尾段的合法视频段。
Uint8List _mp4Payload() => Uint8List.fromList(
    [0, 0, 0, 16, ...'ftyp'.codeUnits, ...'isom'.codeUnits, 0, 0, 0, 0]);

/// MicroVideoOffset 元素式 XMP 包(与 spliceMotionPhoto 同款)。
String _microXmp(int offset) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/" '
    'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">'
    '<GCamera:MicroVideoOffset>$offset</GCamera:MicroVideoOffset></x:xmpmeta>';

/// 真可解码的运动照片 JPEG:XMP 标记(静帧长度记录视频段长)+ MP4 尾段。
/// 返回 (整文件, 剥离视频段后的静帧)。
(Uint8List, Uint8List) _motionPhotoJpg(Uint8List mp4) {
  final still = injectXmpApp1(_gradientJpeg(), _microXmp(mp4.length));
  return (Uint8List.fromList([...still, ...mp4]), still);
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

  test('取消 running(分块在途):软取消等在途块跑完,任务 cancelled 不重试',
      () async {
    final fake = FakePtpTransport();
    final gallery = FakeGallerySaver();
    final engine = TransferEngineImpl(
      downloader: ObjectDownloader(
        session: PtpSession(transport: fake),
        partialChunkBytes: 64,
      ),
      gallery: gallery,
      backoffFor: (_) => Duration.zero,
    );
    // 0x101B 在册 + 第一块挂闸(128B = 两块,第二块永不发出)
    fake.reply(_okData(
        buildDeviceInfoDataset(operations: const [0x1001, 0x1009, 0x101B])));
    final gate = Completer<void>();
    fake.replyAfter(
        gate.future, _okData(Uint8List.fromList(List.filled(64, 7))));

    var aId = '';
    engine.tasks.listen((ts) {
      if (aId.isEmpty) aId = ts.single.id;
    });
    await engine.enqueue([_entry(1, 'A.NEF', 128)],
        destination: TransferDestination.app);
    // 等第一块真正挂进传输层(running 快照可能先于块请求到达,过早
    // cancel 只走「块间旗标」短路)
    while (fake.requests.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // 取消立即返回(闸未放,任务未落定);不发 Cancel 包(2026-10-16
    // 真机:Zf 收 Cancel 掐链)
    await engine.cancel(aId);
    expect(fake.cancelInFlightCalls, 0);

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.state == TransferState.cancelled);
    gate.complete(); // 在途块跑完
    final tasks = await done;

    // 取消成功:不是 failed、零重试、半成品已删
    expect(tasks.single.attempts, 0);
    expect(Directory('${gallery.root.path}/downloads').listSync(), isEmpty);
  });

  test('进度通知节流:高频块进度合并广播,终态即时', () async {
    final fake = FakePtpTransport();
    final gallery = FakeGallerySaver();
    final engine = TransferEngineImpl(
      downloader: ObjectDownloader(
        session: PtpSession(transport: fake),
        partialChunkBytes: 64,
      ),
      gallery: gallery,
      backoffFor: (_) => Duration.zero,
    );
    // 0x101B 在册 + 20 块连续回放(64B × 20 = 1280B):块间微任务级,
    // 全程落在 100ms 节流窗内,逐块广播(旧实现 20+ 发)应合并。
    fake.reply(_okData(
        buildDeviceInfoDataset(operations: const [0x1001, 0x1009, 0x101B])));
    const chunks = 20;
    for (var i = 0; i < chunks; i++) {
      fake.reply(_okData(Uint8List.fromList(List.filled(64, i))));
    }

    var progressSnapshots = 0;
    engine.tasks.listen((ts) {
      final t = ts.single;
      if (t.state == TransferState.running && t.receivedBytes > 0) {
        progressSnapshots++;
      }
    });

    final done = waitUntil(
        engine, (ts) => ts.single.isTerminal && ts.single.receivedBytes == chunks * 64);
    await engine.enqueue([_entry(1, 'A.NEF', chunks * 64)],
        destination: TransferDestination.app);
    await done;

    // 领界 1 + 尾随 ≤1 为预期;CI 慢机(块间偶超 100ms)留余量到 5,
    // 仍远小于逐块广播的 20。
    expect(progressSnapshots, lessThanOrEqualTo(5));
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

  test('metadataFor:JPG 落盘后注入 XMP;NEF 不问也不改', () async {
    final asked = <String>[];
    final (engine, fake, gallery) = _engine(
        metadataFor: (entry) async {
      asked.add(entry.name);
      return const XmpMetadata(creator: 'Aha', rating: 4);
    });
    final jpeg = _jpegPayload();
    final raw = Uint8List.fromList(List.generate(9, (i) => i));
    fake..reply(_okData(jpeg))..reply(_okData(raw));

    final done = waitUntil(
        engine, (ts) => ts.length == 2 && ts.every((t) => t.isTerminal));
    await engine.enqueue([
      _entry(1, 'DSC_1.JPG', jpeg.length),
      _entry(2, 'DSC_1.NEF', raw.length),
    ], destination: TransferDestination.app);
    final tasks = await done;

    expect(tasks.every((t) => t.state == TransferState.completed), isTrue);
    expect(asked, ['DSC_1.JPG']); // NEF 根本不问提供器
    final jpgOut = await File('${gallery.root.path}/downloads/DSC_1.JPG')
        .readAsBytes();
    expect(jpgOut.length, greaterThan(jpeg.length)); // 已注入
    expect(String.fromCharCodes(jpgOut), contains('dc:creator'));
    expect(String.fromCharCodes(jpgOut), contains('Aha'));
    // NEF 原样(不含 XMP 段)
    final nefOut = await File('${gallery.root.path}/downloads/DSC_1.NEF')
        .readAsBytes();
    expect(nefOut, raw);
  });

  test('metadataFor 抛异常 / 返回空:任务照常完成,文件原样', () async {
    final jpeg = _jpegPayload();
    final (engine, fake, gallery) = _engine(metadataFor: (entry) async {
      if (entry.name == 'DSC_1.JPG') throw Exception('boom');
      return const XmpMetadata(); // 空:提供器给了也不注入
    });
    fake..reply(_okData(jpeg))..reply(_okData(jpeg));

    final done = waitUntil(
        engine, (ts) => ts.length == 2 && ts.every((t) => t.isTerminal));
    await engine.enqueue([
      _entry(1, 'DSC_1.JPG', jpeg.length), // 提供器抛异常
      _entry(2, 'DSC_2.JPG', jpeg.length), // 返回空元数据 → identical 免写
    ], destination: TransferDestination.app);
    await done;

    expect(Directory('${gallery.root.path}/downloads').listSync(), hasLength(2));
    for (final name in ['DSC_1.JPG', 'DSC_2.JPG']) {
      expect(
          await File('${gallery.root.path}/downloads/$name').readAsBytes(),
          jpeg);
    }
  });

  test('watermarkFor:JPG 先水印后 XMP;NEF 两者皆不碰', () async {
    final jpeg = _gradientJpeg();
    final (engine, fake, gallery) = _engine(
      metadataFor: (entry) async => const XmpMetadata(creator: 'Aha'),
      watermarkFor: (entry) async =>
          const WatermarkOptions(style: WatermarkStyle.corner),
      watermarkRaster: _fakeRaster,
    );
    fake..reply(_okData(jpeg))..reply(_okBytes(9));

    final done = waitUntil(
        engine, (ts) => ts.length == 2 && ts.every((t) => t.isTerminal));
    await engine.enqueue([
      _entry(1, 'DSC_1.JPG', jpeg.length),
      _entry(2, 'DSC_2.NEF', 9),
    ], destination: TransferDestination.app);
    await done;

    // JPG:水印重编码(角标在画幅内,字节已非原样)+ XMP 追加其后
    //(顺序反了的话,重编码会把 XMP APP1 一起丢掉)。
    final jpgBytes =
        await File('${gallery.root.path}/downloads/DSC_1.JPG').readAsBytes();
    expect(jpgBytes, isNot(equals(jpeg)));
    final decoded = img.decodeJpg(jpgBytes);
    expect(decoded!.width, 60);
    expect(decoded.height, 40);
    // 角标落点:fontSize 16 → margin 11,badge 缩到 maxW=38、高 8,
    // dstX=11、dstY=21 → (30, 24) 在红块内。
    final p = decoded.getPixel(30, 24);
    expect(p.r, greaterThan(150));
    expect(p.g, lessThan(90));
    final text = utf8.decode(jpgBytes, allowMalformed: true);
    expect(text, contains('dc:creator'));
    expect(text, contains('Aha'));

    // NEF:水印与 XMP 均跳过,原字节落盘
    final nefBytes =
        await File('${gallery.root.path}/downloads/DSC_2.NEF').readAsBytes();
    expect(nefBytes, List.generate(9, (i) => i & 0xFF));
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

  test('gallery 内嵌运动照片:静帧剥离视频段,请求带 videoPath 配对导入', () async {
    final (engine, fake, gallery) = _engine();
    gallery.captureBytes = true;
    final mp4 = _mp4Payload();
    final (motion, still) = _motionPhotoJpg(mp4);
    fake.reply(_okData(motion));
    gallery.importResult = [Uri.parse('content://media/live1')];

    final done = waitUntil(engine, (ts) =>
        ts.length == 1 &&
        ts.single.state == TransferState.completed &&
        ts.single.galleryUri != null);
    await engine.enqueue([_entry(1, 'DSC_0001.JPG', motion.length)],
        destination: TransferDestination.gallery);
    await done;

    // 单请求:静帧文件 + 拆出的视频段临时文件
    expect(gallery.importCalls, hasLength(1));
    final req = gallery.importCalls.single.single;
    expect(req.kind, ObjectKind.image);
    expect(req.videoPath, isNotNull);
    expect(req.videoPath, isNot(req.path));
    final (stillBytes, videoBytes) = gallery.importSnapshots.single.single;
    expect(stillBytes, still); // 静帧 = 剥离后的原样(无水印/XMP 后处理)
    expect(videoBytes, mp4); // 视频段完整落临时文件
    // 静帧与视频段临时文件都清干净
    expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty);
  });

  test('gallery 同基名 JPG+MOV:并成单个实况请求,两成员回填同一 Uri', () async {
    final (engine, fake, gallery) = _engine();
    gallery.captureBytes = true;
    final jpeg = _gradientJpeg();
    final mov = Uint8List.fromList(List.generate(40, (i) => i & 0xFF));
    fake..reply(_okData(jpeg))..reply(_okData(mov));
    gallery.importResult = [Uri.parse('content://media/live2')];

    final done = waitUntil(engine, (ts) =>
        ts.length == 2 &&
        ts.every((t) => t.state == TransferState.completed) &&
        ts.every((t) => t.galleryUri == Uri.parse('content://media/live2')));
    await engine.enqueue([
      _entry(1, 'DSC_0001.JPG', jpeg.length),
      _entry(2, 'DSC_0001.MOV', mov.length, kind: ObjectKind.video),
    ], destination: TransferDestination.gallery);
    await done;

    // 不再单发 MOV:静帧请求携带 videoPath 配对
    expect(gallery.importCalls, hasLength(1));
    final req = gallery.importCalls.single.single;
    expect(req.filename, 'DSC_0001.JPG');
    expect(req.videoPath, isNotNull);
    final (stillBytes, videoBytes) = gallery.importSnapshots.single.single;
    expect(stillBytes, jpeg);
    expect(videoBytes, mov);
    // 两份临时文件(JPG + MOV)都清干净
    expect(Directory('${gallery.root.path}/temp').listSync(), isEmpty);
  });

  test('app 目的地:运动照片保留相机原始单文件不拆', () async {
    final (engine, fake, gallery) = _engine();
    final mp4 = _mp4Payload();
    final (motion, _) = _motionPhotoJpg(mp4);
    fake.reply(_okData(motion));

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'DSC_0001.JPG', motion.length)],
        destination: TransferDestination.app);
    await done;

    expect(await File('${gallery.root.path}/downloads/DSC_0001.JPG')
        .readAsBytes(), motion);
  });

  test('运动照片先拆后水印:静帧重编码,视频段原样保留', () async {
    final (engine, fake, gallery) = _engine(
        watermarkFor: (entry) async =>
            const WatermarkOptions(style: WatermarkStyle.corner),
        watermarkRaster: _fakeRaster);
    gallery.captureBytes = true;
    final mp4 = _mp4Payload();
    final (motion, still) = _motionPhotoJpg(mp4);
    fake.reply(_okData(motion));

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'DSC_0001.JPG', motion.length)],
        destination: TransferDestination.gallery);
    await done;

    expect(gallery.importCalls, hasLength(1));
    final (stillBytes, videoBytes) = gallery.importSnapshots.single.single;
    // 水印重编码后静帧已非剥离原样(顺序反了会把内嵌视频段一起毁掉)
    expect(stillBytes, isNot(equals(still)));
    expect(img.decodeJpg(stillBytes!)!.width, 60);
    // 视频段先拆出来了,不受重编码影响
    expect(videoBytes, mp4);
  });

  // ── 落盘回写拍摄时刻(本地图库连拍聚合的前提)──

  test('app 目的地:entry 带拍摄时刻 → 落盘 mtime 回写为拍摄时刻', () async {
    final (engine, fake, gallery) = _engine();
    fake.reply(_okBytes(12));
    final capturedAt = DateTime(2026, 10, 1, 9, 30, 5);

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'A.NEF', 12, capturedAt: capturedAt)],
        destination: TransferDestination.app);
    final tasks = await done;

    expect(tasks.single.state, TransferState.completed);
    // mtime ≈ 拍摄时刻(setLastModified 异步落盘,文件系统精度不一,
    // 容差 ±2s,不写死毫秒级相等)
    final mtime =
        File('${gallery.root.path}/downloads/A.NEF').statSync().modified;
    expect(mtime.difference(capturedAt).abs(),
        lessThan(const Duration(seconds: 2)));
  });

  test('app 目的地:entry 无拍摄时刻 → mtime 保持落盘时刻不回写', () async {
    final (engine, fake, gallery) = _engine();
    fake.reply(_okBytes(12));

    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'A.NEF', 12)],
        destination: TransferDestination.app);
    await done;

    // 无 capturedAt:不回写,mtime = 落盘时刻(≈ 现在)
    final mtime =
        File('${gallery.root.path}/downloads/A.NEF').statSync().modified;
    expect(mtime.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 2)));
  });

  test('gallery 目的地:不回写拍摄时刻(临时文件导入后即删)', () async {
    final (engine, fake, gallery) = _engine();
    fake.reply(_okBytes(12));
    gallery.importResult = [Uri.parse('content://media/1')];
    // 拍摄时刻取远离落盘时刻的旧值:若被误写,导入时刻快照即穿帮
    final capturedAt = DateTime(2020, 1, 1);

    final done = waitUntil(engine, (ts) =>
        ts.length == 1 &&
        ts.single.state == TransferState.completed &&
        ts.single.galleryUri != null);
    await engine.enqueue([_entry(1, 'A.JPG', 12, capturedAt: capturedAt)],
        destination: TransferDestination.gallery);
    await done;

    // 导入时刻临时文件 mtime 仍是落盘时刻(≈ 现在),未被拍摄时刻覆写
    expect(gallery.importMtimes, hasLength(1));
    final mtime = gallery.importMtimes.single.single;
    expect(mtime.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 2)));
  });

  test('onAppFileSaved:app 目的地单文件落盘沿回调(entry+路径);'
      'gallery 目的地不回调;回调抛异常任务照常完成', () async {
    final saved = <(ObjectEntry, String)>[];
    // app 目的地:回调一次,参数 = 条目 + 落盘路径。
    final (engine, fake, _) = _engine(onAppFileSaved: (entry, path) async {
      saved.add((entry, path));
    });
    fake.reply(_okBytes(12));
    final done = waitUntil(
        engine, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine.enqueue([_entry(1, 'A.NEF', 12)],
        destination: TransferDestination.app);
    final tasks = await done;
    expect(tasks.single.state, TransferState.completed);
    expect(saved, hasLength(1));
    expect(saved.single.$1.handle, 1);
    expect(saved.single.$2, endsWith('A.NEF'));

    // gallery 目的地:不回调。
    final (engine2, fake2, gallery2) =
        _engine(onAppFileSaved: (entry, path) async {
      saved.add((entry, path));
    });
    fake2.reply(_okBytes(12));
    gallery2.importResult = [Uri.parse('content://media/1')];
    final done2 = waitUntil(engine2, (ts) =>
        ts.length == 1 &&
        ts.single.state == TransferState.completed &&
        ts.single.galleryUri != null);
    await engine2.enqueue([_entry(2, 'B.JPG', 12)],
        destination: TransferDestination.gallery);
    await done2;
    expect(saved, hasLength(1)); // 未新增

    // 回调抛异常:任务照常 completed(收尾扩展点失败不挡传输)。
    final (engine3, fake3, _) =
        _engine(onAppFileSaved: (entry, path) async => throw Exception('boom'));
    fake3.reply(_okBytes(12));
    final done3 = waitUntil(
        engine3, (ts) => ts.length == 1 && ts.single.isTerminal);
    await engine3.enqueue([_entry(3, 'C.NEF', 12)],
        destination: TransferDestination.app);
    final tasks3 = await done3;
    expect(tasks3.single.state, TransferState.completed);
  });
}

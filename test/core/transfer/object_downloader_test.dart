import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/aimd_chunk.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';

import '../ptp/ptp_session_harness.dart'
    show FakePtpTransport, buildDeviceInfoDataset;

ObjectEntry _entry(String name, int size, {int handle = 0x12}) => ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: size,
      kind: ObjectKind.image,
    );

PtpResult _okData(Uint8List data) =>
    PtpResult(responseCode: PtpResponseCode.ok, data: data);

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nikonpill_dl_test');
  });
  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  ObjectDownloader downloaderFor(FakePtpTransport fake) =>
      ObjectDownloader(session: PtpSession(transport: fake));

  test('流式落盘:文件字节逐一相符,进度按块回调,测速字段非零', () async {
    final fake = FakePtpTransport();
    final downloader = downloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(300000, (i) => i & 0xFF));
    fake.reply(_okData(payload));

    final progresses = <int>[];
    final result = await downloader.download(
        _entry('DSC_0001.NEF', payload.length),
        targetDir: dir.path,
        onProgress: progresses.add);

    // FakePtpTransport 把数据切两半回调:两块进度,末值 = 文件大小。
    expect(progresses, [150000, 300000]);
    expect(result.bytes, payload.length);
    expect(result.averageBytesPerSecond, greaterThan(0));
    expect(result.elapsed, greaterThanOrEqualTo(Duration.zero));

    final file = File(result.path);
    expect(file.parent.path, dir.path); // 落在指定目标目录内
    expect(await file.readAsBytes(), payload);
  });

  test('取消:停止写盘、排空数据流、删半成品、抛取消异常', () async {
    final fake = FakePtpTransport();
    final downloader = downloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(100, (i) => i));
    fake.reply(_okData(payload));

    var cancelAfterFirstChunk = false;
    final progresses = <int>[];
    await expectLater(
      downloader.download(
        _entry('DSC_0002.NEF', 100),
        targetDir: dir.path,
        onProgress: (received) {
          progresses.add(received);
          cancelAfterFirstChunk = true; // 第一块收完即请求取消
        },
        isCancelled: () => cancelAfterFirstChunk,
      ),
      throwsA(isA<DownloadCancelledException>()),
    );
    // 第二块照常送达(排空)但不再写盘/报进度。
    expect(progresses, [50]);
    expect(await dir.list().toList(), isEmpty); // 半成品已删
  });

  test('GetObject 被拒:上抛且不留半成品', () async {
    final fake = FakePtpTransport();
    final downloader = downloaderFor(fake);

    // 拒绝码用表内在册的 generalError:本测试验证失败清理,不针对特定码。
    fake.fail(const PtpResponseException(
      opcode: PtpOperationCode.getObject,
      responseCode: PtpResponseCode.generalError,
    ));

    await expectLater(
      downloader.download(_entry('DSC_0003.NEF', 100), targetDir: dir.path),
      throwsA(isA<PtpResponseException>()),
    );
    expect(await dir.list().toList(), isEmpty); // 半成品已删
  });

  test('文件名只取最后一段(防御路径分隔符)', () async {
    final fake = FakePtpTransport();
    final downloader = downloaderFor(fake);

    fake.reply(_okData(Uint8List.fromList([9, 9, 9])));

    final result = await downloader.download(_entry('evil/name.NEF', 3),
        targetDir: dir.path);

    expect(File(result.path).uri.pathSegments.last, 'name.NEF');
  });

  test('uniquePath:目录内重名自动加 ` (n)` 序号', () async {
    File('${dir.path}/A.JPG').writeAsBytesSync([1]);
    File('${dir.path}/A (1).JPG').writeAsBytesSync([1]);

    expect(await ObjectDownloader.uniquePath(dir, 'A.JPG'),
        '${dir.path}/A (2).JPG');
    expect(await ObjectDownloader.uniquePath(dir, 'B.NEF'),
        '${dir.path}/B.NEF'); // 无冲突:原名
    expect(await ObjectDownloader.uniquePath(dir, 'noext'),
        '${dir.path}/noext'); // 无扩展名也能消歧
  });

  // ── GetPartialObject 分块路线(iOS IC 单回调风险的主修法) ────────

  /// 0x101B 在册的设备信息应答(分块路线的门禁前提)。
  PtpResult deviceInfoWithPartial() => _okData(
      buildDeviceInfoDataset(operations: const [0x1001, 0x1009, 0x101B]));

  ObjectDownloader chunkedDownloaderFor(FakePtpTransport fake,
          {int chunkBytes = 50}) =>
      ObjectDownloader(
          session: PtpSession(transport: fake), partialChunkBytes: chunkBytes);

  test('分块下载:按偏移逐块取,拼回整档,进度按块累计', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(120, (i) => i));
    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(Uint8List.sublistView(payload, 0, 50)));
    fake.reply(_okData(Uint8List.sublistView(payload, 50, 100)));
    fake.reply(_okData(Uint8List.sublistView(payload, 100, 120)));

    final progresses = <int>[];
    final result = await downloader.download(_entry('DSC_0004.NEF', 120),
        targetDir: dir.path, onProgress: progresses.add);

    expect(progresses, [50, 100, 120]);
    expect(await File(result.path).readAsBytes(), payload);
    // 事务序列:GetDeviceInfo 门禁 + 三次 0x101B(句柄/偏移/长度对账)。
    expect(fake.requests.map((r) => r.opcode), [
      PtpOperationCode.getDeviceInfo,
      ...List.filled(3, PtpOperationCode.getPartialObject)
    ]);
    expect(fake.requests[1].params, [0x12, 0, 50]); // 末块要足不越界
    expect(fake.requests[2].params, [0x12, 50, 50]);
    expect(fake.requests[3].params, [0x12, 100, 20]);
  });

  test('分块取消:块间停发新命令,删半成品,抛取消异常', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(Uint8List.fromList(List.filled(50, 7))));

    var cancelAfterFirstChunk = false;
    await expectLater(
      downloader.download(
        _entry('DSC_0005.NEF', 120),
        targetDir: dir.path,
        onProgress: (_) => cancelAfterFirstChunk = true,
        isCancelled: () => cancelAfterFirstChunk,
      ),
      throwsA(isA<DownloadCancelledException>()),
    );
    // 只发了门禁 + 第一块:取消后不再发新事务(无排空义务)。
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, PtpOperationCode.getPartialObject]);
    expect(await dir.list().toList(), isEmpty); // 半成品已删
  });

  test('分块短读:实收不足按大小对账,FormatException 且不留半成品', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(Uint8List.fromList(List.filled(30, 1)))); // 短读 30/50

    await expectLater(
      downloader.download(_entry('DSC_0006.NEF', 120), targetDir: dir.path),
      throwsA(isA<FormatException>()),
    );
    expect(await dir.list().toList(), isEmpty);
  });

  test('0x101B 不在册:忽略分块参数,回落整档 GetObject', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(80, (i) => i));
    fake.reply(_okData(buildDeviceInfoDataset())); // 默认表无 0x101B
    fake.reply(_okData(payload));

    final result = await downloader.download(_entry('DSC_0007.NEF', 80),
        targetDir: dir.path);

    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, PtpOperationCode.getObject]);
    expect(await File(result.path).readAsBytes(), payload);
  });

  test('分块被相机拒:上抛 PtpResponseException 且不留半成品', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    fake.reply(deviceInfoWithPartial());
    fake.fail(const PtpResponseException(
      opcode: PtpOperationCode.getPartialObject,
      responseCode: PtpResponseCode.generalError,
    ));

    await expectLater(
      downloader.download(_entry('DSC_0008.NEF', 100), targetDir: dir.path),
      throwsA(isA<PtpResponseException>()),
    );
    expect(await dir.list().toList(), isEmpty);
  });

  // ── 分块在途取消(软取消:不发 Cancel 包,2026-10-16 真机定案)──

  test(
      '分块在途取消:不发 Cancel 包(Zf 收 Cancel 掐链),等在途块跑完 '
      '按「取消成功」收场,不再发新块', () async {
    final fake = FakePtpTransport();
    final downloader = chunkedDownloaderFor(fake);

    fake.reply(deviceInfoWithPartial());
    final gate = Completer<void>();
    fake.replyAfter(gate.future,
        _okData(Uint8List.fromList(List.filled(64, 7)))); // 在途块正常跑完

    var flip = false;
    final future = downloader.download(
      _entry('DSC_0009.NEF', 120),
      targetDir: dir.path,
      isCancelled: () => flip,
    );
    // 门禁 + 第一块已发出,块挂在相机闸上
    await pumpEventQueue();
    await pumpEventQueue();
    expect(fake.requests.map((r) => r.opcode).last,
        PtpOperationCode.getPartialObject);
    expect(fake.cancelInFlightCalls, 0,
        reason: '分块路线不发 Cancel 包(2026-10-16 真机:取消即断链)');

    flip = true; // 用户取消:块在途
    gate.complete(); // 在途块跑完
    await expectLater(future, throwsA(isA<DownloadCancelledException>()));
    // 取消后不再发新块;半成品已删
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, PtpOperationCode.getPartialObject]);
    expect(await dir.list().toList(), isEmpty);
  });

  test('整档 GetObject 路线不挂 Cancel-Drain:取消仍走排空旧语义', () async {
    final fake = FakePtpTransport();
    final downloader = downloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(100, (i) => i));
    fake.reply(_okData(payload));

    var flip = false;
    final future = downloader.download(
      _entry('DSC_0010.NEF', 100),
      targetDir: dir.path,
      onProgress: (_) => flip = true, // 第一块到即取消
      isCancelled: () => flip,
    );
    await expectLater(future, throwsA(isA<DownloadCancelledException>()));
    // GetObject 路线无取消轮询:全程零 Cancel 调用
    expect(fake.cancelInFlightCalls, 0);
    expect(await dir.list().toList(), isEmpty);
  });

  // ── AIMD 自适应分块(块大小随策略演化)───────────────────────────

  /// 小数值策略:min 64 / 步长 32,阈值 1 天 = 一律判快(上界/初值可调)。
  AimdChunkPolicy fastAlwaysPolicy({int maxBytes = 200, int? initialBytes}) =>
      AimdChunkPolicy(
          minBytes: 64,
          maxBytes: maxBytes,
          stepBytes: 32,
          initialBytes: initialBytes,
          fastThreshold: const Duration(days: 1));

  Uint8List filler(int n) => Uint8List.fromList(List.filled(n, 7));

  test('AIMD 接线:快块加性升,块请求 maxBytes 逐块跟随策略到封顶', () async {
    final fake = FakePtpTransport();
    final policy = fastAlwaysPolicy();
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 200,
      chunkPolicy: policy,
    );

    // 1040B = 64+96+128+160+192+200+200:第 5 块后到 200 封顶走平。
    fake.reply(deviceInfoWithPartial());
    for (final n in [64, 96, 128, 160, 192, 200, 200]) {
      fake.reply(_okData(filler(n)));
    }
    final result = await downloader.download(_entry('DSC_0011.NEF', 1040),
        targetDir: dir.path);

    expect(result.bytes, 1040);
    // 门禁 + 七块:偏移/请求大小逐块对账(64→96→128→160→192→200→200)。
    expect(
      fake.requests.skip(1).map((r) => r.params),
      [
        [0x12, 0, 64],
        [0x12, 64, 96],
        [0x12, 160, 128],
        [0x12, 288, 160],
        [0x12, 448, 192],
        [0x12, 640, 200],
        [0x12, 840, 200],
      ],
    );
    expect(policy.currentBytes, 200); // 封顶

    // 同下载器(同传输会话)下一档:设备信息走会话缓存(不再发门禁),
    // 首块即从封顶值起步 —— 学习跨档延续。
    fake.reply(_okData(filler(200)));
    await downloader.download(_entry('DSC_0012.NEF', 200), targetDir: dir.path);
    expect(fake.requests.last.params, [0x12, 0, 200]);
  });

  test('AIMD 接线:成功但慢(> 阈值)块大小不动', () async {
    final fake = FakePtpTransport();
    final policy = AimdChunkPolicy(
        minBytes: 64,
        maxBytes: 200,
        stepBytes: 32,
        fastThreshold: const Duration(milliseconds: -1)); // 一律判慢
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 200,
      chunkPolicy: policy,
    );

    fake.reply(deviceInfoWithPartial());
    for (final n in [64, 64, 64, 8]) {
      fake.reply(_okData(filler(n)));
    }
    final result = await downloader.download(_entry('DSC_0013.NEF', 200),
        targetDir: dir.path);

    expect(result.bytes, 200);
    expect(fake.requests.skip(1).map((r) => r.params[2]), [64, 64, 64, 8]);
    expect(policy.currentBytes, 64); // 全程 hold 在起步值
  });

  test('AIMD 接线:块超时喂降 —— 减半,下一档从降后大小起步', () async {
    final fake = FakePtpTransport();
    final policy = fastAlwaysPolicy(maxBytes: 1024, initialBytes: 512);
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 1024,
      chunkPolicy: policy,
    );

    // 第一档:首块 512B 超时 → 乘性减半到 256,下载失败。
    fake.reply(deviceInfoWithPartial());
    fake.fail(TimeoutException('单块读超时'));
    await expectLater(
      downloader.download(_entry('DSC_0014.NEF', 512), targetDir: dir.path),
      throwsA(isA<TimeoutException>()),
    );
    expect(policy.currentBytes, 256);

    // 第二档(同下载器,门禁走会话缓存):首块请求即从 256 起步。
    fake.reply(_okData(filler(256)));
    await downloader.download(_entry('DSC_0015.NEF', 256), targetDir: dir.path);
    expect(fake.requests.last.params, [0x12, 0, 256]);
    expect(policy.currentBytes, 288); // 降后照常续升(+32)
  });

  test('AIMD 接线:传输错误喂降(与超时同口径)', () async {
    final fake = FakePtpTransport();
    final policy = fastAlwaysPolicy(maxBytes: 1024, initialBytes: 512);
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 1024,
      chunkPolicy: policy,
    );

    fake.reply(deviceInfoWithPartial());
    fake.fail(const PtpResponseException(
      opcode: PtpOperationCode.getPartialObject,
      responseCode: PtpResponseCode.generalError,
    ));
    await expectLater(
      downloader.download(_entry('DSC_0016.NEF', 512), targetDir: dir.path),
      throwsA(isA<PtpResponseException>()),
    );
    expect(policy.currentBytes, 256); // 512 → 256

    // 第二档(同下载器,门禁走会话缓存):首块从 256 起步。
    fake.reply(_okData(filler(256)));
    await downloader.download(_entry('DSC_0017.NEF', 256), targetDir: dir.path);
    expect(fake.requests.last.params, [0x12, 0, 256]);
  });

  test('AIMD 接线:取消路在途块跑完照常喂策略(不发 Cancel 包,档位延续)',
      () async {
    final fake = FakePtpTransport();
    final policy = fastAlwaysPolicy(initialBytes: 128);
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 200,
      chunkPolicy: policy,
    );

    // 第一档:块在途用户取消(软取消:等在途块跑完)。
    fake.reply(deviceInfoWithPartial());
    final gate = Completer<void>();
    fake.replyAfter(gate.future, _okData(filler(128)));

    var flip = false;
    final future = downloader.download(
      _entry('DSC_0018.NEF', 256),
      targetDir: dir.path,
      isCancelled: () => flip,
    );
    await pumpEventQueue();
    await pumpEventQueue();
    expect(fake.requests.map((r) => r.opcode).last,
        PtpOperationCode.getPartialObject);

    flip = true;
    expect(fake.cancelInFlightCalls, 0,
        reason: '分块路线不发 Cancel 包(2026-10-16 真机:Zf 收 Cancel 掐链)');

    gate.complete(); // 在途块跑完
    await expectLater(future, throwsA(isA<DownloadCancelledException>()));
    // 在途块成功照常喂策略:128 → 160(取消不是链路信号,不减半)。
    expect(policy.currentBytes, 160);

    // 第二档(同下载器,门禁走会话缓存):首块请求从 160 起步,成功后照常续升。
    fake.reply(_okData(filler(160)));
    await downloader.download(_entry('DSC_0019.NEF', 160), targetDir: dir.path);
    expect(fake.requests.last.params, [0x12, 0, 160]);
    expect(policy.currentBytes, 192);
  });

  // ── GetPartialObjectEx 路线(0x9431,生产 iOS 开,见库注释)────────

  /// Ex 开着的下载器:Ex 策略注入小数值(64 起步 +32 升 200 封顶,
  /// 一律判快);0x101B 策略走缺省(封顶=partialChunkBytes,与 Ex 分账)。
  ObjectDownloader exDownloaderFor(FakePtpTransport fake,
          {AimdChunkPolicy? exPolicy}) =>
      ObjectDownloader(
        session: PtpSession(transport: fake),
        partialChunkBytes: 50,
        enablePartialObjectEx: true,
        exChunkPolicy: exPolicy ??
            AimdChunkPolicy(
                minBytes: 64,
                maxBytes: 200,
                stepBytes: 32,
                initialBytes: 64,
                fastThreshold: const Duration(days: 1)),
      );

  test('Ex 首选:首块即 0x9431,u64 参数低高拆分,AIMD 单独演化', () async {
    final fake = FakePtpTransport();
    final exPolicy = fastAlwaysPolicy(maxBytes: 200, initialBytes: 64);
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: 50,
      enablePartialObjectEx: true,
      exChunkPolicy: exPolicy,
    );

    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(filler(64)));
    fake.reply(_okData(filler(96)));
    fake.reply(_okData(filler(40)));

    final result = await downloader.download(_entry('DSC_0020.NEF', 200),
        targetDir: dir.path);

    expect(result.bytes, 200);
    // 门禁 + 三块全走 0x9431;参数 = [handle, 偏移低, 偏移高, 长度低, 长度高]。
    expect(fake.requests.skip(1).map((r) => r.opcode),
        List.filled(3, NikonOperationCode.getPartialObjectEx));
    expect(fake.requests.skip(1).map((r) => r.params), [
      [0x12, 0, 0, 64, 0],
      [0x12, 64, 0, 96, 0],
      [0x12, 160, 0, 40, 0], // 末块要足不越界
    ]);
    expect(exPolicy.currentBytes, 160); // 64→96→128→160 加性升(与 0x101B 账分立)
  });

  test('Ex 生产缺省策略:块爬过 1MB(hardCap 8MB 真实生效;此前被缺省闸钳死恒 1MB)',
      () async {
    const mb = 1024 * 1024;
    final fake = FakePtpTransport();
    // 不注入 exChunkPolicy:生产缺省策略(起步 1MB,+1MB/次,8MB 闸)。
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      partialChunkBytes: mb,
      enablePartialObjectEx: true,
    );

    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(filler(mb)));
    fake.reply(_okData(filler(2 * mb)));
    fake.reply(_okData(filler(mb + mb ~/ 2)));

    final result = await downloader.download(
        _entry('DSC_0030.NEF', 4 * mb + mb ~/ 2),
        targetDir: dir.path);

    expect(result.bytes, 4 * mb + mb ~/ 2);
    // 门禁 + 三块 0x9431:want 1MB → 2MB → 1.5MB(末块要足不越界)。
    // 第二块 want=2MB 是本回归的守闸线 —— 2026-10-25 修复前缺省闸
    // (1MB)把 8MB 账静默钳回,块恒 1MB,快路线名存实亡。
    expect(fake.requests.skip(1).map((r) => r.opcode),
        List.filled(3, NikonOperationCode.getPartialObjectEx));
    expect(fake.requests.skip(1).map((r) => r.params), [
      [0x12, 0, 0, mb, 0],
      [0x12, mb, 0, 2 * mb, 0],
      [0x12, 3 * mb, 0, mb + mb ~/ 2, 0],
    ]);
  });

  test('Ex 被拒(0x2005):本会话降级 0x101B,本块原样重发,后续不再探',
      () async {
    final fake = FakePtpTransport();
    final downloader = exDownloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(120, (i) => i));
    fake.reply(deviceInfoWithPartial());
    fake.fail(const PtpResponseException(
      opcode: NikonOperationCode.getPartialObjectEx,
      responseCode: PtpResponseCode.operationNotSupported,
    ));
    fake.reply(_okData(Uint8List.sublistView(payload, 0, 50)));
    fake.reply(_okData(Uint8List.sublistView(payload, 50, 100)));
    fake.reply(_okData(Uint8List.sublistView(payload, 100, 120)));

    final result = await downloader.download(_entry('DSC_0021.NEF', 120),
        targetDir: dir.path);

    expect(await File(result.path).readAsBytes(), payload);
    // 门禁 + 探针(0x9431 拒,不喂策略)+ 全程 0x101B:降级后不再探。
    expect(fake.requests.map((r) => r.opcode), [
      PtpOperationCode.getDeviceInfo,
      NikonOperationCode.getPartialObjectEx,
      PtpOperationCode.getPartialObject,
      PtpOperationCode.getPartialObject,
      PtpOperationCode.getPartialObject,
    ]);
  });

  test('Ex 中段短读:规格应答实发可小于请求,续拉不当 EOF', () async {
    final fake = FakePtpTransport();
    final downloader = exDownloaderFor(fake);

    final payload = Uint8List.fromList(List.generate(120, (i) => i));
    fake.reply(deviceInfoWithPartial());
    fake.reply(_okData(Uint8List.sublistView(payload, 0, 30))); // 30 < want 64
    fake.reply(_okData(Uint8List.sublistView(payload, 30, 90))); // 60 < want 90
    fake.reply(_okData(Uint8List.sublistView(payload, 90, 120)));

    final result = await downloader.download(_entry('DSC_0022.NEF', 120),
        targetDir: dir.path);

    expect(await File(result.path).readAsBytes(), payload);
    // 短读续拉:偏移跟实发走(0 → 30 → 90),不按 want 对齐。
    expect(fake.requests.skip(1).map((r) => r.params), [
      [0x12, 0, 0, 64, 0],
      [0x12, 30, 0, 90, 0],
      [0x12, 90, 0, 30, 0],
    ]);
  });

  test('Ex 场景性错误不降级:Access_Denied(视频播放中)照旧上抛走重试',
      () async {
    final fake = FakePtpTransport();
    final downloader = exDownloaderFor(fake);

    fake.reply(deviceInfoWithPartial());
    fake.fail(const PtpResponseException(
      opcode: NikonOperationCode.getPartialObjectEx,
      responseCode: PtpResponseCode.accessDenied,
    ));

    await expectLater(
      downloader.download(_entry('DSC_0023.NEF', 120), targetDir: dir.path),
      throwsA(isA<PtpResponseException>()),
    );
  });
}

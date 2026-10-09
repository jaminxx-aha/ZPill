import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';

import '../ptp/ptp_session_test.dart'
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

    final payload =
        Uint8List.fromList(List.generate(300000, (i) => i & 0xFF));
    fake.reply(_okData(payload));

    final progresses = <int>[];
    final result = await downloader.download(_entry('DSC_0001.NEF', payload.length),
        targetDir: dir.path, onProgress: progresses.add);

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

    final payload =
        Uint8List.fromList(List.generate(100, (i) => i));
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

    final result = await downloader
        .download(_entry('evil/name.NEF', 3), targetDir: dir.path);

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
    expect(fake.requests.map((r) => r.opcode),
        [PtpOperationCode.getDeviceInfo, ...List.filled(3, PtpOperationCode.getPartialObject)]);
    expect(
        fake.requests[1].params, [0x12, 0, 50]); // 末块要足不越界
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

    final result = await downloader
        .download(_entry('DSC_0007.NEF', 80), targetDir: dir.path);

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
}

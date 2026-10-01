import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/ptp/ptp_transport.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';
import 'package:nikon_pill/core/transfer/object_downloader.dart';

import '../ptp/ptp_session_test.dart' show FakePtpTransport;

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
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_bridge/core/browser/object_entry.dart';
import 'package:nikon_bridge/core/ptp/operation_codes.dart';
import 'package:nikon_bridge/core/ptp/ptp_session.dart';
import 'package:nikon_bridge/core/ptp/ptp_transport.dart';
import 'package:nikon_bridge/core/ptpip/object_format.dart';
import 'package:nikon_bridge/core/transfer/object_downloader.dart';
import 'package:nikon_bridge/platform/gallery_saver.dart';

import '../ptp/ptp_session_test.dart' show FakePtpTransport;

/// 假相册:tempDir 指向真实临时目录(验证落盘),import 行为可配置。
final class FakeGallerySaver implements GallerySaver {
  FakeGallerySaver(this.dir);

  final String dir;

  /// 非空:importFile 抛该异常(模拟 ohos v1 的 UnimplementedError 或失败)。
  Object? throwOnImport;

  final List<(String, ObjectKind, String)> importCalls = [];

  @override
  Future<String> tempDir() async => dir;

  @override
  Future<Uri> importFile(
    String tempPath, {
    required ObjectKind kind,
    required String filename,
  }) async {
    importCalls.add((tempPath, kind, filename));
    if (throwOnImport != null) {
      throw throwOnImport!; // ignore: only_throw_errors,模拟未实现/失败路径
    }
    return Uri.parse('content://test/${Uri.file(tempPath).pathSegments.last}');
  }
}

ObjectEntry _entry(String name, int size) => ObjectEntry(
      handle: 0x12,
      name: name,
      sizeInBytes: size,
      kind: ObjectKind.image,
    );

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nikonbridge_dl_test');
  });
  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('流式落盘:文件字节逐一相符,进度按块回调,测速字段非零', () async {
    final gallery = FakeGallerySaver(dir.path)..throwOnImport = UnimplementedError();
    final fake = FakePtpTransport();
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      gallery: gallery,
    );

    final payload =
        Uint8List.fromList(List.generate(300000, (i) => i & 0xFF));
    fake.reply(PtpResult(responseCode: PtpResponseCode.ok, data: payload));

    final entry = _entry('DSC_0001.NEF', payload.length);
    final progresses = <int>[];
    final result = await downloader.download(entry, onProgress: progresses.add);

    // FakePtpTransport 把数据切两半回调:两块进度,末值 = 文件大小。
    expect(progresses, [150000, 300000]);
    expect(result.bytes, payload.length);
    expect(result.galleryUri, isNull); // UnimplementedError → 沙箱后备
    expect(result.averageBytesPerSecond, greaterThan(0));
    expect(result.elapsed, greaterThanOrEqualTo(Duration.zero));

    final file = File(result.path);
    expect(file.parent.path, dir.path); // 落在 gallery 声明的临时目录内
    expect(await file.readAsBytes(), payload);
    // import 被尝试过一次(参数透传 kind/filename)。
    expect(gallery.importCalls.single,
        (result.path, ObjectKind.image, 'DSC_0001.NEF'));
  });

  test('导入成功:返回相册 Uri,文件保留在临时目录', () async {
    final gallery = FakeGallerySaver(dir.path);
    final fake = FakePtpTransport();
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      gallery: gallery,
    );

    final payload = Uint8List.fromList([1, 2, 3, 4]);
    fake.reply(PtpResult(responseCode: PtpResponseCode.ok, data: payload));

    final result = await downloader.download(_entry('DSC_0002.JPG', 4));

    expect(result.galleryUri, isNotNull);
    expect(await File(result.path).readAsBytes(), payload);
  });

  test('GetObject 被拒:上抛且不留半成品', () async {
    final gallery = FakeGallerySaver(dir.path);
    final fake = FakePtpTransport();
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      gallery: gallery,
    );

    // 拒绝码用表内在册的 generalError:本测试验证失败清理,不针对特定码。
    fake.fail(const PtpResponseException(
      opcode: PtpOperationCode.getObject,
      responseCode: PtpResponseCode.generalError,
    ));

    await expectLater(
      downloader.download(_entry('DSC_0003.NEF', 100)),
      throwsA(isA<PtpResponseException>()),
    );
    expect(await dir.list().toList(), isEmpty); // 半成品已删
    expect(gallery.importCalls, isEmpty);
  });

  test('文件名只取最后一段(防御路径分隔符)', () async {
    final gallery = FakeGallerySaver(dir.path);
    final fake = FakePtpTransport();
    final downloader = ObjectDownloader(
      session: PtpSession(transport: fake),
      gallery: gallery,
    );

    fake.reply(PtpResult(
        responseCode: PtpResponseCode.ok,
        data: Uint8List.fromList([9, 9, 9])));

    final result = await downloader.download(_entry('evil/name.NEF', 3));

    expect(File(result.path).uri.pathSegments.last, 'name.NEF');
  });
}

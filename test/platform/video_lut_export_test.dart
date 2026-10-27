import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/media/cube_lut.dart';
import 'package:z_pill/platform/video_lut_export.dart';

/// `zpill/video_lut` 通道件单测:mock 拦截 Dart→原生(export/cancel
/// 载荷),handlePlatformMessage 反向推 'onProgress' 模拟原生进度回传。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zpill/video_lut');
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> outbound;
  late Object? Function(MethodCall call) onCall;

  setUp(() {
    outbound = [];
    onCall = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      outbound.add(call);
      return onCall(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// 原生 → Dart:模拟导出进度回传。
  Future<void> pushFromNative(MethodCall call) =>
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );

  CubeLut makeLut(int size) =>
      CubeLut.fromFunction('t', size, (r, g, b) => [r, g, b]);

  test('isSupported:实现在场 true;通道缺失 false(ohos)', () async {
    onCall = (_) => true;
    expect(await MethodChannelVideoLutExport().isSupported(), isTrue);
    messenger.setMockMethodCallHandler(channel, null); // 无实现
    expect(await MethodChannelVideoLutExport().isSupported(), isFalse);
  });

  test('export:载荷 path/cube/size;进度回传;产物路径返回', () async {
    final lut = makeLut(2);
    final gate = Completer<Object?>();
    onCall = (_) => gate.future; // 原生导出挂起中
    final progress = <int>[];
    final future = MethodChannelVideoLutExport()
        .export('/tmp/in.mp4', lut, onProgress: progress.add);
    await pumpEventQueue();
    expect(outbound.single.method, 'export');
    final args = outbound.single.arguments as Map<Object?, Object?>;
    expect(args['path'], '/tmp/in.mp4');
    expect(args['size'], 2);
    final cube = args['cube'] as Float32List;
    expect(cube.length, 2 * 2 * 2 * 4); // N³×4 RGBA

    await pushFromNative(const MethodCall('onProgress', 42));
    expect(progress, [42]);

    gate.complete('/cache/out.mp4');
    expect(await future, '/cache/out.mp4');
  });

  test('export:在途重复调用拒(StateError);结束后可再发', () async {
    final host = MethodChannelVideoLutExport();
    final lut = makeLut(2);
    final gate = Completer<Object?>();
    onCall = (_) => gate.future;
    final first = host.export('/tmp/in.mp4', lut);
    await pumpEventQueue();
    expect(() => host.export('/tmp/in2.mp4', lut), throwsStateError);
    gate.complete('/cache/out.mp4');
    await first;
    onCall = (_) => '/cache/out2.mp4';
    await host.export('/tmp/in2.mp4', lut); // 不再拒
  });

  test('export:native 错误原样上抛 PlatformException', () async {
    onCall = (_) => throw PlatformException(code: 'export_failed', message: 'boom');
    await expectLater(
      MethodChannelVideoLutExport().export('/tmp/in.mp4', makeLut(2)),
      throwsA(isA<PlatformException>()
          .having((e) => e.code, 'code', 'export_failed')),
    );
  });

  test('cancel:推原生;通道缺失时静默吞(MissingPluginException)', () async {
    final host = MethodChannelVideoLutExport();
    await host.cancel();
    expect(outbound.single.method, 'cancel');
    messenger.setMockMethodCallHandler(channel, null);
    await host.cancel(); // 不炸
  });
}

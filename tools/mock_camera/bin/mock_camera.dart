/// mock 相机 CLI:常驻 TCP 15740,app 端手动填 127.0.0.1 即可连。
///
/// 用法(仓根执行):
/// ```sh
/// dart run tools/mock_camera/bin/mock_camera.dart                 # 缺省 15740
/// dart run tools/mock_camera/bin/mock_camera.dart --port 15741 \
///     --objects-dir ~/Pictures/mock-card   # 真实文件当下载载荷
/// dart run tools/mock_camera/bin/mock_camera.dart --init-fail 1   # 复现占用拒连
/// ```
// ignore_for_file: avoid_print —— CLI 的日志输出就是本职。
library;

import 'dart:async';
import 'dart:io';

import 'package:z_pill/core/ptpip/transport.dart' show kPtpIpPort;

import '../mock_camera.dart';

/// hilog 风格日志:`MM-DD HH:MM:SS.mss PID TID I D0158/MockCamera: msg`。
void hilog(String message) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
      '${now.millisecond.toString().padLeft(3, '0')}';
  print('$stamp $pid $pid I D0158/MockCamera: $message');
}

Future<void> main(List<String> args) async {
  var port = kPtpIpPort;
  String? objectsDir;
  int? initFailReason;
  const usage = '用法: dart run tools/mock_camera/bin/mock_camera.dart '
      '[--port N] [--objects-dir DIR] [--init-fail N]';

  for (var i = 0; i < args.length; i++) {
    String? nextValue() => ++i < args.length ? args[i] : null;
    switch (args[i]) {
      case '--port':
        port = int.tryParse(nextValue() ?? '') ?? port;
      case '--objects-dir':
        objectsDir = nextValue();
      case '--init-fail':
        initFailReason = int.tryParse(nextValue() ?? '');
      case '--help' || '-h':
        print(usage);
        return;
      default:
        print('未知参数:${args[i]}\n$usage');
        exitCode = 64;
        return;
    }
  }

  final device = MockNikonDevice(
    objects: objectsDir == null
        ? defaultMockObjects()
        : loadObjectsFromDirectory(objectsDir),
  );
  final camera = MockPtpIpCamera(
    device: device,
    host: '0.0.0.0',
    requestedPort: port,
    initFailReason: initFailReason,
    log: hilog,
  );

  try {
    await camera.start();
  } on Exception catch (e) {
    hilog('启动失败:$e(端口被占?换个 --port)');
    exitCode = 1;
    return;
  }
  if (objectsDir != null) {
    hilog('对象目录 $objectsDir 装载 ${device.objects.length} 个对象');
  }

  hilog('假相机就绪:${device.model} 端口 ${camera.port},'
      '${device.objects.length} 个对象;'
      'app 手动连接本机 IP:${camera.port}');
  hilog('支持面:GetDeviceInfo/OpenSession/Storage/Handles/ObjectInfo/'
      'GetThumb/GetObject/GetPartialObject/0x90C4/GetEvent(Ex)/0x90C2/'
      '0x90C8/0x9207(事件 0x4002+0x400D)/0x920A/0x920B/0x920C/0x9435;'
      '其余回 0x2005');
  hilog('Ctrl-C 退出');

  final done = Completer<void>();
  void quit(String why) {
    hilog('$why,收线退出');
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => quit('收到 SIGINT'));
  ProcessSignal.sigterm.watch().listen((_) => quit('收到 SIGTERM'));

  await done.future;
  await camera.stop();
  hilog('已退净');
  exit(0);
}

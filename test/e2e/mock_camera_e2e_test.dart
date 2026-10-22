/// 假相机 e2e(真 TCP 回环):boot `tools/mock_camera` → 我方真
/// PtpIpTransport/PtpSession 驱动 → 断言。
///
/// 与 `test/core/ptpip/`(fake 通道回放脚本)的分工:这里的价值在
/// **真 socket 全链路** —— 帧切分/粘包、双通道握手方言、数据相分包
/// 重组、事件推送,一条不落;协议语义的单点覆盖仍在那边。
///
/// 连接驱动镜像 `CameraConnectionImpl._openWirelessLink` +
/// `enableAppControl(remoteLatch: true)`(握手 → GetDeviceInfo →
/// OpenSession → 0x9435/0x90C2 括号),不引入 USB/配对依赖。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_link_router.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/ptpip/codec.dart';
import 'package:z_pill/core/ptpip/transport.dart';
import 'package:z_pill/core/ptpip/object_format.dart';

import '../../tools/mock_camera/mock_camera.dart';

/// 缺省人设只合成一次(MockObject 不可变,跨 server 共享安全)。
final List<MockObject> _persona = defaultMockObjects();

const _folderHandle = 0x00010000;
const _jpgHandle = 0x00010001;
const _nefHandle = 0x00010003;

/// 已连上的客户端三件套(路由器装配镜像生产:session 只见 PtpLinkRouter)。
final class _Live {
  _Live(this.transport, this.link, this.session);
  final PtpIpTransport transport;
  final PtpLinkRouter link;
  final PtpSession session;
}

Future<MockPtpIpCamera> _boot({int? initFailReason}) async {
  final camera = MockPtpIpCamera(
    device: MockNikonDevice(objects: _persona),
    initFailReason: initFailReason,
  );
  await camera.start(); // 随机口,免冲突
  addTearDown(camera.stop);
  return camera;
}

/// 镜像连接层的建链段(TCP 双通道握手;不做 OpenSession)。
Future<_Live> _connect(MockPtpIpCamera camera,
    {bool enableKeepalive = false,
    Duration? keepaliveInterval,
    int keepaliveMaxMissed = 3}) async {
  final transport = PtpIpTransport(
    enableKeepalive: enableKeepalive,
    keepaliveInterval:
        keepaliveInterval ?? const Duration(seconds: 15),
    keepaliveMaxMissed: keepaliveMaxMissed,
  );
  final link = PtpLinkRouter();
  final session = PtpSession(transport: link);
  await transport.connect('127.0.0.1', port: camera.port);
  link.attach(transport);
  addTearDown(() async {
    // 镜像 CameraConnectionImpl._teardown 顺序:detach → 关无线(毒化
    // 在途)→ 会话收尾(CloseSession 经 detach 已挡,静默失败)。
    link.detach();
    await transport.close();
    await session.close();
  });
  return _Live(transport, link, session);
}

/// 镜像 `_openWirelessLink`:握手 → GetDeviceInfo → OpenSession。
Future<_Live> _connectAndOpen(MockPtpIpCamera camera) async {
  final live = await _connect(camera);
  await live.session.getDeviceInfo(force: true);
  await live.session.open();
  return live;
}

/// 轮询等待条件成立(事件是异步推的,不能断言即到)。
Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('假相机 e2e(真 TCP 回环)', () {
    test('握手方言:双通道 Init 逐包镜像,客户端 GUID/主机名入账', () async {
      final camera = await _boot();
      final live = await _connect(camera);

      // 尼康方言入账:GUID(16B)+ 无长度前缀主机名 + u32 版本。
      // 若客户端改发规范布局(u32 长度前缀),主机名必然解出乱码 ——
      // 这条断言就是方言的字节级钉子。
      expect(camera.lastClientHostname, 'Android Device');
      expect(camera.lastClientGuid, kNikonAndroidGuid);
      expect(camera.lastClientProtocolVersion, 0x00010000);
      expect(camera.isSlotOccupied, isTrue);

      await live.transport.close();
      await _until(() => !camera.isSlotOccupied);
      expect(camera.device.sessionOpen, isFalse);
    });

    test('InitFail 拒连:--init-fail 复现槽位占用(PtpInitRejectException)',
        () async {
      final camera = await _boot(initFailReason: 1);
      final transport = PtpIpTransport();

      await expectLater(
        transport.connect('127.0.0.1', port: camera.port),
        throwsA(isA<PtpInitRejectException>()
            .having((e) => e.reason, 'reason', 1)),
      );
    });

    test('单连接槽位:第二客户端 Init 被拒,首个退线后槽位释放', () async {
      final camera = await _boot();
      final first = await _connect(camera);

      final second = PtpIpTransport();
      await expectLater(
        second.connect('127.0.0.1', port: camera.port),
        throwsA(isA<PtpInitRejectException>()
            .having((e) => e.reason, 'reason', 1)),
      );

      await first.transport.close();
      await _until(() => !camera.isSlotOccupied);
      // 释放后第三个客户端即可正常入座。
      final third = await _connect(camera);
      expect(camera.isSlotOccupied, isTrue);
      await third.transport.close();
    });

    test('连接流镜像:GetDeviceInfo 人设 → OpenSession → 0x9435/0x90C2 括号',
        () async {
      final camera = await _boot();
      final live = await _connect(camera);

      final info = await live.session.getDeviceInfo(force: true);
      expect(info.manufacturer, 'Nikon Corporation');
      expect(info.model, 'NIKON ZF');
      // 定宽补零序列号被 _normalizeSerial 剥成短形(配对档案键同口径)。
      expect(info.serialNumber, 'MOCK0001');
      // 操作码表 = mock 实际支持面(不是照抄真机 119 op 大表)。
      expect(info.supportsOperation(NikonOperationCode.getLargeThumb),
          isTrue);
      expect(info.supportsOperation(NikonOperationCode.initiateCaptureRecInMedia),
          isTrue);
      expect(info.supportsOperation(NikonOperationCode.getObjectPropList),
          isFalse);

      await live.session.open();
      expect(live.session.isSessionOpen, isTrue);

      final took = await live.session.enableAppControl(remoteLatch: true);
      expect(took, isTrue);
      // 连接梯:0x9435 OK(假钥匙路径照发)→ 0x90C2(1) OK → 0x90C2(0) OK。
      expect(live.session.connectLadder, containsAll(['9435:OK', '90C2:OK', '90C2退:OK']));
      final device = camera.device;
      expect(device.opCounts[NikonOperationCode.changeApplicationMode], 1);
      expect(device.opCounts[NikonOperationCode.changeCameraMode], 2);
      expect(device.applicationMode, 1);
      expect(device.cameraMode, 0); // 括号收口:开闩即还身
    });

    test('相册清单:存储卡人设 + Zf 方言句柄表 + 逐对象 ObjectInfo', () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);

      final storages = await live.session.getStorageIds();
      expect(storages, [0x00010001]);
      // application 模式方言:真卡 ID 走 0x9209(mock 与 0x1004 同人设)。
      expect(await live.session.getVendorStorageIds(), [0x00010001]);
      final storage = await live.session.getStorageInfo(0x00010001);
      expect(storage.maxCapacityBytes, 64 * 1024 * 1024 * 1024);
      expect(storage.freeSpaceBytes, 32 * 1024 * 1024 * 1024);
      expect(storage.freeSpaceImages, 5000);

      // parent=0 全量(Zf 真机语义:与规范的 0/0xFFFFFFFF 恰好相反)。
      final handles = await live.session.getObjectHandles();
      expect(handles, [
        _folderHandle,
        _jpgHandle,
        0x00010002,
        _nefHandle,
        0x00010004,
      ]);
      // parent=0xFFFFFFFF 只回根层文件夹(同方言)。
      final root = await live.session.getObjectHandles(
          parent: GetObjectHandlesParams.parentAll);
      expect(root, [_folderHandle]);

      for (final handle in handles) {
        final info = await live.session.getObjectInfo(handle);
        final mock = camera.device.object(handle)!;
        expect(info.filename, mock.filename, reason: 'handle 0x${handle.toRadixString(16)}');
        expect(info.objectFormat, mock.format);
        expect(info.compressedSize, mock.body.length);
        expect(info.parentHandle, mock.parent);
      }
      // 格式码方言:NEF 报 0x3000、MOV 报 MTP 0xB982(真机同款)。
      final nef = await live.session.getObjectInfo(_nefHandle);
      expect(nef.objectFormat, ObjectFormatCode.undefined);
      final mov = await live.session.getObjectInfo(0x00010004);
      expect(mov.objectFormat, ObjectFormatCode.mp4);
    });

    test('缩略字节:GetThumb / 0x90C4 与 mock 合成逐字节一致且真可解码',
        () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);

      final jpg = camera.device.object(_jpgHandle)!;
      final thumb = await live.session.getThumb(_jpgHandle);
      expect(thumb, jpg.thumb); // 逐字节
      // 真 JPEG:image 包能解码回人设尺寸(手动冒烟时 app 缩略管线同权)。
      final decoded = img.decodeJpg(thumb);
      expect(decoded, isNotNull);
      expect(decoded!.width, 160);
      expect(decoded.height, 120);

      final nef = camera.device.object(_nefHandle)!;
      final large = await live.session.getLargeThumb(_nefHandle, force: true);
      expect(large, nef.largeThumb);
      expect(large.lengthInBytes, greaterThan(1024)); // ~KB 级人设
      final largeDecoded = img.decodeJpg(large);
      expect(largeDecoded, isNotNull);
      expect(largeDecoded!.width, 320);

      // 文件夹句柄:数据操作拒绝(0x201D)。
      await expectLater(
        live.session.getThumb(_folderHandle),
        throwsA(isA<PtpResponseException>()
            .having((e) => e.responseCode, 'code', PtpResponseCode.invalidParameter)),
      );
    });

    test('GetPartialObject 分块重组:多块读 + 整读 + 尾读均与 mock 合成一致',
        () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);

      final nef = camera.device.object(_nefHandle)!;
      final total = nef.body.length;
      expect(total, 2 * 1024 * 1024);

      // 分块路(镜像下载引擎的 AIMD 循环):512KB 一块,块内再被 mock
      // 的 64KB Data 分片拆成多帧 —— 两层重组都压到。
      const chunk = 512 * 1024;
      final pieces = BytesBuilder(copy: false);
      for (var offset = 0; offset < total; offset += chunk) {
        pieces.add(await live.session.getPartialObject(
            _nefHandle, offset, chunk));
      }
      expect(pieces.toBytes(), nef.body);

      // 整读一次到位(32 个 Data 帧的重组路径)。
      final whole =
          await live.session.getPartialObject(_nefHandle, 0, total);
      expect(whole, nef.body);

      // 尾读:maxBytes 越过尾部按剩余量截断。
      final tail = await live.session
          .getPartialObject(_nefHandle, total - 1000, 0xFFFFFFFF);
      expect(tail, nef.body.sublist(total - 1000));

      // GetObject 流式:回调块重组 == 正文(另一条下载路)。
      final streamed = BytesBuilder(copy: false);
      await live.session.getObject(_jpgHandle, onData: streamed.add);
      final jpg = camera.device.object(_jpgHandle)!;
      expect(streamed.toBytes(), jpg.body);
    });

    test('拍摄事件:0x9207 回 OK 后 0x4002 + 0x400D 到齐,新对象入册',
        () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);
      final device = camera.device;
      expect(device.objects.length, 5);

      final events = <PtpEvent>[];
      final sub = live.session.events.listen(events.add);
      addTearDown(sub.cancel);

      await live.session.initiateCaptureRecInMedia();

      await _until(() => events
          .any((e) => e.code == PtpEventCode.objectAdded));
      await _until(() =>
          events.any((e) => e.code == PtpEventCode.captureComplete));

      final added =
          events.where((e) => e.code == PtpEventCode.objectAdded).toList();
      expect(added, hasLength(1));
      final newHandle = added.single.params.single;

      // 新对象入册:ObjectInfo/缩略照常可取,句柄表可见。
      final info = await live.session.getObjectInfo(newHandle);
      expect(info.filename, 'DSC_0005.JPG');
      expect(info.objectFormat, ObjectFormatCode.exifJpeg);
      final thumb = await live.session.getThumb(newHandle);
      expect(thumb.lengthInBytes, greaterThan(0));
      expect(thumb[0], 0xFF);
      expect(thumb[1], 0xD8);
      final handles = await live.session.getObjectHandles();
      expect(handles, contains(newHandle));
      expect(device.objects.length, 6);
    });

    test('轮询/录像/忙等/未支持:0x941C 空、0x920A/0x920C OK、0x9999 回 0x2005',
        () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);

      // GetEventEx 人设恒空(拍摄事件走事件 socket 推送)。
      expect(await live.session.getEventEx(), isEmpty);

      await live.session.startMovieRec();
      expect(camera.device.recording, isTrue);
      await live.session.endMovieRec();
      expect(camera.device.recording, isFalse);
      await live.session.terminateCapture();
      expect(await live.session.deviceReady(), isTrue);

      // 未实现 op:OperationNotSupported(0x2005),链路不失步。
      final result = await live.session.transport
          .execute(const PtpRequest(opcode: 0x9999));
      expect(result.responseCode, PtpResponseCode.operationNotSupported);
      // 拒绝后链路照常:随手再取一次 DeviceInfo(缓存 force 刷新走真事务)。
      final again = await live.session.getDeviceInfo(force: true);
      expect(again.model, 'NIKON ZF');
    });

    test('心跳:ProbeRequest 在事件通道有回声(生产 keepalive 装配)', () async {
      final camera = await _boot();
      final live = await _connect(
        camera,
        enableKeepalive: true,
        keepaliveInterval: const Duration(milliseconds: 30),
        keepaliveMaxMissed: 100, // 测试窗口内不判死
      );

      await _until(() => camera.probeRequestCount >= 3,
          timeout: const Duration(seconds: 10));
      // 心跳期间链路照常可用。
      final info = await live.session.getDeviceInfo(force: true);
      expect(info.model, 'NIKON ZF');
    });

    test('断线重连:槽位释放后重握手即新会话,拍过的对象仍在册', () async {
      final camera = await _boot();
      final live = await _connectAndOpen(camera);
      await live.session.initiateCaptureRecInMedia();
      expect(camera.device.objects.length, 6);

      // 镜像生产 teardown(与 addTearDown 同款,幂等)。
      live.link.detach();
      await live.transport.close();
      await live.session.close();
      await _until(() => !camera.isSlotOccupied);
      expect(camera.device.sessionOpen, isFalse);

      // 重连 = 全新会话(0x201E 残留路径不被触发)。
      final second = await _connectAndOpen(camera);
      expect(second.session.isSessionOpen, isTrue);
      final handles = await second.session.getObjectHandles();
      expect(handles, hasLength(6)); // 设备人设跨连接保留对象表
      expect(camera.device.opCounts[PtpOperationCode.openSession], 2);
    });
  });
}

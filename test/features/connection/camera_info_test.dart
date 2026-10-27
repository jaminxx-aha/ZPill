// 快门数现读(fetchShutterCount)用例:FakePtpTransport 脚本回放。
//
// 载荷用 TIFF 直开形态(NEF 同构)验证管线 —— 句柄取最大、64KB 被
// 拒降级 512KB、失败静默回 null;HEIF/JPEG 容器解析在
// test/core/exif/nikon_maker_note_test.dart 全量覆盖,此处不重复。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/camera/camera_connection.dart';
import 'package:z_pill/core/browser/album.dart';
import 'package:z_pill/core/ptpip/object_format.dart';
import 'package:z_pill/core/browser/object_entry.dart';
import 'package:z_pill/core/browser/object_repository.dart';
import 'package:z_pill/core/browser/photo_group.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/l10n/message.dart';
import 'package:z_pill/features/connection/camera_overview_controller.dart';

final class _FakeTransport implements PtpTransport {
  final script = Queue<Object>();
  final eventsCtrl = StreamController<PtpEvent>.broadcast();
  final opcodes = <int>[];
  final partialHandles = <int>[];

  void reply(PtpResult r) => script.add(r);
  void fail(Exception e) => script.add(e);

  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    opcodes.add(request.opcode);
    if (request.opcode == PtpOperationCode.getPartialObject &&
        request.params.isNotEmpty) {
      partialHandles.add(request.params.first);
    }
    if (script.isEmpty) throw StateError('脚本耗尽');
    final next = script.removeFirst();
    if (next is Exception) throw next;
    return next as PtpResult;
  }

  @override
  Stream<PtpEvent> get events => eventsCtrl.stream;

  @override
  Future<void> close() async {}
}

final class _FakeConnection implements CameraConnection {
  final statesCtrl = StreamController<CameraLinkState>.broadcast();

  @override
  Stream<CameraLinkState> get states => statesCtrl.stream;
  @override
  CameraLinkState get state => CameraLinkState.connected;
  @override
  L10nMessage? get error => null;
  @override
  String? get deviceName => null;
  @override
  String? get deviceModel => null;
  @override
  bool get isWireless => false;
  @override
  String? get pairingCode => null;
  @override
  Future<void> connect({String? ip, String? instanceName}) async {}
  @override
  Future<void> confirmPairing() async {}
  @override
  Future<void> cancelPairing() async {}
  @override
  Future<void> disconnect() async {}
}

Uint8List _handles(List<int> hs) {
  final b = BytesBuilder()..add(_u32(hs.length));
  for (final h in hs) {
    b.add(_u32(h));
  }
  return b.toBytes();
}

Uint8List _u32(int v) => Uint8List.fromList(
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF]);

/// 合成「Nikon v2(1100 头)+ 0x00A7」TIFF 载荷(直开形态)。
Uint8List _buildTiff(int shutterCount) {
  void w16(BytesBuilder b, int v) =>
      b.add([v & 0xFF, v >> 8 & 0xFF]);
  void w32(BytesBuilder b, int v) => b
      .add([v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF]);
  // Nikon 子 TIFF(Nikon\0\x02 + 0x11\0\0 = 10B 头,真机同款)。
  final sub = BytesBuilder()..add(const [0x49, 0x49, 0x2A, 0x00]);
  w32(sub, 8);
  w16(sub, 2);
  w16(sub, 0x0001); // version type 7 ASCII×4 内联
  w16(sub, 7);
  w32(sub, 4);
  sub.add(const [0x31, 0x31, 0x30, 0x30]);
  w16(sub, 0x00A7); // ShutterCount LONG×1 内联
  w16(sub, 4);
  w32(sub, 1);
  w32(sub, shutterCount);
  w32(sub, 0);
  final mn = (BytesBuilder()
        ..add(const [0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00, 0x02, 0x11, 0x00, 0x00])
        ..add(sub.toBytes()))
      .toBytes();
  // 主 TIFF:IFD0(1 entry 0x8769@26)→ ExifIFD(1 entry 0x927C)→ MakerNote。
  const exifOff = 8 + 2 + 12 + 4; // 26
  const mnOff = exifOff + 2 + 12 + 4; // 46
  final t = BytesBuilder()..add(const [0x49, 0x49, 0x2A, 0x00]);
  w32(t, 8);
  w16(t, 1);
  w16(t, 0x8769);
  w16(t, 4);
  w32(t, 1);
  w32(t, exifOff);
  w32(t, 0);
  w16(t, 1);
  w16(t, 0x927C);
  w16(t, 7);
  w32(t, mn.length);
  w32(t, mnOff);
  w32(t, 0);
  t.add(mn);
  return t.toBytes();
}

final class _FakeRepo implements ObjectRepository {
  _FakeRepo(this.albums);
  final List<CameraAlbum> albums;

  @override
  Future<List<CameraAlbum>> loadAlbums() async => albums;

  @override
  Stream<AlbumsUpdate> get updates => const Stream.empty();

  @override
  Future<ObjectEntry> entryFor(int handle) async => throw UnimplementedError();

  @override
  void removeHandles(Iterable<int> handles) {}

  @override
  void reset() {}

  // ── 评级面(信息总览不消费,空实现)──
  @override
  bool get ratingsLoaded => false;

  @override
  void requestRating(int handle, {bool trashProbe = true}) {}
  @override
  void requestTrashProbe(int handle) {}
  @override
  Duration? durationFor(int handle) => null;
  @override
  void requestVideoDuration(int handle) {}

  @override
  int ratingForHandle(int handle) => 0;

  @override
  int ratingForGroup(PhotoGroup group) => 0;

  @override
  bool ratedUnknownFor(int handle) => false;

  @override
  bool groupRatedUnknown(PhotoGroup group) => false;

  @override
  bool trashMarkedFor(int handle) => false;

  @override
  bool groupTrashStar(PhotoGroup group) => false;

  @override
  PhotoGroup? groupOf(int handle) => null;

  @override
  Future<void> rateGroup(PhotoGroup group, int stars) async =>
      throw UnimplementedError();
}

ObjectEntry _entry(int handle, DateTime captured,
        {String? name, ObjectKind kind = ObjectKind.image}) =>
    ObjectEntry(
      handle: handle,
      name: name ?? 'DSC_${handle.toString().padLeft(4, '0')}.HIF',
      sizeInBytes: 1,
      kind: kind,
      capturedAt: captured,
    );

CameraOverviewController _controller(PtpTransport transport) =>
    CameraOverviewController(
      session: PtpSession(transport: transport),
      connection: _FakeConnection(),
    );

void main() {
  test('现读命中:最新句柄(最大值)的照片解析出快门数', () async {
    final t = _FakeTransport();
    t.reply(PtpResult(
        responseCode: 0x2001, data: _handles([0x111, 0x691958DA, 0x222])));
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(15963)));
    final c = _controller(t);
    expect(await c.fetchShutterCount(), 15963);
    c.dispose();
  });

  test('相册仓库排序优先于最大句柄(句柄序≠拍摄序的根修)', () async {
    final t = _FakeTransport();
    // 相册说最新是句柄 100(小);句柄枚举里另有 50 更大 —— 仓库必须赢。
    // (脚本只放 partial:若实现错误走了枚举,本条被当句柄集解析失败。)
    final repo = _FakeRepo([
      CameraAlbum(
        folderHandle: CameraAlbum.allPhotosHandle,
        name: 'grid.allPhotos',
        items: [
          PhotoGroup([
            _entry(100, DateTime(2026, 10, 22)),
          ]),
        ],
      ),
    ]);
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(15964)));
    final c = CameraOverviewController(
      session: PtpSession(transport: t),
      connection: _FakeConnection(),
      repository: repo,
    );
    expect(await c.fetchShutterCount(), 15964);
    c.dispose();
  });

  test('最新条目是视频组:跳过取最新照片组(视频头无 MakerNote 0x00A7)',
      () async {
    final t = _FakeTransport();
    // 汇总相册混排视频同按时间新→旧:最新是录像(新于最后一张照片)。
    final repo = _FakeRepo([
      CameraAlbum(
        folderHandle: CameraAlbum.allPhotosHandle,
        name: 'grid.allPhotos',
        items: [
          PhotoGroup([
            _entry(200, DateTime(2026, 10, 26, 12),
                name: 'DSC_0100.MOV', kind: ObjectKind.video),
          ]),
          PhotoGroup([
            _entry(100, DateTime(2026, 10, 25),
                name: 'DSC_0099.NEF', kind: ObjectKind.image),
          ]),
        ],
      ),
    ]);
    // 脚本只放照片句柄的 partial:实现若错取视频组(200),脚本耗尽即败。
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(15966)));
    final c = CameraOverviewController(
      session: PtpSession(transport: t),
      connection: _FakeConnection(),
      repository: repo,
    );
    expect(await c.fetchShutterCount(), 15966);
    expect(t.partialHandles, [100]);
    c.dispose();
  });

  test('汇总相册全是视频:静照无源回 null,不再枚举兜底', () async {
    final t = _FakeTransport();
    final repo = _FakeRepo([
      CameraAlbum(
        folderHandle: CameraAlbum.allPhotosHandle,
        name: 'grid.allPhotos',
        items: [
          PhotoGroup([
            _entry(200, DateTime(2026, 10, 26, 12),
                name: 'DSC_0100.MOV', kind: ObjectKind.video),
          ]),
        ],
      ),
    ]);
    final c = CameraOverviewController(
      session: PtpSession(transport: t),
      connection: _FakeConnection(),
      repository: repo,
    );
    // 脚本零应答:实现若仍走 getObjectHandles 兜底(枚举也只会命中
    // 最新视频)即「脚本耗尽」炸 —— 全视频时静照口径本就无源。
    expect(await c.fetchShutterCount(), isNull);
    expect(t.opcodes, isEmpty);
    c.dispose();
  });

  test('64KB 被拒降级 512KB 重试,照样命中', () async {
    final t = _FakeTransport();
    t.reply(PtpResult(responseCode: 0x2001, data: _handles([5])));
    t.fail(const FormatException('0x101B 拒大块'));
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(7)));
    final c = _controller(t);
    expect(await c.fetchShutterCount(), 7);
    c.dispose();
  });

  test('空卡(句柄集为空)回 null', () async {
    final t = _FakeTransport();
    t.reply(PtpResult(responseCode: 0x2001, data: _handles([])));
    final c = _controller(t);
    expect(await c.fetchShutterCount(), isNull);
    c.dispose();
  });

  test('整链失败(枚举即拒)静默回 null 不抛', () async {
    final t = _FakeTransport();
    t.fail(const FormatException('0x200F'));
    final c = _controller(t);
    expect(await c.fetchShutterCount(), isNull);
    c.dispose();
  });

  test('拍照后 0x4002 直指刚拍照片,不依赖仓库缓存', () async {
    final t = _FakeTransport();
    final conn = _FakeConnection();
    final repo = _FakeRepo([
      CameraAlbum(
        folderHandle: CameraAlbum.allPhotosHandle,
        name: 'grid.allPhotos',
        items: [
          PhotoGroup([
            _entry(100, DateTime(2026, 10, 22)),
          ]),
        ],
      ),
    ]);
    // 门永不开放:connected 沿只置 _linkUp,不触发刷参吃脚本。
    final c = CameraOverviewController(
      session: PtpSession(transport: t),
      connection: conn,
      repository: repo,
      connectRefreshGate: () => Completer<void>().future,
    );
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    t.eventsCtrl.add(const PtpEvent(
        code: PtpEventCode.objectAdded, transactionId: 1, params: [0x777]));
    await pumpEventQueue();
    // 脚本只放新句柄的 partial:实现若错走仓库(句柄 100),脚本耗尽即败。
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(15965)));
    expect(await c.fetchShutterCount(), 15965);
    expect(t.partialHandles, [0x777]);
    c.dispose();
  });

  test('弹层在场时拍照沿自动重读,shutterCount 状态更新', () async {
    final t = _FakeTransport();
    final conn = _FakeConnection();
    final c = CameraOverviewController(
      session: PtpSession(transport: t),
      connection: conn,
      connectRefreshGate: () => Completer<void>().future,
    );
    conn.statesCtrl.add(CameraLinkState.connected);
    await pumpEventQueue();
    c.shutterLive = true;
    t.reply(PtpResult(responseCode: 0x2001, data: _buildTiff(15965)));
    t.eventsCtrl.add(const PtpEvent(
        code: PtpEventCode.objectAdded, transactionId: 1, params: [0x777]));
    await pumpEventQueue();
    // 事件沿自动重读:零枚举(仅 1 个 partial 直指 0x777),状态即新值。
    expect(c.shutterCount, 15965);
    expect(c.shutterReading, isFalse);
    expect(t.opcodes, [PtpOperationCode.getPartialObject]);
    expect(t.partialHandles, [0x777]);
    c.dispose();
  });
}

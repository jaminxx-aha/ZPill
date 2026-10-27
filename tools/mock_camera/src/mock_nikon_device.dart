/// 假相机的设备人设:PTP 操作分发表 + 会话/模式状态 + 合成应答。
///
/// 只做「协议语义」,不做任何 socket 事 —— TCP/握手/分包在
/// `mock_ptpip_server.dart`。操作码语义一律以我方客户端
/// (`lib/core/ptp/ptp_session.dart`)为镜像:mock 是它的对端。
///
/// 支持面(= GetDeviceInfo 上报的操作码表):
/// - 标准:0x1001 GetDeviceInfo / 0x1002 OpenSession / 0x1003 CloseSession /
///   0x1004 GetStorageIDs / 0x1005 GetStorageInfo / 0x1007 GetObjectHandles /
///   0x1008 GetObjectInfo / 0x1009 GetObject / 0x100A GetThumb /
///   0x100E InitiateCapture / 0x1016 SetDevicePropValue(数据出相,收条) /
///   0x101B GetPartialObject
/// - 尼康:0x90C2 ChangeCameraMode / 0x90C4 GetLargeThumb / 0x90C7 GetEvent /
///   0x90C8 DeviceReady / 0x9207 InitiateCaptureRecInMedia /
///   0x920A StartMovieRecInCard / 0x920B EndMovieRec / 0x920C TerminateCapture /
///   0x9435 ChangeApplicationMode / 0x941C GetEventEx
/// - 其余一律 OperationNotSupported(0x2005)。
library;

import 'dart:typed_data';

import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/ptpip/object_format.dart';
import 'package:z_pill/core/utils/byte_writer.dart';

import 'mock_objects.dart';

/// 设备应答:响应码 + 响应参数 + 可选数据相 + 相机要推的异步事件。
final class MockPtpReply {
  const MockPtpReply(
      {required this.code, this.params = const [], this.data, this.events});
  final int code;
  final List<int> params;

  /// 数据入相载荷(由 server 拆 StartData/Data/EndData 发出)。
  final Uint8List? data;
  final List<MockPtpEvent>? events;
}

/// 相机侧待推事件(事件码 + 参数;tid 由 server 填)。
final class MockPtpEvent {
  const MockPtpEvent(this.code, this.params);
  final int code;
  final List<int> params;
}

/// 假尼康机身(Zf 人设)。
final class MockNikonDevice {
  MockNikonDevice({
    List<MockObject>? objects,
    this.model = 'NIKON ZF',
    this.manufacturer = 'Nikon Corporation',
    this.deviceVersion = 'MockV1.00',
    // 定宽左补零,镜像 Zf 序列号方言(客户端 _normalizeSerial 剥前导零)。
    this.serialNumber = '000000000000000000000000MOCK0001',
    this.storageId = 0x00010001,
  }) : _objects = List.of(objects ?? defaultMockObjects());

  final String model;
  final String manufacturer;
  final String deviceVersion;
  final String serialNumber;

  /// 唯一存储槽 ID(双卡机型人设可扩,当前单卡)。
  final int storageId;

  final List<MockObject> _objects;

  // ── 会话状态(客户端可观测,mock 单连接语义) ──
  bool sessionOpen = false;

  /// 0x90C2 的当前值(1 = remote / 0 = PC-camera)。
  int cameraMode = 0;

  /// 0x9435 的当前值。
  int applicationMode = 0;

  bool recording = false;

  /// 各操作码被调次数(e2e 断言连接流实际发了什么)。
  final Map<int, int> opCounts = {};

  /// 当前对象表(含拍后新增;e2e 断言用)。
  List<MockObject> get objects => List.unmodifiable(_objects);

  MockObject? object(int handle) {
    for (final o in _objects) {
      if (o.handle == handle) return o;
    }
    return null;
  }

  /// 拍后新增对象的下一个 DSC 序号(取现有最大值 + 1)。
  late final int _nextDscIndex = () {
    var max = 4;
    final re = RegExp(r'^DSC_(\d{4})\.JPG$');
    for (final o in _objects) {
      final m = re.firstMatch(o.filename);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (n > max) max = n;
      }
    }
    return max + 1;
  }();
  var _captureCount = 0;

  static const int _storageTypeRemovableRam = 4; // ISO 15740 StorageType
  static const int _fsTypeGenericHierarchical = 2; // DCIM 层级目录
  static const int _accessReadWrite = 0;

  /// GetDeviceInfo 数据集(构造期缓存,字节布局镜像 PtpDeviceInfo.parse)。
  late final Uint8List deviceInfoDataset = _buildDeviceInfo();

  /// 操作分发:唯一入口,server 把每个 OperationRequest 交给这里。
  MockPtpReply execute(
      int opcode, List<int> params, Uint8List? dataOut) {
    opCounts[opcode] = (opCounts[opcode] ?? 0) + 1;
    // 会话门:OpenSession 前只放行 GetDeviceInfo / OpenSession(真机同款)。
    if (!sessionOpen &&
        opcode != PtpOperationCode.getDeviceInfo &&
        opcode != PtpOperationCode.openSession) {
      return const MockPtpReply(code: PtpResponseCode.sessionNotOpen);
    }
    switch (opcode) {
      case PtpOperationCode.getDeviceInfo:
        return MockPtpReply(
            code: PtpResponseCode.ok, data: deviceInfoDataset);
      case PtpOperationCode.openSession:
        if (sessionOpen) {
          // 上次会话残留:真机 0x201E,客户端 _openLocked 会 Close+重开。
          return const MockPtpReply(code: PtpResponseCode.sessionAlreadyOpen);
        }
        sessionOpen = true;
        return const MockPtpReply(code: PtpResponseCode.ok);
      case PtpOperationCode.closeSession:
        sessionOpen = false;
        return const MockPtpReply(code: PtpResponseCode.ok);
      case PtpOperationCode.getStorageIds:
        return MockPtpReply(
          code: PtpResponseCode.ok,
          data: (ByteWriter()
                ..u32(1)
                ..u32(storageId))
              .takeBytes(),
        );
      case NikonOperationCode.getVendorStorageIds:
        // application 模式方言:0x1004 恒幻影无卡 ID,真卡 ID 走 0x9209
        //(官方 §6.2.3.1)—— mock 同人设回同一组 ID。
        return MockPtpReply(
          code: PtpResponseCode.ok,
          data: (ByteWriter()
                ..u32(1)
                ..u32(storageId))
              .takeBytes(),
        );
      case PtpOperationCode.getStorageInfo:
        return _storageInfo(params);
      case PtpOperationCode.getObjectHandles:
        return _objectHandles(params);
      case PtpOperationCode.getObjectInfo:
        return _objectInfoReply(params);
      case PtpOperationCode.getObject:
        final o = object(params.isEmpty ? -1 : params[0]);
        if (o == null || o.isFolder) {
          return const MockPtpReply(code: PtpResponseCode.invalidParameter);
        }
        return MockPtpReply(code: PtpResponseCode.ok, data: o.body);
      case PtpOperationCode.getThumb:
        final o = object(params.isEmpty ? -1 : params[0]);
        if (o == null || o.isFolder) {
          return const MockPtpReply(code: PtpResponseCode.invalidParameter);
        }
        return MockPtpReply(code: PtpResponseCode.ok, data: o.thumb);
      case PtpOperationCode.initiateCapture:
        return _capture();
      case PtpOperationCode.setDevicePropValue:
        // 数据出相收条(值不消费;enableAppControl 的 0xD1F0 兜底走这里)。
        return const MockPtpReply(code: PtpResponseCode.ok);
      case PtpOperationCode.getPartialObject:
        return _partialObject(params);
      case NikonOperationCode.changeCameraMode:
        cameraMode = params.isEmpty ? 0 : params[0];
        return const MockPtpReply(code: PtpResponseCode.ok);
      case NikonOperationCode.changeApplicationMode:
        applicationMode = params.isEmpty ? 0 : params[0];
        return const MockPtpReply(code: PtpResponseCode.ok);
      case NikonOperationCode.getLargeThumb:
        final o = object(params.isEmpty ? -1 : params[0]);
        if (o == null || o.isFolder) {
          return const MockPtpReply(code: PtpResponseCode.invalidParameter);
        }
        return MockPtpReply(code: PtpResponseCode.ok, data: o.largeThumb);
      case NikonOperationCode.getEvent:
        // 与 0x941C 同布局的空队列(u32 元素数 0)。客户端无 0x90C7 调用
        // 方,留作探针/后续轮询引擎的对端。
        return MockPtpReply(
          code: PtpResponseCode.ok,
          data: (ByteWriter()..u32(0)).takeBytes(),
        );
      case NikonOperationCode.getEventEx:
        // 人设恒空(拍摄事件走事件 socket 推送;真机 Zf 可能只走本队列,
        // 见 server 类注的留账)。
        return MockPtpReply(
          code: PtpResponseCode.ok,
          data: (ByteWriter()..u32(0)).takeBytes(),
        );
      case NikonOperationCode.deviceReady:
        return const MockPtpReply(code: PtpResponseCode.ok);
      case NikonOperationCode.initiateCaptureRecInMedia:
        return _capture();
      case NikonOperationCode.startMovieRecInCard:
        recording = true;
        return const MockPtpReply(code: PtpResponseCode.ok);
      case NikonOperationCode.endMovieRec:
        recording = false;
        return const MockPtpReply(code: PtpResponseCode.ok);
      case NikonOperationCode.terminateCapture:
        return const MockPtpReply(code: PtpResponseCode.ok);
      default:
        return const MockPtpReply(code: PtpResponseCode.operationNotSupported);
    }
  }

  /// 拍摄:合成新 JPEG 对象入表,回 OK + ObjectAdded(0x4002)/
  /// CaptureComplete(0x400D)两事件(server 在响应后推到事件 socket)。
  MockPtpReply _capture() {
    final index = _nextDscIndex + _captureCount++;
    final name = 'DSC_${index.toString().padLeft(4, '0')}.JPG';
    final body = synthesizeJpeg(320, 240, seed: 0x9000 + index);
    final thumb = synthesizeJpeg(160, 120, seed: 0x9000 + index);
    final handle = 0x00010001 + _objects.length;
    _objects.add(MockObject(
      handle: handle,
      storageId: storageId,
      format: ObjectFormatCode.exifJpeg,
      filename: name,
      body: body,
      thumb: thumb,
      largeThumb: synthesizeJpeg(320, 240, seed: 0x9000 + index),
      parent: 0x00010000,
      captureDate: '20261015T101530.00',
      thumbWidth: 160,
      thumbHeight: 120,
      imageWidth: 320,
      imageHeight: 240,
    ));
    return MockPtpReply(
      code: PtpResponseCode.ok,
      events: [
        MockPtpEvent(PtpEventCode.objectAdded, [handle]),
        const MockPtpEvent(PtpEventCode.captureComplete, []),
      ],
    );
  }

  MockPtpReply _storageInfo(List<int> params) {
    if (params.isEmpty || params[0] != storageId) {
      // 无卡/未知槽:ISO 标准码 0x2013。
      return const MockPtpReply(code: PtpResponseCode.storeNotAvailable);
    }
    return MockPtpReply(
      code: PtpResponseCode.ok,
      data: (ByteWriter()
            ..u16(_storageTypeRemovableRam)
            ..u16(_fsTypeGenericHierarchical)
            ..u16(_accessReadWrite)
            ..u64(64 * 1024 * 1024 * 1024) // 64GB 卡
            ..u64(32 * 1024 * 1024 * 1024) // 32GB 可用
            ..u32(5000)
            ..ptpString('SD Card')
            ..ptpString('NIKON ZF'))
          .takeBytes(),
    );
  }

  /// GetObjectHandles:镜像 Zf 真机方言 —— parent=0 全量、0xFFFFFFFF 只回
  /// 根层文件夹(两者语义与规范相反,2026-09-27 真机实测);format /
  /// storage 过滤参数按规范语义。
  MockPtpReply _objectHandles(List<int> params) {
    final storage = params.isNotEmpty ? params[0] : GetObjectHandlesParams.storageAll;
    final format = params.length > 1 ? params[1] : GetObjectHandlesParams.formatAll;
    final parent = params.length > 2 ? params[2] : GetObjectHandlesParams.parentRoot;
    Iterable<MockObject> sel = _objects;
    if (parent == GetObjectHandlesParams.parentAll) {
      sel = sel.where((o) => o.isFolder && o.parent == 0);
    } else if (parent != GetObjectHandlesParams.parentRoot) {
      sel = sel.where((o) => o.parent == parent);
    }
    if (format != GetObjectHandlesParams.formatAll) {
      sel = sel.where((o) => o.format == format);
    }
    if (storage != GetObjectHandlesParams.storageAll) {
      sel = sel.where((o) => o.storageId == storage);
    }
    final handles = sel.map((o) => o.handle).toList();
    return MockPtpReply(
      code: PtpResponseCode.ok,
      data: (ByteWriter()
            ..u32(handles.length)
            ..raw([for (final h in handles) ..._u32Bytes(h)]))
          .takeBytes(),
    );
  }

  static List<int> _u32Bytes(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  /// GetPartialObject(0x101B):params [handle, offset, maxBytes],32 位
  /// 偏移分块读(客户端 AIMD 分块下载的对端)。越界/句柄无效回
  /// 0x201D;maxBytes 越过尾部按剩余量截断(真机同款宽容)。
  MockPtpReply _partialObject(List<int> params) {
    if (params.length < 3) {
      return const MockPtpReply(code: PtpResponseCode.invalidParameter);
    }
    final o = object(params[0]);
    if (o == null || o.isFolder) {
      return const MockPtpReply(code: PtpResponseCode.invalidParameter);
    }
    final offset = params[1];
    final maxBytes = params[2];
    if (offset >= o.body.length) {
      return const MockPtpReply(code: PtpResponseCode.invalidParameter);
    }
    final end = (offset + maxBytes) > o.body.length ? o.body.length : offset + maxBytes;
    return MockPtpReply(
      code: PtpResponseCode.ok,
      data: Uint8List.sublistView(o.body, offset, end),
    );
  }

  MockPtpReply _objectInfoReply(List<int> params) {
    final o = object(params.isEmpty ? -1 : params[0]);
    if (o == null) {
      return const MockPtpReply(code: PtpResponseCode.invalidParameter);
    }
    return MockPtpReply(code: PtpResponseCode.ok, data: _objectInfoDataset(o));
  }

  /// ObjectInfo 数据集:52B 定长头 + 三串,布局镜像
  /// `lib/core/ptpip/object_info.dart` 的 parse(同一真机校验口径)。
  Uint8List _objectInfoDataset(MockObject o) {
    final w = ByteWriter()
      ..u32(o.storageId)
      ..u16(o.format)
      ..u16(0) // ProtectionStatus
      ..u32(o.body.length)
      ..u16(o.isFolder ? 0 : ObjectFormatCode.exifJpeg) // ThumbFormat
      ..u32(o.isFolder ? 0 : o.thumb.length)
      ..u32(o.thumbWidth)
      ..u32(o.thumbHeight)
      ..u32(o.imageWidth)
      ..u32(o.imageHeight)
      ..u32(o.isFolder ? 0 : 24) // ImageBitDepth
      ..u32(o.parent)
      ..u16(o.isFolder ? 1 : 0) // AssociationType(1 = generic folder)
      ..u32(0) // AssociationDesc
      ..u32(0) // SequenceNumber
      ..ptpString(o.filename)
      ..ptpString(o.captureDate)
      ..ptpString(o.captureDate); // ModificationDate(拍后不改,同值)
    return w.takeBytes();
  }

  Uint8List _buildDeviceInfo() {
    const operations = <int>[
      PtpOperationCode.getDeviceInfo, // 0x1001
      PtpOperationCode.openSession, // 0x1002
      PtpOperationCode.closeSession, // 0x1003
      PtpOperationCode.getStorageIds, // 0x1004
      PtpOperationCode.getStorageInfo, // 0x1005
      NikonOperationCode.getVendorStorageIds, // 0x9209
      PtpOperationCode.getObjectHandles, // 0x1007
      PtpOperationCode.getObjectInfo, // 0x1008
      PtpOperationCode.getObject, // 0x1009
      PtpOperationCode.getThumb, // 0x100A
      PtpOperationCode.initiateCapture, // 0x100E
      PtpOperationCode.setDevicePropValue, // 0x1016
      PtpOperationCode.getPartialObject, // 0x101B
      NikonOperationCode.changeCameraMode, // 0x90C2
      NikonOperationCode.getLargeThumb, // 0x90C4
      NikonOperationCode.getEvent, // 0x90C7
      NikonOperationCode.deviceReady, // 0x90C8
      NikonOperationCode.initiateCaptureRecInMedia, // 0x9207
      NikonOperationCode.startMovieRecInCard, // 0x920A
      NikonOperationCode.endMovieRec, // 0x920B
      NikonOperationCode.terminateCapture, // 0x920C
      NikonOperationCode.getEventEx, // 0x941C
      NikonOperationCode.changeApplicationMode, // 0x9435
    ];
    const events = <int>[
      PtpEventCode.objectAdded,
      PtpEventCode.objectRemoved,
      PtpEventCode.devicePropChanged,
      PtpEventCode.storageInfoChanged,
      PtpEventCode.captureComplete,
    ];
    const imageFormats = <int>[
      ObjectFormatCode.exifJpeg,
      ObjectFormatCode.undefined, // NEF 真机口径
      ObjectFormatCode.mp4,
    ];
    final w = ByteWriter()
      ..u16(100) // StandardVersion
      ..u32(0x0000000A) // VendorExtensionId(尼康区段;客户端不消费)
      ..u16(100) // VendorExtensionVersion
      ..ptpString('Nikon: 1.0') // VendorExtensionDesc
      ..u16(0) // FunctionalMode
      ..u32(operations.length)
      ..raw([for (final op in operations) ..._u16Bytes(op)])
      ..u32(events.length)
      ..raw([for (final ev in events) ..._u16Bytes(ev)])
      ..u32(0) // DevicePropsSupported:属性族人设不支持(空表)
      ..u32(1) // CaptureFormats
      ..raw(_u16Bytes(ObjectFormatCode.exifJpeg))
      ..u32(imageFormats.length)
      ..raw([for (final f in imageFormats) ..._u16Bytes(f)])
      ..ptpString(manufacturer)
      ..ptpString(model)
      ..ptpString(deviceVersion)
      ..ptpString(serialNumber);
    return w.takeBytes();
  }

  static List<int> _u16Bytes(int v) => [v & 0xFF, (v >> 8) & 0xFF];
}

/// 链路无关的 PTP 会话层(ISO 15740):OpenSession 生命周期 +
/// 浏览/传输所需的操作封装。
///
/// 只面对 [PtpTransport](USB/PTP-IP 在此归一);PtpIpSession 的既有逻辑
/// 后续统一收敛到本层,本轮先服务 USB 线。
///
/// 会话恢复策略照搬 tools/usb_probe 的 ensure_session(**真机验证**):
/// 上次会话未正常关闭时,相机对 OpenSession 回 SessionAlreadyOpen
/// (0x201E),此时发 CloseSession(响应可忽略)再重开即可。
library;

import 'dart:async';
import 'dart:typed_data';

import '../browser/storage_info.dart';
import '../ptpip/object_info.dart';
import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'device_prop.dart';
import 'operation_codes.dart';
import 'ptp_transport.dart';

/// 相机返回非 OK 响应码时抛出;上层(UI/连接层)以此提示用户。
final class PtpResponseException implements Exception {
  const PtpResponseException({
    required this.opcode,
    required this.responseCode,
    this.params = const [],
  });

  final int opcode;
  final int responseCode;

  /// 响应参数(通常为空)。
  final List<int> params;

  @override
  String toString() {
    final op = opcode.toRadixString(16).toUpperCase().padLeft(4, '0');
    final rc = responseCode.toRadixString(16).toUpperCase().padLeft(4, '0');
    final extra = params.isEmpty ? '' : ' params=$params';
    return 'PtpResponseException: 操作 0x$op 收到响应 0x$rc$extra';
  }
}

/// GetDeviceInfo(0x1001)数据集 —— 最小解析(仅浏览/连接所需字段,
/// 数组完整收录:后续能力检查如 GetPartialObjectEx 在册与否要用)。
///
/// 布局按 ISO 15740 §9,经 Zf 真机 probe 校验(probe.py dump_device_info
/// 同一解析):standardVersion u16 / vendorExtensionId u32 /
/// vendorExtensionVersion u16 / desc STRING / functionalMode u16,
/// 随后 5 组「u32 计数 + N 个 u16」(操作/事件/属性/捕获格式/图像格式),
/// 最后 manufacturer / model / deviceVersion / serialNumber 四个 STRING。
final class PtpDeviceInfo {
  const PtpDeviceInfo({
    required this.standardVersion,
    required this.vendorExtensionId,
    required this.functionalMode,
    required this.operationsSupported,
    required this.eventsSupported,
    required this.devicePropsSupported,
    required this.captureFormats,
    required this.imageFormats,
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    this.serialNumber,
  });

  final int standardVersion;
  final int vendorExtensionId;
  final int functionalMode;
  final List<int> operationsSupported;
  final List<int> eventsSupported;
  final List<int> devicePropsSupported;
  final List<int> captureFormats;
  final List<int> imageFormats;
  final String manufacturer;
  final String model;
  final String deviceVersion;
  final String? serialNumber;

  /// 操作是否在册(相机能力检查,如 GetPartialObjectEx 断点续传)。
  bool supportsOperation(int opcode) => operationsSupported.contains(opcode);

  static PtpDeviceInfo parse(Uint8List dataset) {
    final r = ByteReader(dataset);
    final standardVersion = r.u16();
    final vendorExtensionId = r.u32();
    r.u16(); // VendorExtensionVersion
    r.ptpString(); // VendorExtensionDesc
    final functionalMode = r.u16();
    final operationsSupported = _u16Array(r);
    final eventsSupported = _u16Array(r);
    final devicePropsSupported = _u16Array(r);
    final captureFormats = _u16Array(r);
    final imageFormats = _u16Array(r);
    return PtpDeviceInfo(
      standardVersion: standardVersion,
      vendorExtensionId: vendorExtensionId,
      functionalMode: functionalMode,
      operationsSupported: operationsSupported,
      eventsSupported: eventsSupported,
      devicePropsSupported: devicePropsSupported,
      captureFormats: captureFormats,
      imageFormats: imageFormats,
      manufacturer: r.ptpString() ?? '',
      model: r.ptpString() ?? '',
      deviceVersion: r.ptpString() ?? '',
      serialNumber: r.ptpString(),
    );
  }

  /// PTP 数组数据集类型:u32 计数 + N 个 u16。
  static List<int> _u16Array(ByteReader r) {
    final n = r.u32();
    return [for (var i = 0; i < n; i++) r.u16()];
  }
}

/// MfDrive(0x9204)的结果分类(OpenZCine MFDriveOutcome 口径):
/// 行程尽头与步进量过小是**结果而非错误** —— 遥控跟焦 UI 据此提示,
/// 不当失败弹错。
enum MfDriveOutcome {
  /// OK:一步驱动完成。
  complete,

  /// 0xA00C:步进行程尽头(再往这个方向没有更多行程)。
  endOfTravel,

  /// 0xA00E:步进量过小,镜头未动(提高单步脉冲数)。
  stepTooSmall,

  /// 链路/状态类拒绝(镜头不可遥控 —— 机械对焦环;或机身忙)。
  refused,
}

/// PTP 会话:open/close 生命周期 + 浏览/下载操作封装。
///
/// 事务串行:相机一次只接受一个事务,本层用 future-chain 互斥把所有
/// [PtpTransport.execute] 排成全局队列(缩略图/大图预览/下载混流时,
/// 上层可放心并发调用;单文件下载在整个事务期间持锁)。
/// 锁不可重入:加锁段内不得再调用本类的其他加锁方法。
final class PtpSession {
  PtpSession({required this.transport});

  final PtpTransport transport;

  Future<void> _gate = Future<void>.value();

  /// 把 [op] 排入全局串行队列;失败不断链(后续排队照常执行)。
  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _gate.then((_) => op());
    _gate = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  bool _sessionOpen = false;

  /// 会话是否已打开(OpenSession 成功且未 CloseSession)。
  bool get isSessionOpen => _sessionOpen;

  /// 0x90C2 remote 模式是否在持有(USB 连接流兜底进入,或用户接管/
  /// 连拍括持开启)。每次开新会话复位 —— 机身对每个连接自行重估模式,
  /// 旧链的持有态不得带到新链。
  bool _remoteModeActive = false;
  bool get remoteModeActive => _remoteModeActive;

  PtpDeviceInfo? _deviceInfo;

  /// 上次 GetDeviceInfo 的缓存(纯读,不发事务;未取过为 null)——
  /// 快门码选择等只需 op 表的调用方用它,避免无谓往返。
  PtpDeviceInfo? get cachedDeviceInfo => _deviceInfo;

  /// GetDeviceInfo;会话内缓存([force] 强制刷新)。
  /// 唯一可在 OpenSession 之前调用的操作。
  Future<PtpDeviceInfo> getDeviceInfo({bool force = false}) async {
    if (_deviceInfo != null && !force) return _deviceInfo!;
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: PtpOperationCode.getDeviceInfo),
        ));
    _ensureOk(result, PtpOperationCode.getDeviceInfo);
    _deviceInfo = PtpDeviceInfo.parse(result.data!);
    return _deviceInfo!;
  }

  /// OpenSession(带 0x201E 自动恢复,照搬 probe ensure_session)。
  /// 恢复链(Close + 重开)整体持锁,避免与其他操作交错。
  Future<void> open() async {
    if (_sessionOpen) return;
    await _serialized(_openLocked);
  }

  Future<void> _openLocked() async {
    final result = await transport.execute(
      const PtpRequest(opcode: PtpOperationCode.openSession, params: [1]),
    );
    if (result.responseCode == PtpResponseCode.sessionAlreadyOpen) {
      // 上次会话未关(拔线/崩溃残留):关掉重开。残留会话的
      // CloseSession 可能报错(会话号不属于本连接),响应码与异常都不阻断重开。
      try {
        await transport.execute(
          const PtpRequest(opcode: PtpOperationCode.closeSession),
        );
      } on Exception {
        // 尽力而为,见上
      }
      final retry = await transport.execute(
        const PtpRequest(opcode: PtpOperationCode.openSession, params: [1]),
      );
      _ensureOk(retry, PtpOperationCode.openSession);
    } else {
      _ensureOk(result, PtpOperationCode.openSession);
    }
    _sessionOpen = true;
    _remoteModeActive = false; // 新链新账:旧链的 remote 模式持有态不带来
  }

  /// CloseSession(幂等、尽力而为):相机已拔出时不因清理报错。
  /// 设备级断开由连接层调 transport.close()。
  Future<void> close() async {
    _remoteModeActive = false; // 链将亡:remote 持有态一律作废(含未开会话的旁路持有)
    if (!_sessionOpen) return;
    _sessionOpen = false;
    await _serialized(() async {
      try {
        await transport.execute(
          const PtpRequest(opcode: PtpOperationCode.closeSession),
        );
      } on Exception {
        // 链路已断:本地状态已清,足够
      }
    });
  }

  /// GetObjectHandles:u32 计数 + N 个 u32 handle。
  ///
  /// 参数默认值 = Zf 真机语义的全量枚举:**parent 必须传 0**
  /// (GetObjectHandlesParams:Zf 把 0 与 0xFFFFFFFF 的语义做反了)。
  Future<List<int>> getObjectHandles({
    int storageId = GetObjectHandlesParams.storageAll,
    int objectFormat = GetObjectHandlesParams.formatAll,
    int parent = GetObjectHandlesParams.parentRoot,
  }) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getObjectHandles,
          params: [storageId, objectFormat, parent],
        )));
    _ensureOk(result, PtpOperationCode.getObjectHandles);
    final data = result.data!;
    if (data.length % 4 != 0) {
      throw FormatException('GetObjectHandles 数据集 ${data.length}B 非 4 对齐');
    }
    final r = ByteReader(data);
    final count = r.u32();
    return [for (var i = 0; i < count; i++) r.u32()];
  }

  /// GetStorageIDs(0x1004):u32 计数 + N 个 u32(双卡槽 = 两个 ID)。
  Future<List<int>> getStorageIds() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: PtpOperationCode.getStorageIds),
        ));
    _ensureOk(result, PtpOperationCode.getStorageIds);
    final data = result.data!;
    if (data.length % 4 != 0) {
      throw FormatException('GetStorageIDs 数据集 ${data.length}B 非 4 对齐');
    }
    final r = ByteReader(data);
    final count = r.u32();
    return [for (var i = 0; i < count; i++) r.u32()];
  }

  /// GetStorageInfo(0x1005):单存储槽容量/余量(双卡余量展示)。
  Future<CameraStorage> getStorageInfo(int storageId) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(
              opcode: PtpOperationCode.getStorageInfo, params: [storageId]),
        ));
    _ensureOk(result, PtpOperationCode.getStorageInfo);
    return CameraStorage.parse(id: storageId, dataset: result.data!);
  }

  /// GetObjectInfo:ObjectInfo 数据集与 PTP-IP 同构,复用 ptpip 解析。
  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getObjectInfo,
          params: [handle],
        )));
    _ensureOk(result, PtpOperationCode.getObjectInfo);
    return PtpObjectInfo.parse(handle: handle, dataset: result.data!);
  }

  /// DeleteObject(0x100B,标准码):删除相机上的单个对象。
  ///
  /// RAW+JPG 合并组按成员逐个删;被删对象由仓库层出缓存
  /// (ObjectRepository.removeHandles)。**不可逆**,调用方必须弹确认。
  Future<void> deleteObject(int handle) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.deleteObject,
          params: [handle],
        )));
    _ensureOk(result, PtpOperationCode.deleteObject);
  }

  /// GetObject 流式下载:数据容器按块经 [onData] 回调(64KB 级),
  /// **不整体驻留内存** —— 上层边收边写盘。
  Future<void> getObject(
    int handle, {
    required void Function(Uint8List chunk) onData,
  }) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(opcode: PtpOperationCode.getObject, params: [handle]),
          onData: onData,
        ));
    _ensureOk(result, PtpOperationCode.getObject);
  }

  /// GetThumb(0x100A):内嵌缩略图,数据小,整体内存返回。
  Future<Uint8List> getThumb(int handle) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(opcode: PtpOperationCode.getThumb, params: [handle]),
        ));
    _ensureOk(result, PtpOperationCode.getThumb);
    return _sniffJpegStart(result.data ?? Uint8List(0));
  }

  /// GetPartialObject(0x101B):从 [offset] 起最多 [maxBytes] 字节,
  /// 32 位偏移分块读。不做能力检查(诊断用途:直接观察相机响应码),
  /// 转正断点续传时再加 supportsOperation 门禁。
  Future<Uint8List> getPartialObject(
    int handle,
    int offset,
    int maxBytes,
  ) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getPartialObject,
          params: [handle, offset, maxBytes],
        )));
    _ensureOk(result, PtpOperationCode.getPartialObject);
    return result.data ?? Uint8List(0);
  }

  /// Nikon GetLargeThumb(0x90C4):大图预览 JPEG(NEF 也能看)。
  /// 相机不支持时抛 [UnsupportedError](上层回落 GetThumb 放大)。
  /// [force] 跳过能力检查直发(诊断用:operationsSupported 可信度
  /// 本身在验证中时,以相机真实响应码为准)。
  Future<Uint8List> getLargeThumb(int handle, {bool force = false}) async {
    // 能力检查走缓存的 GetDeviceInfo(命中时无锁,不会与本方法的锁嵌套)。
    final info = await getDeviceInfo();
    if (!force && !info.supportsOperation(NikonOperationCode.getLargeThumb)) {
      throw UnsupportedError('相机不支持 Nikon GetLargeThumb(0x90C4)');
    }
    final result = await _serialized(() => transport.execute(
          PtpRequest(
              opcode: NikonOperationCode.getLargeThumb, params: [handle]),
        ));
    _ensureOk(result, NikonOperationCode.getLargeThumb);
    return _sniffJpegStart(result.data ?? Uint8List(0));
  }

  /// JPEG SOI(FFD8)嗅探:数据非 FFD8 开头时在前 512B 内找 SOI 并剥头
  /// (Nikon 0x90C4 数据布局真机验证中,防御性处理「头 + JPEG」形态;
  /// 找不到则原样返回,交由上层解码器报错占位)。
  static Uint8List _sniffJpegStart(Uint8List data) {
    if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xD8) {
      return data;
    }
    for (var i = 0; i + 1 < data.length && i < 512; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) {
        return Uint8List.sublistView(data, i);
      }
    }
    return data;
  }

  /// 事件流 = 异步通道(USB interrupt / PTP-IP 事件 socket)+ 轮询注入
  /// ([emitPolledEvents],[NikonEventPoller] 用)的并流。尼康机身的重要
  /// 事件(ObjectAdded/CaptureComplete/0x4006)可能只走 GetEventEx
  /// 0x941C 轮询通道(OpenZCine/libgphoto2 实测口径),两路并存、
  /// 消费端幂等。
  late final Stream<PtpEvent> _events = _mergedStreams(
      [transport.events, _eventInjections.stream]);
  final _eventInjections = StreamController<PtpEvent>.broadcast();

  Stream<PtpEvent> get events => _events;

  /// 轮询事件注入([NikonEventPoller] 调用)。
  void emitPolledEvents(Iterable<PtpEvent> polled) {
    for (final e in polled) {
      _eventInjections.add(e);
    }
  }

  /// 广播并流(单订阅源 → 广播聚合;单监听者模型,close 后不再复听)。
  static Stream<T> _mergedStreams<T>(List<Stream<T>> streams) {
    late StreamController<T> ctrl;
    final subs = <StreamSubscription<T>>[];
    var pending = streams.length;
    ctrl = StreamController<T>.broadcast(
      onListen: () {
        for (final s in streams) {
          subs.add(s.listen(ctrl.add,
              onError: ctrl.addError,
              onDone: () {
                if (--pending == 0) ctrl.close();
              }));
        }
      },
      onCancel: () {
        for (final s in subs) {
          s.cancel();
        }
        subs.clear();
      },
    );
    return ctrl.stream;
  }

  /// Nikon GetEventEx(0x941C,Gen-3 事件轮询):拉取并清空厂商事件队列。
  ///
  /// 布局(OpenZCine PTPNikonEventList):`u32 元素数 + N ×
  /// (u16 事件码 + u16 参数数 + 参数数 × u32)`;元素数上限 2048 防御。
  /// 相机不支持(旧机身回 0x2005)时上抛,由 [NikonEventPoller] 停轮询。
  Future<List<PtpEvent>> getEventEx() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.getEventEx,
        )));
    _ensureOk(result, NikonOperationCode.getEventEx);
    final data = result.data ?? Uint8List(0);
    if (data.length < 4) return const [];
    var count = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    if (count > 2048) count = 2048;
    final events = <PtpEvent>[];
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 4 > data.length) break;
      final code = data[offset] | (data[offset + 1] << 8);
      final paramCount = data[offset + 2] | (data[offset + 3] << 8);
      offset += 4;
      if (offset + paramCount * 4 > data.length) break;
      final params = <int>[
        for (var p = 0; p < paramCount; p++)
          data[offset + p * 4] |
              (data[offset + p * 4 + 1] << 8) |
              (data[offset + p * 4 + 2] << 16) |
              (data[offset + p * 4 + 3] << 24),
      ];
      offset += paramCount * 4;
      events.add(PtpEvent(
          code: code, transactionId: 0xFFFFFFFF, params: params));
    }
    return events;
  }

  /// Nikon GetPtpIpPairingCode(0x952B):智能设备模式的配对验证码。
  ///
  /// 数据集 = count(u32 LE)+ count 个字节,各字节的十进制值连成验证码
  /// (NiConn_DEMO 对 SnapBridge 抓包的语义;例:count=4,字节
  /// 05 00 07 07 → "5077")。**响应非 OK 时返回 null**(多半意味着本
  /// 客户端已配对或相机不要求配对,上层据此跳过配对相;具体语义待真机
  /// 核对);链路级异常照常抛出,不在此吞。
  Future<String?> getPairingCode() async {
    late final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.getPtpIpPairingCode)));
      _ensureOk(result, NikonOperationCode.getPtpIpPairingCode);
    } on PtpResponseException {
      return null;
    }
    final data = result.data;
    if (data == null || data.length < 4) return null;
    final count = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    if (count <= 0 || count > data.length - 4) return null;
    return [for (var i = 0; i < count; i++) data[4 + i]].join();
  }

  /// Nikon CompletePairing(0x935A,param 0x2001):确认配对。
  ///
  /// 相机把本客户端(Init 载荷里的 16B UUID)记为已配对设备;Z50II 实测
  /// 配对完成后相机自行结束会话(Zf 待真机核对)—— 响应前链路被收线
  /// 属预期,上层按配对完成处理,不当作失败。
  Future<void> completePairing() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
        opcode: NikonOperationCode.completePairing, params: [0x2001])));
    _ensureOk(result, NikonOperationCode.completePairing);
  }

  // ---- 遥控域:曝光参数 / Live View / 快门释放 ----

  /// SetDevicePropValue(0x1016)总开关。2026-10-05 生产翻开:Zf 真机
  /// 已实证 0x1016 可写(probe 写 0xD406 成功、回读生效),且 app 的
  /// 写入值域一律取自相机自报 PropDesc(枚举域/getSet/类型),不发
  /// 臆造值。旗标保留作紧急关断:写路径真机出问题时置回 false,
  /// setDevicePropValue 直接抛 UnsupportedError、UI 调节入口静默只读。
  static bool kSetPropEnabled = true;

  /// GetDevicePropValue(0x1015):当前值。响应是裸值数据集,解码类型
  /// 查标准表(见 [PtpDevicePropValue.parse]);方言偏离时改走
  /// [getDevicePropDesc] 拿自描述类型(待真机核对)。
  ///
  /// **扩展属性码(> 0xFFFF,0x0001_xxxx)自动改走 Gen-3 Ex 读**
  /// (0x943B,OpenZCine 实测口径:2 字节码必须走标准 op,混用会拒)。
  Future<PtpDevicePropValue> getDevicePropValue(int propCode) async {
    final op = propCode > 0xFFFF
        ? NikonOperationCode.getDevicePropValueEx
        : PtpOperationCode.getDevicePropValue;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [propCode],
        )));
    _ensureOk(result, op);
    return PtpDevicePropValue.parse(propCode, result.data ?? Uint8List(0));
  }

  /// GetDevicePropDesc(0x1014):属性全描述(类型/可写性/枚举域/默认值),
  /// 数据集自描述类型,是裸值解码的对照组。
  Future<PtpDevicePropDesc> getDevicePropDesc(int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getDevicePropDesc,
          params: [propCode],
        )));
    _ensureOk(result, PtpOperationCode.getDevicePropDesc);
    return PtpDevicePropDesc.parse(result.data ?? Uint8List(0));
  }

  /// SetDevicePropValue(0x1016,数据入相)。门禁 [kSetPropEnabled]。
  /// 扩展属性码(> 0xFFFF)自动改走 Gen-3 Ex 写(0x943C,同
  /// [getDevicePropValue] 的路由口径)。
  Future<void> setDevicePropValue(PtpDevicePropValue value) async {
    if (!kSetPropEnabled) {
      throw UnsupportedError(
          'SetDevicePropValue 已被总闸关断(kSetPropEnabled=false,紧急关断)');
    }
    final op = value.code > 0xFFFF
        ? NikonOperationCode.setDevicePropValueEx
        : PtpOperationCode.setDevicePropValue;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [value.code],
          dataOut: value.encode(),
        )));
    _ensureOk(result, op);
  }

  /// 连接后切「应用模式」(Z 系真机口径,OpenZCine 实测:不切则相机对
  /// 遥控写回 0x200F AccessDenied)。链路对齐 OpenZCine 连接脚本:
  /// ① 0x9435 ChangeApplicationMode p1=1(无线/二代+直通);② 非 OK
  /// 应答(USB 人设恒拒,2026-10-07 真机)且 [usbRemoteFallback](USB
  /// 连接流专用)→ **0x90C2 ChangeCameraMode(1) 进 remote 模式** ——
  /// OpenZCine USB 兜底同款:「USB 上 0x9435 恒拒,remote 模式被接受
  /// 并解锁控制」,Zf 收到即退出上传优先模式;③ 仍败 → 回退写
  /// ApplicationMode 属性 0xD1F0=1(u8,一代 op 缺席口径)。
  /// **不写 0xD406 initiator 身份**:OpenZCine 全程不写,而身份写会让
  /// 机身把主机按新身份归类(op 表 119→124 变化)—— 2026-10-07 真机
  /// 复报:写身份 + remote 模式 = 机身停「已连接到计算机」屏不进取景;
  /// 不写 + remote 模式 + 连接即开取景(HomeShell autoLiveViewOnConnect)
  /// = 及时取景。usbfs 主机实证过的身份写只保留在 LiveViewEngine 的
  /// 0xA004 自愈末级(见 [writeInitiatorIdentity])。
  /// **不走 [kSetPropEnabled] 门禁** —— 它是连接模式控制而非拍摄参数
  /// 写,且发生在任何参数面板之前;连双失败也只返回 false 不抛(尽力
  /// 而为,拍照/读参数不依赖它,真机核对)。
  Future<bool> enableAppControl({bool usbRemoteFallback = false}) async {
    var rc = PtpResponseCode.operationNotSupported;
    try {
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.changeApplicationMode,
            params: [1],
          )));
      rc = result.responseCode;
    } on Object {
      // op 缺席/链路类(含脚本耗尽类 StateError):走回退。
      // 尽力而为步骤,on Object 兜底 —— 它失败不得影响连接主流程。
    }
    if (rc == PtpResponseCode.ok) return true;
    if (usbRemoteFallback) {
      try {
        // remote 模式 = 机身拨盘锁定、控制权交 host(与用户「接管」
        // 同一形态)—— 成功即置 [remoteModeActive],UI 侧对齐接管态。
        await changeCameraMode(1);
        return true;
      } on Object {
        // 0x90C2 也被拒(老机身 op 缺席):落到 0xD1F0。
      }
    }
    try {
      final w = ByteWriter()..u8(1);
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: PtpOperationCode.setDevicePropValue,
            params: [PtpDevicePropCode.applicationMode],
            dataOut: w.takeBytes(),
          )));
      return result.responseCode == PtpResponseCode.ok;
    } on Object {
      return false;
    }
  }

  /// 写会话发起者身份 0xD406='NikonPill'(尽力而为,失败/被拒返 false)。
  ///
  /// Zf USB 实证(2026-10-07 探针):initiator 为出厂/残留 MTP 主机串
  /// ('Windows/… MTPClassDriver')时 0x9201 StartLiveView 被拒 0xA004,
  /// 写任一非 MTP 身份串('NikonPill'/'Android Device' 均验)即解锁;
  /// 该值**每次连接弹回出厂**。身份写同时让机身把主机按新身份归类
  /// (op 表 119→124 变化;真机复报:remote 模式下带身份写 = 停
  /// 「已连接到计算机」屏),**且 iOS IC 链上不生效** —— 故连接流
  /// [enableAppControl] 不再写它(OpenZCine 全程不写),只作
  /// LiveViewEngine 0xA004 自愈的**末级**兜底(usbfs 直连主机
  /// 0x90C2 意外失效时的另一把钥匙)。
  /// 载荷 = PTP 字符串(u8 字符数 + UTF-16LE,无终止符),与探针
  /// ptp_str 同款。
  Future<bool> writeInitiatorIdentity() async {
    try {
      final w = ByteWriter()..ptpString('NikonPill');
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: PtpOperationCode.setDevicePropValue,
            params: [PtpDevicePropCode.sessionInitiatorInfo],
            dataOut: w.takeBytes(),
          )));
      return result.responseCode == PtpResponseCode.ok;
    } on Object {
      return false; // op 不在册/链路类:尽力而为,不拦调用方
    }
  }

  /// Nikon ChangeCameraMode(0x90C2,源 = OpenZCine 全系在册):切换
  /// 「remote / PC-camera」模式。[mode] 1 = remote(**APP 接管控制**:
  /// 机身拨盘锁定、屏幕可能熄灭,host 写入的会话值仅在持有期保值;
  /// Zf 在 USB 上传优先模式下收到它即退回及时取景),0 = 解除。
  /// 可在释放/AF/清洁中被拒(0xA003),调用方容忍。
  /// 成功即同步 [remoteModeActive]。
  Future<void> changeCameraMode(int mode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeCameraMode,
          params: [mode],
        )));
    _ensureOk(result, NikonOperationCode.changeCameraMode);
    _remoteModeActive = mode == 1;
  }

  /// Nikon StartLiveView(0x9201,候选码,待真机核对)。
  /// 每次开启取景重置 [getLiveViewObject] 的取码回退旗标 —— 会话跨
  /// 连接复用(PtpLinkRouter 换 transport),换接一台支持 0x9428 的
  /// 机身时下一次取景自动重新直试 Ex 码。
  Future<void> startLiveView() async {
    _liveViewFallbackLegacy = false;
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.startLiveView),
        ));
    _ensureOk(result, NikonOperationCode.startLiveView);
  }

  /// Nikon EndLiveView(0x9202,候选码,待真机核对)。
  Future<void> endLiveView() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.endLiveView),
        ));
    _ensureOk(result, NikonOperationCode.endLiveView);
  }

  /// Nikon GetLiveViewImage(0x9203,候选码,待真机核对):取一帧取景图像。
  /// 帧格式未经抓包定案,复用缩略图的 SOI 嗅探剥杂头(防御性兼容
  /// 「头 + JPEG」形态),嗅探不到 SOI 原样返回交上层解码器报错。
  Future<Uint8List> getLiveViewImage() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getLiveViewImage),
        ));
    _ensureOk(result, NikonOperationCode.getLiveViewImage);
    return _sniffJpegStart(result.data ?? Uint8List(0));
  }

  /// 同取帧,但**不剥头**返回原始 LiveViewObject —— display-info 头
  /// 里带相机每帧自报的 AF 框/虚拟水平仪/录制态(见
  /// core/remote/live_view_header.dart),监看层用它解析后再取 JPEG。
  ///
  /// 取码口径(2026-10-07 订正):**先 0x9428 GetLiveViewImageEx** ——
  /// OpenZCine 全系(Gen-1/2/3)取帧只用它,应答必带 display-info 头;
  /// 旧 0x9203 在 Zf 上应答解析不出头(水平仪回落手机/对焦框不出的
  /// 根因)。被拒(不支持/拒绝类,非忙)则记下会话内改走 0x9203 兜底
  /// (本次上抛、下一拍生效);0x2019 忙是正常轮询抖动,不上旗标照常
  /// 上抛给引擎退避。
  Future<Uint8List> getLiveViewObject() async {
    if (_liveViewFallbackLegacy) {
      final result = await _serialized(() => transport.execute(
            const PtpRequest(opcode: NikonOperationCode.getLiveViewImage),
          ));
      _ensureOk(result, NikonOperationCode.getLiveViewImage);
      return result.data ?? Uint8List(0);
    }
    try {
      final result = await _serialized(() => transport.execute(
            const PtpRequest(opcode: NikonOperationCode.getLiveViewImageEx),
          ));
      _ensureOk(result, NikonOperationCode.getLiveViewImageEx);
      return result.data ?? Uint8List(0);
    } on PtpResponseException catch (e) {
      if (e.responseCode == PtpResponseCode.deviceBusy) rethrow;
      _liveViewFallbackLegacy = true; // 下一拍起走 0x9203
      rethrow;
    }
  }

  /// 0x9428 被拒后本会话改走 0x9203(StartLiveView 时重置 —— 会话跨
  /// 连接复用,换接机身后下一次取景自动重新直试 Ex 码)。
  bool _liveViewFallbackLegacy = false;

  /// InitiateCapture(0x100E 标准,params [0,0]):快门释放,落卡存储。
  /// 0x2019 DeviceBusy(半按对焦未就绪等)按异常上抛,上层提示重试。
  Future<void> initiateCapture() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(
              opcode: PtpOperationCode.initiateCapture, params: [0, 0]),
        ));
    _ensureOk(result, PtpOperationCode.initiateCapture);
  }

  /// Nikon InitiateCaptureRecInMedia(0x9207):落卡拍。
  /// 参数 [captureSort, 0x0000] 对齐 OpenZCine initiateStillCapture
  /// (libgphoto2 ptp_nikon_capture2 双参形态):[captureSort] 缺省
  /// 0xFFFFFFFF = 直接释放不动焦点(preserveFocus 形态);0xFFFFFFFE =
  /// 先驱动 AF 再释放(半按-全按);0x0000 为旧实证形(2026-10-05 Zf
  /// 真机通过,但 2026-10-06 应用模式/接管态被 0x201D InvalidParameter
  /// 拒 —— 上层 [RemoteController] 按候选序回退)。参数在 USB/PTP-IP
  /// 容器里都是 u32,哨兵值两条链路均可完整传输。
  Future<void> initiateCaptureRecInMedia({int captureSort = 0xFFFFFFFF}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.initiateCaptureRecInMedia,
          params: [captureSort, 0],
        )));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInMedia);
  }

  /// Nikon TerminateCapture(0x920C,params [0,0]):终止进行中的连拍/
  /// Bulb 曝光,已拍帧保留(OpenZCine terminateStillCapture 同款;运行
  /// 已自行结束时相机会拒绝,调用方容忍)。真机核对。
  Future<void> terminateCapture() async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.terminateCapture,
          params: [0, 0],
        )));
    _ensureOk(result, NikonOperationCode.terminateCapture);
  }

  /// Nikon MfDrive(0x9204):手动对焦步进(相对量,跟焦环语义 ——
  /// 无绝对位置读出)。[towardNear] true = 向近对焦(参数 1)/false
  /// = 向远(参数 2);[pulses] 步进量,钳到 1..32767。OpenZCine 同款:
  /// 步进行程尽头(0xA00C)与步进量过小(0xA00E)是**结果而非错误**,
  /// 以 [MfDriveOutcome] 返回;镜头不可遥控(机械环)回 invalid-status
  /// 类 → refused。
  Future<MfDriveOutcome> mfDrive(
      {required bool towardNear, required int pulses}) async {
    final clamped = pulses.clamp(1, 32767);
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.mfDrive,
            params: [towardNear ? 1 : 2, clamped],
          )));
    } on Exception {
      return MfDriveOutcome.refused;
    }
    if (result.responseCode == PtpResponseCode.ok) {
      return MfDriveOutcome.complete;
    }
    return switch (result.responseCode) {
      NikonResponseCode.mfDriveStepEnd => MfDriveOutcome.endOfTravel,
      NikonResponseCode.mfDriveStepInsufficiency => MfDriveOutcome.stepTooSmall,
      _ => MfDriveOutcome.refused,
    };
  }

  /// Nikon StartMovieRecInCard(0x920A,无参无数据):开始卡上录制
  /// (取景开启为前置;OpenZCine 同款,真机核对)。
  Future<void> startMovieRec() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.startMovieRecInCard,
        )));
    _ensureOk(result, NikonOperationCode.startMovieRecInCard);
  }

  /// Nikon EndMovieRec(0x920B,无参无数据):结束卡上录制。
  Future<void> endMovieRec() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.endMovieRec,
        )));
    _ensureOk(result, NikonOperationCode.endMovieRec);
  }

  /// 相机时钟(0x5011,PTP 日期时间 STR 型 "YYYYMMDDTHHMMSS")。
  /// 读:本地墙钟口径比较(相机值无时区,跨时区携带的机身按本地时间
  /// 对齐是操作者预期 —— OpenZCine CameraClockSync 同款)。null = 读
  /// 失败/畸形。
  Future<DateTime?> getCameraClock() async {
    try {
      final v = await getDevicePropValue(PtpDevicePropCode.dateTime);
      final s = v.value as String?;
      if (s == null || s.length < 14) return null;
      final y = int.tryParse(s.substring(0, 4));
      final mo = int.tryParse(s.substring(4, 6));
      final d = int.tryParse(s.substring(6, 8));
      final h = int.tryParse(s.substring(9, 11));
      final mi = int.tryParse(s.substring(11, 13));
      final sec = int.tryParse(s.substring(13, 15));
      if (y == null || mo == null || d == null || h == null || mi == null ||
          sec == null) {
        return null;
      }
      return DateTime(y, mo, d, h, mi, sec);
    } on Exception {
      return null;
    }
  }

  /// 相机时钟校准:把相机时钟设为手机本地时间([now] 注入供测试)。
  /// OpenZCine 口径:**只在漂移超过阈值时写**(事务延迟 + 线格式 1 秒
  /// 粒度让小修正抖动;5 秒高于任何监看用途又必抓到抽屉里放一年的
  /// 机身),且不await影响连接主流程(尽力而为)。
  Future<void> syncCameraClock({DateTime? now, Duration threshold = const Duration(seconds: 5)}) async {
    final phone = (now ?? DateTime.now());
    final camera = await getCameraClock();
    if (camera == null) return;
    if (phone.difference(camera).abs() < threshold) return;
    final t = phone.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final s = '${t.year}${two(t.month)}${two(t.day)}T'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      await setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.dateTime,
          dataType: PtpDataType.string,
          value: s));
    } on Exception {
      // 尽力而为:校时失败不影响连接
    }
  }

  /// Nikon InitiateCaptureRecInSdram(0x90C0,候选码,待真机核对):
  /// 无卡拍进机身缓存(速传场景的对象随后经 ObjectAddedInSdram 事件流出)。
  Future<void> initiateCaptureRecInSdram() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
        opcode: NikonOperationCode.initiateCaptureRecInSdram)));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInSdram);
  }

  /// Nikon ChangeAfArea(0x9205):移动取景对焦区域。
  /// 参数布局按 OpenZCine PTPIPClientSession:两 UINT32 = 帧头 whole-size
  /// 坐标系 x/y(@16/18,如 6048×3400;recentre 发 coordinateWidth/2 实证),
  /// 无数据相。需取景开启(取景结束的机身拒 ChangeAfArea)。
  Future<void> changeAfArea(int x, int y) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeAfArea,
          params: [x, y],
        )));
    _ensureOk(result, NikonOperationCode.changeAfArea);
  }

  /// Nikon AfDrive(0x90C1,候选码,待真机核对):驱动自动对焦(一次
  /// 半按)。需取景开启(0xA00B notLiveView = 未开取景的应答形态);
  /// 未合焦回 0xA002 OutOfFocus,状态不允许回 0xA004。
  Future<void> afDrive() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.afDrive)));
    _ensureOk(result, NikonOperationCode.afDrive);
  }

  /// Nikon AfDriveCancel(0x9206,候选码,待真机核对):取消进行中的
  /// 自动对焦。注意:PtpSession 事务全局串行,afDrive 的响应未回前本
  /// 操作只能排队 —— 能否真的打断长对焦待真机核对,先入库备用。
  Future<void> afDriveCancel() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.afDriveCancel)));
    _ensureOk(result, NikonOperationCode.afDriveCancel);
  }

  /// Nikon DeviceReady(0x90C8):拍照后的忙等探针。
  /// **0x2019 DeviceBusy 是语义不是错误**(返回 false);其余响应码照常
  /// 抛 [PtpResponseException],链路级异常自然传播(调用方据此判死链)。
  Future<bool> deviceReady() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.deviceReady),
        ));
    if (result.responseCode == PtpResponseCode.deviceBusy) {
      return false;
    }
    _ensureOk(result, NikonOperationCode.deviceReady);
    return true;
  }

  void _ensureOk(PtpResult result, int opcode) {
    if (result.responseCode != PtpResponseCode.ok) {
      throw PtpResponseException(
        opcode: opcode,
        responseCode: result.responseCode,
        params: result.params,
      );
    }
  }
}

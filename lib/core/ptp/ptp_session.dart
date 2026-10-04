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

import 'dart:typed_data';

import '../ptpip/object_info.dart';
import '../utils/byte_reader.dart';
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

  PtpDeviceInfo? _deviceInfo;

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
  }

  /// CloseSession(幂等、尽力而为):相机已拔出时不因清理报错。
  /// 设备级断开由连接层调 transport.close()。
  Future<void> close() async {
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

  /// GetObjectInfo:ObjectInfo 数据集与 PTP-IP 同构,复用 ptpip 解析。
  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getObjectInfo,
          params: [handle],
        )));
    _ensureOk(result, PtpOperationCode.getObjectInfo);
    return PtpObjectInfo.parse(handle: handle, dataset: result.data!);
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

  /// 异步事件流透传(ObjectAdded / CaptureComplete…)。
  Stream<PtpEvent> get events => transport.events;

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

  /// SetDevicePropValue(0x1016)总开关。真机验证可写域之前恒为 false
  /// (0xD406「写过即回弹」的教训:未验证的写操作一律不落到相机),
  /// 翻开前 setDevicePropValue 直接抛 UnsupportedError。
  static const bool kSetPropEnabled = false;

  /// GetDevicePropValue(0x1015):当前值。响应是裸值数据集,解码类型
  /// 查标准表(见 [PtpDevicePropValue.parse]);方言偏离时改走
  /// [getDevicePropDesc] 拿自描述类型(待真机核对)。
  Future<PtpDevicePropValue> getDevicePropValue(int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getDevicePropValue,
          params: [propCode],
        )));
    _ensureOk(result, PtpOperationCode.getDevicePropValue);
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
  Future<void> setDevicePropValue(PtpDevicePropValue value) async {
    if (!kSetPropEnabled) {
      throw UnsupportedError(
          'SetDevicePropValue 未启用:待真机核对可写域后翻开 kSetPropEnabled');
    }
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.setDevicePropValue,
          params: [value.code],
          dataOut: value.encode(),
        )));
    _ensureOk(result, PtpOperationCode.setDevicePropValue);
  }

  /// Nikon StartLiveView(0x9201,候选码,待真机核对)。
  Future<void> startLiveView() async {
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

  /// InitiateCapture(0x100E 标准,params [0,0]):快门释放,落卡存储。
  /// 0x2019 DeviceBusy(半按对焦未就绪等)按异常上抛,上层提示重试。
  Future<void> initiateCapture() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(
              opcode: PtpOperationCode.initiateCapture, params: [0, 0]),
        ));
    _ensureOk(result, PtpOperationCode.initiateCapture);
  }

  /// Nikon InitiateCaptureRecInMedia(0x9207,候选码,待真机核对):落卡拍。
  Future<void> initiateCaptureRecInMedia() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.initiateCaptureRecInMedia),
        ));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInMedia);
  }

  /// Nikon InitiateCaptureRecInSdram(0x90C0,候选码,待真机核对):
  /// 无卡拍进机身缓存(速传场景的对象随后经 ObjectAddedInSdram 事件流出)。
  Future<void> initiateCaptureRecInSdram() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
        opcode: NikonOperationCode.initiateCaptureRecInSdram)));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInSdram);
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

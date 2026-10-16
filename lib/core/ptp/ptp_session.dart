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
      serialNumber: _normalizeSerial(r.ptpString()),
    );
  }

  /// 序列号方言归一(2026-10-09 真机定案):Zf 回定宽 32 位、左补零的
  /// 序列号(实测 '00000000000000000000000008014411' —— 尾段 8014411
  /// 与 mDNS 实例名 Z_f_8014411 同源);剥前导零,全零占位(剥后为空)
  /// 视为未提供 → null。注意:配对档案键由此换形(旧档案按补零串
  /// 落账的,重连一次即迁移)。
  static String? _normalizeSerial(String? raw) {
    final s = raw?.replaceFirst(RegExp('^0+'), '');
    return (s == null || s.isEmpty) ? null : s;
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

  /// 请求取消当前在途事务(PTP-IP Cancel-Drain)。
  ///
  /// **必须绕过 [_serialized]**:调用窗口正是互斥锁被在途事务持有的
  /// 时候,排队等锁 = 等在途事务自己完成,取消就失去意义(死等退化)。
  /// 链路不支持(USB / 路由器未挂内层 / 未连接)或无在途事务 → false,
  /// 无害 no-op;调用方继续走「置旗标、等当前事务自然完成」的优雅降级。
  ///
  /// 返回 true = Cancel 已发出,在途 execute 随后以
  /// [PtpCancelledException] 完成(排水收口由传输层 dispatcher 异步驱动,
  /// 本方法不等它)。取消通道自身异常同样按 false 落回旧路径。
  /// **2026-10-16 真机定案:Zf 收 Cancel 直接掐链 —— 生产已无调用方**
  /// (分块下载软取消替代,见 ObjectDownloader);方法留档备将来
  /// Cancel 友好的机身。
  Future<bool> cancelInFlight() async {
    // 能力探测必须用 if-case 模式绑定:is 检查对「与声明类型无关的
    // 接口」不做类型提升(Dart 流分析只向下提升),裸 is 后调用会编译错。
    if (transport case final PtpCancelCapable capable) {
      try {
        return await capable.cancelInFlight();
      } on Exception {
        return false; // 排水通道异常:不放大成取消失败,旧路径兜底
      }
    }
    return false;
  }

  /// 连接梯诊断(2026-10-07 iPhone-USB 回归定案用):enableAppControl
  /// 与 LiveViewEngine 0xA004 自愈把每步「op:结果」记入;取景失败时随
  /// lastError 一并浮出到拍摄页,真机一眼读出哪一级被拒。open() 清零
  /// (一连接一账)。
  final List<String> connectLadder = [];

  /// 记一笔连接梯诊断(见 [connectLadder])。
  void noteLadder(String step) => connectLadder.add(step);

  /// 连接梯诊断用的响应码短记(OK / 0xA004 形)。
  static String ladderRc(int rc) => rc == PtpResponseCode.ok
      ? 'OK'
      : '0x${rc.toRadixString(16).toUpperCase()}';

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

  /// 保护态乐观覆盖(会话内,句柄 → 是否保护):0x1012 SetObjectProtection
  /// 无读回应答,查看器以本会话发出/读回的写为准;挂在会话上 —— 页
  /// State 每次进页重建,页面级缓存重开即清空(2026-10-16 真机复报
  /// 「加锁后重进显示未锁」根因)。基线真值 = ObjectInfo 的
  /// ProtectionStatus(相册列表自带,重列即新);本 Map 只记会话内的
  /// 写入增量(含解锁,故是 Map 非 Set),读回成功也覆写于此。
  /// open() 清空(新链重列,真值回基线)。
  final Map<int, bool> protectionOptimistic = {};

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
    _largeThumbDegraded = false; // 新链新账:0x90C4 重新探测
    _objectPropListDegraded = false; // 新链新账:0x9805 重新探测
    protectionOptimistic.clear(); // 新链新账:保护态乐观值不跨连接
    connectLadder.clear(); // 一连接一账:新连接的梯从零记
  }

  /// CloseSession(幂等、尽力而为):相机已拔出时不因清理报错。
  /// 设备级断开由连接层调 transport.close()。
  Future<void> close() async {
    _remoteModeActive = false; // 链将亡:remote 持有态一律作废(含未开会话的旁路持有)
    _largeThumbDegraded = false; // 链将亡:0x90C4 降级态作废,新链重探
    _objectPropListDegraded = false; // 链将亡:0x9805 降级态作废,新链重探
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

  /// GetVendorStorageIDs(0x9209,§6.2.3.1):真卡 StorageID 列表。
  ///
  /// application 模式下标准 0x1004 恒回无卡幻影 ID(0x00010000/
  /// 0x00020000,与实际插卡无关 —— 官方明文;0x1005 对幻影 ID 回
  /// 0x2008),有效卡 ID 只能走本码;数据集与 0x1004 同构。
  Future<List<int>> getVendorStorageIds() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getVendorStorageIds),
        ));
    _ensureOk(result, NikonOperationCode.getVendorStorageIds);
    final data = result.data!;
    if (data.length % 4 != 0) {
      throw FormatException(
          'GetVendorStorageIDs 数据集 ${data.length}B 非 4 对齐');
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
    final data = result.data ?? Uint8List(0);
    // 找不到 SOI 原样返回(旧机身怪布局防御):交上层解码器报错占位。
    return _sniffJpegStart(data) ?? data;
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

  /// Nikon GetLargeThumb(0x90C4):高清缩略 JPEG(N-link 口径约 1024px,
  /// 单张数百 KB)。相机不支持时抛 [UnsupportedError](上层回落
  /// GetThumb)。
  /// [force] 跳过能力检查直发 —— **生产路径**(缩略图缓存取大图即
  /// force):无线 STA 的 operationsSupported 是假门(9 op 小表常态
  /// 人设,在册校验会拒掉 0x90C4,直发相机却正常回 JPEG —— 2026-10-01
  /// 真机诊断⑥实证;见 memory zf-wifi-mode-gate「勿按表拒连」)。
  ///
  /// 响应字节先做 JPEG SOI 嗅探:非 FFD8 开头时在前 512B 内剥头找
  /// SOI(防御「头 + JPEG」形态);整段无 SOI = 非 JPEG 载荷(如 Zf
  /// 对 NEF 回 320×212 压缩条带,TODO §同日续五定案)→ 视为不支持抛
  /// [UnsupportedError],垃圾字节不进 .jpg 缓存。
  ///
  /// 会话级降级([largeThumbDegraded]):真发一次失败(错误应答/非
  /// SOI/超时断链)即置位,本会话后续调用秒拒 [UnsupportedError] 不再
  /// 逐张浪费 RTT;[open()] 开新会话复位重探(同 [_remoteModeActive]
  /// 「新链新账」纪律)。码表不在册(假门)不置位 —— 真发证据才算数。
  Future<Uint8List> getLargeThumb(int handle, {bool force = false}) async {
    if (!force) {
      // 能力检查走缓存的 GetDeviceInfo(命中时无锁,不会与本方法的锁嵌套)。
      final info = await getDeviceInfo();
      if (!info.supportsOperation(NikonOperationCode.getLargeThumb)) {
        throw UnsupportedError('相机不支持 Nikon GetLargeThumb(0x90C4)');
      }
    }
    if (_largeThumbDegraded) {
      throw UnsupportedError('Nikon GetLargeThumb(0x90C4) 本会话已降级');
    }
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(
            PtpRequest(
                opcode: NikonOperationCode.getLargeThumb, params: [handle]),
          ));
      _ensureOk(result, NikonOperationCode.getLargeThumb);
    } on Exception {
      // 错误应答(PtpResponseException)/ 超时(USB 单事务
      // TimeoutException、PTP-IP 看门狗断链 PtpLinkException):一次
      // 失败即降级本会话;原异常上抛(诊断要真相),调用方回落 GetThumb。
      _largeThumbDegraded = true;
      rethrow;
    }
    final data = result.data ?? Uint8List(0);
    final jpeg = _sniffJpegStart(data);
    if (jpeg == null) {
      _largeThumbDegraded = true;
      throw UnsupportedError(
          'Nikon GetLargeThumb(0x90C4) 返回非 JPEG 数据(${data.length}B)');
    }
    return jpeg;
  }

  /// 0x90C4 会话级降级旗标:本会话内 GetLargeThumb 已被真发证实不可用
  /// (错误应答/非 SOI/超时),缩略管线据此直走 0x100A。[open()] /
  /// [close()] 复位 —— 新连接重新探测。
  bool _largeThumbDegraded = false;
  bool get largeThumbDegraded => _largeThumbDegraded;

  /// 0x9805 会话级降级旗标(语义同 [_largeThumbDegraded]):本会话内
  /// GetObjectPropList 已被真发证实不可用(错误应答/数据集不可信/链路
  /// 异常),仓库层据此直走逐对象 GetObjectInfo。[open()] / [close()]
  /// 复位 —— 新连接重新探测;码表不在册不置位(不做 supportsOperation
  /// 门禁,STA 9-op 小表假门,直发纪律同 0x90C4/0x920F)。
  bool _objectPropListDegraded = false;
  bool get objectPropListDegraded => _objectPropListDegraded;

  /// JPEG SOI(FFD8)嗅探:数据非 FFD8 开头时在前 512B 内找 SOI 并剥头
  /// (Nikon 0x90C4 数据布局真机验证中,防御性处理「头 + JPEG」形态);
  /// 找不到返回 null = 非 JPEG 载荷(0x90C4 对 NEF 回压缩条带的形态)。
  static Uint8List? _sniffJpegStart(Uint8List data) {
    if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xD8) {
      return data;
    }
    for (var i = 0; i + 1 < data.length && i < 512; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) {
        return Uint8List.sublistView(data, i);
      }
    }
    return null;
  }

  /// 事件流 = 异步通道(USB interrupt / PTP-IP 事件 socket)+ 轮询注入
  /// ([emitPolledEvents],[NikonEventPoller] 用)的并流。尼康机身的重要
  /// 事件(ObjectAdded/CaptureComplete/0x4006)可能只走 GetEventEx
  /// 0x941C 轮询通道(OpenZCine/libgphoto2 实测口径),两路并存、
  /// 消费端幂等。
  late final Stream<PtpEvent> _events =
      _mergedStreams([transport.events, _eventInjections.stream]);
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
          subs.add(s.listen(ctrl.add, onError: ctrl.addError, onDone: () {
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
      events
          .add(PtpEvent(code: code, transactionId: 0xFFFFFFFF, params: params));
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
      result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getPtpIpPairingCode)));
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
  /// 数据集自描述类型,是裸值解码的对照组。扩展属性码(> 0xFFFF)自动
  /// 改走 Gen-3 Ex desc(0x943A,同 [getDevicePropValue] 路由口径;
  /// 2026-10-12 USB 探针实证:0x0001D001 色调/0x0001D005-06 主体检测
  /// 全应答,FORM 布局与标准 desc 同构 —— 色调/主体检测从此吃相机
  /// FORM 而非 pickValues 直供)。
  Future<PtpDevicePropDesc> getDevicePropDesc(int propCode) async {
    final op = propCode > 0xFFFF
        ? NikonOperationCode.getDevicePropDescEx
        : PtpOperationCode.getDevicePropDesc;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [propCode],
        )));
    _ensureOk(result, op);
    return PtpDevicePropDesc.parse(result.data ?? Uint8List(0),
        expectedCode: propCode);
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

  /// SetObjectProtection(0x1012,官方 §6.2.1.14):对象保护标记。
  /// 参数 [句柄, 0x0000 不保护 / 0x0001 只读]。目录(Association)/
  /// SDRAM 对象会被拒(Invalid_Object_Handle),卡写保护回 Store_Read_Only。
  Future<void> setObjectProtection(int objectHandle,
      {required bool protect}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.setObjectProtection,
          params: [objectHandle, protect ? 0x0001 : 0x0000],
        )));
    _ensureOk(result, PtpOperationCode.setObjectProtection);
  }

  /// GetVendorCodes(0x9439,官方 §6.2.2.1):查询相机支持的厂商码全表
  /// —— [deviceProps] = false 拿厂商操作码表(param 0x09),true 拿厂商
  /// 属性码表(param 0x0D)。应答 = u32 元素数 + N×u32 码(4 字节扩展码
  /// 全量,含 0x0001_xxxx 形态)。**这是自录厂商码表的正规通道**,免
  /// 逐码盲试;不在表内的码不代表不应答(STA 9-op 小表同理)。
  Future<List<int>> getVendorCodes({required bool deviceProps}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getVendorCodes,
          params: [deviceProps ? 0x0D : 0x09],
        )));
    _ensureOk(result, NikonOperationCode.getVendorCodes);
    final data = result.data;
    if (data == null || data.length < 4) return const [];
    final bd = ByteData.sublistView(data);
    final count = bd.getUint32(0, Endian.little);
    final codes = <int>[];
    for (var i = 0; i < count && 4 + i * 4 + 4 <= data.length; i++) {
      codes.add(bd.getUint32(4 + i * 4, Endian.little));
    }
    return codes;
  }

  /// 4 字节扩展操作码包装(官方 §6.2.2.2-4):以 0x9440/0x9441/0x9442
  /// 执行 0x0001_xxxx 形态的命令 —— P1 = 扩展码,P2-5 透传命令参数
  /// (至多 4 个;带数据相的命令不能走 [extendedOperationNone])。
  /// 现有 Ex 属性 ops(0x943A-C)之外的第二条官方扩展通道。
  Future<PtpResult> extendedOperationNone(int extOp,
      {List<int> params = const []}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationDataNone,
          params: [extOp, ...params],
        )));
    _ensureOk(result, NikonOperationCode.operationDataNone);
    return result;
  }

  /// 4 字节扩展操作的读数据相版(0x9441,应答数据在 result.data)。
  Future<PtpResult> extendedOperationReceive(int extOp,
      {List<int> params = const []}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationReceiveData,
          params: [extOp, ...params],
        )));
    _ensureOk(result, NikonOperationCode.operationReceiveData);
    return result;
  }

  /// 4 字节扩展操作的写数据相版(0x9442,dataOut 发给相机)。
  Future<PtpResult> extendedOperationSend(int extOp,
      {List<int> params = const [], Uint8List? data}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationSendData,
          params: [extOp, ...params],
          dataOut: data ?? Uint8List(0),
        )));
    _ensureOk(result, NikonOperationCode.operationSendData);
    return result;
  }

  /// Nikon GetPictCtrlData(0x90CC):读优化校准(0xD200)槽位详情里的
  /// 注册名。params = [槽位号(即 0xD200 的值), 0];数据集布局按
  /// digiCamControl NikonBase.GetPictureControl 实证 —— [3..22] 是
  /// 20 字节 ASCII 名(NUL 截断,[0..2] 为未知/单色/自定义标志)。
  /// 用于自定义(201-209)/云下载(301-309)槽位的真名显示(静态表只有
  /// 「自定义 N」「云 N」占位);数据不足 23 字节或名字空白返回 null,
  /// 上层回落静态标签。Zf 待真机核对。
  Future<String?> getPictureControlName(int slot) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getPictCtrlData,
          params: [slot, 0],
        )));
    _ensureOk(result, NikonOperationCode.getPictCtrlData);
    final data = result.data;
    if (data == null || data.length < 23) return null;
    final nameCodes = <int>[];
    for (var i = 3; i < 23; i++) {
      final b = data[i];
      if (b == 0) break;
      if (b >= 0x20 && b < 0x7F) nameCodes.add(b);
    }
    final name = String.fromCharCodes(nameCodes).trim();
    return name.isEmpty ? null : name;
  }

  /// 连接后切「应用模式」(Z 系真机口径,OpenZCine 实测:不切则相机对
  /// 遥控写回 0x200F AccessDenied)。链路对齐 OpenZCine 连接脚本:
  /// ① 0x9435 ChangeApplicationMode p1=1(无线/二代+直通);②
  /// [remoteLatch](连接流两路同款,USB/无线)→ **0x90C2 ChangeCameraMode(1)
  /// 进 remote 模式**。2026-10-07 归因梯(macOS-IC 真机,即 iPhone 代理
  /// 链)定案:0x9435 在 IC 人设下**回 OK 但是假钥匙** —— 0x9201 仍被
  /// 0xA004 拒;唯一实证解锁 = 0x90C2(1)(接受即 0x9201 通、取到 84KB
  /// 帧;机身 remote + 取景运行 = 及时取景)。**无线/AP 同病(2026-10-15
  /// 真机)**:AP 进拍摄取景/对焦全坏 —— 0x9435 在无线上同样回 OK 假
  /// 钥匙,旧无线流只发 0x9435 即返回,0x90C2 全程没拉过;故连接流
  /// **无论传输介质、无论 0x9435 成败都直取 remote 模式**(OpenZCine
  /// 「0x9435 失败才兜底 0x90C2」的分支在人设下永远走不到);0x90C2
  /// 未成而 0x9435 已 OK 仍按旧语义算成;③ 双双未成 → 回退写
  /// ApplicationMode 属性 0xD1F0=1(u8,一代 op 缺席口径)。remote 的
  /// 镜像收尾在连接层(CloseSession 前 0x90C2(0)):不退则机身停
  /// 「已连接到计算机」屏(2026-10-07 真机:remote 态跨拔插保持,半按
  /// 快门才退)。
  /// **不写 0xD406 initiator 身份**:OpenZCine 全程不写,而身份写会让
  /// 机身把主机按新身份归类(op 表 119→124 变化)—— 2026-10-07 真机
  /// 复报:写身份 + remote 模式 = 机身停「已连接到计算机」屏不进取景;
  /// 不写 + remote 模式 + 连接即开取景(HomeShell autoLiveViewOnConnect)
  /// = 及时取景。usbfs 主机实证过的身份写只保留在 LiveViewEngine 的
  /// 0xA004 自愈末级(见 [writeInitiatorIdentity])。
  /// **不走 [kSetPropEnabled] 门禁** —— 它是连接模式控制而非拍摄参数
  /// 写,且发生在任何参数面板之前;连双失败也只返回 false 不抛(尽力
  /// 而为,拍照/读参数不依赖它,真机核对)。
  Future<bool> enableAppControl({bool remoteLatch = false}) async {
    var rc = PtpResponseCode.operationNotSupported;
    try {
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.changeApplicationMode,
            params: [1],
          )));
      rc = result.responseCode;
      noteLadder('9435:${ladderRc(rc)}');
    } on Object {
      // op 缺席/链路类(含脚本耗尽类 StateError):走回退。
      // 尽力而为步骤,on Object 兜底 —— 它失败不得影响连接主流程。
      noteLadder('9435:ERR');
    }
    if (rc == PtpResponseCode.ok && !remoteLatch) return true;
    if (remoteLatch) {
      // 2026-10-07 归因梯定案(macOS-IC 真机):0x9435 在 IC 人设下回
      // OK 但是假钥匙(0x9201 仍 0xA004),唯一实证解锁 = 0x90C2(1)。
      // 2026-10-15 真机:无线/AP 同病(0x9435 同样 OK 假钥匙)。故连接
      // 流无论介质、无论 0x9435 成败都直取 remote 模式。
      try {
        await changeCameraMode(1);
        noteLadder('90C2:OK');
        // 开闩即还身(2026-10-07 v8/v9 定案):上传优先门是**单向闩**
        // —— 0x90C2(1) 打开后不因 0x90C2(0) 而关(v9 ⑧→⑨→⑩:背靠背
        // 1→0 后 0x9201 照通、帧照流);而 remote **持有态**才是机身停
        // 「已连接到计算机」屏的元凶(拨盘锁定,取景运行也不翻屏)。
        // 1→0 背靠背 = 已连接屏只闪一次往返,机身直回自己的取景屏。
        // 退失败不影响流(仅屏显停留已连接),由 teardown 兜底。
        try {
          await changeCameraMode(0);
          noteLadder('90C2退:OK');
        } on Object {
          noteLadder('90C2退:拒');
        }
        return true;
      } on PtpResponseException catch (e) {
        noteLadder('90C2:${ladderRc(e.responseCode)}');
      } on Object {
        // 0x90C2 也被拒/链路类:落到 0xD1F0。
        noteLadder('90C2:ERR');
      }
    }
    if (rc == PtpResponseCode.ok) return true; // remote 未成但应用模式已接受
    try {
      final w = ByteWriter()..u8(1);
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: PtpOperationCode.setDevicePropValue,
            params: [PtpDevicePropCode.applicationMode],
            dataOut: w.takeBytes(),
          )));
      noteLadder('D1F0:${ladderRc(result.responseCode)}');
      return result.responseCode == PtpResponseCode.ok;
    } on Object {
      noteLadder('D1F0:ERR');
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
  /// 机身拨盘锁定,host 写入的会话值仅在持有期保值)。2026-10-07 真机
  /// 定案:USB 上传优先门(0x9201 → 0xA004)的唯一实证钥匙(0x9435
  /// 是假钥匙);remote + 0x9201 取景运行 = 机身及时取景,remote 持有
  /// 而取景停 = 机身停「已连接到计算机」屏(跨拔插保持,0x90C2(0)
  /// 或半按快门才退)。0 = 解除。
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
    final data = result.data ?? Uint8List(0);
    return _sniffJpegStart(data) ?? data;
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
      if (y == null ||
          mo == null ||
          d == null ||
          h == null ||
          mi == null ||
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
  Future<void> syncCameraClock(
      {DateTime? now, Duration threshold = const Duration(seconds: 5)}) async {
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

  /// Nikon InitiateCaptureRecInSdram(0x90C0):SDRAM 拍摄(无卡拍进
  /// 机身缓存,速传场景的对象随后经 ObjectAddedInSdram 事件流出)。
  /// **必须有 CaptureSort 参数**(2026-10-13 USB 探针:无参 0x2006、
  /// [0,0] 0x201D、0xFFFFFFFF 直释放 0x2001 —— 官方 §6.2.4.2
  /// P1=CaptureSort 同 0x9207;[0,0] 是两码共用的坑)。
  /// [captureSort] 缺省 0xFFFFFFFF。
  Future<void> initiateCaptureRecInSdram({int captureSort = 0xFFFFFFFF}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
        opcode: NikonOperationCode.initiateCaptureRecInSdram,
        params: [captureSort])));
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
    final result = await _serialized(() => transport
        .execute(const PtpRequest(opcode: NikonOperationCode.afDrive)));
    _ensureOk(result, NikonOperationCode.afDrive);
  }

  /// Nikon AfDriveCancel(0x9206,候选码,待真机核对):取消进行中的
  /// 自动对焦。注意:PtpSession 事务全局串行,afDrive 的响应未回前本
  /// 操作只能排队 —— 能否真的打断长对焦待真机核对,先入库备用。
  Future<void> afDriveCancel() async {
    final result = await _serialized(() => transport
        .execute(const PtpRequest(opcode: NikonOperationCode.afDriveCancel)));
    _ensureOk(result, NikonOperationCode.afDriveCancel);
  }

  /// Nikon DeviceReady(0x90C8):拍照后的忙等探针。
  /// **忙等码是语义不是错误**(返回 false):0x2019 DeviceBusy(标准);
  /// 0xA200 Bulb_Release_Busy / 0xA201 Silent_Release_Busy(官方
  /// §6.3.2.15/16 定名;§2.8.4 B 门序列步 5 实证 —— B 门曝光进行中
  /// DeviceReady 即回 0xA200,收门/落定等待据此继续等,2026-10-15)。
  /// 其余响应码照常抛 [PtpResponseException],链路级异常自然传播
  /// (调用方据此判死链)。
  Future<bool> deviceReady() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.deviceReady),
        ));
    final rc = result.responseCode;
    if (rc == PtpResponseCode.deviceBusy ||
        rc == NikonResponseCode.bulbReleaseBusy ||
        rc == NikonResponseCode.silentReleaseBusy) {
      return false;
    }
    _ensureOk(result, NikonOperationCode.deviceReady);
    return true;
  }

  // ── 官方指令书候选区接线(2026-10-13 USB 探针批 + §6.2 规格比对)──

  /// GetFhdPicture(0x920F):对象的 FHD 尺寸 JPEG(探针实录 744KB)。
  /// 无 FHD 可取回 0xA00F NoFullHDPresent(由 [_ensureOk] 抛,调用方
  /// 回落 GetThumb)。NEF 预览快路:744KB 对比整档 NEF 数十 MB。
  Future<Uint8List> getFhdPicture(int handle) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(
              opcode: NikonOperationCode.getFhdPicture, params: [handle]),
        ));
    _ensureOk(result, NikonOperationCode.getFhdPicture);
    final data = result.data ?? Uint8List(0);
    // 与 GetThumb 同款宽收:无 SOI 原样返回,交上层解码器报错占位。
    return _sniffJpegStart(data) ?? data;
  }

  /// ChangeAELock(0x9426,官方 §6.2.4.5):AE/AWB 锁开关。
  /// [lock] P1 LockValue(0 释放/1 锁 hold);[type] P2 LockType
  /// (0=AE/1=AWB/2=AE+AWB,2026-10-13 规格书坐标重排定案;探针
  /// (1,2) 锁/(0,2) 解锁双 OK)。**应答 OK ≠ 生效**(官方明说):调用方
  /// 事后读 AELockStatus 0xD105 / AWBLockStatus 0xD12F 确认。WB 非
  /// auto 时 AWB 锁被拒 0x200F、AE+AWB 只生效 AE(官方 Response 表)。
  Future<void> changeAELock({required bool lock, int type = 2}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeAELock,
          params: [lock ? 1 : 0, type],
        )));
    _ensureOk(result, NikonOperationCode.changeAELock);
  }

  /// StartTracking(0x9424,官方 §6.2.6.7):开始主体追踪 / 更新追踪目标。
  /// 参数同 ChangeAfArea(0x9205):whole-size 坐标系 x/y。门控在官方
  /// Access_Denied 条文:照片档 0xD05D 须自动区/追踪档(拒 0x200F),
  /// 无取景 0xA00B;坐标处有识别目标则更新选中并进待命,没有则以该
  /// 坐标起追。追踪态跟 LiveViewObject 帧头(§2.9),不设独立读回。
  Future<void> startTracking(int x, int y) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.startTracking,
          params: [x, y],
        )));
    _ensureOk(result, NikonOperationCode.startTracking);
  }

  /// EndTracking(0x9425):结束主体追踪(无参)。
  Future<void> endTracking() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.endTracking),
        ));
    _ensureOk(result, NikonOperationCode.endTracking);
  }

  /// ClearEvent(0x9461,探针 2026-10-13 OK):清相机事件队列 ——
  /// 重连沿清上一会话残留,防旧事件误触发即拍即览等消费端。
  Future<void> clearEvent() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.clearEvent),
        ));
    _ensureOk(result, NikonOperationCode.clearEvent);
  }

  /// AfAndCaptureRecInSdram(0x90CB,官方 §6.2.4.3 无参):AF 驱动后
  /// 拍摄入 SDRAM(= 0x9207 [0xFFFFFFFE, 0x0001] 的固定形,探针无参
  /// OK)。对象随后按 §2.8.2 流出:ObjectAddedInSdram 0xC101(逐张带
  /// 句柄)→ GetObjectInfo → GetObject/GetPartialObject → 全部取完
  /// 收 CaptureCompleteRecInSdram 0xC102。
  Future<void> afAndCaptureRecInSdram() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.afAndCaptureRecInSdram),
        ));
    _ensureOk(result, NikonOperationCode.afAndCaptureRecInSdram);
  }

  /// ChangeMonitorOff(0x9422,官方 §6.2.2.17):主监听器(机背屏)
  /// 强制关/取消。P1 0 取消强制关闭 / 1 强制关闭。**应答 OK 只代表
  /// 「请求已收到」,完成不保证**;状态读回 MonitorOffStatus 0xD1BA
  /// (u8 只读 0/1)。电池耗尽拒 0x200F、拍摄中拒 0x2019。
  Future<void> changeMonitorOff({required bool off}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeMonitorOff,
          params: [off ? 1 : 0],
        )));
    _ensureOk(result, NikonOperationCode.changeMonitorOff);
  }

  /// SaveCameraSetting(0x9420,官方 §6.2.2.18):设置落非易失区(与
  /// 关机时落盘同动作)。**响应后除 CloseSession 外禁发任何命令**
  /// (官方 Command Outline)—— 调用方须自行遵守,故不接 UI。
  Future<void> saveCameraSetting() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.saveCameraSetting),
        ));
    _ensureOk(result, NikonOperationCode.saveCameraSetting);
  }

  /// GetCameraSettingData(0x946D,官方 §6.2.2.19):读卡 1 上的相机
  /// 设定文件(机身菜单「保存/载入设定」产物)。数据集 = 64B ASCII
  /// 文件名(63 字符 + NUL)+ 文件体;无卡/卡初始化中 Store_Not_Available。
  Future<({String name, Uint8List data})> getCameraSettingData() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getCameraSettingData),
        ));
    _ensureOk(result, NikonOperationCode.getCameraSettingData);
    final data = result.data ?? Uint8List(0);
    var name = '';
    if (data.length >= 64) {
      final end = data.indexWhere((b) => b == 0, 0);
      name =
          String.fromCharCodes(data.sublist(0, end < 0 || end > 63 ? 63 : end));
      return (name: name, data: Uint8List.sublistView(data, 64));
    }
    return (name: name, data: data);
  }

  /// SendCameraSettingData(0x946E,官方 §6.2.2.20):把设定文件写回
  /// 卡 1。**只写卡,不应用到相机**(应用须机身菜单载入)—— 与快照
  /// 逐属性恢复(直接写属性)语义不同,调用方提示语须如实区分。
  Future<void> sendCameraSettingData(String name, Uint8List data) async {
    final bytes = ByteWriter();
    final nameBytes = name.length > 63 ? name.substring(0, 63) : name;
    for (var i = 0; i < 64; i++) {
      bytes.u8(i < nameBytes.length ? nameBytes.codeUnitAt(i) : 0);
    }
    bytes.raw(data);
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.sendCameraSettingData,
          dataOut: bytes.takeBytes(),
        )));
    _ensureOk(result, NikonOperationCode.sendCameraSettingData);
  }

  /// GetObjectPropsSupported(0x9801,官方 §6.2.11.1):相机支持的对象
  /// 属性码表(u32 计数 + N×u16)。
  Future<List<int>> getObjectPropsSupported() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getObjectPropsSupported),
        ));
    _ensureOk(result, NikonOperationCode.getObjectPropsSupported);
    return _parseU16Array(result.data);
  }

  /// GetObjectPropDesc(0x9802,官方 §6.2.11.2):对象属性描述(类型/
  /// 可写性/FORM)。数据集随类型变宽(u16 类型 + u8 GetSet + FORM),
  /// 本轮无消费方,先裸透传,接线时按属性定宽解。
  Future<Uint8List> getObjectPropDesc(int handle, int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getObjectPropDesc,
          params: [handle, propCode],
        )));
    _ensureOk(result, NikonOperationCode.getObjectPropDesc);
    return result.data ?? Uint8List(0);
  }

  /// GetObjectPropValue(0x9803,官方 §6.2.11.3):读对象属性裸值。
  /// 类型自描述不在值内(见 0x9802 Desc),调用方按已知属性定宽解
  /// (如 ProtectionStatus 0x0004 = u16)。
  Future<Uint8List> getObjectPropValue(int handle, int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getObjectPropValue,
          params: [handle, propCode],
        )));
    _ensureOk(result, NikonOperationCode.getObjectPropValue);
    return result.data ?? Uint8List(0);
  }

  /// SetObjectPropValue(0x9804,官方 §6.2.11.4):写对象属性裸值。
  Future<void> setObjectPropValue(
      int handle, int propCode, Uint8List value) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.setObjectPropValue,
          params: [handle, propCode],
          dataOut: value,
        )));
    _ensureOk(result, NikonOperationCode.setObjectPropValue);
  }

  /// GetObjectPropList(0x9805,官方 §6.2.11.5):对象属性批量读 ——
  /// 一把拿多对象多属性(首屏枚举 1×RTT 替代 N×GetObjectInfo)。
  ///
  /// 参数(官方 §6.2.11.5 Operation Parameter 表,按位序不可跳档):
  /// [handle] P1 ObjectHandle:具体句柄 / 0x00000000 根层直下 /
  /// 0xFFFFFFFF 全部对象;[formatCode] P2 [ObjectFormatCode]:
  /// 0x00000000 = 全部格式;[propCode] P3 ObjectPropCode:具体属性码 /
  /// 0x00000000(按 [groupCode] 组,Zf §6.6 信息组 = 0x00000001)/
  /// 0xFFFFFFFF 全部属性;[groupCode] P4 [ObjectPropGroupCode](仅 P3=
  /// 0x00000000 时生效;给了 [depth] 而未给组码时补 0x00000000 占位);
  /// [depth] P5 [Depth]:null = 省略(仅 P1 指定对象)/ 0x00000000
  /// 指定深度 / 0xFFFFFFFF 整个层级。首屏全量五参形
  /// [0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF] = n-link 生产同款。
  ///
  /// 数据集(官方 §6.2.11.5 数据集表)= u32 NumberOfElements +
  /// N×(u32 ObjectHandle + u16 PropertyCode + u16 Datatype + DTS 值),
  /// **无 GetSet 字节**(那是 0x9802 ObjectPropDesc 的布局;n-link 的
  /// 「无计数前缀连续流」口径与官方表相左,以官方为准 —— 若真机应答
  /// 果真无计数,首 u32 会被当元素数解析,几乎必然解析弃/降级,安全
  /// 回退逐对象,不产脏数据)。
  ///
  /// 会话级降级([objectPropListDegraded]):真发失败(错误应答/解析
  /// 弃/链路异常)即置位,本会话后续调用秒拒 [UnsupportedError] 不再
  /// 逐枚举浪费 RTT;[open()] 开新会话复位重探(同
  /// [_largeThumbDegraded] 纪律)。不做能力表门禁直发(在册假门)。
  Future<List<PtpObjectProp>> getObjectPropList(
    int handle, {
    int formatCode = 0x00000000,
    int propCode = 0xFFFFFFFF,
    int? groupCode,
    int? depth,
  }) async {
    if (_objectPropListDegraded) {
      throw UnsupportedError('GetObjectPropList(0x9805) 本会话已降级');
    }
    // P4/P5 按位序不可跳:给了任一可选后段参数,P4 组码缺席补 0。
    final params = [handle, formatCode, propCode];
    if (groupCode != null || depth != null) {
      params.add(groupCode ?? 0x00000000);
    }
    if (depth != null) params.add(depth);
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.getObjectPropList,
            params: params,
          )));
      _ensureOk(result, NikonOperationCode.getObjectPropList);
    } on Exception {
      // 错误应答(op 不在册/参数拒)或链路异常:真发证据,一次失败即
      // 降级本会话;原异常上抛(诊断要真相),调用方回退逐对象路径。
      _objectPropListDegraded = true;
      rethrow;
    }
    try {
      return _parseObjectPropList(result.data);
    } on FormatException {
      _objectPropListDegraded = true; // 数据集不可信:整体弃,不产脏数据
      rethrow;
    } on ArgumentError {
      // ByteReader 越界(RangeError 族)= 截断数据集,与格式弃同判。
      _objectPropListDegraded = true;
      throw const FormatException('GetObjectPropList(0x9805) 数据集截断越界');
    }
  }

  /// 0x9805 ObjectPropList 数据集解析(官方 §6.2.11.5 数据集表):
  /// u32 计数 + N×(u32 句柄 + u16 属性码 + u16 类型 + DTS 值)。
  ///
  /// 防错位三闸(n-link 纪律):①计数与字节流互相印证 —— 提前耗尽或
  /// 解完仍有尾巴都判不可信;②值类型按 [_readObjectPropValue] 定宽读,
  /// 表外未知类型整体抛 [FormatException];③ByteReader 越界(截断)归
  /// 一为 [FormatException]。任一触发 = 本会话降级,回退逐对象。
  static List<PtpObjectProp> _parseObjectPropList(Uint8List? data) {
    // OK 应答零数据/不足计数头:按「空属性表」读(单对象查询的合法形;
    // 全量场景下空表由仓库层按缺口回退补齐,不判失败)。
    if (data == null || data.length < 4) return const [];
    final r = ByteReader(data);
    final count = r.u32();
    final props = <PtpObjectProp>[];
    for (var i = 0; i < count; i++) {
      if (r.remaining < 8) {
        throw FormatException(
            'GetObjectPropList(0x9805) 数据集在第 $i/$count 条提前耗尽');
      }
      final objectHandle = r.u32();
      final code = r.u16();
      final type = r.u16();
      final valueStart = r.offset;
      final value = _readObjectPropValue(r, type);
      props.add(PtpObjectProp(
        handle: objectHandle,
        code: code,
        dataType: type,
        rawValue: Uint8List.sublistView(data, valueStart, r.offset),
        value: value,
      ));
    }
    if (!r.eof) {
      throw FormatException(
          'GetObjectPropList(0x9805) 数据集解完计数 $count 后仍剩 ${r.remaining}B');
    }
    return props;
  }

  /// 0x9805 条目值读取:标准标量直解;**已知宽度的扩展形态**(INT128/
  /// UINT128 0x0009/0x000A —— Zf §6.6.1.13 PersistentUID 在列;数组型
  /// 0x4001-0x4008 u32 元素数 + 元素×N —— §6.6.1.16
  /// RepresentativeSampleData 在列)按宽度跳过不弃解析(值置 null,
  /// rawValue 留档,宽度已知不会错位);**表外未知类型整体抛
  /// [FormatException]**(宁弃不猜,n-link 纪律)。
  static Object? _readObjectPropValue(ByteReader r, int typeCode) {
    switch (typeCode) {
      case 0x0001: // INT8
        _needPropBytes(r, 1);
        return r.u8().toSigned(8);
      case 0x0002: // UINT8
        _needPropBytes(r, 1);
        return r.u8();
      case 0x0003: // INT16
        _needPropBytes(r, 2);
        return r.u16().toSigned(16);
      case 0x0004: // UINT16
        _needPropBytes(r, 2);
        return r.u16();
      case 0x0005: // INT32
        _needPropBytes(r, 4);
        return r.u32().toSigned(32);
      case 0x0006: // UINT32
        _needPropBytes(r, 4);
        return r.u32();
      case 0x0007: // INT64
        _needPropBytes(r, 8);
        return r.u64().toSigned(64);
      case 0x0008: // UINT64
        _needPropBytes(r, 8);
        return r.u64();
      case 0x0009: // INT128:16B 已知宽,Dart int 放不下,跳过不解值
      case 0x000A: // UINT128(§6.6.1.13 PersistentUID)
        _needPropBytes(r, 16);
        r.raw(16);
        return null;
      case 0x4001: // AINT8 ─ 数组:u32 元素数 + 元素×宽
      case 0x4002: // AUINT8(§6.6.1.16 RepresentativeSampleData)
      case 0x4003: // AINT16
      case 0x4004: // AUINT16
      case 0x4005: // AINT32
      case 0x4006: // AUINT32
      case 0x4007: // AINT64
      case 0x4008: // AUINT64
        _needPropBytes(r, 4);
        final n = r.u32();
        final width = switch (typeCode) {
          0x4001 || 0x4002 => 1,
          0x4003 || 0x4004 => 2,
          0x4005 || 0x4006 => 4,
          _ => 8,
        };
        if (n > r.remaining ~/ width) {
          throw FormatException(
              'GetObjectPropList(0x9805) 数组元素数 $n 超出剩余 ${r.remaining}B');
        }
        r.raw(n * width);
        return null;
      case 0xFFFF: // STR:u8 字符数 + UTF-16LE(0xFF = 未提供)
        _needPropBytes(r, 1);
        final n = r.bytes[r.offset];
        if (n != 0xFF) _needPropBytes(r, 1 + 2 * n);
        return r.ptpString();
      default:
        throw FormatException(
            'GetObjectPropList(0x9805) 未知数据集类型 0x${typeCode.toRadixString(16)}(防错位整体弃)');
    }
  }

  /// 0x9805 值读取的剩余字节预检(不足 = 截断数据集)。
  static void _needPropBytes(ByteReader r, int n) {
    if (r.remaining < n) {
      throw FormatException(
          'GetObjectPropList(0x9805) 值字节不足(需 $n 剩 ${r.remaining}B)');
    }
  }

  /// u32 计数 + N×u16 数组解析(0x9801)。
  static List<int> _parseU16Array(Uint8List? data) {
    if (data == null || data.length < 4) return const [];
    final reader = ByteReader(data);
    final count = reader.u32();
    final out = <int>[];
    for (var i = 0; i < count && !reader.eof; i++) {
      out.add(reader.u16());
    }
    return out;
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

/// 0x9805 GetObjectPropList 数据集元素(官方 §6.2.11.5)。
final class PtpObjectProp {
  const PtpObjectProp({
    required this.handle,
    required this.code,
    required this.dataType,
    required this.rawValue,
    this.value,
  });

  final int handle;
  final int code;
  final int dataType;

  /// 值字节(未解出类型时的兜底)。
  final Uint8List rawValue;

  /// 按 DTS 类型解出的值(string 可能 null)。
  final Object? value;
}

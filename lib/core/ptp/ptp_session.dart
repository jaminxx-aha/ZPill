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
import '../log/app_log.dart';
import '../ptpip/object_info.dart';
import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'device_prop.dart';
import 'operation_codes.dart';
import 'ptp_transport.dart';

// 会话门面按域拆文件(mixin 同库,私有成员互通):
// core = 串行锁/生命周期/事件/配对;browse = 枚举与对象属性;
// remote = 取景/拍摄/曝光/对焦等生产线操作。
part 'ptp_session_browse.dart';
part 'ptp_session_core.dart';
part 'ptp_session_remote.dart';

/// 相机返回非 OK 响应码时抛出;上层(UI/连接层)以此提示用户。

/// 会话内部按域三分的 mixin(同库私有):[_SessionCore] 持串行锁/会话
/// 生命周期/事件流/配对与全局状态字段(跨域复位沿在 open/close,字段
/// 必须同处),[_BrowseOps] 浏览下载域,[_RemoteOps] 遥控域;门面
/// [PtpSession] 按序 mix,公开 API 与静态成员位置不变(静态不随 mixin
/// 继承,kSetPropEnabled/ladderRc 留在门面)。域内方法与原实现逐行一致。

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

/// 连接握手(GetDeviceInfo / OpenSession)的短超时。
///
/// 运行时事务用传输层缺省窗(USB 15s:相机写卡/清缓存可能慢),但连接
/// 握手不需要等满 15s。**10s** 是按真机标定的:ohos 立刻断开重连时
/// 相机对首笔 GetDeviceInfo 实测 ~6s 才回(上一条事务收尾),5s 会误判
/// 成楔死并触发复位;10s 留出余量,健康链路握手仍是亚秒级。真楔死
/// (10s 仍无响应)才交给连接层走 USB 端口复位两段式重连。
const Duration kConnectHandshakeTimeout = Duration(seconds: 10);

/// 连接首笔 GetDeviceInfo 的短探针。
///
/// teardown 有意不送 CloseSession(避免挂满串行门),相机侧旧会话仍开着;
/// 此时相机对 GetDeviceInfo 可能沉默。先用 2s 探针,沉默即走
/// OpenSession 的 0x201E 自愈(Close+Open)再取 —— 不能在这里等 10s
/// 然后复位 USB(2026-11-04 ohos「断开后首连必败」根因)。
const Duration kConnectProbeTimeout = Duration(seconds: 2);

/// 数据集数组元素上限。正常相机全卡对象数远低于 100 万;超过即按
/// 畸形响应拒绝,防止 count 字段驱动超大 List 分配。
const int _kMaxPtpArrayElements = 1 << 20;

Uint8List _requireData(PtpResult result, String opName) {
  final data = result.data;
  if (data == null) {
    throw FormatException('$opName 应答 OK 但缺少数据相');
  }
  return data;
}

List<int> _readU32Array(Uint8List data, String opName) {
  if (data.length < 4 || data.length % 4 != 0) {
    throw FormatException('$opName 数据集 ${data.length}B 非 u32 数组');
  }
  final r = ByteReader(data);
  final count = r.u32();
  if (count > _kMaxPtpArrayElements || count > r.remaining ~/ 4) {
    throw FormatException(
        '$opName 计数 $count 超出剩余 ${r.remaining ~/ 4} 项或上限 '
        '$_kMaxPtpArrayElements');
  }
  return [for (var i = 0; i < count; i++) r.u32()];
}

/// GetDeviceInfo(0x1001)数据集 —— 最小解析(仅浏览/连接所需字段,
/// 数组完整收录:后续能力检查如 GetPartialObjectEx 在册与否要用)。
///
/// 布局按 ISO 15740 §9,经 Zf 真机 probe 校验(probe.py dump_device_info
/// 同一解析):standardVersion u16 / vendorExtensionId u32 /
/// vendorExtensionVersion u16 / desc STRING / functionalMode u16,
/// 随后 5 组「u32 计数 + N 个 u16」(操作/事件/属性/捕获格式/图像格式),

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
    if (n > _kMaxPtpArrayElements || n > r.remaining ~/ 2) {
      throw FormatException(
          'DeviceInfo 数组计数 $n 超出剩余 ${r.remaining ~/ 2} 项或上限 '
          '$_kMaxPtpArrayElements');
    }
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

/// JPEG SOI(FFD8)嗅探:数据非 FFD8 开头时在前 512B 内找 SOI 并剥头
/// (Nikon 0x90C4 数据布局真机验证中,防御性处理「头 + JPEG」形态);
/// 找不到返回 null = 非 JPEG 载荷(0x90C4 对 NEF 回压缩条带的形态)。
/// 连接梯诊断用的响应码短记(OK / 0xA004 形);域内 mixin 用,
/// 门面静态 [PtpSession.ladderRc] 委托于此(静态不随 mixin 继承)。
String _ladderRc(int rc) => rc == PtpResponseCode.ok
    ? 'OK'
    : '0x${rc.toRadixString(16).toUpperCase()}';

Uint8List? _sniffJpegStart(Uint8List data) {
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

/// PTP 会话:open/close 生命周期 + 浏览/下载/遥控操作封装(域内实现在
/// 三个同库私有 mixin,见文件头注记)。
///
/// 事务串行:相机一次只接受一个事务,本层用 future-chain 互斥把所有
/// [PtpTransport.execute] 排成全局队列(缩略图/大图预览/下载混流时,
/// 上层可放心并发调用;单文件下载在整个事务期间持锁)。
final class PtpSession
    with _SessionCore, _BrowseOps, _RemoteOps {
  PtpSession({
    required this.transport,
    this.mfReadyPolls = 25,
    this.mfReadyPollInterval = const Duration(milliseconds: 80),
  });

  @override
  final PtpTransport transport;

  /// MfDrive(0x9204)激活后完成态就绪轮询的拍数与间隔(官方 §6.2.5.3);
  /// 测试注入收窄(拍数/间隔归零)免真钟等待。
  @override
  final int mfReadyPolls;
  @override
  final Duration mfReadyPollInterval;


  /// 连接梯诊断用的响应码短记(OK / 0xA004 形)。静态成员不随 mixin
  /// 继承,留在门面(下游按 PtpSession.ladderRc 引用)。
  static String ladderRc(int rc) => _ladderRc(rc);

  /// SetDevicePropValue(0x1016)总开关。2026-10-05 生产翻开:Zf 真机
  /// 已实证 0x1016 可写(probe 写 0xD406 成功、回读生效),且 app 的
  /// 写入值域一律取自相机自报 PropDesc(枚举域/getSet/类型),不发
  /// 臆造值。旗标保留作紧急关断:写路径真机出问题时置回 false,
  /// setDevicePropValue 直接抛 UnsupportedError、UI 调节入口静默只读。
  static bool kSetPropEnabled = true;
}

/// 0x9434 GetObjectsMetaData 数据集元素(官方 §6.2.3.3)。
final class PtpObjectMeta {
  const PtpObjectMeta({required this.handle, required this.attribute});

  final int handle;

  /// ObjectAttribute:bit0 = Rating(有星级)、bit1 = Protected,其余保留。
  final int attribute;

  bool get hasRating => (attribute & 0x1) != 0;
  bool get isProtected => (attribute & 0x2) != 0;
}

/// 0x9434 数据集解析(§6.2.3.3 数据集表;2026-10-22 真机 392B 实测
/// 校准):u32 Version + u32 NumElement + N×16B = u32 ObjectHandle +
/// u32 ObjectAttribute + u8 Reserved + 5×u8 时刻(秒/分/时/日/月)+
/// u16 年。计数与字节数互证,不齐即 FormatException(防错位整体弃)。
/// 顶层纯函数(mixin 静态不随门面暴露,诊断侧直接引用)。
List<PtpObjectMeta> parseObjectsMetaData(Uint8List data) {
  if (data.length < 8) return const [];
  final r = ByteReader(data);
  r.u32(); // Version(未消费)
  final count = r.u32();
  const metaBytes = 16;
  if (data.length - 8 != count * metaBytes) {
    throw const FormatException(
        'GetObjectsMetaData(0x9434) 数据集字节数与计数不符(防错位整体弃)');
  }
  final out = <PtpObjectMeta>[];
  for (var i = 0; i < count; i++) {
    final handle = r.u32();
    final attribute = r.u32();
    r.skip(8); // Reserved + 时刻 5B + 年 2B(未消费)
    out.add(PtpObjectMeta(handle: handle, attribute: attribute));
  }
  return out;
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

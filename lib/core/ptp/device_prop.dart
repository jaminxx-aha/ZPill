/// PTP 标准数据集类型(DataSet Type)编解码 + 设备属性数据集解析。
///
/// 服务遥控域(0x1014 GetDevicePropDesc / 0x1015 GetDevicePropValue /
/// 0x1016 SetDevicePropValue):DevicePropDesc 数据集自描述类型,PropValue
/// 数据集是**无类型头的裸值** —— 0x1015 的解码类型只能来自标准属性表
/// (见 [kStandardPropDataType])或长度嗅探,真机核对后如有方言偏离以
/// 0x1014 的自描述类型为准。
///
/// 类型码表(ISO 15740 §9.2):int8=0x0001 … uint64=0x0008、
/// string=0xFFFF;数组类型 0x4001-0x4008 遥控域用不到,暂不实现。
library;

import 'dart:typed_data';

import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'operation_codes.dart';

/// PTP 标准数据集类型。
enum PtpDataType {
  int8(0x0001, 1),
  uint8(0x0002, 1),
  int16(0x0003, 2),
  uint16(0x0004, 2),
  int32(0x0005, 4),
  uint32(0x0006, 4),
  int64(0x0007, 8),
  uint64(0x0008, 8),
  string(0xFFFF, null);

  const PtpDataType(this.code, this.width);

  /// ISO 15740 类型码。
  final int code;

  /// 定宽字节数(string 变长,null)。
  final int? width;

  factory PtpDataType.fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    throw FormatException('未知 PTP 数据集类型 0x${code.toRadixString(16)}');
  }

  /// 从 [reader] 当前位置读一个该类型的值(string 可为 null)。
  Object? read(ByteReader reader) {
    switch (this) {
      case PtpDataType.int8:
        return reader.u8().toSigned(8);
      case PtpDataType.uint8:
        return reader.u8();
      case PtpDataType.int16:
        return reader.u16().toSigned(16);
      case PtpDataType.uint16:
        return reader.u16();
      case PtpDataType.int32:
        return reader.u32().toSigned(32);
      case PtpDataType.uint32:
        return reader.u32();
      case PtpDataType.int64:
        return reader.u64().toSigned(64);
      case PtpDataType.uint64:
        return reader.u64();
      case PtpDataType.string:
        return reader.ptpString();
    }
  }

  /// 把 [value] 编码进 [writer](0x1016 的裸值载荷)。
  ///
  /// 不做类型收窄校验:调用方拿的是 0x1015/0x1014 回读的值,类型匹配
  /// 由数据流保证;Dart int 对 u8/u16/u32 写入会按宽度截断。
  void write(ByteWriter writer, Object? value) {
    switch (this) {
      case PtpDataType.int8:
        writer.u8((value as int) & 0xFF);
      case PtpDataType.uint8:
        writer.u8((value as int) & 0xFF);
      case PtpDataType.int16:
        writer.u16((value as int) & 0xFFFF);
      case PtpDataType.uint16:
        writer.u16((value as int) & 0xFFFF);
      case PtpDataType.int32:
        writer.u32((value as int) & 0xFFFFFFFF);
      case PtpDataType.uint32:
        writer.u32((value as int) & 0xFFFFFFFF);
      case PtpDataType.int64:
        writer.u64((value as int) & 0xFFFFFFFFFFFFFFFF);
      case PtpDataType.uint64:
        writer.u64((value as int) & 0xFFFFFFFFFFFFFFFF);
      case PtpDataType.string:
        writer.ptpString(value as String?);
    }
  }
}

/// ISO 15740 标准属性规定的数据集类型(节选:遥控域用到的)。
///
/// 用途:0x1015 的响应是裸值(无类型头),标准属性的解码类型查本表;
/// 表外属性按字节宽度嗅探(见 [PtpDevicePropValue.parse])。
/// 厂商方言可能偏离标准类型 —— 偏离时以 0x1014 PropDesc 自描述为准,
/// 待真机核对。
const Map<int, PtpDataType> kStandardPropDataType = {
  PtpDevicePropCode.batteryLevel: PtpDataType.uint8,
  PtpDevicePropCode.fNumber: PtpDataType.uint16,
  PtpDevicePropCode.exposureTime: PtpDataType.uint32,
  PtpDevicePropCode.exposureIndex: PtpDataType.uint16,
  PtpDevicePropCode.focalLength: PtpDataType.uint16,
};

/// 0x1015 GetDevicePropValue / 0x1016 SetDevicePropValue 的值单元。
final class PtpDevicePropValue {
  PtpDevicePropValue({
    required this.code,
    required this.dataType,
    this.value,
  });

  final int code;
  final PtpDataType dataType;

  /// 当前值(string 属性可为 null = 0xFF「未提供」)。
  final Object? value;

  /// 解码 0x1015 响应数据集(裸值):标准表查类型,表外按宽度嗅探。
  ///
  /// 嗅探规则:奇长且符合 PTP 字符串长度布局(1+2n)按 string,
  /// 其余按 1/2/4/8 字节 → u8/u16/u32/u64。已知类型字段全失配时
  /// 抛 FormatException —— 宁可失败不可静默错值。
  static PtpDevicePropValue parse(int propCode, Uint8List data) {
    final standard = kStandardPropDataType[propCode];
    if (standard != null) {
      return PtpDevicePropValue(
        code: propCode,
        dataType: standard,
        value: standard.read(ByteReader(data)),
      );
    }
    final n = data.length;
    PtpDataType sniffed;
    if (n >= 3 && n.isOdd && data[0] == (n - 1) ~/ 2) {
      sniffed = PtpDataType.string;
    } else {
      switch (n) {
        case 1:
          sniffed = PtpDataType.uint8;
        case 2:
          sniffed = PtpDataType.uint16;
        case 4:
          sniffed = PtpDataType.uint32;
        case 8:
          sniffed = PtpDataType.uint64;
        default:
          throw FormatException(
              'prop 0x${propCode.toRadixString(16)} 裸值长度 $n 无法嗅探类型');
      }
    }
    return PtpDevicePropValue(
      code: propCode,
      dataType: sniffed,
      value: sniffed.read(ByteReader(data)),
    );
  }

  /// 编码 0x1016 的 dataOut 载荷(裸值,无类型头)。
  Uint8List encode() {
    final writer = ByteWriter();
    dataType.write(writer, value);
    return writer.takeBytes();
  }

  @override
  String toString() =>
      'PtpDevicePropValue(0x${code.toRadixString(16)}, $dataType, $value)';
}

/// 0x1014 GetDevicePropDesc 响应数据集。
///
/// 布局(ISO 15740 §10.5.1.3,2026-10-05 真机修正):
/// `u16 propCode + u16 dataType + u8 getSet + 当前值 + 出厂默认值 +
/// u8 formFlag + FORM`。出厂默认值位于 FORM **之前** —— 旧版漏读了
/// 它,把出厂值首字节当 formFlag,枚举/范围域全丢(Zf 真机「所有属性
/// 取值域未知」的根因;OpenZCine Z 系真机代码同样在 FORM 前跳过两个
/// 值)。FORM 区解析失败时,整型属性再做「0x02 + u16 计数 + N 值恰好
/// 收尾」扫描兜底,容忍缺出厂值/值区多字段的方言数据集(OpenZCine
/// devicePropDescEnumValues 同款)。防御性可选解析,截断/不识别一律
/// 降级为 null 不上抛。
final class PtpDevicePropDesc {
  PtpDevicePropDesc({
    required this.code,
    required this.dataType,
    required this.getSet,
    this.currentValue,
    this.factoryValue,
    this.enumValues,
    this.rangeMin,
    this.rangeMax,
    this.rangeStep,
  });

  final int code;
  final PtpDataType dataType;

  /// true = 可写(0x01),false = 只读(0x00)。
  final bool getSet;

  final Object? currentValue;

  /// 出厂默认值(**值区第一个**;当前值第二个,见 [parse] 的顺序注);
  /// 截断/缺省为 null。
  final Object? factoryValue;

  /// FORM=0x02 枚举域;FORM 截断或非枚举时为 null。
  final List<Object?>? enumValues;

  /// FORM=0x01 范围域三元组;同上,解析失败为 null。
  final Object? rangeMin;
  final Object? rangeMax;
  final Object? rangeStep;

  /// 防御性解析:头部三字段 + 当前值缺失时其余字段可全空,不抛异常
  /// (相机方言的截断数据集仍可显示「存在但未知」)。
  static PtpDevicePropDesc parse(Uint8List data) {
    final r = ByteReader(data);
    if (r.remaining < 5) {
      throw FormatException('DevicePropDesc 头部截断(${r.remaining}B)');
    }
    final code = r.u16();
    final dataType = PtpDataType.fromCode(r.u16());
    final getSet = r.u8() != 0;

    // 值区两值的顺序(gphoto2 ptp_unpack_DPD 权威,2026-10-06 订正):
    // **出厂默认值在前,当前值在后**。旧版读反 —— 真机后果:光圈永远
    // 显示出厂默认(= 镜头最大光圈 f/2.0),应用写入/机身拨盘改动都
    // 「不生效」。截断数据集:值读失败保描述,FORM 不再可信。
    Object? factoryValue;
    var valuesIntact = false;
    try {
      factoryValue = dataType.read(r);
      valuesIntact = true;
    } on Object {
      factoryValue = null; // 值区截断
    }
    // 字符串型 read 可能合法返回 null,不能以 null 判截断 —— 以完成
    // 标志为准。
    Object? currentValue;
    if (valuesIntact || dataType == PtpDataType.string) {
      try {
        currentValue = dataType.read(r);
      } on Object {
        currentValue = null;
        valuesIntact = false; // 第二值截断:FORM 位置不可信
      }
    }

    List<Object?>? enumValues;
    Object? rangeMin, rangeMax, rangeStep;
    if (valuesIntact && !r.eof) {
      try {
        final formFlag = r.u8();
        switch (formFlag) {
          case 0x01: // Range FORM:最小 / 最大 / 步长
            rangeMin = dataType.read(r);
            rangeMax = dataType.read(r);
            rangeStep = dataType.read(r);
          case 0x02: // Enumeration FORM:u16 个数 + N 值
            final count = r.u16();
            enumValues = [
              for (var i = 0; i < count; i++) dataType.read(r),
            ];
          default:
            break; // 0x00 无 FORM:正常收尾
        }
      } on Object {
        // FORM 区截断/越界:整组降级为 null,走扫描兜底
      }
    }
    // 扫描兜底:定长路径没解出 FORM 时,整型属性按「u8 0x02 + u16
    // 计数 + count×宽度恰好填满缓冲」定位枚举段(缺出厂值/值区多
    // 字段的方言数据集也能救回;误报面被「恰好收尾」约束到极小)。
    if (enumValues == null && rangeMin == null) {
      enumValues = _scanEnumForm(data, dataType);
    }

    return PtpDevicePropDesc(
      code: code,
      dataType: dataType,
      getSet: getSet,
      currentValue: currentValue,
      factoryValue: factoryValue,
      enumValues: enumValues,
      rangeMin: rangeMin,
      rangeMax: rangeMax,
      rangeStep: rangeStep,
    );
  }

  /// 枚举段扫描:全缓冲找「u8 0x02 + u16 计数 + count×宽度 恰好
  /// 填满到结尾」的候选(第一个命中即用)。宽度未知(字符串型)返回
  /// null —— 字符串枚举各值自述长度,没有可用的收尾约束。
  static List<Object?>? _scanEnumForm(Uint8List data, PtpDataType type) {
    final width = type.width;
    if (width == null) return null;
    final b = data;
    final n = b.length;
    for (var i = 0; i + 2 < n; i++) {
      if (b[i] != 0x02) continue;
      final count = b[i + 1] | (b[i + 2] << 8);
      final start = i + 3;
      if (count == 0 || start + count * width != n) continue;
      final r = ByteReader(b, start);
      return [for (var k = 0; k < count; k++) type.read(r)];
    }
    return null;
  }

  @override
  String toString() =>
      'PtpDevicePropDesc(0x${code.toRadixString(16)}, $dataType, '
      'getSet=$getSet, current=$currentValue, enum=$enumValues)';
}

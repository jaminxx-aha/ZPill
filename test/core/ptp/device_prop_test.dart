import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/core/utils/byte_reader.dart';
import 'package:nikon_pill/core/utils/byte_writer.dart';

/// 表外假属性码(0xD0xx 老尼康区,现代表不在册;仅测长度嗅探路径)。
const int kVendorProp = 0xD0F0;

/// 手搓 DevicePropDesc 数据集(u16 code + u16 dataType + u8 getSet + 值 + FORM)。
ByteWriter propDescHeader({
  required int propCode,
  required PtpDataType dataType,
  required bool getSet,
  Object? value,
}) {
  final w = ByteWriter()
    ..u16(propCode)
    ..u16(dataType.code)
    ..u8(getSet ? 1 : 0);
  if (value != null || dataType == PtpDataType.string) {
    dataType.write(w, value);
  }
  return w;
}

void main() {
  group('PtpDataType', () {
    test('fromCode:标准码全往返,未知码抛 FormatException', () {
      for (final t in PtpDataType.values) {
        expect(PtpDataType.fromCode(t.code), t);
      }
      expect(() => PtpDataType.fromCode(0x4001), throwsFormatException); // 数组类型未实现
      expect(() => PtpDataType.fromCode(0x0009), throwsFormatException);
    });

    test('定宽类型 write→read 往返(含符号位)', () {
      final cases = <PtpDataType, List<int>>{
        PtpDataType.int8: [-128, -1, 127],
        PtpDataType.uint8: [0, 255],
        PtpDataType.int16: [-32768, -1, 32767],
        PtpDataType.uint16: [0, 65535],
        PtpDataType.int32: [-2147483648, -1],
        PtpDataType.uint32: [0, 4294967295],
        PtpDataType.int64: [-9223372036854775808, -1],
        PtpDataType.uint64: [0, 9223372036854775807],
      };
      cases.forEach((type, values) {
        for (final v in values) {
          final w = ByteWriter()..u16(type.code);
          type.write(w, v);
          final r = ByteReader(w.takeBytes());
          r.u16(); // 跳类型头占位
          expect(type.read(r), v, reason: '$type $v');
        }
      });
    });

    test('string:往返 + null(0xFF)+ 截断 NUL 兼容读侧', () {
      for (final s in ['A', 'f/1.8', '你好', '']) {
        final w = ByteWriter();
        PtpDataType.string.write(w, s);
        expect(PtpDataType.string.read(ByteReader(w.takeBytes())), s);
      }
      final w = ByteWriter();
      PtpDataType.string.write(w, null);
      expect(w.takeBytes(), [0xFF]);
      expect(PtpDataType.string.read(ByteReader(Uint8List.fromList([0xFF]))),
          isNull);
    });
  });

  group('PtpDevicePropValue.parse', () {
    test('标准表属性:fNumber=0x5007 按 u16 解码', () {
      final data = ByteWriter()..u16(18); // 18 → f/1.8 的 1.8×10
      final v = PtpDevicePropValue.parse(
          PtpDevicePropCode.fNumber, data.takeBytes());
      expect(v.dataType, PtpDataType.uint16);
      expect(v.value, 18);
    });

    test('表外属性按宽度嗅探:4B → u32(exposureBias 类)', () {
      final w = ByteWriter()..u32(0x00000100);
      final v = PtpDevicePropValue.parse(kVendorProp, w.takeBytes());
      expect(v.dataType, PtpDataType.uint32);
      expect(v.value, 0x100);
    });

    test('表外属性字符串嗅探:1+2n 布局 → string', () {
      // 'AB':n=2,布局 = 02 00 41 00 42 00(6 字节,奇长)
      final w = ByteWriter()
        ..u8(2)
        ..utf16le('AB');
      final v = PtpDevicePropValue.parse(kVendorProp, w.takeBytes());
      expect(v.dataType, PtpDataType.string);
      expect(v.value, 'AB');
    });

    test('无法嗅探的长度抛 FormatException(宁失败不错值)', () {
      expect(
          () => PtpDevicePropValue.parse(
              kVendorProp, Uint8List.fromList([1, 2, 3, 4, 5])),
          throwsFormatException);
    });

    test('encode:裸值无类型头,与 parse 互逆(标准表属性)', () {
      final w = ByteWriter()..u32(10000); // exposureTime 1/10000s
      final v = PtpDevicePropValue.parse(
          PtpDevicePropCode.exposureTime, w.takeBytes());
      expect(v.encode(), [0x10, 0x27, 0x00, 0x00]);
    });
  });

  group('PtpDevicePropDesc.parse', () {
    test('完整布局:枚举 FORM(u16 计数 + N 值)+ MTP 出厂默认组', () {
      // fNumber:u16 类型,当前 18,枚举域 [16,18,20,22],出厂 [18]
      final w = propDescHeader(
        propCode: PtpDevicePropCode.fNumber,
        dataType: PtpDataType.uint16,
        getSet: true,
        value: 18,
      )
        ..u8(0x02) // FORM = Enumeration
        ..u16(4)
        ..u16(16)..u16(18)..u16(20)..u16(22)
        ..u16(1) // MTP factory group:个数 + 值
        ..u16(18);
      final d = PtpDevicePropDesc.parse(w.takeBytes());
      expect(d.code, PtpDevicePropCode.fNumber);
      expect(d.dataType, PtpDataType.uint16);
      expect(d.getSet, isTrue);
      expect(d.currentValue, 18);
      expect(d.enumValues, [16, 18, 20, 22]);
      expect(d.factoryValues, [18]);
    });

    test('范围 FORM:min/max/step 三元组', () {
      final w = propDescHeader(
        propCode: PtpDevicePropCode.exposureIndex,
        dataType: PtpDataType.uint16,
        getSet: true,
        value: 200,
      )
        ..u8(0x01) // FORM = Range
        ..u16(100)..u16(25600)..u16(100);
      final d = PtpDevicePropDesc.parse(w.takeBytes());
      expect(d.rangeMin, 100);
      expect(d.rangeMax, 25600);
      expect(d.rangeStep, 100);
      expect(d.enumValues, isNull);
    });

    test('FORM=0x00 无形式 + 无出厂组:字段全 null', () {
      final w = propDescHeader(
        propCode: PtpDevicePropCode.batteryLevel,
        dataType: PtpDataType.uint8,
        getSet: false,
        value: 80,
      )..u8(0x00);
      final d = PtpDevicePropDesc.parse(w.takeBytes());
      expect(d.getSet, isFalse);
      expect(d.currentValue, 80);
      expect(d.enumValues, isNull);
      expect(d.factoryValues, isNull);
    });

    test('截断容错:值区完好 FORM 截断 → 降级 null 不抛', () {
      final w = propDescHeader(
        propCode: PtpDevicePropCode.fNumber,
        dataType: PtpDataType.uint16,
        getSet: true,
        value: 18,
      )
        ..u8(0x02) // FORM = Enumeration,但计数被截断
        ..u8(0x04); // 只有半个 u16
      final d = PtpDevicePropDesc.parse(w.takeBytes());
      expect(d.currentValue, 18);
      expect(d.enumValues, isNull);
    });

    test('截断容错:值区截断 → current=null、FORM 区不再解析', () {
      final w = ByteWriter()
        ..u16(PtpDevicePropCode.exposureTime)
        ..u16(PtpDataType.uint32.code)
        ..u8(1)
        ..u16(5000); // u32 只写了 2 字节 → 值区截断
      final d = PtpDevicePropDesc.parse(w.takeBytes());
      expect(d.currentValue, isNull);
      expect(d.enumValues, isNull);
      expect(d.dataType, PtpDataType.uint32); // 头部三字段仍然可信
    });

    test('头部截断(<5B)抛 FormatException', () {
      expect(
          () => PtpDevicePropDesc.parse(Uint8List.fromList([0x07, 0x50])),
          throwsFormatException);
    });
  });
}


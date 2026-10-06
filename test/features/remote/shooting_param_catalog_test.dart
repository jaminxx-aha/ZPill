import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';

ShootingParam _param(int code) =>
    kShootingParams.singleWhere((p) => p.code == code);

void main() {
  test('目录顺序与码表(标准区在册 + 厂商区候选;序 = 刷新/展示序)', () {
    expect(kShootingParams.map((p) => p.code), [
      PtpDevicePropCode.exposureProgramMode,
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.exposureTime,
      PtpDevicePropCode.exposureIndex,
      PtpDevicePropCode.exposureBiasCompensation,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.wbColorTemp,
      PtpDevicePropCode.flashMode,
      PtpDevicePropCode.exposureMeteringMode,
      PtpDevicePropCode.stillFocusMode,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.captureAreaCrop,
      PtpDevicePropCode.activePicCtrlItem,
    ]);
  });

  test('display:模式尼康方言表(2=P/3=A/4=S,U 段与场景段齐)',
      () {
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(1), '手动 M');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(2), '程序 P',
        reason: '尼康方言 2=P(ISO 标准表 2=自动是错的)');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(3), '光圈优先 A');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(4), '快门优先 S');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(0x8010), '自动');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(0x8050), 'U1');
  });

  test('display:白平衡/色温/闪光尼康方言表', () {
    expect(_param(PtpDevicePropCode.whiteBalance).display(2), '自动');
    expect(_param(PtpDevicePropCode.whiteBalance).display(6), '白炽灯');
    expect(_param(PtpDevicePropCode.whiteBalance).display(0x8010), '阴天');
    expect(_param(PtpDevicePropCode.whiteBalance).display(0x8012), '色温');
    expect(_param(PtpDevicePropCode.wbColorTemp).display(5500), '5500K');
    expect(_param(PtpDevicePropCode.flashMode).display(2), '关闭');
    expect(_param(PtpDevicePropCode.flashMode).display(0x8010), '补充闪光');
    expect(_param(PtpDevicePropCode.flashMode).display(0x8012), '后帘同步');
  });

  test('display:释放模式全表(单张/连拍档/自拍/C 高速档)', () {
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(1), '单张');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(2), '高速连拍');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x8010), '低速连拍');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x8011), '自拍');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x811E), '连拍 C30');
  });

  test('display:画质 14 值表 + RAW 压缩 + 图像区域', () {
    expect(_param(PtpDevicePropCode.compressionSetting).display(0), 'JPEG 基本');
    expect(_param(PtpDevicePropCode.compressionSetting).display(5), 'JPEG 精细★');
    expect(_param(PtpDevicePropCode.compressionSetting).display(7), 'RAW');
    expect(_param(PtpDevicePropCode.compressionSetting).display(12), 'RAW+JPEG 精细');
    expect(_param(PtpDevicePropCode.rawCompressionType).display(0), '无损压缩');
    expect(_param(PtpDevicePropCode.rawCompressionType).display(4), '高效率');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(0), 'FX');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(2), 'DX');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(5), '16:9');
  });

  test('display:优化校准内置组 + 段位格式化(创意/自定义/云)', () {
    expect(_param(PtpDevicePropCode.activePicCtrlItem).display(1), '标准');
    expect(_param(PtpDevicePropCode.activePicCtrlItem).display(4), '单色');
    expect(_param(PtpDevicePropCode.activePicCtrlItem).display(103), 'Pop');
    expect(_param(PtpDevicePropCode.activePicCtrlItem).display(202), '自定义 2');
    expect(_param(PtpDevicePropCode.activePicCtrlItem).display(305), '云 5');
  });

  test('display:数值格式化(光圈/快门打包分数/ISO/EV)', () {
    expect(_param(PtpDevicePropCode.fNumber).display(280), 'f/2.8');
    // 快门值 = 0xD100 打包分数(num<<16|den)
    expect(_param(PtpDevicePropCode.exposureTime).display(1 << 16 | 100),
        '1/100s');
    expect(_param(PtpDevicePropCode.exposureTime).display(4 << 16 | 1), '4s');
    expect(_param(PtpDevicePropCode.exposureTime).display(13 << 16 | 10),
        '13/10s');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFF), 'Bulb');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFE), 'X 同步');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFD), 'Time');
    expect(_param(PtpDevicePropCode.exposureIndex).display(200), 'ISO 200');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(300), '+0.3');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(-700),
        '-0.7');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(0), '0.0');
  });

  test('display:表外值裸显 + 未读占位', () {
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(7), '值 7',
        reason: '测光表外值(2/3/4/0x8010 在表)');
    expect(_param(PtpDevicePropCode.whiteBalance).display(3), '值 3'); // 表外枚举
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(null), '--');
    expect(kShootingParams.any((p) => p.code == PtpDevicePropCode.imageSize),
        isFalse,
        reason: '图像尺寸(0x5003 STR 型)已移出目录');
  });

  test('读写路径路由:ISO/快门读写全走厂商码,模式由转盘拥有只读', () {
    // Z 系真机口径(OpenZCine):静照 ISO/快门的标准码只读且不跟厂商写
    // —— 写走 0xD0B4/0xD100,值读走 0xD0B5/0xD100。
    final iso = _param(PtpDevicePropCode.exposureIndex);
    expect(iso.readCode, PtpDevicePropCode.isoControlSensitivity);
    expect(iso.writeCode, PtpDevicePropCode.exposureIndexEx);
    expect(iso.writeType, PtpDataType.uint32);
    expect(iso.writeConvert, isNull, reason: 'ISO 裸数直写');
    final shutter = _param(PtpDevicePropCode.exposureTime);
    expect(shutter.readCode, PtpDevicePropCode.stillShutterSpeed);
    expect(shutter.writeCode, PtpDevicePropCode.stillShutterSpeed);
    expect(shutter.writeType, PtpDataType.uint32);
    expect(shutter.writeConvert, isNull, reason: '面板值已是打包分数');
    expect(shutter.dialOwned, isTrue, reason: '机顶快门拨盘拥有 → 接管后才可调');
    expect(_param(PtpDevicePropCode.exposureIndex).dialOwned, isTrue,
        reason: 'ISO 按键+指令拨盘调整(2026-10-06 真机 0x200F)→ 接管后才可调');
    expect(_param(PtpDevicePropCode.fNumber).dialOwned, isTrue,
        reason: '光圈为指令拨盘参数(A/M 主拨盘)→ 接管后才可调');
    // 其余参数无路由(读码 = 写码 = 展示码)
    for (final code in [
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.activePicCtrlItem,
    ]) {
      expect(_param(code).writeCode, isNull, reason: '0x$code 无需路由');
      expect(_param(code).readCode, isNull);
    }
    // 模式:机顶转盘物理拥有 → dialOwned(接管后可写,OpenZCine 同款
    // 0x500E u16 标准写路径);对焦只留 0xD061 单一芯片(0x500A 只读
    // 镜像已移出,避免「对焦/对焦模式」双芯片)。
    expect(_param(PtpDevicePropCode.exposureProgramMode).readOnly, isFalse);
    expect(_param(PtpDevicePropCode.exposureProgramMode).dialOwned, isTrue);
    expect(kShootingParams.any((p) => p.code == PtpDevicePropCode.focusMode),
        isFalse,
        reason: '0x500A 只读镜像移出目录');
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(3), '矩阵',
        reason: '尼康方言:3=矩阵(ISO 标准表 3=点是错的)');
    expect(_param(PtpDevicePropCode.fNumber).readOnly, isFalse);
  });

  test('快门取值域直供表:标准档打包值 + Bulb 哨兵(无 Time/X 同步)', () {
    final pick = _param(PtpDevicePropCode.exposureTime).pickValues!;
    expect(pick.first, 1 << 16 | 8000, reason: '1/8000s 打包');
    expect(pick, containsAll(<int>[1 << 16 | 100, 13 << 16 | 10, 30 << 16 | 1]));
    expect(pick.last, 0xFFFFFFFF, reason: 'Bulb');
    expect(pick, isNot(contains(0xFFFFFFFD)), reason: 'Time 是机顶拨盘位');
    expect(pick, isNot(contains(0xFFFFFFFE)), reason: 'X 同步是机顶拨盘位');
    // 其余参数取值域仍走相机 PropDesc
    expect(_param(PtpDevicePropCode.exposureIndex).pickValues, isNull);
  });

  test('曝光三要素标记 prominent(大芯片行),其余进横滚行', () {
    expect(kShootingParams
        .where((p) => p.prominent)
        .map((p) => p.label), ['光圈', '快门', 'ISO']);
    expect(kShootingParams.where((p) => p.prominent), hasLength(3));
  });
}

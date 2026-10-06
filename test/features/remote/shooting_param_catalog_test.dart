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
      PtpDevicePropCode.focusMode,
      PtpDevicePropCode.stillFocusMode,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.imageSize,
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

  test('display:数值格式化(光圈/快门/ISO/EV)', () {
    expect(_param(PtpDevicePropCode.fNumber).display(280), 'f/2.8');
    expect(_param(PtpDevicePropCode.exposureTime).display(10000), '1/100s');
    expect(_param(PtpDevicePropCode.exposureTime).display(4000000), '4s');
    expect(_param(PtpDevicePropCode.exposureIndex).display(200), 'ISO 200');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(300), '+0.3');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(-700),
        '-0.7');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(0), '0.0');
  });

  test('display:表外值裸显 + 未读占位(测光/图像尺寸无值表)', () {
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(2), '值 2');
    expect(_param(PtpDevicePropCode.imageSize).display(3), '值 3');
    expect(_param(PtpDevicePropCode.whiteBalance).display(3), '值 3'); // 表外枚举
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(null), '--');
  });

  test('写路径路由:ISO/快门走厂商码,模式由转盘拥有只读', () {
    // Z 系真机口径(OpenZCine):静照 ISO/快门的标准码只读不可写
    final iso = _param(PtpDevicePropCode.exposureIndex);
    expect(iso.writeCode, PtpDevicePropCode.exposureIndexEx);
    expect(iso.writeType, PtpDataType.uint32);
    final shutter = _param(PtpDevicePropCode.exposureTime);
    expect(shutter.writeCode, PtpDevicePropCode.stillShutterSpeed);
    expect(shutter.writeType, PtpDataType.uint32);
    expect(shutter.writeConvert, isNotNull);
    // 其余参数无路由(写码 = 读码)
    for (final code in [
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.activePicCtrlItem,
    ]) {
      expect(_param(code).writeCode, isNull, reason: '0x$code 无需路由');
    }
    // 模式:机顶转盘物理拥有(OpenZCine read-only 口径)
    expect(_param(PtpDevicePropCode.exposureProgramMode).readOnly, isTrue);
    expect(_param(PtpDevicePropCode.fNumber).readOnly, isFalse);
  });

  test('快门 µs → 0xD100 分数打包(标准档全命中 + 舍入容差 + 表外拒绝)',
      () {
    final pack = _param(PtpDevicePropCode.exposureTime).writeConvert!;
    expect(pack(10000), 0x00010064, reason: '1/100');
    expect(pack(1000000), 0x00010001, reason: '1s');
    expect(pack(4000000), 0x00040001, reason: '4s');
    expect(pack(30000000), 30 << 16 | 1, reason: '30s');
    expect(pack(16667), 0x0001003C, reason: '1/60(µs=16667 舍入)');
    expect(pack(156), 0x00011900, reason: '1/6400(156.25µs 舍入)');
    expect(pack(1300000), 0x000D000A, reason: '1.3s = 13/10');
    expect(pack(2500000), 0x00050002, reason: '2.5s = 5/2');
    expect(pack(0), isNull, reason: '非法值');
    expect(pack(137), isNull, reason: '表外(1/8000 与 1/6400 之间)');
  });

  test('曝光三要素标记 prominent(大芯片行),其余进横滚行', () {
    expect(kShootingParams
        .where((p) => p.prominent)
        .map((p) => p.label), ['光圈', '快门', 'ISO']);
    expect(kShootingParams.where((p) => p.prominent), hasLength(3));
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';

ShootingParam _param(int code) =>
    kShootingParams.singleWhere((p) => p.code == code);

void main() {
  test('目录顺序与码表(码 = Zf 在册,序 = 刷新/展示序)', () {
    expect(kShootingParams.map((p) => p.code), [
      PtpDevicePropCode.exposureProgramMode,
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.exposureTime,
      PtpDevicePropCode.exposureIndex,
      PtpDevicePropCode.exposureBiasCompensation,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.exposureMeteringMode,
      PtpDevicePropCode.focusMode,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
    ]);
  });

  test('display:枚举标签命中(模式/白平衡/释放)', () {
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(1), '手动 M');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(3), '光圈优先 A');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(4), '快门优先 S');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(5), '程序 P');
    expect(_param(PtpDevicePropCode.whiteBalance).display(2), '自动');
    expect(_param(PtpDevicePropCode.whiteBalance).display(6), '白炽灯');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(1), '单张');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(2), '连拍');
  });

  test('display:数值格式化(光圈/快门/ISO/EV)', () {
    expect(_param(PtpDevicePropCode.fNumber).display(28), 'f/2.8');
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

  test('display:表外值裸显 + 未读占位(测光/对焦/画质标签待真机核对)', () {
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(2), '值 2');
    expect(_param(PtpDevicePropCode.focusMode).display(3), '值 3');
    expect(_param(PtpDevicePropCode.compressionSetting).display(7), '值 7');
    expect(_param(PtpDevicePropCode.whiteBalance).display(3), '值 3'); // 表外枚举
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(null), '--');
  });

  test('曝光三要素标记 prominent(大芯片行),其余进 Wrap', () {
    expect(kShootingParams
        .where((p) => p.prominent)
        .map((p) => p.label), ['光圈', '快门', 'ISO']);
    expect(kShootingParams.where((p) => p.prominent), hasLength(3));
  });
}

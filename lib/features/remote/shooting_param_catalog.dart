/// 拍摄参数目录:拍摄页参数 chips 与编辑面板的唯一事实源。
///
/// 码表:Zf 真机 GetDeviceInfo 在册属性(2026-09-27),只收在册码 ——
/// AF 区域 / 色调模式 / 优化校准(Picture Control)无在册码,按铁律
/// 不可臆造,见 TODO 抓包阻塞项(真机用 probe --propdesc 探查后再录)。
/// 枚举值标签:ISO 15740 标准值表语义,尼康方言布局待真机核对 ——
/// 表外值显示原始数字「值 N」,回读真机后补齐标签表。
library;

import '../../core/ptp/operation_codes.dart';

/// 单个拍摄参数:属性码 + 中文名 + 值展示规则。
final class ShootingParam {
  const ShootingParam({
    required this.code,
    required this.label,
    this.enumLabels = const {},
    this.format,
    this.prominent = false,
  });

  /// PTP DevicePropCode(0x5004/0x5005/…)。
  final int code;

  /// 中文参数名(芯片标签)。
  final String label;

  /// 标准枚举值 → 中文标签;键外的值回退 [format] / 「值 N」。
  final Map<int, String> enumLabels;

  /// 数值格式化(光圈/快门/ISO/EV)。
  final String Function(int v)? format;

  /// 曝光三要素(大号芯片行);其余进参数 Wrap 小芯片。
  final bool prominent;

  /// 当前值展示:null = 未读;枚举表外 → 格式化 → 原始数字。
  String display(int? value) {
    if (value == null) {
      return '--';
    }
    return enumLabels[value] ?? format?.call(value) ?? '值 $value';
  }
}

String _formatFNumber(int v) => 'f/${(v / 10).toStringAsFixed(1)}';

String _formatIso(int v) => 'ISO $v';

/// EV:千分之一档(ISO 15740),一位小数带符号。
String _formatEv(int v) {
  final ev = v / 1000;
  final s = ev.toStringAsFixed(1);
  return ev > 0 ? '+$s' : s;
}

String _formatShutter(int us) {
  if (us <= 0) {
    return '--';
  }
  if (us >= 1000000) {
    final s = us / 1000000;
    return '${s == s.roundToDouble() ? s.toInt() : s.toStringAsFixed(1)}s';
  }
  return '1/${(1000000 / us).round()}s';
}

/// 目录顺序 = 刷新顺序 = 展示顺序(三要素居首,其余按拍摄调整频率)。
const kShootingParams = <ShootingParam>[
  ShootingParam(
    code: PtpDevicePropCode.exposureProgramMode,
    label: '模式',
    enumLabels: {
      1: '手动 M',
      2: '自动',
      3: '光圈优先 A',
      4: '快门优先 S',
      5: '程序 P',
      6: '动作程序',
    },
  ),
  ShootingParam(
      code: PtpDevicePropCode.fNumber,
      label: '光圈',
      format: _formatFNumber,
      prominent: true),
  ShootingParam(
      code: PtpDevicePropCode.exposureTime,
      label: '快门',
      format: _formatShutter,
      prominent: true),
  ShootingParam(
      code: PtpDevicePropCode.exposureIndex,
      label: 'ISO',
      format: _formatIso,
      prominent: true),
  ShootingParam(
      code: PtpDevicePropCode.exposureBiasCompensation,
      label: 'EV',
      format: _formatEv),
  ShootingParam(
    code: PtpDevicePropCode.whiteBalance,
    label: '白平衡',
    enumLabels: {
      1: '手动',
      2: '自动',
      4: '日光',
      5: '荧光灯',
      6: '白炽灯',
      7: '闪光灯',
    },
  ),
  // 测光/对焦/画质:标准枚举布局与尼康方言未定论(待真机核对),
  // 值先裸显「值 N」,核对后补标签表。
  ShootingParam(code: PtpDevicePropCode.exposureMeteringMode, label: '测光'),
  ShootingParam(code: PtpDevicePropCode.focusMode, label: '对焦'),
  ShootingParam(
    code: PtpDevicePropCode.stillCaptureMode,
    label: '释放',
    enumLabels: {1: '单张', 2: '连拍', 3: '间隔'},
  ),
  ShootingParam(code: PtpDevicePropCode.compressionSetting, label: '画质'),
];

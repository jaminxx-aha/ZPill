/// 拍摄参数目录:拍摄页参数 chips 与编辑面板的唯一事实源。
///
/// 码表分两区:
/// - 0x50xx 标准区:Zf 真机 GetDeviceInfo 在册(2026-09-27)。
/// - 0xD0xx/0xD2xx 厂商区:候选码(OpenZCine/libgphoto2 值表),不在
///   Zf 在册表内 —— 在册表不是真相的全部(与 STA 9-op 小表同理),
///   相机可能照常应答;PropDesc 拒答时置空显示「--」,无害。
///
/// 枚举值标签:尼康方言值表(源 = OpenZCine PTPCameraPropertyDecoders,
/// 其又源出 libgphoto2 config.c;**全部标 verify-on-HW,Zf 待真机核对**)。
/// 表外值回退格式化/「值 N」,回读真机后如有出入只改标签表。
/// 优化校准的创意组(101-120)/自定义(201-209)/云(301-309)按段格式化。
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

  /// 枚举值 → 中文标签;键外的值回退 [format] / 「值 N」。
  final Map<int, String> enumLabels;

  /// 数值格式化(光圈/快门/ISO/EV/色温/优化校准段)。
  final String Function(int v)? format;

  /// 曝光三要素(大号芯片行);其余进参数横滚行小芯片。
  final bool prominent;

  /// 当前值展示:null = 未读;枚举表外 → 格式化 → 原始数字。
  String display(int? value) {
    if (value == null) {
      return '--';
    }
    return enumLabels[value] ?? format?.call(value) ?? '值 $value';
  }
}

/// 光圈:f 值 ×100(ISO 15740 定点,Zf 实际布局待真机核对)。
String _formatFNumber(int v) => 'f/${(v / 100).toStringAsFixed(1)}';

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

/// 白平衡色温 0xD01E:开尔文裸值。
String _formatColorTemp(int v) => '${v}K';

/// 优化校准 0xD200 段位:101-120 创意组 / 201-209 自定义 / 301-309 云下载
/// (内置 1-11 与创意组成员走枚举表)。
String _formatPicCtrl(int v) {
  if (v >= 101 && v <= 120) return '创意 ${v - 100}';
  if (v >= 201 && v <= 209) return '自定义 ${v - 200}';
  if (v >= 301 && v <= 309) return '云 ${v - 300}';
  return '值 $v';
}

/// 目录顺序 = 刷新顺序 = 展示顺序(三要素居首,其余按拍摄调整频率;
/// 对焦/对焦模式相邻,画质三件套 RAW压缩/尺寸/区域相邻)。
const kShootingParams = <ShootingParam>[
  // 曝光模式:尼康方言(libgphoto2 exposure_program_modes 候选表;
  // ISO 标准表 2=自动/5=程序 对尼康是错的 —— 2=P、3=A、4=S)。
  ShootingParam(
    code: PtpDevicePropCode.exposureProgramMode,
    label: '模式',
    enumLabels: {
      1: '手动 M',
      2: '程序 P',
      3: '光圈优先 A',
      4: '快门优先 S',
      0x8010: '自动',
      0x8011: '人像',
      0x8012: '风景',
      0x8013: '微距',
      0x8014: '运动',
      0x8015: '夜景',
      0x8016: '夜景人像',
      0x8017: '儿童',
      0x8018: '场景',
      0x8019: '特效',
      0x8050: 'U1',
      0x8051: 'U2',
      0x8052: 'U3',
      0x8053: 'U4',
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
  // 白平衡:尼康方言候选表(2=自动、4=直射阳光…;ISO 标准表 1=手动
  // 对尼康不成立 —— 表外值裸显)。
  ShootingParam(
    code: PtpDevicePropCode.whiteBalance,
    label: '白平衡',
    enumLabels: {
      2: '自动',
      4: '直射阳光',
      5: '荧光灯',
      6: '白炽灯',
      7: '闪光',
      0x8010: '阴天',
      0x8011: '背阴',
      0x8012: '色温',
      0x8013: '手动预设',
      0x8016: '自然自动',
    },
  ),
  ShootingParam(
      code: PtpDevicePropCode.wbColorTemp,
      label: '色温',
      format: _formatColorTemp),
  // 闪光:尼康方言候选表(默认「自动/前帘同步」不在表内,表外裸显)。
  ShootingParam(
    code: PtpDevicePropCode.flashMode,
    label: '闪光',
    enumLabels: {
      2: '关闭',
      4: '防红眼',
      0x8010: '补充闪光',
      0x8011: '慢速同步',
      0x8012: '后帘同步',
      0x8013: '防红眼慢速',
    },
  ),
  // 测光/图像尺寸:无可靠值表(OpenZCine 亦无解码表),裸显「值 N」。
  ShootingParam(code: PtpDevicePropCode.exposureMeteringMode, label: '测光'),
  // 对焦 0x500A:视频口径方言表(AF-F 为视频全时 AF);静照权威源是
  // 0xD061(OpenZCine 实测口径),两枚并陈互为对照。
  ShootingParam(
    code: PtpDevicePropCode.focusMode,
    label: '对焦',
    enumLabels: {0: 'AF-S', 1: 'AF-C', 2: 'AF-F', 4: 'MF'},
  ),
  ShootingParam(
    code: PtpDevicePropCode.stillFocusMode,
    label: '对焦模式',
    enumLabels: {0: 'AF-S', 1: 'AF-C', 4: 'MF', 5: 'AF-A'},
  ),
  // 释放:尼康方言全表(libgphoto2/OpenZCine StillDriveMode 候选;
  // ISO 标准表 2=连拍/3=间隔 对尼康不成立 —— C15-C120 为高速连拍档)。
  ShootingParam(
    code: PtpDevicePropCode.stillCaptureMode,
    label: '释放',
    enumLabels: {
      1: '单张',
      0x8010: '低速连拍',
      2: '高速连拍',
      0x8019: '高速连拍+',
      0x8011: '自拍',
      0x8100: '快速',
      0x810F: '连拍 C15',
      0x811E: '连拍 C30',
      0x813C: '连拍 C60',
      0x8178: '连拍 C120',
    },
  ),
  // 画质:尼康 14 值全表(★ = 画质优先/最优压缩档)。
  ShootingParam(
    code: PtpDevicePropCode.compressionSetting,
    label: '画质',
    enumLabels: {
      0: 'JPEG 基本',
      1: 'JPEG 基本★',
      2: 'JPEG 标准',
      3: 'JPEG 标准★',
      4: 'JPEG 精细',
      5: 'JPEG 精细★',
      6: 'TIFF',
      7: 'RAW',
      8: 'RAW+JPEG 基本',
      9: 'RAW+JPEG 基本★',
      10: 'RAW+JPEG 标准',
      11: 'RAW+JPEG 标准★',
      12: 'RAW+JPEG 精细',
      13: 'RAW+JPEG 精细★',
    },
  ),
  // ---- 以下厂商候选区(0xD0xx/0xD2xx,不在 Zf 在册表,拒答显示「--」)----
  // NEF(RAW)记录压缩:一代机身用 1/2,现役机身 0/3/4。
  ShootingParam(
    code: PtpDevicePropCode.rawCompressionType,
    label: 'RAW 压缩',
    enumLabels: {
      0: '无损压缩',
      1: '压缩(旧型)',
      2: '未压缩',
      3: '高效率★',
      4: '高效率',
    },
  ),
  ShootingParam(code: PtpDevicePropCode.imageSize, label: '图像尺寸'),
  ShootingParam(
    code: PtpDevicePropCode.captureAreaCrop,
    label: '图像区域',
    enumLabels: {0: 'FX', 2: 'DX', 4: '1:1', 5: '16:9'},
  ),
  ShootingParam(
    code: PtpDevicePropCode.activePicCtrlItem,
    label: '优化校准',
    enumLabels: {
      1: '标准',
      2: '中性',
      3: '鲜艳',
      4: '单色',
      5: '人像',
      6: '风景',
      7: '平面',
      8: '自动',
      9: 'Flat Mono',
      10: 'Deep Tone Mono',
      11: 'Rich Tone Portrait',
      // 创意组 20 员(官方中文译名未定,先用 OpenZCine 原名)
      101: 'Dream',
      102: 'Morning',
      103: 'Pop',
      104: 'Sunday',
      105: 'Somber',
      106: 'Drama',
      107: 'Silence',
      108: 'Bleach',
      109: 'Melancholic',
      110: 'Pure',
      111: 'Denim',
      112: 'Toy',
      113: 'Sepia',
      114: 'Blue',
      115: 'Red',
      116: 'Pink',
      117: 'Charcoal',
      118: 'Graphite',
      119: 'Binary',
      120: 'Carbon',
    },
    format: _formatPicCtrl,
  ),
];

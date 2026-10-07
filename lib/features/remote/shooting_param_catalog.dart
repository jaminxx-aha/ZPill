/// 拍摄参数目录:拍摄页参数 chips 与编辑面板的唯一事实源。
///
/// 码表分两区:
/// - 0x50xx 标准区:Zf 真机 GetDeviceInfo 在册(2026-09-27)。
/// - 0xD0xx/0xD2xx 厂商区:候选码(OpenZCine/libgphoto2 值表),不在
///   Zf 在册表内 —— 在册表不是真相的全部(与 STA 9-op 小表同理),
///   相机可能照常应答;PropDesc 拒答时置空显示「--」,无害。
///
/// **写路径路由(2026-10-06,Z 系真机口径,源 = OpenZCine)**:静照
/// ISO/快门的标准码 0x500F/0x500D **只读不可写** —— Z 机身写 ISO 走
/// 0xD0B4(u32,值 = ISO 数)、写快门走 0xD100(u32 分数打包
/// num<<16|den)。**值回读同理**(2026-10-06 真机反馈「改了不同步」
/// 根因):标准码不跟厂商写 —— ISO 值读 0xD0B5(有效 ISO,Auto ISO
/// 时 = 机身当前应用值)、快门读写全走 0xD100(OpenZCine 轮询同款,
/// 其明确弃用 0x500D:名义单位 0.0001s 连 1/8000s 都无法整表,精度
/// 差)。快门取值域由目录标准档表([_kShutterPickValues])直供打包值,
/// 不再依赖 0x500D 枚举。曝光模式 0x500E 由机顶转盘拥有,遥控不可改
/// (只读展示)。真机核对。
///
/// **拨盘拥有参数([ShootingParam.dialOwned],影控台同款语义)**:
/// 快门等受机身物理拨盘控制,调节前需「APP 接管控制」(0x90C2 remote
/// 模式,机身拨盘锁定)—— 拍摄页弹确认后启用接管再开放编辑。
///
/// 枚举值标签:尼康方言值表(源 = OpenZCine PTPCameraPropertyDecoders,
/// 其又源出 libgphoto2 config.c;**全部标 verify-on-HW,Zf 待真机核对**)。
/// 表外值回退格式化/「值 N」,回读真机后如有出入只改标签表。
/// 优化校准的创意组(101-120)/自定义(201-209)/云(301-309)按段格式化。
library;

import '../../core/ptp/device_prop.dart';
import '../../core/ptp/operation_codes.dart';

/// 单个拍摄参数:属性码 + 中文名 + 值展示规则 + 读写路径路由。
final class ShootingParam {
  const ShootingParam({
    required this.code,
    required this.label,
    this.enumLabels = const {},
    this.format,
    this.prominent = false,
    this.readCode,
    this.writeCode,
    this.writeType,
    this.writeConvert,
    this.pickValues,
    this.dialOwned = false,
    this.readOnly = false,
  });

  /// PTP DevicePropCode(0x5004/0x5005/…)—— 展示键与 PropDesc 来源。
  final int code;

  /// 中文参数名(芯片标签)。
  final String label;

  /// 枚举值 → 中文标签;键外的值回退 [format] / 「值 N」。
  final Map<int, String> enumLabels;

  /// 数值格式化(光圈/快门/ISO/EV/色温/优化校准段)。
  final String Function(int v)? format;

  /// 曝光三要素(大号芯片行);其余进参数横滚行小芯片。
  final bool prominent;

  /// 值回读属性码:缺省同 [code];厂商写路由的参数标准码不跟写 ——
  /// ISO 读 0xD0B5(有效 ISO)/ 快门读 0xD100(打包分数)。
  final int? readCode;

  /// 写路径属性码:缺省同 [code];Z 系 ISO/快门的标准码只读,
  /// 写走厂商码(0xD0B4/0xD100)。
  final int? writeCode;

  /// 写数据类型:缺省用相机 PropDesc 自报类型;写码与读码类型不同时
  /// 显式指定(如 ISO:读码 u32 / 写码 u32,标准码才是 u16)。
  final PtpDataType? writeType;

  /// 写值换算:面板值 → 写码值;null 返回值 = 无法换算,拒绝发送
  /// (宁失败不错值)。快门面板值已是打包分数,无需换算。
  final int? Function(int v)? writeConvert;

  /// 取值域直供表(缺省用相机 PropDesc 枚举/范围):快门用目录标准档
  /// 打包值 —— 0x500D 枚举单位存疑弃用(见库注)。
  final List<int>? pickValues;

  /// 受机身物理拨盘控制的参数(快门等):调节前弹「APP 接管控制」
  /// 确认(0x90C2 remote 模式,影控台同款;接管期间机身拨盘锁定)。
  final bool dialOwned;

  /// 机身物理件拥有、接管也不开放的参数(模式转盘):遥控只读。
  final bool readOnly;

  /// 当前值展示:null = 未读;枚举表外 → 格式化 → 原始数字。
  String display(int? value) {
    if (value == null) {
      return '--';
    }
    return enumLabels[value] ?? format?.call(value) ?? '值 $value';
  }
}

/// 目录码 → 参数(写路由/只读判定用)。
final shootingParamByCode = <int, ShootingParam>{
  for (final p in kShootingParams) p.code: p,
};

/// 光圈:f 值 ×100(ISO 15740 定点,Zf 实际布局待真机核对)。
String _formatFNumber(int v) => 'f/${(v / 100).toStringAsFixed(1)}';

String _formatIso(int v) => 'ISO $v';

/// EV:千分之一档(ISO 15740),一位小数带符号。
String _formatEv(int v) {
  final ev = v / 1000;
  final s = ev.toStringAsFixed(1);
  return ev > 0 ? '+$s' : s;
}

/// 快门(0xD100 打包分数)展示:哨兵 Bulb/X 同步/Time;分数
/// num<<16|den → 「1/Ns」/「Ns」/「n/ds」(OpenZCine stillShutterLabel
/// 同款口径)。
String _formatShutterRaw(int raw) {
  switch (raw) {
    case 0xFFFFFFFF:
      return 'Bulb';
    case 0xFFFFFFFE:
      return 'X 同步';
    case 0xFFFFFFFD:
      return 'Time';
  }
  final n = (raw >> 16) & 0xFFFF;
  final d = raw & 0xFFFF;
  if (n <= 0 || d <= 0) return '--';
  if (d == 1) return '${n}s';
  if (n == 1) return '1/${d}s';
  return '$n/${d}s';
}

/// 尼康标准快门档(分子, 分母;1/8000s … 30s)。0x500D 名义单位
/// 0.0001s 连 1/8000s 都无法整表(OpenZCine 弃用之),快门读写与取值
/// 域全走 0xD100 打包分数,不再做 µs 往返换算。
const _shutterStops = <(int, int)>[
  (1, 8000), (1, 6400), (1, 5000), (1, 4000), (1, 3200), (1, 2500),
  (1, 2000), (1, 1600), (1, 1250), (1, 1000), (1, 800), (1, 640),
  (1, 500), (1, 400), (1, 320), (1, 250), (1, 200), (1, 160),
  (1, 125), (1, 100), (1, 80), (1, 60), (1, 50), (1, 40),
  (1, 30), (1, 25), (1, 20), (1, 15), (1, 13), (1, 10),
  (1, 8), (1, 6), (1, 5), (1, 4), (1, 3), (2, 5), (1, 2),
  (3, 5), (4, 5), (1, 1), (13, 10), (8, 5), (2, 1), (5, 2),
  (3, 1), (4, 1), (5, 1), (6, 1), (8, 1), (10, 1), (13, 1),
  (15, 1), (20, 1), (25, 1), (30, 1),
];

/// 快门取值域直供表:标准档打包值(num<<16|den,快→慢)+ Bulb 哨兵
/// (OpenZCine 选择器同款;Time/X 同步是机顶拨盘位,不入选)。
/// (const 列表不支持 for 元素、记录解构 for 会崩 analyzer —— 用 $1/$2
/// 取值的惰性 final。)
final _kShutterPickValues = <int>[
  for (final nd in _shutterStops) (nd.$1 << 16) | nd.$2,
  0xFFFFFFFF, // Bulb
];

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
/// (final 非 const:快门条目携带惰性计算的取值域直供表。)
final kShootingParams = <ShootingParam>[
  // 曝光模式:尼康方言(libgphoto2 exposure_program_modes 候选表;
  // ISO 标准表 2=自动/5=程序 对尼康是错的 —— 2=P、3=A、4=S)。
  // dialOwned:机顶模式转盘物理拥有 —— 遥控修改需 APP 接管(0x90C2
  // remote 模式锁定转盘后写入;OpenZCine 有同款 0x500E u16 标准写路径,
  // verify-on-HW)。场景段(0x801x)写入相机可能拒,以应答为准。
  ShootingParam(
    code: PtpDevicePropCode.exposureProgramMode,
    label: '模式',
    dialOwned: true,
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
  // 光圈:f 值 ×100(ISO 15740 定点,Zf 实际布局待真机核对)。
  // dialOwned:指令拨盘拥有(A/M 档的主拨盘参数)—— 接管后可写
  //(2026-10-06 真机:ISO 写 0x200F 实证拨盘级参数需接管,光圈同类)。
  ShootingParam(
      code: PtpDevicePropCode.fNumber,
      label: '光圈',
      format: _formatFNumber,
      prominent: true,
      dialOwned: true),
  // 快门:读写全走 0xD100(u32 分数打包 num<<16|den,哨兵 Bulb/X 同步/
  // Time)—— 标准码 0x500D 只读且单位存疑(名义 0.0001s 连 1/8000s
  // 都无法整表,OpenZCine 弃用),取值域 = 目录标准档打包表。dialOwned:
  // 机顶快门拨盘拥有,调节前弹「APP 接管控制」确认(0x90C2 remote 模式,
  // 影控台同款)。
  ShootingParam(
      code: PtpDevicePropCode.exposureTime,
      label: '快门',
      format: _formatShutterRaw,
      prominent: true,
      readCode: PtpDevicePropCode.stillShutterSpeed,
      writeCode: PtpDevicePropCode.stillShutterSpeed,
      writeType: PtpDataType.uint32,
      pickValues: _kShutterPickValues,
      dialOwned: true),
  // ISO:值读走 0xD0B5(有效 ISO,Auto ISO 时 = 机身当前应用值;标准码
  // 0x500F 不跟厂商写,真机「改了不同步」根因)/ 写 0xD0B4(u32,值 =
  // ISO 数);取值域仍用 0x500F PropDesc 相机自报枚举。dialOwned:机身
  // 上 ISO 由按键+指令拨盘调整(拨盘级)—— 接管后可写(2026-10-06
  // 真机:0xD0B4 写 0x200F,同快门/模式的拨盘语义)。
  ShootingParam(
      code: PtpDevicePropCode.exposureIndex,
      label: 'ISO',
      format: _formatIso,
      prominent: true,
      dialOwned: true,
      readCode: PtpDevicePropCode.isoControlSensitivity,
      writeCode: PtpDevicePropCode.exposureIndexEx,
      writeType: PtpDataType.uint32),
  ShootingParam(
      code: PtpDevicePropCode.exposureBiasCompensation,
      label: 'EV',
      format: _formatEv),
  // 白平衡:尼康方言候选表(2=自动、4=直射阳光…;ISO 标准表 1=手动
  // 对尼康不成立 —— 表外值裸显)。0x8012 = 色温档:WB 处于该档时
  // 0xD01E 的开尔文值才生效(见色温条目)。
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
  // 色温 0xD01E(u16,2500-10000K 连续值;OpenZCine WhiteBalanceKelvin
  // Policy)。**只在 WB=色温档(0x8012)时生效** —— 控制器写入前自动
  // 先切 WB 模式(真机「改了没效果」根因)。
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
  // 测光:尼康方言值表(OpenZCine exposureMetering;ISO 标准表 2=中央
  // 3=点 对尼康是错的 —— 3=矩阵、4=点)。
  ShootingParam(
    code: PtpDevicePropCode.exposureMeteringMode,
    label: '测光',
    enumLabels: {
      2: '中央重点',
      3: '矩阵',
      4: '点测光',
      0x8010: '高光',
    },
  ),
  // 对焦模式 0xD061(u8;静照权威源,单一芯片 —— 0x500A 是只读镜像已
  // 移出,0x801x 值空间与这里完全不同):pickValues 直供,厂商码
  // PropDesc 拒答时面板照常可调(0=AF-S/1=AF-C/4=MF/5=AF-A,OpenZCine
  // stillFocusModeD061 同表)。
  ShootingParam(
    code: PtpDevicePropCode.stillFocusMode,
    label: '对焦模式',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 4, 5],
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
  // ---- 厂商候选区(0xD0xx/0xD2xx;0xD05D AF 区域 2026-10-07 USB 实证
  // 在册可读写,其余不在 Zf 在册表,拒答显示「--」)----
  // NEF(RAW)记录压缩:一代机身用 1/2,现役机身 0/3/4。pickValues 直供
  // + 显式 u8(厂商码 PropDesc 拒答时类型会错落到 u16 默认,写入无效)。
  ShootingParam(
    code: PtpDevicePropCode.rawCompressionType,
    label: 'RAW 压缩',
    writeType: PtpDataType.uint8,
    pickValues: [0, 3, 4],
    enumLabels: {
      0: '无损压缩',
      1: '压缩(旧型)',
      2: '未压缩',
      3: '高效率★',
      4: '高效率',
    },
  ),
  // 图像尺寸 0x5003:**STR 型**(OpenZCine stringFromPTPStringData),
  // int 面板体系外 —— 移出目录(STR 支持留抓包项,TODO §二)。
  // 图像区域 0xD030(u8):同 RAW 压缩,pickValues + 显式 u8。
  ShootingParam(
    code: PtpDevicePropCode.captureAreaCrop,
    label: '图像区域',
    writeType: PtpDataType.uint8,
    pickValues: [0, 2, 4, 5],
    enumLabels: {0: 'FX', 2: 'DX', 4: '1:1', 5: '16:9'},
  ),
  // AF 区域模式 0xD05D(u16):**取值域走相机 Desc FORM**(勿 pickValues
  // 直供 —— OpenZCine 表与 Zf 两套人马)。Zf FORM 七值形状实证
  // (2026-10-07 USB,框 w×h 为 whole-size 空间):0x8010 单点 293×316 /
  // 0x8011 自动(无固定框,subjectActive 置位)/ 0x8017 精确 163×174 /
  // 0x8018 宽S 815×884 / 0x8019 宽L 1859×1452 / 0x801E 宽C1 横带
  // 5513×884 / 0x801F 宽C2 竖条 815×3724 —— 无 动态区域/3D 追踪。
  // 0x8010/0x8011/0x8017 形状定案;宽 S/L/C1/C2 按框尺寸/形状推断,
  // 机身菜单核对后定稿。竖条/横带模式框高度饱和,触控对焦 Y 轴不动
  // 属预期 —— 面板可在切换模式时提示(待做)。STA 无线侧在册性待核。
  ShootingParam(
    code: PtpDevicePropCode.stillFocusMeteringMode,
    label: 'AF 区域',
    writeType: PtpDataType.uint16,
    enumLabels: {
      0x8010: '单点',
      0x8011: '自动',
      0x8017: '精确',
      0x8018: '宽S',
      0x8019: '宽L',
      0x801E: '宽C1',
      0x801F: '宽C2',
    },
  ),
  // ---- Ex 扩展属性码(0x0001_xxxx,> u16;读写自动走 Gen-3 Ex ops
  // 0x943B/0x943C,见 PtpSession.getDevicePropValue 路由)----
  // 主体检测 AF(0x0001D006,u8;OpenZCine movieAFSubject 表 —— 标的
  // 是 movie 属性,静照在册性待真机核对)。pickValues 直供。
  ShootingParam(
    code: 0x0001D006,
    label: '主体检测',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 2, 3, 4, 5, 6],
    enumLabels: {
      0: '关闭',
      1: '自动',
      2: '人',
      3: '动物',
      4: '车辆',
      5: '鸟',
      6: '飞机',
    },
  ),
  // 色调模式(0x0001D01C,u8;OpenZCine:2 = HLG,其余 SDR)。此前因
  // 超出 u16 属性码位宽不敢编码(截断会静默写错值),Ex ops 落地后
  // 解锁。待真机核对值域。
  ShootingParam(
    code: 0x0001D01C,
    label: '色调',
    writeType: PtpDataType.uint8,
    pickValues: [1, 2],
    enumLabels: {1: 'SDR', 2: 'HLG'},
  ),
  // 优化校准 0xD200(u16):pickValues 直供内置组(1-11),创意组/云组
  // 仍可读显示(段位格式化);厂商码 PropDesc 拒答时面板照常可调。
  ShootingParam(
    code: PtpDevicePropCode.activePicCtrlItem,
    label: '优化校准',
    pickValues: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
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

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
import '../../l10n/message.dart';

/// 0xD061 对焦模式的 MF 值集(尼康方言全表:0=AF-S/1=AF-C/2=AF-F/
/// 3=MF(固定)/4=MF(选择)/5=AF-A;libgphoto2 config.c,nico Z fc 实证
/// 两 MF 态同拦)。机身在任一 MF 态时 AF 马达脱开,远程对焦控制
/// (0x90C1/0x9205/0x9204)全部无效、只有镜头对焦环能动焦 ——
/// RemoteController 据此门控对焦域。多机型口径:值 3 在 Zf 取值域外、
/// 其余 Z 机身可能回,门控按全方言集判定(fail-open 只对未知值)。
const kStillFocusModeMfValues = {3, 4};

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
    this.picksAuthoritative = false,
    this.readOnly = false,
    this.videoOnly = false,
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

  /// 目录取值域表压过相机 PropDesc(pickValues 权威):描述层高估
  /// 硬件域时用 —— EV 0x5010 相机报范围 ±5000,硬件 EV 拨盘只 ±3
  /// (2026-10-17 用户真机比对)。
  final bool picksAuthoritative;

  /// 机身物理件拥有、接管也不开放的参数(模式转盘):遥控只读。
  final bool readOnly;

  /// 视频档专属参数(拨杆视频档生效;只在 [CaptureMode.video] 刷/显,
  /// 照片档不占面板)。官方 §6.5.3/§6.5.12 视频拍摄菜单族。
  final bool videoOnly;

  /// 当前值展示:null = 未读;枚举表外 → 格式化 → 裸值(语言中性,
  /// 与 ISO 裸值同款口径;2026-10-16 前「值 N」中文兜底在 EN 直通)。
  String display(int? value) {
    if (value == null) {
      return '--';
    }
    return enumLabels[value] ?? format?.call(value) ?? '$value';
  }
}

/// 目录码 → 参数(写路由/只读判定/事件刷新过滤用):静照 + 视频两表
/// 合并(码空间不相交)。
final shootingParamByCode = <int, ShootingParam>{
  for (final p in kShootingParams) p.code: p,
  for (final p in kVideoShootingParams) p.code: p,
};

/// 光圈:f 值 ×100(ISO 15740 定点,Zf 实际布局待真机核对)。
String _formatFNumber(int v) => 'f/${(v / 100).toStringAsFixed(1)}';

/// ISO:裸数值 —— 标签随行展示(2026-10-08 竖屏内联读出行起,值不再
/// 内嵌「ISO 」前缀,否则与标签拼成「ISO ISO 200」)。
String _formatIso(int v) => '$v';

/// EV:千分之一档(ISO 15740),一位小数带符号。
String _formatEv(int v) {
  final ev = v / 1000;
  final s = ev.toStringAsFixed(1);
  return ev > 0 ? '+$s' : s;
}

/// 快门(0xD100 打包分数)展示:哨兵 B 门/X 同步/T 门;分数
/// num<<16|den → 「1/Ns」/「Ns」/「n/ds」(OpenZCine stillShutterLabel
/// 同款口径)。哨兵串原文即 t() 键(中文显「B 门」,英文经 en_catalog
/// 回 'Bulb')。
String _formatShutterRaw(int raw) {
  switch (raw) {
    case 0xFFFFFFFF:
      return 'param.bulb';
    case 0xFFFFFFFE:
      return 'param.xSync';
    case 0xFFFFFFFD:
      return 'param.time';
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
/// (OpenZCine 选择器同款;X 同步/Time 仍是机顶拨盘位不入选 —— T 门
/// 0xFFFFFFFD 2026-10-17 真机定案:0xD100 写入合法收下,但 0x9207
/// 拍照路径官方规格明文拒绝(Invalid_Status = "The shutter speed is
/// set to Time",§6.2.4.1),能选不能拍,不进表)。
/// (const 列表不支持 for 元素、记录解构 for 会崩 analyzer —— 用 $1/$2
/// 取值的惰性 final。)
final _kShutterPickValues = <int>[
  for (final nd in _shutterStops) (nd.$1 << 16) | nd.$2,
  0xFFFFFFFF, // Bulb
];

/// EV 取值域直供表(0x5010):±3 EV、1/3 步,值 = EV×1000(规格
/// §6.5.1.13 值域 ±5 是全规格泛表,Zf 物理 EV 拨盘只 ±3,描述层
/// 报的范围域 -5000..+5000 高于硬件 —— 目录表压过相机域
/// [ShootingParam.picksAuthoritative],2026-10-17 用户真机比对:
/// 相机只有 -3..+3,app 滑条出到 ±5)。
final _kEvPickValues = <int>[
  -3000, -2666, -2333, -2000, -1666, -1333, -1000, -666, -333, 0, //
  333, 666, 1000, 1333, 1666, 2000, 2333, 2666, 3000,
];

/// 白平衡色温 0xD01E:开尔文裸值。
String _formatColorTemp(int v) => '${v}K';

/// 优化校准 0xD200 段位(101-120 创意组 / 201-209 自定义 / 301-309 云
/// 下载):键化走 displayParamValue(键+{n} 参,目录 display 无参通道;
/// 内置 1-11 与创意组成员走枚举表)。

/// 白平衡值空间标签(静照 0x5005 与视频 0xD23A 共用 —— 官方 §6.5.3.9:
/// 视频表复用静照表并加 0x8015「同照片设置」;尼康方言,verify-on-HW)。
const kWhiteBalanceLabels = <int, String>{
  2: 'param.auto',
  4: 'param.daylight',
  5: 'param.fluorescent',
  6: 'param.incandescent',
  7: 'param.flash',
  0x8010: 'param.cloudy',
  0x8011: 'param.shade',
  0x8012: 'param.colorTemp',
  0x8013: 'param.presetManual',
  0x8016: 'param.naturalAuto',
};

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
    label: 'param.mode',
    dialOwned: true,
    enumLabels: {
      1: 'param.modeM',
      2: 'param.modeP',
      3: 'param.modeA',
      4: 'param.modeS',
      0x8010: 'param.auto',
      0x8011: 'param.portrait',
      0x8012: 'param.landscape',
      0x8013: 'param.macro',
      0x8014: 'param.sports',
      0x8015: 'param.night',
      0x8016: 'param.nightPortrait',
      0x8017: 'param.children',
      0x8018: 'param.scene',
      0x8019: 'param.effects',
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
      label: 'info.aperture',
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
      // label 即 t() 键(zh「快门」/en 'Shutter';2026-10-16 EN 抽查:
      // 此前中文原文直通,是全目录唯一漏键的静态 label)。
      label: 'param.shutter',
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
  // EV(0x5010,i16,规格 §6.5.1.13 值 = EV×1000):**可写,门 = APP
  // 接管闩**(2026-10-17 用户真机:未闩 0x200F AccessDenied,与曝光
  // 模式 P/M 无关)。dialOwned 同快门/ISO —— Zf 有物理 EV 拨盘,面板
  // 先出接管区;取值域目录直供 ±3(picksAuthoritative,见
  // _kEvPickValues 注)。
  ShootingParam(
      code: PtpDevicePropCode.exposureBiasCompensation,
      label: 'EV',
      format: _formatEv,
      pickValues: _kEvPickValues,
      picksAuthoritative: true,
      dialOwned: true),
  // 白平衡:尼康方言候选表(2=自动、4=直射阳光…;ISO 标准表 1=手动
  // 对尼康不成立 —— 表外值裸显)。0x8012 = 色温档:WB 处于该档时
  // 0xD01E 的开尔文值才生效(见色温条目)。
  ShootingParam(
    code: PtpDevicePropCode.whiteBalance,
    label: 'param.wb',
    enumLabels: kWhiteBalanceLabels,
  ),
  // 色温 0xD01E(u16,2500-10000K 连续值;OpenZCine WhiteBalanceKelvin
  // Policy)。**只在 WB=色温档(0x8012)时生效** —— 控制器写入前自动
  // 先切 WB 模式(真机「改了没效果」根因)。
  ShootingParam(
      code: PtpDevicePropCode.wbColorTemp,
      label: 'param.colorTemp',
      format: _formatColorTemp),
  // 闪光:尼康方言候选表(默认「自动/前帘同步」不在表内,表外裸显)。
  ShootingParam(
    code: PtpDevicePropCode.flashMode,
    label: 'param.flash',
    enumLabels: {
      2: 'common.off',
      4: 'param.redEye',
      0x8010: 'param.fillFlash',
      0x8011: 'param.slowSync',
      0x8012: 'param.rearCurtain',
      0x8013: 'param.redEyeSlow',
    },
  ),
  // 测光:尼康方言值表(OpenZCine exposureMetering;ISO 标准表 2=中央
  // 3=点 对尼康是错的 —— 3=矩阵、4=点)。
  ShootingParam(
    code: PtpDevicePropCode.exposureMeteringMode,
    label: 'param.metering',
    enumLabels: {
      2: 'param.centerWeighted',
      3: 'param.matrix',
      4: 'param.spot',
      0x8010: 'param.highlight',
    },
  ),
  // 对焦模式 0xD061(u8;静照权威源,单一芯片 —— 0x500A 是只读镜像已
  // 移出,0x801x 值空间与这里完全不同):pickValues 直供,厂商码
  // PropDesc 拒答时面板照常可调(0=AF-S/1=AF-C/4=MF/5=AF-A,OpenZCine
  // stillFocusModeD061 同表)。**多机型**:全方言另有 2=AF-F/3=MF(固定)
  //(libgphoto2 config.c),标签表收录(读侧展示);pickValues 仍按 Zf
  // 取值域直供,其余机身 FORM 枚举优先、desc 拒答时 [0,1,4,5] 也能完成
  // AF↔MF 切换(3/4 两值等价 MF)。门控值集见 [kStillFocusModeMfValues]。
  ShootingParam(
    code: PtpDevicePropCode.stillFocusMode,
    label: 'param.focusMode',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 4, 5],
    enumLabels: {
      0: 'AF-S',
      1: 'AF-C',
      2: 'AF-F',
      3: 'MF',
      4: 'MF',
      5: 'AF-A',
    },
  ),
  // 释放:尼康方言全表(libgphoto2/OpenZCine StillDriveMode 候选;
  // ISO 标准表 2=连拍/3=间隔 对尼康不成立 —— C15-C120 为高速连拍档)。
  ShootingParam(
    code: PtpDevicePropCode.stillCaptureMode,
    label: 'param.release',
    enumLabels: {
      1: 'param.single',
      0x8010: 'param.burstLow',
      2: 'param.burstHigh',
      0x8019: 'param.burstHighPlus',
      0x8011: 'remote.selfTimer',
      0x8100: 'common.fast',
      0x810F: 'param.burstC15',
      0x811E: 'param.burstC30',
      0x813C: 'param.burstC60',
      0x8178: 'param.burstC120',
    },
  ),
  // 画质:尼康 14 值全表(★ = 画质优先/最优压缩档)。
  ShootingParam(
    code: PtpDevicePropCode.compressionSetting,
    label: 'param.quality',
    enumLabels: {
      0: 'param.jpegBasic',
      1: 'param.jpegBasicStar',
      2: 'param.jpegNormal',
      3: 'param.jpegNormalStar',
      4: 'param.jpegFine',
      5: 'param.jpegFineStar',
      6: 'TIFF',
      7: 'RAW',
      8: 'param.rawJpegBasic',
      9: 'param.rawJpegBasicStar',
      10: 'param.rawJpegNormal',
      11: 'param.rawJpegNormalStar',
      12: 'param.rawJpegFine',
      13: 'param.rawJpegFineStar',
    },
  ),
  // ---- 厂商候选区(0xD0xx/0xD2xx;0xD05D AF 区域 2026-10-07 USB 实证
  // 在册可读写,其余不在 Zf 在册表,拒答显示「--」)----
  // NEF(RAW)记录压缩:一代机身用 1/2,现役机身 0/3/4。pickValues 直供
  // + 显式 u8(厂商码 PropDesc 拒答时类型会错落到 u16 默认,写入无效)。
  ShootingParam(
    code: PtpDevicePropCode.rawCompressionType,
    label: 'param.rawCompression',
    writeType: PtpDataType.uint8,
    pickValues: [0, 3, 4],
    enumLabels: {
      0: 'param.lossless',
      1: 'param.compressedLegacy',
      2: 'param.uncompressed',
      3: 'param.heStar',
      4: 'param.he',
    },
  ),
  // 图像尺寸 0x5003:**STR 型**(OpenZCine stringFromPTPStringData),
  // int 面板体系外 —— 移出目录(STR 支持留抓包项,TODO §二)。
  // 图像区域 0xD030(u8):同 RAW 压缩,pickValues + 显式 u8。
  ShootingParam(
    code: PtpDevicePropCode.captureAreaCrop,
    label: 'param.imageArea',
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
  // 机身菜单核对后定稿。宽C1/C2 饱和轴触屏移框不动属预期 —— 提示
  // 已做(afAreaAxisHint:AF 面板常驻行 + 切换沿 notice)。STA 无线
  // 侧在册性待核。
  ShootingParam(
    code: PtpDevicePropCode.stillFocusMeteringMode,
    label: 'param.afArea',
    writeType: PtpDataType.uint16,
    enumLabels: {
      0x8010: 'param.singlePoint',
      0x8011: 'param.auto',
      0x8017: 'param.pinpoint',
      0x8018: 'param.wideS',
      0x8019: 'param.wideL',
      0x801E: 'param.wideC1',
      0x801F: 'param.wideC2',
    },
  ),
  // ---- Ex 扩展属性码(0x0001_xxxx,> u16;读写自动走 Gen-3 Ex ops
  // 0x943B/0x943C,见 PtpSession.getDevicePropValue 路由)----
  // 主体检测 AF(0x0001D006,u8;OpenZCine movieAFSubject 表 —— 标的
  // 是 movie 属性,静照在册性待真机核对)。pickValues 直供。
  ShootingParam(
    code: 0x0001D006,
    label: 'param.subjectDetection',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 2, 3, 4, 5, 6],
    enumLabels: {
      0: 'common.off',
      1: 'param.auto',
      2: 'param.people',
      3: 'param.animals',
      4: 'param.vehicles',
      5: 'param.birds',
      6: 'param.airplanes',
    },
  ),
  // 色调模式(0x0001D01C,u8)。静照真值域 = [0,2](OpenZCine 手册 ZR
  // 页:StillToneMode 0 SDR,2 HLG);Zf 的 FORM 却枚举 H.265 视频族
  // 整表 0/1/2(§6.5.3.3:0 SDR/1 N-Log/2 HLG)—— 1(N-Log)在静照
  // 不可写,写之 0x201C InvalidDevicePropValue(2026-10-16 真机;该码
  // 因此入册)。标签 1 = N-Log 照实显,面板列表跟随相机 FORM,点击被
  // 相机拒属域真值。
  ShootingParam(
    code: 0x0001D01C,
    label: 'param.toneMode',
    writeType: PtpDataType.uint8,
    pickValues: [0, 2],
    enumLabels: {0: 'SDR', 1: 'N-Log', 2: 'HLG'},
  ),
  // 优化校准 0xD200(u16):相机 FORM 枚举驱动(真机 46 项全在 FORM,
  // 静态表只有内置 11 项 —— pickValues 曾把 desc 读短路,值域被砍到
  // 11 项,2026-10-07 用户反馈「相机 46 个应用只有 11 个」根因)。
  // 自定义(201-209)/云(301-309)组的真名由 0x90CC 拉取
  // (RemoteController.picCtrlNames),静态标签只是占位。
  ShootingParam(
    code: PtpDevicePropCode.activePicCtrlItem,
    label: 'param.pictureControl',
    enumLabels: {
      1: 'param.standard',
      2: 'param.neutral',
      3: 'param.vivid',
      4: 'param.monochrome',
      5: 'param.portrait',
      6: 'param.landscape',
      7: 'param.flat',
      8: 'param.auto',
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
  ),
];

/// 视频参数族(2026-10-12 官方指令书 §6.5.3/§6.5.12 落地,「movie 参数族
/// 须真机探测」的差集收账):拨杆视频档生效,**只在 [CaptureMode.video]
/// 刷/显**(照片档零流量)。取值域一律相机 FORM 驱动 —— 枚举随帧率/
/// 镜头/N-Log 浮动(§6.5.12.2:快门枚举随帧率收口,120fps 最慢 1/125;
/// §6.5.3.8:N-Log 开时 ISO 范围收口),静态值表只标官方逐字确认过的值。
/// 0xD1FD TimeCodeOrigin 是 AUINT8 数组型(int 面板体系外,不入);
/// 0xD0A0 MovieRecordScreenSize u64(尺寸/帧率复合编码,待布局定案后入)。
/// 0x0001D006 主体检测静照/视频同码共用(§6.5.3.59 = §6.5.2.67),不重复。
final kVideoShootingParams = <ShootingParam>[
  // 视频曝光四件套(§6.5.12.1-3/§6.5.3.8):写入门 = 视频档 A/M(相机拒,
  // 0x200F → tile 锁标机制接)。
  ShootingParam(
    code: PtpDevicePropCode.movieFnumber,
    label: 'param.movieAperture',
    format: _formatFNumber,
    videoOnly: true,
  ),
  ShootingParam(
    code: PtpDevicePropCode.movieShutterSpeed,
    label: 'param.movieShutter',
    format: _formatShutterRaw,
    videoOnly: true,
  ),
  ShootingParam(
    code: PtpDevicePropCode.movieExposureIndex,
    label: 'param.movieIso',
    format: _formatIso,
    videoOnly: true,
  ),
  ShootingParam(
    code: PtpDevicePropCode.movieExposureBiasCompensation,
    label: 'param.movieEv',
    format: _formatEv,
    videoOnly: true,
  ),
  // 视频白平衡(u16):0x8015 = 同照片设置(官方默认值档,§6.5.3.9),
  // 其余复用静照 WB 值空间。
  ShootingParam(
    code: PtpDevicePropCode.movieWhiteBalance,
    label: 'param.movieWb',
    enumLabels: {0x8015: 'param.sameAsPhotos', ...kWhiteBalanceLabels},
    videoOnly: true,
  ),
  // N-Log 输出(u8 只读,§6.5.12.4 Get-only):LUT/log 路的读侧入口;
  // 值域收口(ISO 上限等)随它联动,FORM 驱动。
  ShootingParam(
    code: PtpDevicePropCode.movieLogOutput,
    label: 'N-Log',
    readOnly: true,
    enumLabels: {0: 'common.offShort', 1: 'common.on'},
    videoOnly: true,
  ),
  // 视频减震(u8,§6.5.3.62:双形态 —— 镜头防抖仅 Normal 档时 {0,1,100},
  // 全档时 {0,1,2,100};值域以 FORM 为准)。
  ShootingParam(
    code: PtpDevicePropCode.movieVibrationReduction,
    label: 'param.movieVr',
    writeType: PtpDataType.uint8,
    enumLabels: {0: 'common.offShort', 1: 'param.normal', 2: 'param.sports', 100: 'param.sameAsPhotos'},
    videoOnly: true,
  ),
  // 电子减震(u8 Range 0/1,§6.5.3.63;120p/升格/Hi-Res Zoom 时拒)。
  ShootingParam(
    code: PtpDevicePropCode.electronicVR,
    label: 'param.evr',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1],
    enumLabels: {0: 'common.offShort', 1: 'common.on'},
    videoOnly: true,
  ),
  // 时间码三件(u8,§6.5.3.69-72;0xD1FD 起源时间是数组型不入)。
  ShootingParam(
    code: PtpDevicePropCode.recordTimeCodes,
    label: 'param.timecode',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 2],
    enumLabels: {0: 'common.offShort', 1: 'common.on', 2: 'param.onHdmi'},
    videoOnly: true,
  ),
  ShootingParam(
    code: PtpDevicePropCode.timeCodeCountUpMethod,
    label: 'param.countUp',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1],
    enumLabels: {0: 'param.recRun', 1: 'param.freeRun'},
    videoOnly: true,
  ),
  ShootingParam(
    code: PtpDevicePropCode.timeCodeDropFrame,
    label: 'param.dropFrame',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1],
    enumLabels: {0: 'common.offShort', 1: 'common.on'},
    videoOnly: true,
  ),
  // 视频图像区域(u8:0=FX/2=DX,§6.5.3.5;静照 0xD030 同名异码,
  // 四值空间不通用)。
  ShootingParam(
    code: PtpDevicePropCode.movieCaptureAreaCrop,
    label: 'param.movieArea',
    writeType: PtpDataType.uint8,
    pickValues: [0, 2],
    enumLabels: {0: 'FX', 2: 'DX'},
    videoOnly: true,
  ),
  // H.265 10-bit(MOV)色调(u8 Ex 扩展码 0x0001D001,§6.5.3.3;
  // >0xFFFF 自动走 Ex ops)。
  ShootingParam(
    code: PtpDevicePropCode.movieH265ToneMode,
    label: 'param.h265Tone',
    writeType: PtpDataType.uint8,
    pickValues: [0, 1, 2],
    enumLabels: {0: 'SDR', 1: 'N-Log', 2: 'HLG'},
    videoOnly: true,
  ),
];

/// AF 区域宽C1/C2(0x801E 横带 5513×884 / 0x801F 竖条 815×3724,
/// whole-size 空间)框已顶满一条轴:触屏移框(0x9205)在饱和轴被机身
/// 钳位,「点了框不动」属相机行为非缺陷 —— AF 编辑面板常驻提示行与
/// 切换沿 notice(RemoteController.setParam)共用此文案。
L10nMessage? afAreaAxisHint(int? value) {
  if (value == 0x801E) return const (key: 'param.wideC1Hint', args: null);
  if (value == 0x801F) return const (key: 'param.wideC2Hint', args: null);
  return null;
}

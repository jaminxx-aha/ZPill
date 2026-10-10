/// 尼康 LiveViewObject(0x9428 GetLiveViewImageEx 数据相)帧头解析:
/// display-info header + JPEG。头里带**相机自己每帧报告**的状态 ——
/// 对焦框数组(真实尺寸/位置,随 AF 区域设置变化)、虚拟水平仪角度、
/// 机身录制态、持机旋转方向、声音电平、录制时间码。
///
/// 布局源 = OpenZCine PTPLiveViewObject(ZR/Z7 原始 dump 确认,MIT):
/// - **头只在 0x9428(Ex)的应答里** —— 老码 0x9203 的应答在 Zf 上
///   解析不出头(2026-10-07 真机反馈:水平仪回落手机/对焦框不出),
///   OpenZCine 全系(Gen-1/2/3)取帧只用 0x9428,无回退路径;
/// - 头是**大端**(与 PTP 容器的小端相反,读错方向框会跑出屏外);
/// - JPEG 长度 = 头内 BE u32 @12;AF 坐标系「whole size」= BE u16 @16/18
///   (如 6048×3400;0x9205 ChangeAfArea 的参数就在这个坐标系,不是 JPEG
///   像素);
/// - 头长三代机 1024B / 一代机 512B(以 SOI 位置判定),其余未知机身
///   在前 2KB 内扫 SOI 定头长(域读取一律以头长为界,宁缺不错);
/// - 声音电平 @824-827(L/R × 峰值保持/当前,各 0-14 段,与机身自家
///   屏同款分段表);
/// - 水平仪角度 @840/844/848,BE 有符号 16.16 定点(度 = 值/65536),
///   0xFFFFFFFF = 本帧不可靠;**一代头无这些域**(512B 截断,读不到即 null);
/// - 录制态 @828(0=取景,1=录制,机身侧自启的录制也能看到);
/// - 时间码 @831-835(显示开关 + 时/分/秒/帧各 1 字节);
/// - 旋转 @839(0=横/1=左转竖/2=右转竖/3=倒置)。
///
/// 守卫口径对齐 OpenZCine(其守卫曾在真机 dump 上验证):whole-size
/// 只查 >0(不限区间)、areaCount=0 仍读 1 槽、框数组可为空(空 ≠ 头
/// 无效)、水平仪/录制/旋转与对焦域互不连坐 —— 各域独立解析,读不到
/// 就是 null/false,宁缺不错。
library;

import 'dart:typed_data';

/// 单个 AF/主体检测框(whole-size 坐标系)。
final class LiveViewAfBox {
  const LiveViewAfBox({
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  final int centerX;
  final int centerY;
  final int width;
  final int height;
}

/// 相机报告的对焦结果(@42:2=合焦,1=未合焦,其余=未知)。
enum LiveViewFocusResult { unknown, notFocused, focused }

/// 相机虚拟水平仪角度(度;16.16 定点解出)。roll 规范口径 0–360°
/// 逆时针为正(0=水平),pitch = 前后倾,yaw = 持机轴倾。
final class LiveViewLevelAngles {
  const LiveViewLevelAngles(
      {required this.roll, required this.pitch, required this.yaw});

  final double roll;
  final double pitch;
  final double yaw;

  /// 0–360° 折算到 ±180°(359.5 → −0.5)。
  static double signedDegrees(double degrees) {
    final wrapped = degrees.remainder(360);
    final positive = wrapped < 0 ? wrapped + 360 : wrapped;
    return positive > 180 ? positive - 360 : positive;
  }

  double get signedRoll => signedDegrees(roll);
  double get signedPitch => signedDegrees(pitch);
}

/// 相机声音电平指示(@824-827:L/R × 峰值保持/当前,各 0-14 段 ——
/// 与机身自家屏同款分段表,0 = 静音)。相机侧已做电平动力学与峰值
/// 保持,取值直接上屏无需本地衰减。
final class LiveViewSound {
  const LiveViewSound({
    required this.peakLeft,
    required this.peakRight,
    required this.currentLeft,
    required this.currentRight,
  });

  /// 分段表上限(0…14 共 15 段);越界段值钳到它(防误报字节撑爆表)。
  static const int maxSegment = 14;

  /// 峰值保持段,左声道(0…14)。
  final int peakLeft;

  /// 峰值保持段,右声道(0…14)。
  final int peakRight;

  /// 当前电平段,左声道(0…14)。
  final int currentLeft;

  /// 当前电平段,右声道(0…14)。
  final int currentRight;
}

/// 录制时间码(@831-835:显示开关 + 时/分/秒/帧,各 1 字节)。on =
/// 机身「时间码显示」开着(相机自家屏同款语义 —— 用户在相机菜单里
/// 关掉它,监看端也不显示)。
final class LiveViewTimecode {
  const LiveViewTimecode({
    required this.on,
    required this.hour,
    required this.minute,
    required this.second,
    required this.frame,
  });

  final bool on;
  final int hour;
  final int minute;
  final int second;
  final int frame;

  /// 双位补零的 HH:MM:SS:FF(帧 = 录制帧号)。
  String get display =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')}:${frame.toString().padLeft(2, '0')}';
}

/// 一帧的 display-info 头(裸 JPEG / 定位不到头 → null)。
final class LiveViewHeader {
  const LiveViewHeader({
    required this.coordinateWidth,
    required this.coordinateHeight,
    required this.focusResult,
    required this.subjectDetectionActive,
    required this.trackingAFActive,
    required this.selectedBoxIndex,
    required this.boxes,
    required this.recording,
    required this.rotationRaw,
    required this.level,
    required this.sound,
    required this.timecode,
  });

  /// AF 框的坐标系宽高(whole size;框与 0x9205 参数共用)。
  final int coordinateWidth;
  final int coordinateHeight;
  final LiveViewFocusResult focusResult;
  final bool subjectDetectionActive;
  final bool trackingAFActive;
  final int? selectedBoxIndex;
  final List<LiveViewAfBox> boxes;

  /// 机身正在录制(@828;机身侧自己按的录制也如实)。
  final bool recording;

  /// 持机旋转(@839:0 横 / 1 左转竖 / 2 右转竖 / 3 倒置;未知值按 0)。
  final int rotationRaw;

  /// 相机虚拟水平仪(null = 头太短/本帧不可靠)。
  final LiveViewLevelAngles? level;

  /// 相机声音电平(null = 头太短,一代 512B 头无此域)。
  final LiveViewSound? sound;

  /// 录制时间码(null = 头太短;on=false = 机身时间码显示关)。
  final LiveViewTimecode? timecode;

  bool get isVertical => rotationRaw == 1 || rotationRaw == 2;
}

int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

bool _soiAt(Uint8List b, int o) =>
    o + 2 < b.length && b[o] == 0xFF && b[o + 1] == 0xD8 && b[o + 2] == 0xFF;

const int _headerLenGen3 = 1024;
const int _headerLenGen1 = 512;
const int _maxBoxes = 96;

/// 定位 display-info 头长:SOI 所在处即头结束(OpenZCine 同款以 SOI@512
/// 区分一代/三代;这里再多一道前 2KB 扫描兜未知机身)。返回 0 = 裸 JPEG
/// (无头),-1 = 定位不到。
int _detectHeaderLength(Uint8List object) {
  if (_soiAt(object, 0)) return 0;
  for (final candidate in const [_headerLenGen3, _headerLenGen1]) {
    if (_soiAt(object, candidate)) return candidate;
  }
  final bound = object.length < 2048 ? object.length - 2 : 2048;
  for (var i = 1; i + 2 < bound; i++) {
    if (object[i] == 0xFF && object[i + 1] == 0xD8 && object[i + 2] == 0xFF) {
      return i;
    }
  }
  return -1;
}

/// 解析帧头。头不是独立数据集 —— 它就是对象载荷的前缀;判定依据是
/// JPEG 的位置(头在 SOI 之前)。对焦域与 Gen-3 域(录制/旋转/水平仪)
/// 互不连坐:任一域读不到只影响它自己。
LiveViewHeader? parseLiveViewHeader(Uint8List object) {
  if (object.length < 56) return null;
  final headerLen = _detectHeaderLength(object);
  if (headerLen < 56) return null; // 裸 JPEG(0)或定位不到(-1)

  final coordW = _be16(object, 16);
  final coordH = _be16(object, 18);
  if (coordW <= 0 || coordH <= 0) return null;

  final focusResult = switch (object[42]) {
    2 => LiveViewFocusResult.focused,
    1 => LiveViewFocusResult.notFocused,
    _ => LiveViewFocusResult.unknown,
  };
  final subjectActive = object[43] == 1;
  final trackingAFActive = headerLen > 46 && object[46] != 0;
  final selectedIndex = object[45];

  // 槽位数 OpenZCine 口径:areaCount 至少按 1 读、至多 96;空槽
  //(零尺寸)丢弃;框数组允许为空(无 AF 状态 ≠ 头无效)。
  final areaCount = object[44];
  final slots =
      areaCount < 1 ? 1 : (areaCount > _maxBoxes ? _maxBoxes : areaCount);
  final boxes = <LiveViewAfBox>[];
  for (var i = 0; i < slots; i++) {
    final base = 48 + i * 8;
    if (base + 8 > headerLen) break;
    final w = _be16(object, base);
    final h = _be16(object, base + 2);
    if (w == 0 || h == 0) continue;
    boxes.add(LiveViewAfBox(
      centerX: _be16(object, base + 4),
      centerY: _be16(object, base + 6),
      width: w,
      height: h,
    ));
  }

  // Gen-3 域(头长 ≥852 才存在;一代 512B 头读不到 → 安全默认)。
  final recording = headerLen > 828 && object[828] == 1;
  final rotationRaw =
      headerLen > 839 ? (object[839] > 3 ? 0 : object[839]) : 0;

  // 声音电平(@824-827)与时间码(@831-835):同为 Gen-3 域,与对焦/
  // 水平仪互不连坐;段值越界钳 14(OpenZCine 同款防误报)。
  LiveViewSound? sound;
  if (headerLen >= 828) {
    int seg(int o) =>
        object[o] > LiveViewSound.maxSegment ? LiveViewSound.maxSegment : object[o];
    sound = LiveViewSound(
        peakLeft: seg(824),
        peakRight: seg(825),
        currentLeft: seg(826),
        currentRight: seg(827));
  }
  LiveViewTimecode? timecode;
  if (headerLen >= 836) {
    timecode = LiveViewTimecode(
      on: object[831] == 1,
      hour: object[832],
      minute: object[833],
      second: object[834],
      frame: object[835],
    );
  }

  LiveViewLevelAngles? level;
  if (headerLen >= 852) {
    double? angle(int o) {
      final raw = _be32(object, o);
      if (raw == 0xFFFFFFFF) return null; // 本帧不可靠
      // 有符号 16.16 → 度
      final v = raw >= 0x80000000 ? raw - 0x100000000 : raw;
      return v / 65536.0;
    }

    final roll = angle(840);
    if (roll != null) {
      level = LiveViewLevelAngles(
          roll: roll, pitch: angle(844) ?? 0, yaw: angle(848) ?? 0);
    }
  }

  final selected = subjectActive && selectedIndex < boxes.length
      ? selectedIndex
      : null;
  return LiveViewHeader(
    coordinateWidth: coordW,
    coordinateHeight: coordH,
    focusResult: focusResult,
    subjectDetectionActive: subjectActive,
    trackingAFActive: trackingAFActive,
    selectedBoxIndex: selected,
    boxes: boxes,
    recording: recording,
    rotationRaw: rotationRaw,
    level: level,
    sound: sound,
    timecode: timecode,
  );
}

/// 从 LiveViewObject 里剥出 JPEG:先按已知头长(1024/512)找 SOI,再前
/// 2KB 扫描(OpenZCine 同款);都找不到则原样返回(交给上层解码器报错,
/// 与既有 [PtpSession] SOI 嗅探的宽容语义一致)。
Uint8List extractLiveViewJpeg(Uint8List object) {
  if (_soiAt(object, 0)) return object;
  for (final candidate in const [_headerLenGen3, _headerLenGen1]) {
    if (_soiAt(object, candidate)) {
      return Uint8List.sublistView(object, candidate);
    }
  }
  final bound = object.length < 2048 ? object.length - 2 : 2048;
  for (var i = 0; i + 2 < bound; i++) {
    if (object[i] == 0xFF && object[i + 1] == 0xD8 && object[i + 2] == 0xFF) {
      return Uint8List.sublistView(object, i);
    }
  }
  return object;
}

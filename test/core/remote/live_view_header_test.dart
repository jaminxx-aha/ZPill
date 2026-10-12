import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/remote/live_view_header.dart';

/// 合成一帧 LiveViewObject:display-info 头(大端)+ SOI 开头的 JPEG 尾。
/// 头长 [headerLen](三代 1024 / 一代 512 / 任意奇数头验 SOI 定长),
/// JPEG 尾长 [tailLen](默认 8;加长可让总长越过 852 验证「域读取以
/// 头长为界,不读 JPEG 载荷」)。
Uint8List _frame({
  int headerLen = 1024,
  int coordW = 6048,
  int coordH = 3400,
  int jpegLen = 4096,
  int focusResult = 2,
  int subjectActive = 0,
  int areaCount = 1,
  int selectedIndex = 0,
  int trackingAF = 0,
  List<List<int>> boxes = const [
    [240, 240, 3024, 1700],
  ],
  int? recordingByte,
  int? rotationByte,
  double? levelRoll, // 度;null = 不写(0xFFFFFFFF 不可靠用 [unreliableLevel])
  double? levelPitch,
  bool unreliableLevel = false,
  ({int peakL, int peakR, int curL, int curR})? sound,
  ({bool on, int h, int m, int s, int f})? tc,
  int? countdown, // @836-837 BE u16 秒(null = 不写)
  int? spotWb, // @838(null = 不写)
  int? overheat, // @853(null = 不写)
  int tailLen = 8,
  bool poisonPastHeader = false, // 在头长之后、828+ 域写垃圾,验不越界读
}) {
  final b = Uint8List(headerLen + tailLen);
  void be16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  void be32(int o, int v) {
    b[o] = (v >> 24) & 0xFF;
    b[o + 1] = (v >> 16) & 0xFF;
    b[o + 2] = (v >> 8) & 0xFF;
    b[o + 3] = v & 0xFF;
  }

  be32(12, jpegLen);
  be16(16, coordW);
  be16(18, coordH);
  b[42] = focusResult;
  b[43] = subjectActive;
  b[44] = areaCount;
  b[45] = selectedIndex;
  b[46] = trackingAF;
  for (var i = 0; i < boxes.length && i < 96; i++) {
    final base = 48 + i * 8;
    be16(base, boxes[i][0]);
    be16(base + 2, boxes[i][1]);
    be16(base + 4, boxes[i][2]);
    be16(base + 6, boxes[i][3]);
  }
  if (recordingByte != null && b.length > 828) b[828] = recordingByte;
  if (rotationByte != null && b.length > 839) b[839] = rotationByte;
  if (sound != null && b.length >= 828) {
    b[824] = sound.peakL;
    b[825] = sound.peakR;
    b[826] = sound.curL;
    b[827] = sound.curR;
  }
  if (tc != null && b.length >= 836) {
    b[831] = tc.on ? 1 : 0;
    b[832] = tc.h;
    b[833] = tc.m;
    b[834] = tc.s;
    b[835] = tc.f;
  }
  if (countdown != null && b.length >= 838) be16(836, countdown);
  if (spotWb != null && b.length > 838) b[838] = spotWb;
  if (overheat != null && b.length > 853) b[853] = overheat;
  if (b.length >= 852) {
    if (unreliableLevel) {
      be32(840, 0xFFFFFFFF);
    } else if (levelRoll != null) {
      be32(840, (levelRoll * 65536).round().toUnsigned(32));
      be32(844, ((levelPitch ?? 0) * 65536).round().toUnsigned(32));
    }
  }
  if (poisonPastHeader) {
    // 头长之后全填非零垃圾(再盖回 SOI),并在 828+ 域写**陷阱值**:
    // 解析若越过头长读到它们,recording/rotation/level 必现非默认值。
    for (var i = headerLen; i < b.length; i++) {
      b[i] = 0xAB;
    }
    if (b.length > 828) b[828] = 1; // recording 陷阱
    if (b.length > 839) b[839] = 2; // rotation 陷阱
    if (b.length >= 828) {
      b[824] = 14; // 声音电平陷阱(非零段)
      b[825] = 14;
      b[826] = 14;
      b[827] = 14;
    }
    if (b.length >= 836) {
      b[831] = 1; // 时间码陷阱(on + 非零时码)
      b[832] = 9;
    }
    if (b.length >= 852) {
      b[840] = 0;
      b[841] = 0;
      b[842] = 0;
      b[843] = 0; // roll=0° → level 非 null 陷阱
    }
  }
  // JPEG 尾:SOI + 伪载荷
  b[headerLen] = 0xFF;
  b[headerLen + 1] = 0xD8;
  b[headerLen + 2] = 0xFF;
  return b;
}

void main() {
  test('三代头全量解析:坐标系/对焦结果/框数组/选中框', () {
    final h = parseLiveViewHeader(_frame(
      focusResult: 2,
      subjectActive: 1,
      areaCount: 2,
      selectedIndex: 1,
      trackingAF: 0,
      boxes: const [
        [240, 240, 3024, 1700], // AF 区域(单点小框)
        [900, 1200, 2100, 1900], // 人脸框(主体检测)
      ],
    ));
    expect(h, isNotNull);
    expect(h!.coordinateWidth, 6048);
    expect(h.coordinateHeight, 3400);
    expect(h.focusResult, LiveViewFocusResult.focused);
    expect(h.subjectDetectionActive, isTrue);
    expect(h.selectedBoxIndex, 1);
    expect(h.boxes.length, 2);
    expect(h.boxes[0].width, 240); // 真实尺寸,不是固定比例
    expect(h.boxes[1].centerX, 2100);
  });

  test('空槽丢弃、框数组可为空(空 ≠ 头无效,OpenZCine 口径)', () {
    final h = parseLiveViewHeader(_frame(
      areaCount: 3,
      boxes: const [
        [0, 0, 3024, 1700], // w=0 空槽
        [200, 200, 9999, 1700], // 越界框保留(OpenZCine 不按坐标系过滤)
        [160, 160, 1000, 1000],
      ],
    ));
    expect(h, isNotNull);
    expect(h!.boxes.length, 2);
    expect(h.boxes[0].width, 200);
    expect(h.boxes[1].width, 160);

    // 全空槽:头仍有效(坐标系/水平仪照常),只是没有框可画
    final empty = parseLiveViewHeader(_frame(
      areaCount: 2,
      boxes: const [
        [0, 0, 3024, 1700],
        [0, 0, 3024, 1700],
      ],
      levelRoll: -1.5,
    ));
    expect(empty, isNotNull);
    expect(empty!.boxes, isEmpty);
    expect(empty.coordinateWidth, 6048);
    expect(empty.level, isNotNull); // 对焦域空不连坐水平仪
  });

  test('areaCount=0 仍读 1 槽 / >96 截断(OpenZCine max(areaCount,1) 口径)', () {
    final zero = parseLiveViewHeader(_frame(areaCount: 0));
    expect(zero, isNotNull);
    expect(zero!.boxes.length, 1); // 默认 boxes[0] 有效

    final over = parseLiveViewHeader(_frame(areaCount: 97));
    expect(over, isNotNull); // 截断到 96 槽,不再整体拒收
    expect(over!.boxes.length, 1); // 只有 box[0] 写了值,其余空槽丢弃
  });

  test('水平仪 16.16 定点:正负角/0xFFFFFFFF 不可靠', () {
    final tilted = parseLiveViewHeader(_frame(levelRoll: -1.5, levelPitch: 3));
    expect(tilted!.level, isNotNull);
    expect(tilted.level!.roll, closeTo(-1.5, 1e-6));
    expect(tilted.level!.pitch, closeTo(3, 1e-6));

    final unreliable = parseLiveViewHeader(_frame(unreliableLevel: true));
    expect(unreliable!.level, isNull);
  });

  test('signedDegrees:0-360 折 ±180(359.5 → −0.5)', () {
    expect(LiveViewLevelAngles.signedDegrees(359.5), closeTo(-0.5, 1e-9));
    expect(LiveViewLevelAngles.signedDegrees(90), 90);
    expect(LiveViewLevelAngles.signedDegrees(-3), closeTo(-3, 1e-9));
  });

  test('录制态与旋转:828=1 → recording;839 越界值按 0', () {
    final rec = parseLiveViewHeader(_frame(
      recordingByte: 1,
      rotationByte: 7,
    ));
    expect(rec!.recording, isTrue);
    expect(rec.rotationRaw, 0); // 未知值兜底横拍
    expect(rec.isVertical, isFalse);

    final vertical = parseLiveViewHeader(_frame(recordingByte: 0, rotationByte: 2));
    expect(vertical!.recording, isFalse);
    expect(vertical.rotationRaw, 2);
    expect(vertical.isVertical, isTrue);
  });

  test('声音电平与时间码:824-827/831-835 解析,段值越界钳 14', () {
    final h = parseLiveViewHeader(_frame(
      sound: (peakL: 20, peakR: 9, curL: 7, curR: 0), // 20 越界 → 钳 14
      tc: (on: true, h: 1, m: 23, s: 45, f: 12),
    ));
    expect(h!.sound, isNotNull);
    expect(h.sound!.peakLeft, 14); // 越界钳制
    expect(h.sound!.peakRight, 9);
    expect(h.sound!.currentLeft, 7);
    expect(h.sound!.currentRight, 0);
    expect(h.timecode, isNotNull);
    expect(h.timecode!.on, isTrue);
    expect(h.timecode!.display, '01:23:45:12');

    // 机身「时间码显示」关:on=false,其余字节照读(域不连坐)。
    final off = parseLiveViewHeader(_frame(
      tc: (on: false, h: 2, m: 0, s: 0, f: 0),
    ));
    expect(off!.timecode!.on, isFalse);
    expect(off.timecode!.display, '02:00:00:00');
  });

  test('一代 512B 头:Gen-3 域读不到 → level null / recording false', () {
    final h = parseLiveViewHeader(_frame(headerLen: 512));
    expect(h, isNotNull);
    expect(h!.level, isNull);
    expect(h.recording, isFalse);
    expect(h.boxes.length, 1);
    expect(h.sound, isNull, reason: '声音电平同为 Gen-3 域');
    expect(h.timecode, isNull, reason: '时间码同为 Gen-3 域');
    expect(h.recordingCountdownSeconds, isNull, reason: '倒计时 @836 同为 Gen-3 域');
    expect(h.spotWbRaw, isNull, reason: '点测 WB @838 同为 Gen-3 域');
    expect(h.overheatRaw, isNull, reason: '过热 @853 同为 Gen-3 域');
  });

  test('倒计时/点测 WB/过热:836/838/853 解析,三域互不连坐', () {
    // 官方 §9.7.1:倒计时 3600 起秒倒数(过热 30s 起);点测 WB
    // 0 关/1-4 采集态;过热 0 正常/1-4 升温级。
    final h = parseLiveViewHeader(_frame(
      countdown: 30,
      spotWb: 2,
      overheat: 4,
    ));
    expect(h, isNotNull);
    expect(h!.recordingCountdownSeconds, 30);
    expect(h.spotWbRaw, 2);
    expect(h.overheatRaw, 4);

    // 域互不连坐:只写过热,倒计时/点测 WB 字节未写 = 0(0 是合法值:
    // 倒计时未起/点测关),头长足够即照读,不因邻域缺席而置 null。
    final onlyOverheat = parseLiveViewHeader(_frame(overheat: 1));
    expect(onlyOverheat!.recordingCountdownSeconds, 0);
    expect(onlyOverheat.spotWbRaw, 0);
    expect(onlyOverheat.overheatRaw, 1);
  });

  test('未知头长(SOI 位置定头长):域读取以头长为界,不读 JPEG 载荷', () {
    // 头 640B + 长 JPEG 尾(总长 > 852):828+ 落在 JPEG 里。
    // 域读取若不看头长,会把 JPEG 垃圾当录制/水平仪值。
    final h = parseLiveViewHeader(_frame(
      headerLen: 640,
      tailLen: 400,
      poisonPastHeader: true,
    ));
    expect(h, isNotNull);
    expect(h!.coordinateWidth, 6048);
    expect(h.boxes.length, 1); // 框数组在头内(@48 < 640)照常
    expect(h.recording, isFalse); // @828 在头外 → 不读(垃圾 0xAB ≠ 1 也不该读)
    expect(h.rotationRaw, 0);
    expect(h.level, isNull);
    expect(h.sound, isNull, reason: '@824-827 在头外 → 不读(陷阱 14 段)'
        '不该亮成电平)');
    expect(h.timecode, isNull, reason: '@831-835 在头外 → 不读(陷阱 on '
        '+ 9 时不该亮成时间码)');
    expect(h.recordingCountdownSeconds, isNull,
        reason: '@836-837 在头外 → 不读');
    expect(h.spotWbRaw, isNull, reason: '@838 在头外 → 不读');
    expect(h.overheatRaw, isNull, reason: '@853 在头外 → 不读');
  });

  test('小坐标系合法(whole-size 只查 >0,不限区间)', () {
    final h = parseLiveViewHeader(_frame(coordW: 640, coordH: 424));
    expect(h, isNotNull);
    expect(h!.coordinateWidth, 640);
    expect(h.coordinateHeight, 424);
  });

  test('非头载荷 → null(裸 JPEG / 全零垃圾 / 定位不到 SOI / 太短)', () {
    expect(parseLiveViewHeader(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])), isNull);
    expect(parseLiveViewHeader(Uint8List(1200)), isNull); // 全零:无 SOI 可定位
    // 头内全零但 SOI 在 1024:coordW=0 不像头 → null
    final zeroHeader = Uint8List(1024 + 8);
    zeroHeader[1024] = 0xFF;
    zeroHeader[1025] = 0xD8;
    zeroHeader[1026] = 0xFF;
    expect(parseLiveViewHeader(zeroHeader), isNull);
    expect(parseLiveViewHeader(Uint8List(40)), isNull); // 太短
  });

  test('extractLiveViewJpeg:已知头长直切/短头扫描/裸 JPEG 原样/无 SOI 原样', () {
    final gen3 = _frame();
    expect(extractLiveViewJpeg(gen3)[0], 0xFF);
    expect(extractLiveViewJpeg(gen3)[1], 0xD8);
    expect(extractLiveViewJpeg(gen3).length, 8);

    final gen1 = _frame(headerLen: 512);
    expect(extractLiveViewJpeg(gen1).length, 8);

    // 头长不是 1024/512:前 2KB 扫描兜底
    final odd = Uint8List(600 + 8);
    odd.setAll(0, _frame().sublist(0, 600)); // 复用头部字段
    odd[600] = 0xFF;
    odd[601] = 0xD8;
    odd[602] = 0xFF;
    expect(extractLiveViewJpeg(odd).length, 8);

    final bare = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
    expect(extractLiveViewJpeg(bare), same(bare));

    final noSoi = Uint8List(3000);
    expect(extractLiveViewJpeg(noSoi), same(noSoi));
  });
}

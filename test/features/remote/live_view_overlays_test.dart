import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/remote/live_view_header.dart';
import 'package:nikon_pill/features/remote/live_view_overlays.dart';

LiveViewHeader _header({
  bool recording = false,
  LiveViewSound? sound,
  LiveViewTimecode? timecode,
}) {
  return LiveViewHeader(
    coordinateWidth: 6048,
    coordinateHeight: 3400,
    focusResult: LiveViewFocusResult.unknown,
    subjectDetectionActive: false,
    trackingAFActive: false,
    selectedBoxIndex: null,
    boxes: const [],
    recording: recording,
    rotationRaw: 0,
    level: null,
    sound: sound,
    timecode: timecode,
  );
}

void main() {
  group('recordingReadoutOf:录制读出可见性(纯决策)', () {
    test('头缺失 / 取景未开启 → 全不显示(末帧保留期冻结读出不驻屏)', () {
      expect(recordingReadoutOf(null, liveViewActive: true),
          (timecode: false, meters: false));
      expect(
          recordingReadoutOf(
              _header(
                  sound: const LiveViewSound(
                      peakLeft: 9,
                      peakRight: 9,
                      currentLeft: 5,
                      currentRight: 5),
                  timecode: const LiveViewTimecode(
                      on: true, hour: 1, minute: 2, second: 3, frame: 4)),
              liveViewActive: false),
          (timecode: false, meters: false),
          reason: '取景已停,读出随 AF 框同规退场');
    });

    test('时间码随机身「时间码显示」开关;头无域不显示', () {
      expect(
          recordingReadoutOf(
              _header(
                  timecode: const LiveViewTimecode(
                      on: true, hour: 0, minute: 0, second: 0, frame: 0)),
              liveViewActive: true).timecode,
          isTrue);
      expect(
          recordingReadoutOf(
              _header(
                  timecode: const LiveViewTimecode(
                      on: false, hour: 1, minute: 2, second: 3, frame: 4)),
              liveViewActive: true).timecode,
          isFalse,
          reason: '机身菜单里关了时间码显示,监看端同随');
      expect(
          recordingReadoutOf(_header(), liveViewActive: true).timecode,
          isFalse,
          reason: 'Gen-1 短头无时间码域');
    });

    test('电平表:录制常驻(静音也显示);待机有电平才现身', () {
      final silent = const LiveViewSound(
          peakLeft: 0, peakRight: 0, currentLeft: 0, currentRight: 0);
      expect(
          recordingReadoutOf(_header(recording: true, sound: silent),
              liveViewActive: true).meters,
          isTrue,
          reason: '录制中静音正是要看见的');
      expect(
          recordingReadoutOf(_header(recording: false, sound: silent),
              liveViewActive: true).meters,
          isFalse,
          reason: '拍照取景恒零电平 → 不占屏');
      expect(
          recordingReadoutOf(
              _header(
                  sound: const LiveViewSound(
                      peakLeft: 0,
                      peakRight: 0,
                      currentLeft: 3,
                      currentRight: 0)),
              liveViewActive: true).meters,
          isTrue,
          reason: '影片待机机身报电平 → 开录前试音表');
      expect(recordingReadoutOf(_header(), liveViewActive: true).meters,
          isFalse,
          reason: 'Gen-1 短头无电平域');
    });
  });

  group('TimecodeView', () {
    testWidgets('等宽双位 HH:MM:SS:FF 上屏', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TimecodeView(
              timecode: LiveViewTimecode(
                  on: true, hour: 1, minute: 23, second: 45, frame: 12)),
        ),
      ));
      expect(find.text('01:23:45:12'), findsOneWidget);
    });
  });

  group('AudioMetersView', () {
    testWidgets('双声道行,各 15 段;L/R 标签在场', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AudioMetersView(
              sound: const LiveViewSound(
                  peakLeft: 9,
                  peakRight: 0,
                  currentLeft: 5,
                  currentRight: 2)),
        ),
      ));
      expect(find.text('L'), findsOneWidget);
      expect(find.text('R'), findsOneWidget);
      for (final label in const ['L', 'R']) {
        final row = tester.widget<Row>(find.byKey(ValueKey('meter-$label')));
        // 标签 + 15 段
        expect(row.children.length, 1 + LiveViewSound.maxSegment + 1);
      }
    });
  });

  group('audioSegmentColor:三区段色(纯函数)', () {
    test('绿 0-8 / 黄 9-11 / 红 12-14:current=13 顶亮段即红,10-12 见黄', () {
      // current=13 → 亮 0-12:顶段 12 红(OpenZCine 连续填充 -6dB 起红,
      // 计数语义下移一段 → 值 13 即红,不再须 14 满格)
      expect(audioSegmentColor(12, current: 13, peak: 13),
          const Color(0xFFFF5C52));
      // current=14(钳制满格)→ 12/13 两段红
      expect(audioSegmentColor(13, current: 14, peak: 14),
          const Color(0xFFFF5C52));
      // current=12 → 顶段 11 黄;current=10 → 顶段 9 黄(大声说话区)
      expect(audioSegmentColor(11, current: 12, peak: 12),
          const Color(0xFFF5D052));
      expect(audioSegmentColor(9, current: 10, peak: 10),
          const Color(0xFFF5D052));
      // current=9 → 顶段 8 绿(安全区,正常说话)
      expect(
          audioSegmentColor(8, current: 9, peak: 9), const Color(0xFF56EB84));
      expect(audioSegmentColor(0, current: 5, peak: 9),
          const Color(0xFF56EB84));
    });

    test('峰值保持标随区着色:红区红标/黄区黄标,绿区白标;未亮近隐;静音不亮标', () {
      // 峰值冲进红区:红标 = 刚才差点削波
      expect(audioSegmentColor(13, current: 5, peak: 13),
          const Color(0xFFFF5C52));
      expect(audioSegmentColor(12, current: 5, peak: 12),
          const Color(0xFFFF5C52));
      // 峰值在黄区:黄标
      expect(audioSegmentColor(10, current: 5, peak: 10),
          const Color(0xFFF5D052));
      // 峰值在绿区:白标(中性)
      expect(audioSegmentColor(8, current: 5, peak: 8),
          Colors.white.withValues(alpha: 0.6));
      // 未亮未标:近隐
      expect(audioSegmentColor(5, current: 5, peak: 9),
          Colors.white.withValues(alpha: 0.12));
      // 静音(0/0):全隐,不亮零段标
      expect(audioSegmentColor(0, current: 0, peak: 0),
          Colors.white.withValues(alpha: 0.12));
    });
  });
}

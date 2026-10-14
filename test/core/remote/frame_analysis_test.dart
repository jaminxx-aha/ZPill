import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/remote/frame_analysis.dart';
import 'package:nikon_pill/core/remote/frame_analyzer.dart';

/// 32×24 灰度渐变 JPEG(左黑右白),右端四分之一过曝。
Uint8List _gradientJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, x * 8, x * 8, x * 8, 255); // 0..248
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

Uint8List _whiteCornerJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      final white = x >= 24 && y < 8; // 右上角纯白
      image.setPixelRgba(x, y, white ? 255 : 20, white ? 255 : 20,
          white ? 255 : 20, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

final class _FakeFrames extends ChangeNotifier implements ValueListenable<Uint8List?> {
  @override
  Uint8List? value;
}

void main() {
  group('jpegSofSize(标记结构嗅探,不解码)', () {
    test('真实编码帧 → 32×24', () {
      expect(jpegSofSize(_gradientJpeg()), (width: 32, height: 24));
    });

    test('手拼段链:跳过 APP0 读 SOF0 宽高', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0(空段)
        0xFF, 0xC0, 0x00, 0x0B, 0x08, // SOF0:段长 11、精度 8
        0x00, 0x18, // 高 24
        0x00, 0x20, // 宽 32
        0x01, 0x00, 0x00, 0x00, // 1 分量占位
      ]);
      expect(jpegSofSize(jpeg), (width: 32, height: 24));
    });

    test('DHT(0xC4)不误判为 SOF;SOF2(渐进式)照常解析', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xC4, 0x00, 0x04, 0x00, 0x00, // DHT(空段,C0..CF 排除项)
        0xFF, 0xC2, 0x00, 0x0B, 0x08, // SOF2:渐进式
        0x00, 0x0C, // 高 12
        0x00, 0x10, // 宽 16
        0x01, 0x00, 0x00, 0x00,
      ]);
      expect(jpegSofSize(jpeg), (width: 16, height: 12));
    });

    test('非 JPEG / 空 / SOI+EOI 无 SOF → null', () {
      expect(jpegSofSize(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(jpegSofSize(Uint8List(0)), isNull);
      expect(
          jpegSofSize(
              Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])), // 只有起止标记
          isNull);
    });
  });

  group('analyzeJpegFrame', () {
    test('渐变帧:直方图铺开 + 无过曝', () async {
      final a = analyzeJpegFrame(_gradientJpeg(), maskCols: 8, maskRows: 6);
      expect(a, isNotNull);
      expect(a!.width, 32);
      expect(a.height, 24);
      final nonZero = a.lumaHistogram.where((v) => v > 0).length;
      expect(nonZero, greaterThan(4), reason: '渐变应铺开多桶');
      expect(a.hasOverexposure, isFalse, reason: '最高采样 luma≈248 < 250');
    });

    test('右上白角:掩码命中右上格,不误伤左下', () async {
      final a = analyzeJpegFrame(_whiteCornerJpeg(),
          maskCols: 8, maskRows: 6, lumaThreshold: 250);
      expect(a, isNotNull);
      // JPEG 压缩可能把边缘值略压低:右上格必须命中,左下必须不命中
      expect(a!.overexposedMask[0 * 8 + 7], 1, reason: '右上格过曝');
      expect(a.overexposedMask[5 * 8 + 0], 0, reason: '左下格是暗部');
      expect(a.hasOverexposure, isTrue);
    });

    test('非 JPEG 字节:返回 null 不抛', () {
      expect(analyzeJpegFrame(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(analyzeJpegFrame(Uint8List(0)), isNull);
    });

    test('normalizedHistogram:最大桶 = 1.0', () {
      final a = analyzeJpegFrame(_gradientJpeg(), maskCols: 8, maskRows: 6);
      final n = a!.normalizedHistogram;
      expect(n.reduce((x, y) => x > y ? x : y), 1.0);
    });

    test('伪色:渐变帧铺满多带,暗端/亮端带不同;带索引与边界表一致', () {
      final a = analyzeJpegFrame(_gradientJpeg(), maskCols: 8, maskRows: 6);
      final bands = a!.falseColorCells.toSet();
      expect(bands.length, greaterThan(2), reason: '渐变应跨多个亮度带');
      // 带分类与边界表对齐
      expect(FrameAnalysis.falseColorBandOf(0), 0);
      expect(FrameAnalysis.falseColorBandOf(15), 0);
      expect(FrameAnalysis.falseColorBandOf(16), 1);
      expect(FrameAnalysis.falseColorBandOf(249), 5);
      expect(FrameAnalysis.falseColorBandOf(250), 6);
    });

    test('对焦峰值:白角帧右上有强边缘,纯色帧无', () {
      final corner = analyzeJpegFrame(_whiteCornerJpeg(),
          maskCols: 8, maskRows: 6, peakingCols: 16, peakingRows: 12);
      expect(corner!.hasPeaking, isTrue, reason: '黑底到白角的陡变是强边缘');
      // 渐变帧相邻格差远低于阈值:无峰值
      final gradient =
          analyzeJpegFrame(_gradientJpeg(), maskCols: 8, maskRows: 6);
      expect(gradient!.hasPeaking, isFalse);
    });

    test('峰值灵敏度阈值:参数改档产生不同掩码(24/40/64 = 低/中/高档)', () {
      // 渐变帧按 8 列峰格采样,相邻格均值差恰 32(0..248 渐变 / 4px 格):
      // 低于中档、高于低档 —— 三档在此帧上分出三种结果。
      FrameAnalysis grad(int threshold) => analyzeJpegFrame(_gradientJpeg(),
          maskCols: 8,
          maskRows: 6,
          peakingCols: 8,
          peakingRows: 6,
          peakingThreshold: threshold)!;
      expect(
          analyzeJpegFrame(_gradientJpeg(),
                  maskCols: 8, maskRows: 6, peakingCols: 8, peakingRows: 6)!
              .hasPeaking,
          isFalse,
          reason: '缺省阈值 = 中档 40(旧行为不变)');
      expect(grad(40).hasPeaking, isFalse, reason: '32 < 40:中档不圈渐变');
      expect(grad(64).hasPeaking, isFalse, reason: '高档只圈最陡边缘');
      final low = grad(24);
      expect(low.hasPeaking, isTrue, reason: '32 ≥ 24:低档连渐变也圈');
      // 每行第 0..6 列右向邻格差 32 入掩码(末列无右邻、竖向差 0 不入)
      expect(low.peakingMask.where((c) => c == 1).length, 7 * 6);
      // 白角陡变(格均值差 ~235)三档全命中:高档压掉的是渐变级弱边缘
      for (final t in const [24, 40, 64]) {
        expect(
            analyzeJpegFrame(_whiteCornerJpeg(),
                    maskCols: 8,
                    maskRows: 6,
                    peakingCols: 8,
                    peakingRows: 6,
                    peakingThreshold: t)!
                .hasPeaking,
            isTrue,
            reason: '黑底→白角陡变远超最高档 64');
      }
    });

    group('波形(列-亮度桶密度,2026-10-14 监看差集)', () {
      test('白角帧:右上列顶桶命中、左下暗列不见白;各列采样总数相等', () {
        final a = analyzeJpegFrame(_whiteCornerJpeg(), waveformCols: 8);
        expect(a!.waveformCols, 8);
        expect(a.waveformBins, a.lumaHistogram.length);
        final bins = a.waveformBins;
        int colTotal(int col) {
          var t = 0;
          for (var b = 0; b < bins; b++) {
            t += a.waveform[col * bins + b];
          }
          return t;
        }

        // 顶桶带(bins-4..bins-1)只允许亮列命中(JPEG 压缩可能把
        // 255 压掉一两档,不给单桶精确值)。
        int topBand(int col) {
          var t = 0;
          for (var b = bins - 4; b < bins; b++) {
            t += a.waveform[col * bins + b];
          }
          return t;
        }

        expect(topBand(6), greaterThan(0), reason: '右上白角列顶桶带命中');
        expect(topBand(0), 0, reason: '左下暗列(luma≈20)不见白');
        // 等宽分列:每列源像素数相同 → 采样总数相同。
        expect(colTotal(0), colTotal(7));
        expect(colTotal(0), greaterThan(0));
      });

      test('渐变帧:右列主桶显著高于左列(列分布随亮度单调上移)', () {
        final a = analyzeJpegFrame(_gradientJpeg(), waveformCols: 8);
        int peakBin(int col) {
          final bins = a!.waveformBins;
          var best = 0, bestV = 0;
          for (var b = 0; b < bins; b++) {
            final v = a.waveform[col * bins + b];
            if (v > bestV) {
              bestV = v;
              best = b;
            }
          }
          return best;
        }

        expect(peakBin(7) - peakBin(0), greaterThan(16),
            reason: '0..248 渐变两端主桶差应远超 16 桶');
      });
    });
  });

  group('FrameAnalyzer', () {
    test('禁用:帧到达零分析', () {
      final analyzer = FrameAnalyzer(everyNth: 2);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      addTearDown(() => analyzer.dispose());

      frames.value = _gradientJpeg();
      frames.notifyListeners();
      expect(analyzer.analysis.value, isNull);
    });

    test('启用:每 N 帧一算,中间帧跳过', () {
      final analyzer = FrameAnalyzer(everyNth: 2);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      addTearDown(() => analyzer.dispose());

      frames.value = _whiteCornerJpeg();
      frames.notifyListeners(); // 第 0 帧(_seen 0 % 2 == 0 → 算)
      expect(analyzer.analysis.value, isNotNull);
      expect(analyzer.analysis.value!.hasOverexposure, isTrue);

      final first = analyzer.analysis.value;
      frames.value = _gradientJpeg();
      frames.notifyListeners(); // 第 1 帧 → 跳过
      expect(analyzer.analysis.value, same(first), reason: '中间帧不得重算');
    });

    test('detach 清结果;重挂后重新可用', () {
      final analyzer = FrameAnalyzer();
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      frames.value = _gradientJpeg();
      frames.notifyListeners();
      expect(analyzer.analysis.value, isNotNull);
      analyzer.detach();
      expect(analyzer.analysis.value, isNull);
    });
  });
}

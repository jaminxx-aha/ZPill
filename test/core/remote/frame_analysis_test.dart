import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:nikon_pill/core/remote/frame_analysis.dart';
import 'package:nikon_pill/core/remote/frame_analyzer.dart';
import 'package:nikon_pill/core/remote/peaking_engines.dart';
import 'package:nikon_pill/core/ptp/ptp_session.dart';
import 'package:nikon_pill/core/remote/scopes.dart';
import 'package:nikon_pill/features/remote/remote_controller.dart';

import '../ptp/ptp_session_harness.dart';

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

/// 左半纯红 / 右半纯蓝 32×24(Parade 通道独立性与矢量色相方向的载体;
/// 两色都无绿 —— G 通道全零,G 联密度只能落在底桶)。
Uint8List _splitColorJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      final red = x < 16;
      image.setPixelRgba(x, y, red ? 255 : 0, 0, red ? 0 : 255, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 三横带 32×24:上带纯白 / 中带中灰 / 下带纯黑(红绿灯三带判定的载体;
/// 白 luma 255 ≥ 250 过、灰 128 合式、黑 0 < 16 欠)。
Uint8List _threeBandJpeg() {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    final v = y < 8 ? 255 : (y < 16 ? 128 : 0);
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// 平涂色帧 32×24(矢量盘口径:纯红 → R 射线,中灰 → 盘心)。
Uint8List _flatJpeg(int r, int g, int b) {
  final image = img.Image(width: 32, height: 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

final class _FakeFrames extends ChangeNotifier implements ValueListenable<Uint8List?> {
  @override
  Uint8List? value;
}

/// 合成峰格平面:cols×rows,luma 由 [lumaOf] 逐格给出(counts 全 1;
/// [holes] 内的格挖成空格,峰格均值 0 = analyzeJpegFrame 的稀疏采样口径)。
(List<double>, List<int>) _plane(int cols, int rows,
    double Function(int x, int y) lumaOf, {Set<int> holes = const {}}) {
  final means = List<double>.filled(cols * rows, 0);
  final counts = List<int>.filled(cols * rows, 1);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final i = y * cols + x;
      if (holes.contains(i)) {
        counts[i] = 0;
        continue;
      }
      means[i] = lumaOf(x, y);
    }
  }
  return (means, counts);
}

/// 高斯软边列值(离散高斯 CDF,边心 ±8 抽头归一):center 左侧回到
/// lo,过 center 升到 lo+amplitude;σ→0 退化为硬台阶。峰值增量落在
/// center-1 → center 列间(quad 锚在 center-1 列 → 双尺度亮该列)。
double _gaussEdgeLuma(int x,
    {required double lo,
    required double amplitude,
    required double sigma,
    required int center}) {
  var z = 0.0;
  var acc = 0.0;
  for (var o = -8; o <= 8; o++) {
    final w = math.exp(-o * o / (2 * sigma * sigma));
    z += w;
    if (center + o <= x) acc += w;
  }
  return lo + amplitude * acc / z;
}

/// 散景帧:128×96 垂直高斯软边(暗 20 → 亮 240,σ2.5px;默认峰格
/// 64×48 = 2px/格,偶数像素单点采样 → 网格口径 σ≈1.25 格)。软边
/// 峰格邻差 ≈70(经典引擎阈值 24/40/64 都过 = 旧误报);再模糊后
/// 比值 ≈1.7 < 1.90(双尺度三档全灭)。
Uint8List _softEdgeJpeg() {
  final image = img.Image(width: 128, height: 96);
  for (var y = 0; y < 96; y++) {
    for (var x = 0; x < 128; x++) {
      final v = _gaussEdgeLuma(x,
              lo: 20, amplitude: 220, sigma: 2.5, center: 64)
          .round()
          .clamp(0, 255);
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
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

    test('峰值灵敏度阈值(经典引擎回归):参数改档产生不同掩码(24/40/64 = 低/中/高档)', () {
      // 渐变帧按 8 列峰格采样,相邻格均值差恰 32(0..248 渐变 / 4px 格):
      // 低于中档、高于低档 —— 三档在此帧上分出三种结果。显式走经典
      // 引擎(单尺度梯度,2026-10-14 前的唯一路径)锁旧路径行为。
      FrameAnalysis grad(int threshold) => analyzeJpegFrame(_gradientJpeg(),
          maskCols: 8,
          maskRows: 6,
          peakingCols: 8,
          peakingRows: 6,
          peakingEngine: PeakingEngine.gradient,
          peakingThreshold: threshold)!;
      // 缺省引擎已是双尺度:纯渐变(每格等差)再模糊后能量不变,
      // 比值 = 1,任何档都不亮(与经典中档 32 < 40 结论一致)。
      expect(
          analyzeJpegFrame(_gradientJpeg(),
                  maskCols: 8, maskRows: 6, peakingCols: 8, peakingRows: 6)!
              .hasPeaking,
          isFalse,
          reason: '缺省引擎 = 双尺度,渐变比值 1 恒不亮');
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
                    peakingEngine: PeakingEngine.gradient,
                    peakingThreshold: t)!
                .hasPeaking,
            isTrue,
            reason: '黑底→白角陡变远超最高档 64');
      }
    });

    test('散景帧端到端:经典引擎亮(旧误报),双尺度(缺省)不亮', () {
      final jpeg = _softEdgeJpeg();
      expect(
          analyzeJpegFrame(jpeg,
                  peakingEngine: PeakingEngine.gradient,
                  peakingThreshold: 40)!
              .hasPeaking,
          isTrue,
          reason: '软边峰格邻差 ~70 ≥ 40:经典引擎圈散景(旧行为误报)');
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        expect(
            analyzeJpegFrame(jpeg,
                    peakingRatioThreshold: p.ratioThreshold,
                    peakingNoiseGate: p.noiseGate)!
                .hasPeaking,
            isFalse,
            reason: '双尺度档 $level:比值 ≈1.7 < 阈值,散景不亮');
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

    group('示波器族采样(2026-10-15:Parade/矢量/红绿灯同环积累)', () {
      test('Parade:左红右蓝帧 —— R 联密度在亮桶偏左,B 联偏右,G 联不见亮桶;三联与波形同采样集',
          () {
        final a = analyzeJpegFrame(_splitColorJpeg(), waveformCols: 8);
        expect(a, isNotNull);
        final bins = a!.waveformBins;
        final plane = a.waveformCols * bins;
        // 列通道计数(ch 0=R/1=G/2=B;b0..b1 桶区间闭开合计)。
        int chColRange(int ch, int col, int b0, int b1) {
          var t = 0;
          for (var b = b0; b < b1; b++) {
            t += a.parade[ch * plane + col * bins + b];
          }
          return t;
        }

        // 顶桶带(bins-4..bins):只有亮通道命中 —— 红半幅的 R、蓝半幅的 B。
        // 列 1-2 / 5-6 离红蓝接缝(列 4 边界)远,避开 4:2:0 插值渗色。
        final rTopLeft = chColRange(0, 1, bins - 4, bins) +
            chColRange(0, 2, bins - 4, bins);
        final rTopRight = chColRange(0, 5, bins - 4, bins) +
            chColRange(0, 6, bins - 4, bins);
        final bTopRight = chColRange(2, 5, bins - 4, bins) +
            chColRange(2, 6, bins - 4, bins);
        final bTopLeft = chColRange(2, 1, bins - 4, bins) +
            chColRange(2, 2, bins - 4, bins);
        final gTop = chColRange(1, 1, bins - 4, bins) +
            chColRange(1, 2, bins - 4, bins) +
            chColRange(1, 5, bins - 4, bins) +
            chColRange(1, 6, bins - 4, bins);
        expect(rTopLeft, greaterThan(0), reason: '红半幅 R 通道命中亮桶');
        expect(rTopRight, 0, reason: '蓝半幅无红,顶桶带必空');
        expect(bTopRight, greaterThan(0), reason: '蓝半幅 B 通道命中亮桶');
        expect(bTopLeft, 0, reason: '红半幅无蓝,顶桶带必空');
        expect(gTop, 0, reason: '两色都无绿,G 联顶桶带必空(暗桶不判)');

        // 同采样集不变量:每列三联计数彼此相等,且等于该列波形计数
        // (同一批采样各记一笔)。
        int waveCol(int col) {
          var t = 0;
          for (var b = 0; b < bins; b++) {
            t += a.waveform[col * bins + b];
          }
          return t;
        }

        for (final col in const [0, 3, 7]) {
          final r = chColRange(0, col, 0, bins);
          final g = chColRange(1, col, 0, bins);
          final b = chColRange(2, col, 0, bins);
          expect(r, g);
          expect(g, b);
          expect(r, waveCol(col),
              reason: '列 $col:Parade 三联与波形共用同一批采样');
        }
      });

      test('矢量:纯红帧全落 Cr 正半盘(色相方向),灰帧聚盘心;总量与波形同采样集',
          () {
        const n = scopeVectorGridN;
        final red = analyzeJpegFrame(_flatJpeg(255, 0, 0), vectorN: n)!;
        // 纯红:nx = (Cr−128)/127.5 = 1(Cr 正端 = 盘右半)、ny ≈ −0.34
        //(Cb 负 = 下半)。JPEG 色度噪声 ±3 只在盘缘内侧挪格,不过中线。
        var redCells = 0;
        for (var i = 0; i < red.vector.length; i++) {
          if (red.vector[i] == 0) continue;
          redCells++;
          expect(i % n, greaterThan(n ~/ 2),
              reason: '纯红所有采样都在 Cr 正半盘(右半)');
        }
        expect(redCells, greaterThan(0));
        // 密度主格在下半盘(Cb < 128 一侧,行号 > 中心行)
        var bestI = 0, bestV = 0;
        for (var i = 0; i < red.vector.length; i++) {
          if (red.vector[i] > bestV) {
            bestV = red.vector[i];
            bestI = i;
          }
        }
        expect(bestI ~/ n, greaterThan(n ~/ 2), reason: '红的主密度在下半盘');

        final gray = analyzeJpegFrame(_flatJpeg(128, 128, 128), vectorN: n)!;
        for (var i = 0; i < gray.vector.length; i++) {
          if (gray.vector[i] == 0) continue;
          final col = i % n, row = i ~/ n;
          expect((col - n ~/ 2).abs(), lessThan(3),
              reason: '灰帧色度无偏离,采样聚盘心(±2 格容 JPEG 噪声)');
          expect((row - n ~/ 2).abs(), lessThan(3));
        }

        // 总量不变量:矢量盘收下每个采样(与波形/直方图同批)。
        int sum(List<int> xs) {
          var t = 0;
          for (final v in xs) {
            t += v;
          }
          return t;
        }

        expect(sum(red.vector), sum(red.waveform));
        expect(sum(red.vector), red.lumaHistogram.reduce((x, y) => x + y));
      });

      test('红绿灯:三横带帧上过/中合/下欠;全白全过、全黑全欠、灰帧全合',
          () {
        final bands = analyzeJpegFrame(_threeBandJpeg())!.trafficLights;
        expect(bands.length, 3);
        expect(bands[0].state, ScopeTrafficState.over, reason: '上带纯白 ≥ 250');
        expect(bands[1].state, ScopeTrafficState.ok, reason: '中带中灰合式');
        expect(bands[2].state, ScopeTrafficState.under, reason: '下带纯黑 < 16');
        expect(bands[0].overFraction, greaterThan(0.5));
        expect(bands[1].okFraction, greaterThan(0.5));
        expect(bands[2].underFraction, greaterThan(0.5));

        final white = analyzeJpegFrame(_flatJpeg(255, 255, 255))!;
        for (final b in white.trafficLights) {
          expect(b.state, ScopeTrafficState.over);
        }
        final black = analyzeJpegFrame(_flatJpeg(0, 0, 0))!;
        for (final b in black.trafficLights) {
          expect(b.state, ScopeTrafficState.under);
        }
        final gray = analyzeJpegFrame(_flatJpeg(128, 128, 128))!;
        for (final b in gray.trafficLights) {
          expect(b.state, ScopeTrafficState.ok);
        }
      });
    });
  });

  group('双尺度比值引擎(合成网格,Zhuo & Sim 2011 口径)', () {
    const cols = 16, rows = 12;

    // 垂直边平面:x 向软/硬边、y 向均匀;边落在 col 7→8(center=8)。
    (List<double>, List<int>) vEdge(double sigma, double lo, double amplitude) =>
        _plane(cols, rows,
            (x, y) => _gaussEdgeLuma(x, lo: lo, amplitude: amplitude, sigma: sigma, center: 8));

    Uint8List dual((List<double>, List<int>) plane,
            {double ratio = 2.10, int gate = 450}) =>
        dualScalePeakingMask(
            means: plane.$1,
            counts: plane.$2,
            cols: cols,
            rows: rows,
            ratioThreshold: ratio,
            noiseGate: gate);

    Uint8List grad((List<double>, List<int>) plane, {int threshold = 40}) =>
        gradientPeakingMask(
            means: plane.$1,
            counts: plane.$2,
            cols: cols,
            rows: rows,
            threshold: threshold);

    Set<int> lit(Uint8List m) =>
        {for (var i = 0; i < m.length; i++) if (m[i] == 1) i};

    test('锐利台阶边(σ→0):双尺度恰亮边左列(行 0..rows-2),三档全亮', () {
      final plane = vEdge(0.05, 20, 200); // 20 → 220 单格台阶
      final m = dual(plane);
      expect(lit(m), {for (var y = 0; y + 1 < rows; y++) y * cols + 7},
          reason: 'quad 锚在边左列 col 7,末行无完整 quad');
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        expect(
            lit(dual(plane, ratio: p.ratioThreshold, gate: p.noiseGate))
                .isNotEmpty,
            isTrue,
            reason: '台阶比值饱和 4.0、E_B ≈ 11700,档 $level 也亮');
      }
      // 经典引擎同列(行 0..rows-1:只查右邻,末行也亮)
      expect(lit(grad(plane, threshold: 64)),
          {for (var y = 0; y < rows; y++) y * cols + 7});
    });

    test('高斯软边:σ0.7(近合焦)三档亮且只在边列;σ1.4(失焦)三档灭', () {
      final near = vEdge(0.7, 20, 235);
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        final m = dual(near, ratio: p.ratioThreshold, gate: p.noiseGate);
        expect(lit(m).isNotEmpty, isTrue, reason: 'σ0.7 比值 ≈3.2,档 $level 也亮');
        expect(lit(m).every((i) => i % cols == 7), isTrue,
            reason: '只在边左列亮,侧翼格比值 <1 不亮');
      }
      final far = vEdge(1.4, 20, 235);
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        expect(
            lit(dual(far, ratio: p.ratioThreshold, gate: p.noiseGate)).isEmpty,
            isTrue,
            reason: 'σ1.4 比值 ≈1.55 < 1.90,最松档也不亮');
      }
    });

    test('散景高亮(亮块软边)核心回归:同平面经典三档全亮、双尺度三档全灭', () {
      // 散景光斑的网格口径 = 全幅亮块(20→255)+ 软边:软边峰值邻差
      // ≈67 ≥ 经典最高档 64 → 旧引擎三档全误亮(散景高亮被当合焦);
      // 再模糊后能量比 ≈1.55 → 双尺度三档全灭 —— 本算法的存在理由。
      final bokeh = vEdge(1.4, 20, 235);
      for (final t in const [24, 40, 64]) {
        expect(lit(grad(bokeh, threshold: t)).isNotEmpty, isTrue,
            reason: '经典引擎档 $t:软边邻差 ~67 过单阈值(旧误报)');
      }
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        expect(
            lit(dual(bokeh, ratio: p.ratioThreshold, gate: p.noiseGate))
                .isEmpty,
            isTrue,
            reason: '双尺度档 $level:比值判据剔除散景');
      }
      // 机制核验:阈值放开到 1.0(比值不限)就亮 —— 拒绝来自比值而非
      // 能量门槛(E_B ≈ 5800 ≥ 高档门槛 1200,门槛是放行的)。
      expect(lit(dual(bokeh, ratio: 1.0, gate: 1200)).isNotEmpty, isTrue);
    });

    test('高频噪声纹理(±16 棋盘):双尺度三档全灭(门槛拒),经典低档满屏', () {
      // 传感器噪声不被镜头模糊,比值上看恒「合焦」—— 拒它靠粗尺度
      // 能量门槛:棋盘再模糊后 ≈平坦,E_B 远不过档。经典引擎只看
      // 邻差 32 ≥ 低档 24 → 满屏误亮(旧噪声误报)。
      final plane =
          _plane(cols, rows, (x, y) => 128 + ((x + y) % 2 == 0 ? 16 : -16));
      for (final level in const [0, 1, 2]) {
        final p = peakingDualScaleParamsOf(level);
        expect(
            lit(dual(plane, ratio: p.ratioThreshold, gate: p.noiseGate))
                .isEmpty,
            isTrue,
            reason: '档 $level:再模糊后棋盘归平坦,能量不过门槛');
      }
      // 经典低档:邻差 32 ≥ 24,除右下角格(无右/下邻)外全亮
      expect(lit(grad(plane, threshold: 24)).length, cols * rows - 1);
    });

    test('纯平坦/全黑/全白:两引擎都不亮(低光/平坦区定义)', () {
      for (final v in const [128.0, 0.0, 255.0]) {
        final plane = _plane(cols, rows, (x, y) => v);
        expect(lit(dual(plane)).isEmpty, isTrue, reason: '平坦 luma $v');
        expect(lit(grad(plane)).isEmpty, isTrue);
      }
    });

    test('档位单调:低 ⊇ 中 ⊇ 高;σ1.0 边(比值 ≈2.08)低档亮/高档灭', () {
      final plane = vEdge(1.0, 20, 200);
      final masks = [
        for (final level in const [0, 1, 2])
          lit(dual(plane,
              ratio: peakingDualScaleParamsOf(level).ratioThreshold,
              gate: peakingDualScaleParamsOf(level).noiseGate))
      ];
      expect(masks[0].isNotEmpty, isTrue, reason: 'σ1.0 比值 ≈2.08 ≥ 低档 1.90');
      expect(masks[2].isEmpty, isTrue, reason: 'σ1.0 比值 ≈2.08 < 高档 2.30');
      // 越严越少(结构性:低档两参数都更松,亮集单调收缩)
      expect(masks[2].difference(masks[1]), isEmpty);
      expect(masks[1].difference(masks[0]), isEmpty);
    });

    test('空格:所在 quad 跳过不抛;网格不足 2 行/列恒不亮', () {
      // 台阶边亮侧(col 8)挖空格:含空格的 quad(行 4/5 的 col 7)
      // 跳过,远离空格的行照常亮,也不冒出新列。
      final holes = {5 * cols + 8};
      final plane =
          _plane(cols, rows, (x, y) => x >= 8 ? 220.0 : 20.0, holes: holes);
      final m = lit(dual(plane));
      expect(m.every((i) => i % cols == 7), isTrue, reason: '不冒新列');
      expect(m.contains(4 * cols + 7) || m.contains(5 * cols + 7), isFalse,
          reason: '含空格的 quad(行 4/5)不亮');
      expect(m.contains(1 * cols + 7), isTrue, reason: '远离空格的行照常亮');
      expect(m.contains(9 * cols + 7), isTrue);
      // 退化网格:单行/单列无完整 quad
      final (m1, c1) = _plane(1, 4, (x, y) => x + y * 100);
      expect(
          dualScalePeakingMask(
              means: m1, counts: c1, cols: 1, rows: 4, ratioThreshold: 2.10, noiseGate: 450),
          everyElement(0));
      final (m2, c2) = _plane(4, 1, (x, y) => 0.0);
      expect(
          dualScalePeakingMask(
              means: m2, counts: c2, cols: 4, rows: 1, ratioThreshold: 2.10, noiseGate: 450),
          everyElement(0));
    });

    test('peakingSharpnessRatio:除零守卫 / 饱和钳 / ≥ 阈值边界语义', () {
      expect(peakingSharpnessRatio(100, 0), 0);
      expect(peakingSharpnessRatio(100, -5), 0, reason: '负粗能量(不发生)守卫');
      expect(peakingSharpnessRatio(400, 100), closeTo(peakingRatioCeiling, 1e-12));
      expect(peakingSharpnessRatio(1e9, 1), peakingRatioCeiling,
          reason: '完美合焦饱和 4.0');
      expect(peakingSharpnessRatio(210, 100), closeTo(2.10, 1e-12),
          reason: '恰在阈值上 → 判据 ≥ 成立');
      expect(peakingSharpnessRatio(209, 100), closeTo(2.09, 1e-12),
          reason: '阈值下 → 不亮');
    });

    test('peakingDualScaleParamsOf:三档同向有序,表外档回落中档', () {
      final low = peakingDualScaleParamsOf(0);
      final mid = peakingDualScaleParamsOf(1);
      final high = peakingDualScaleParamsOf(2);
      expect(low.ratioThreshold, lessThan(mid.ratioThreshold));
      expect(mid.ratioThreshold, lessThan(high.ratioThreshold));
      expect(low.noiseGate, lessThan(mid.noiseGate));
      expect(mid.noiseGate, lessThan(high.noiseGate));
      for (final bogus in const [-1, 3, 99]) {
        expect(peakingDualScaleParamsOf(bogus), mid,
            reason: '档 $bogus 表外回落中');
      }
    });
  });

  group('FrameAnalyzer', () {
    /// 分析已迁子 isolate(Isolate.run,2026-10-22):结果经端口消息回主
    /// isolate,不是微任务/定时器 —— pumpEventQueue 的默认轮数对 isolate
    /// spawn(~ms)不保证够,这里轮询到条件成立,限时兜底。
    Future<void> waitUntil(bool Function() done,
        {Duration limit = const Duration(seconds: 10)}) async {
      final sw = Stopwatch()..start();
      while (!done()) {
        if (sw.elapsed > limit) {
          fail('等待超时(${limit.inMilliseconds}ms):条件未成立 —— '
              '分析结果未在限时内回主 isolate?');
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('禁用:帧到达零分析', () {
      final analyzer = FrameAnalyzer(everyNth: 2);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      addTearDown(() => analyzer.dispose());

      frames.value = _gradientJpeg();
      frames.notifyListeners();
      expect(analyzer.analysis.value, isNull);
    });

    test('启用:每 N 帧一算,中间帧跳过', () async {
      final analyzer = FrameAnalyzer(everyNth: 2);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      addTearDown(() => analyzer.dispose());

      frames.value = _whiteCornerJpeg();
      frames.notifyListeners(); // 第 0 帧(_seen 0 % 2 == 0 → 触发分析)
      // 异步化:结果回主 isolate 才可见,不再同步断言(见 waitUntil 注释)。
      await waitUntil(() => analyzer.analysis.value != null);
      expect(analyzer.analysis.value!.hasOverexposure, isTrue);

      final first = analyzer.analysis.value;
      frames.value = _gradientJpeg();
      frames.notifyListeners(); // 第 1 帧 → 跳过(_seen 1 % 2 != 0)
      await pumpEventQueue();
      expect(analyzer.analysis.value, same(first), reason: '中间帧不得重算');
    });

    test('全链装配(控制器引擎帧沿):isolate 信报可达 —— 实例方法里写 '
        'Isolate.run 会沿闭包 context 链捕获 this(分析器 → 引擎通知器 → '
        '监听闭包 → 控制器),控制器含 _AsyncCompleter(起景门)随信发送即 '
        '「object is unsendable」,分析静默失败、叠层只余黑盒(2026-10-22 '
        '真机实证);顶层入口函数构造性消除,本用例以生产装配图复现', () async {
      final controller =
          RemoteController(session: PtpSession(transport: FakePtpTransport()));
      addTearDown(controller.dispose);
      controller.analyzer.enabled.value = true;

      controller.engine.frame.value = _whiteCornerJpeg();
      controller.engine.frame.notifyListeners();
      await waitUntil(() => controller.analyzer.analysis.value != null);
      expect(controller.analyzer.analysis.value!.hasOverexposure, isTrue);
    });

    test('detach 清结果;在途结果弃;重挂后重新可用', () async {
      final analyzer = FrameAnalyzer();
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;

      final jpeg = _gradientJpeg();
      frames.value = jpeg;
      frames.notifyListeners(); // 触发分析(在途)
      analyzer.detach(); // 世代翻:在途结果回来不得复活已清的 analysis
      expect(analyzer.analysis.value, isNull);
      // 等量任务见证:同帧字节直跑一次 Isolate.run —— 它完成即证明
      // spawn+解码量级的往返在本时限内可完成,analyzer 的在途任务同理;
      // 若世代闸缺失,迟到投递会把 analysis 从 null 复活成非 null。
      await Isolate.run(() => analyzeJpegFrame(jpeg));
      await pumpEventQueue();
      expect(analyzer.analysis.value, isNull, reason: 'detach 世代后的迟到结果弃');

      // 重挂后重新可用(在途闸随 attach 重建,不被上一世代卡死)。
      analyzer.attach(frames);
      frames.value = _gradientJpeg();
      frames.notifyListeners();
      await waitUntil(() => analyzer.analysis.value != null);
      expect(analyzer.analysis.value, isNotNull);
    });

    test('dispose 后不投递:在途分析的结果被世代闸丢弃', () async {
      final analyzer = FrameAnalyzer(everyNth: 1);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      var deliveries = 0;
      analyzer.analysis.addListener(() => deliveries++);

      final jpeg = _gradientJpeg();
      frames.value = jpeg;
      frames.notifyListeners(); // 触发在途分析
      analyzer.dispose(); // 世代翻 + notifier dispose:迟到结果不得投递
      // 等量任务见证(同上一用例):它完成即证明在途量级的往返可完成;
      // 若世代闸缺失,迟到投递会写已 dispose 的 notifier(断言炸)。
      await Isolate.run(() => analyzeJpegFrame(jpeg));
      await pumpEventQueue();
      expect(deliveries, 0, reason: 'dispose 后不得投递(notifier 已 dispose)');
    });

    test('在途跳过:分析在途时新触发丢弃,不积压;完成后恢复', () async {
      final analyzer = FrameAnalyzer(everyNth: 1);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      addTearDown(() => analyzer.dispose());
      var deliveries = 0;
      analyzer.analysis.addListener(() => deliveries++);

      // 同步突发 10 帧:第 0 帧触发分析(Isolate.run 必在途 —— 同步代码
      // 期间不可能完成),后续 9 帧全部命中在途闸 —— 同一时刻至多一个
      // 分析在跑,不排队不积压(丢分析帧,取景帧照常走 UI)。
      for (var i = 0; i < 10; i++) {
        frames.value = _whiteCornerJpeg();
        frames.notifyListeners();
      }
      await waitUntil(() => analyzer.analysis.value != null);
      await pumpEventQueue();
      expect(deliveries, 1,
          reason: '突发 10 帧只触发一次分析(在途时后续触发丢弃)');
      expect(analyzer.analysis.value!.hasOverexposure, isTrue);

      // 在途结束后:下一帧恢复触发(在途闸不得卡死分析通道)。
      frames.value = _whiteCornerJpeg();
      frames.notifyListeners();
      await waitUntil(() => deliveries >= 2);
      expect(deliveries, 2, reason: '在途结束后恢复节流分析');
    });

    test('引擎字段传参:缺省双尺度散景不亮;切经典引擎即亮', () async {
      final analyzer = FrameAnalyzer(everyNth: 1);
      final frames = _FakeFrames();
      analyzer.attach(frames);
      analyzer.enabled.value = true;
      addTearDown(() => analyzer.dispose());

      frames.value = _softEdgeJpeg();
      frames.notifyListeners();
      await waitUntil(() => analyzer.analysis.value != null);
      expect(analyzer.analysis.value!.hasPeaking, isFalse,
          reason: '缺省引擎 = 双尺度,散景软边不亮');

      analyzer.peakingEngine = PeakingEngine.gradient;
      analyzer.peakingThreshold = 40; // 监看灵敏度中档
      final first = analyzer.analysis.value;
      frames.value = _softEdgeJpeg();
      frames.notifyListeners();
      // 新结果以对象身份区分(同帧内容,值可能相等但对象必新)。
      await waitUntil(() => !identical(analyzer.analysis.value, first));
      expect(analyzer.analysis.value!.hasPeaking, isTrue,
          reason: '改引擎字段 = 改判定(页面「峰值算法」切档路径)');
    });
  });
}

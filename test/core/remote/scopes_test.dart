import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/remote/scopes.dart';

/// 平面极角(弧度;只做同角比较,与盘面方向语义一致)。
double _angle(double nx, double ny) => math.atan2(ny, nx);

/// 平面半径(盘内判定用)。
double _radius(double nx, double ny) => math.sqrt(nx * nx + ny * ny);

void main() {
  group('ExposureScale(N-Log legal-range 64-940 ↔ 0-100 IRE)', () {
    test('锚点:黑码 64 → 0 IRE,白码 940 → 100,半幅 502 → 50', () {
      expect(nLogIreOfCode10(nLogLegalBlackCode10), 0);
      expect(nLogIreOfCode10(nLogLegalWhiteCode10), 100);
      expect(nLogIreOfCode10(502), 50);
    });

    test('IRE → 码逆换算 + 往返自闭(线性域外不钳)', () {
      expect(nLogCode10OfIre(0), nLogLegalBlackCode10);
      expect(nLogCode10OfIre(100), nLogLegalWhiteCode10);
      expect(nLogCode10OfIre(50), 502);
      for (final code in const [64.0, 127.2, 372.0, 502.0, 940.0, 1019.0]) {
        expect(nLogCode10OfIre(nLogIreOfCode10(code)), closeTo(code, 1e-9),
            reason: '码 $code 往返');
      }
      // 域外线性外延:0 码下探负 IRE、1023 码上探超 100 IRE
      expect(nLogIreOfCode10(0), lessThan(0));
      expect(nLogIreOfCode10(1023), greaterThan(100));
    });

    test('官方锚点读数:真黑 127.2 ≈ 7.2 IRE,18% 灰 372 ≈ 35.2 IRE', () {
      // 《N-Log Specification Document》v1.0.0 pp.4-5(锚点常量本体),
      // IRE 换算 = legal-range 线性式(OpenZCine ExposureScale 同语义)。
      expect(nLogIreOfCode10(nLogTrueBlackCode10), closeTo(7.21, 0.01));
      expect(nLogIreOfCode10(nLogMidGrayCode10), closeTo(35.16, 0.01));
    });

    test('真黑→合法白归一:127.2 → 0、940 → 1、18% 灰 372 → ≈0.300', () {
      expect(nLogNormalizedOfCode10(nLogTrueBlackCode10), 0);
      expect(nLogNormalizedOfCode10(nLogLegalWhiteCode10), 1);
      expect(nLogNormalizedOfCode10(nLogMidGrayCode10), closeTo(0.3012, 0.0005),
          reason: 'OpenZCine black→clip 口径文档值 ≈0.300,精确式 0.3012');
      // 合法黑(64)在归一口径下为负(黑下),不钳 —— 调用方自便。
      expect(nLogNormalizedOfCode10(nLogLegalBlackCode10), lessThan(0));
    });

    test('8-bit 监看帧 luma 桥:studio-swing 16 → ≈0 IRE、235 → ≈100.3 IRE', () {
      expect(nLogIreOfLuma8(16), lessThan(0.1),
          reason: '合法黑 16 ×1023/255 ≈ 64.4 码 ≈ 0.04 IRE');
      expect(nLogIreOfLuma8(235), closeTo(100.3, 0.05),
          reason: '合法白 235 ≈ 942.5 码,微超合法白(100.3 IRE)');
      // luma ↔ 码互逆
      for (final luma in const [0, 16, 64, 128, 235, 255]) {
        expect(nLogLuma8OfCode10(nLogCode10OfLuma8(luma)), luma.toDouble(),
            reason: 'luma $luma 往返');
      }
      // IRE ↔ luma 互逆(波形图 Y 轴刻度反投用;8-bit 取整一步
      // ≈ 0.46 IRE,容差取 0.5)
      for (final ire in const [0.0, 25.0, 50.0, 100.0]) {
        expect(
            nLogIreOfLuma8(nLogLuma8OfIre(ire).round()), closeTo(ire, 0.5),
            reason: 'IRE $ire 往返');
      }
    });
  });

  group('Rec.601 色度式(与帧分析 luma 同族)', () {
    test('灰阶无色度:任意灰 → Cb = Cr = 128(权重和恰为零)', () {
      for (final v in const [0, 16, 128, 200, 255]) {
        // 权重和数学上恰为零,浮点上有 ULP 级残差
        expect(rec601Cb(v, v, v), closeTo(128, 1e-9));
        expect(rec601Cr(v, v, v), closeTo(128, 1e-9));
      }
    });

    test('纯原色:红推 Cr 至正端、蓝推 Cb 至正端、绿双负', () {
      // 红 (255,0,0):Cb = 128 − 0.168736·255 ≈ 84.97,Cr = 128 + 127.5 = 255.5
      expect(rec601Cb(255, 0, 0), closeTo(84.97, 0.01));
      expect(rec601Cr(255, 0, 0), closeTo(255.5, 0.01));
      // 蓝 (0,0,255):Cb = 128 + 127.5 = 255.5,Cr = 128 − 0.081312·255 ≈ 107.27
      expect(rec601Cb(0, 0, 255), closeTo(255.5, 0.01));
      expect(rec601Cr(0, 0, 255), closeTo(107.27, 0.01));
      // 绿 (0,255,0):两轴都往负端
      expect(rec601Cb(0, 255, 0), lessThan(128));
      expect(rec601Cr(0, 255, 0), lessThan(128));
    });
  });

  group('矢量盘(角度 = 色相,半径 = 饱和度)', () {
    test('vectorCellOf:盘心/盘缘/越盘钳边;nx = Cr(右正)、ny = Cb(上正)',
        () {
      const n = 48;
      // 盘心 → 中心格(round(0.5·47) = 24;行 24 = ny 0)
      expect(vectorCellOf(0, 0, n), 24 * n + 24);
      // Cr 正端(右) + Cb 正端(上):首行右缘
      expect(vectorCellOf(1, 1, n), 0 * n + (n - 1));
      // Cr 负端(左) + Cb 负端(下):末行左缘
      expect(vectorCellOf(-1, -1, n), (n - 1) * n + 0);
      // 越盘钳边(超饱和采样不丢,贴盘缘)
      expect(vectorCellOf(1.5, -1.7, n), (n - 1) * n + (n - 1));
    });

    test('RGB 采样一步落格:纯红 → 右缘(Cr 正端)下侧(Cb 负);灰 → 盘心',
        () {
      // 纯红 (255,0,0):nx = 1(右缘列 n−1)、ny ≈ −0.337(行 31)——
      // 红的色相方向,与 75% 目标框同射线(见下一测)。
      const n = 48;
      expect(vectorCellIndexOf(255, 0, 0, n), 31 * n + (n - 1));
      // 灰 (128,128,128):无色度 → 盘心格
      expect(vectorCellIndexOf(128, 128, 128, n), 24 * n + 24);
    });

    test('75% 六目标:与同色纯色同一色相射线(75% 红恰在 R 框方向)', () {
      // 目标框与采样同一 Rec.601 式自洽:六目标各与对应纯色(255 档)
      // 同角度、半径 < 1(盘内)。
      const hues = [
        (255, 0, 0), // R
        (255, 0, 255), // Mg
        (0, 0, 255), // B
        (0, 255, 255), // Cy
        (0, 255, 0), // G
        (255, 255, 0), // Yl
      ];
      expect(vectorTargetLabels.length, vectorTargets75.length);
      for (var i = 0; i < hues.length; i++) {
        final (r, g, b) = hues[i];
        final (tx, ty) = vectorTargets75[i];
        final pureNx = (rec601Cr(r, g, b) - 128) / 127.5;
        final pureNy = (rec601Cb(r, g, b) - 128) / 127.5;
        final label = vectorTargetLabels[i];
        expect(_angle(tx, ty) - _angle(pureNx, pureNy), closeTo(0, 0.01),
            reason: '$label 框与纯色同色相射线');
        expect(_radius(tx, ty), lessThan(1.0), reason: '$label 框在盘内');
      }
      // 75% 红 (191,0,0):nx = 0.749、ny ≈ −0.253 —— 纯红射线上半径 0.75 档
      final (rx, ry) = vectorTargets75[0];
      expect(rx, closeTo(0.749, 0.001));
      expect(ry, closeTo(-0.253, 0.001));
    });
  });

  group('红绿灯(三横带欠/合/过,OpenZCine 0.10 阈值)', () {
    test('常量口径:欠 < 16(合法黑)、过 ≥ 250(斑马纹同阈值)、10% 点灯',
        () {
      expect(scopeTrafficUnderLuma, 16);
      expect(scopeTrafficOverLuma, 250);
      expect(scopeTrafficFractionThreshold, 0.10);
    });

    test('全黑/全白/正常三帧:under / over / ok', () {
      // 全黑(每带全欠)
      final black = Uint32List.fromList([100, 0, 0, 100, 0, 0, 100, 0, 0]);
      for (final b in trafficLightsOf(black)) {
        expect(b.state, ScopeTrafficState.under);
      }
      // 全白(每带全过)
      final white = Uint32List.fromList([0, 0, 100, 0, 0, 100, 0, 0, 100]);
      for (final b in trafficLightsOf(white)) {
        expect(b.state, ScopeTrafficState.over);
      }
      // 正常(欠/过各 5% < 10%)
      final normal = Uint32List.fromList([5, 90, 5, 5, 90, 5, 5, 90, 5]);
      for (final b in trafficLightsOf(normal)) {
        expect(b.state, ScopeTrafficState.ok);
      }
    });

    test('阈值边界:恰 10% 不点灯(判据是 >),11% 点灯', () {
      final atEdge = trafficLightsOf(Uint32List.fromList([10, 90, 0])).first;
      expect(atEdge.underFraction, closeTo(0.10, 1e-12));
      expect(atEdge.state, ScopeTrafficState.ok, reason: '恰在阈值上不判欠');
      final over = trafficLightsOf(Uint32List.fromList([11, 89, 0])).first;
      expect(over.state, ScopeTrafficState.under, reason: '11% > 10% 判欠');
    });

    test('同带双超:过曝优先于欠曝(削顶不可救)', () {
      final both = trafficLightsOf(Uint32List.fromList([20, 60, 20])).first;
      expect(both.underFraction, greaterThan(scopeTrafficFractionThreshold));
      expect(both.overFraction, greaterThan(scopeTrafficFractionThreshold));
      expect(both.state, ScopeTrafficState.over);
    });

    test('空带按合式不误报;短输入按 0 补不抛', () {
      final empty = trafficLightsOf(Uint32List(9)).first;
      expect(empty.samples, 0);
      expect(empty.state, ScopeTrafficState.ok);
      // 手拼短数据(防御口径):长度不足 9 按 0 补,末带空 = ok
      final short = trafficLightsOf(Uint32List.fromList([5, 5, 5]));
      expect(short.length, 3);
      expect(short[2].samples, 0);
      expect(short[2].state, ScopeTrafficState.ok);
      expect(trafficLightsOf(Uint32List(0)).length, 3,
          reason: '空输入三带全空,不抛');
    });

    test('派生读数:分数与样本计数自洽', () {
      final band = trafficLightsOf(Uint32List.fromList([30, 70, 0])).first;
      expect(band.samples, 100);
      expect(band.underFraction, 0.3);
      expect(band.okFraction, 0.7);
      expect(band.overFraction, 0.0);
      expect(band.state, ScopeTrafficState.under);
    });
  });
}

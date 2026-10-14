import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/features/edit/lut_presets.dart';

/// 「N-Log 还原」内置 LUT 对账。
///
/// 锚点数值来源(2026-10-14 检索,三源交叉一致):
/// - 尼康官方《N-Log Specification Document》v1.0.0(2018-09-01)pp.4-5,
///   download.nikonimglib.com/archive3/hDCmK00m9JDI03RPruD74xpoU905/
///   N-Log_Specification_(En)01.pdf:
///   逆向式 `if (x < 452) y = (x/650)^3 − 0.0075; else y = exp[(x−619)/150]`
///   (x = 10-bit 码值,y = 反射率,y = 0.18 即 18% 灰);
///   正向锚点 0% 黑 → 127.2、18% 灰 → 372.0、90% 白 → 603.2、
///   反射率 1.0 → 619;色域 BT.2020/D65(→BT.709 矩阵 = ITU-R BT.2087-0)。
/// - colour-science nikon_n_log.py(BSD-3):常数逐项一致,
///   log_encoding_NLog(0.18) = 0.3636677 ✓。
/// - EaryChow/Nikon-N-Log-EOTF-LUT-Generator(GitHub):同式独立实现。
///
/// 输出侧为 ITU-R BT.709-6 OETF(18% 灰 → 0.409 ≈ 41 IRE、90% 白 →
/// 0.949 ≈ 95 IRE 均为 709 标准位)。灰轴(消色差)下色域矩阵行和 = 1
/// (白点守恒),格点期望值退化为纯 TRC 值;非格点处矩阵通道耦合,
/// 三线性插值有 ≤0.3% 偏差(33³ 下实测,插值路容差即按此放宽)。
void main() {
  final lut = builtinLuts[3];

  test('索引稳定:表序不变,N-Log 还原追加在尾部', () {
    // 监看 LUT 索引按 builtinLuts 表序持久化(monitor_toggles 的
    // monitorLutOf),插入中间会让老用户的索引指到错误 LUT —— 本测
    // 锁死前三项与尾部新增。
    expect(builtinLuts.map((l) => l.title).toList(),
        orderedEquals(['青橙', '褪色胶片', '冷调', 'N-Log 还原']));
    // 33³:矩阵耦合下 17³ 的锚点插值误差最大 −6.7%,33³ 收敛到 ±0.3%。
    expect(lut.size, 33);
  });

  test('网格点精确对账:apply 命中格点即表值本身,无插值误差', () {
    // n = j/32 为 33³ 网格格点;期望 = 官方逆向式 → BT.709 OETF 的精确
    // 计算值(Float32 表存储误差 < 1e-7,容差 1e-4 足量)。立方根段
    // (x < 452)与对数段(x ≥ 452)各取数点;反射率 > 1(x > 619)钳 1,
    // 黑位以下(x < 127.2,即 n < 0.1244)负反射率截 0。
    final anchors = <double, double>{
      0: 0, 0.09375: 0, 0.125: 0.000513, // 黑位以下/附近(截 0)
      0.15625: 0.033171, 0.1875: 0.082135, 0.25: 0.195061, // 立方根段
      0.3125: 0.310467, 0.375: 0.431366,
      0.4375: 0.558166, 0.46875: 0.624246, 0.5: 0.697045, // 对数段
      0.5625: 0.865364, 0.59375: 0.962433,
      0.625: 1, 0.75: 1, 1: 1, // 超白钳制(反射率 > 1)
    };
    anchors.forEach((n, expected) {
      final out = lut.apply(n, n, n);
      for (var ch = 0; ch < 3; ch++) {
        expect(out[ch], closeTo(expected, 1e-4), reason: 'n=$n ch=$ch');
      }
    });
  });

  test('官方逐点锚点(插值路):18% 灰 / 90% 白 / 黑位 / 分段点', () {
    // 18% 灰:官方正向式 650·(0.18+0.0075)^⅓ = 372.03 → n = 0.36367;
    // 精确输出 0.409(BT.709 的 18% 灰标准位 ≈ 41 IRE)。33³ 三线性
    // 插值偏差实测 −0.0021 → 容差 0.005(任务口径 ±2%)。
    final n18 = 650 * _cbrt(0.1875) / 1023;
    expect(lut.apply(n18, n18, n18)[0], closeTo(0.409, 0.005));

    // 90% 白:150·ln(0.9)+619 = 603.20 → n = 0.58963;精确输出 0.949
    // (≈ 95 IRE)。插值偏差实测 −0.0026 → 容差 0.005。
    final n90 = (150 * _ln(0.9) + 619) / 1023;
    expect(lut.apply(n90, n90, n90)[0], closeTo(0.949, 0.005));

    // 黑位:650·0.0075^⅓ = 127.23 → n = 0.12437,反射率恰为 0,输出
    // 须近零(其下负反射率全截 0)。
    final nBlack = 650 * _cbrt(0.0075) / 1023;
    expect(lut.apply(nBlack, nBlack, nBlack)[0], lessThan(0.005));

    // 分段点 x = 452:立方根段与对数段在此连续(官方两式在 y=0.328 /
    // x=451.8 交界,偏差 < 1e-3),输出 ≈ 0.567。
    final nCross = 452 / 1023;
    expect(lut.apply(nCross, nCross, nCross)[0], closeTo(0.567, 0.005));
  });

  test('单调性:各通道沿自身轴严格单调不减;灰轴近单调', () {
    // 色域矩阵对角项为正(1.6605/1.1329/1.1187)→ 输出通道对自身输入
    // 单调;交叉通道可反向(2020 高饱和红转 709 时绿分量下降,是色域
    // 收窄的正确行为,不纳入单调断言)。
    for (final fixed in [0.0, 0.3, 0.7, 1.0]) {
      var prevR = -1.0, prevG = -1.0, prevB = -1.0;
      for (var k = 0; k <= 300; k++) {
        final v = k / 300;
        final r = lut.apply(v, fixed, fixed)[0];
        final g = lut.apply(fixed, v, fixed)[1];
        final b = lut.apply(fixed, fixed, v)[2];
        expect(r, greaterThanOrEqualTo(prevR), reason: 'R 轴 v=$v 回落');
        expect(g, greaterThanOrEqualTo(prevG), reason: 'G 轴 v=$v 回落');
        expect(b, greaterThanOrEqualTo(prevB), reason: 'B 轴 v=$v 回落');
        prevR = r;
        prevG = g;
        prevB = b;
      }
    }
    // 灰轴(对角线):矩阵偏对角角点把格内插值面拖低,在白切割膝
    // (x≈619 前的 [0.594, 0.625] 格)有 ≤0.005 的下坠(0.962 → 0.957),
    // 是矩阵型 3D LUT + 三线性的固有伪影(专业 33³ 查找表同款),断言
    // 其有界(≤0.006)而非严格单调;其余区域不得回落。
    var prev = -1.0;
    for (var k = 0; k <= 1000; k++) {
      final n = k / 1000;
      final v = lut.apply(n, n, n)[0];
      expect(v, greaterThanOrEqualTo(prev - 0.006), reason: '灰轴 n=$n 回落');
      prev = math.max(prev, v);
    }
  });

  test('端点与域外:恒在 [0,1] 且无 NaN(超黑/超白/高饱和)', () {
    final cases = [
      (0.0, 0.0, 0.0),
      (1.0, 1.0, 1.0),
      (1.0, 0.0, 0.0),
      (0.0, 1.0, 0.0),
      (0.0, 0.0, 1.0),
      (0.05, 0.6, 0.99), // 超黑+近白+超白混布
      (0.99, 0.5, 0.02),
      (0.3, 0.3, 0.9), // 高饱和(BT.709 域外,矩阵出负须截 0)
    ];
    for (final (r, g, b) in cases) {
      final out = lut.apply(r, g, b);
      for (var ch = 0; ch < 3; ch++) {
        expect(out[ch].isNaN, isFalse, reason: '($r,$g,$b) ch=$ch NaN');
        expect(out[ch], inInclusiveRange(0.0, 1.0),
            reason: '($r,$g,$b) ch=$ch 越界');
      }
    }
    // 端点精确:黑 = 0(负反射率截 0)、白 = 1(超白钳制,反射率 14.78)。
    expect(lut.apply(0, 0, 0), everyElement(0.0));
    expect(lut.apply(1, 1, 1), everyElement(1.0));
  });

  test('色域矩阵:BT.2020 三原色 → BT.709 同名原色', () {
    // 色域矩阵的原色映射性质:满饱和原色映到原色。N-Log 域 (1,0,0)
    // 是满饱和超亮 BT.2020 红(线性 14.78),经矩阵 + 钳制仍须落在
    // 709 红 (1,0,0) —— 锁死矩阵符号结构(非对角负项)不被抄错。
    expect(lut.apply(1, 0, 0), orderedEquals([1.0, 0.0, 0.0]));
    expect(lut.apply(0, 1, 0), orderedEquals([0.0, 1.0, 0.0]));
    expect(lut.apply(0, 0, 1), orderedEquals([0.0, 0.0, 1.0]));
  });
}

double _cbrt(double v) => math.pow(v, 1 / 3).toDouble();
double _ln(double v) => math.log(v);

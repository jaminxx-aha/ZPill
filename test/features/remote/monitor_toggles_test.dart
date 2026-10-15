import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/data/settings_store.dart';
import 'package:nikon_pill/features/remote/monitor_toggles.dart';

void main() {
  group('ScopeKind(示波器族档位,2026-10-15)', () {
    test('循环:off → 波形 → RGB → 矢量 → 红绿灯 → off', () {
      expect(ScopeKind.off.next, ScopeKind.waveform);
      expect(ScopeKind.waveform.next, ScopeKind.parade);
      expect(ScopeKind.parade.next, ScopeKind.vector);
      expect(ScopeKind.vector.next, ScopeKind.traffic);
      expect(ScopeKind.traffic.next, ScopeKind.off);
    });

    test('设置索引 → 档:表内直取,表外(负数/手改文件)回落关', () {
      expect(scopeKindOf(0), ScopeKind.off);
      expect(scopeKindOf(4), ScopeKind.traffic);
      expect(scopeKindOf(-1), ScopeKind.off);
      expect(scopeKindOf(9), ScopeKind.off);
    });
  });

  group('监看开关组 ↔ 设置桥接', () {
    test('旧档迁移:monitorWaveform 布尔(2026-10-15 前唯一波形开关)→ 波形档',
        () {
      // 旧档只有波形布尔且开着、scope 缺省 off → 升格波形档(一次性迁移)
      final legacy = const AppSettings()
          .copyWith(monitorWaveform: true, monitorScope: ScopeKind.off.index);
      expect(monitorTogglesFromSettings(legacy).scope, ScopeKind.waveform);
      // 写回沿把 scope 一并落盘,且旧字段保连贯(= 是波形档)
      final written =
          applyMonitorToggles(legacy, monitorTogglesFromSettings(legacy));
      expect(written.monitorScope, ScopeKind.waveform.index);
      expect(written.monitorWaveform, isTrue);
      // 再读:已落盘的 scope 档优先,旧字段退役为镜像(不二次迁移)
      expect(monitorTogglesFromSettings(written).scope, ScopeKind.waveform);
    });

    test('旧档关波形 + 新档非 off:不迁移(显式选档优先)', () {
      final s = const AppSettings().copyWith(
          monitorWaveform: false, monitorScope: ScopeKind.vector.index);
      expect(monitorTogglesFromSettings(s).scope, ScopeKind.vector);
      // 波形关 + scope = off:关就是关,不升格
      final off = const AppSettings().copyWith(monitorWaveform: false);
      expect(monitorTogglesFromSettings(off).scope, ScopeKind.off);
    });

    test('桥接往返自闭:五档 + N-Log 刻度,fromSettings → apply 回同一档',
        () {
      for (final kind in ScopeKind.values) {
        final s = applyMonitorToggles(
            const AppSettings(),
            monitorTogglesFromSettings(const AppSettings())
                .copyWith(scope: kind, scopeNLog: true));
        expect(s.monitorScope, kind.index, reason: '$kind 落盘');
        expect(s.monitorWaveform, kind == ScopeKind.waveform,
            reason: '旧字段随 scope 保连贯(= 波形档)');
        expect(s.monitorScopeNLog, isTrue);
        // 读回同一档
        expect(monitorTogglesFromSettings(s).scope, kind);
        expect(monitorTogglesFromSettings(s).scopeNLog, isTrue);
      }
    });

    test('开关组值相等:copyWith 改档产生新值,未改字段保持', () {
      const base = MonitorToggles();
      final scoped = base.copyWith(scope: ScopeKind.parade, scopeNLog: true);
      expect(scoped == base, isFalse);
      expect(scoped.scope, ScopeKind.parade);
      expect(scoped.scopeNLog, isTrue);
      expect(scoped.grid, base.grid);
      expect(scoped.peakingLevel, base.peakingLevel);
      expect(scoped.lutIndex, base.lutIndex);
      // 同参构造值相等(设置监听差分沿用它)
      expect(
          base.copyWith(scope: ScopeKind.parade, scopeNLog: true) == scoped,
          isTrue);
      expect(base.hashCode, isNot(scoped.hashCode));
    });
  });
}

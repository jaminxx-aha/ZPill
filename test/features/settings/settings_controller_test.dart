import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/core/browser/photo_group.dart';
import 'package:z_pill/data/settings_store.dart';
import 'package:z_pill/features/settings/settings_page.dart';

/// 可编程内存设置库:gate 扣住写盘、fail 让下一次写抛错。
final class _GateStore implements SettingsStore {
  final _ctrl = StreamController<AppSettings>.broadcast();
  final writes = <AppSettings>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  Stream<AppSettings> get settings => _ctrl.stream;

  @override
  Future<AppSettings> current() async => const AppSettings();

  @override
  Future<void> update(AppSettings settings) async {
    writes.add(settings);
    final g = gate;
    if (g != null) await g.future;
    if (fail) throw StateError('disk full');
    _ctrl.add(settings);
  }
}

void main() {
  test('写盘失败置 persistFailed;retryPersist 成功后清除', () async {
    final store = _GateStore()..fail = true;
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    await pumpEventQueue(); // 等构造沿 _load 落定

    await controller.setAutoTransfer(true);
    expect(controller.settings.autoTransfer, isTrue, reason: '本次会话内仍生效');
    expect(controller.persistFailed, isTrue);
    expect(store.writes, hasLength(1));

    store.fail = false;
    await controller.retryPersist();
    expect(controller.persistFailed, isFalse);
    expect(store.writes, hasLength(2));
    expect(store.writes.last.autoTransfer, isTrue);
  });

  test('连续改动串行落盘且只保留最新待写快照(旧值不晚到覆盖新值)', () async {
    final store = _GateStore()..gate = Completer<void>();
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    await pumpEventQueue(); // 等构造沿 _load 落定

    // 第一笔写被 gate 扣住;后续三笔只覆盖待写槽,不并发进 store。
    unawaited(controller.setAutoTransfer(true));
    unawaited(controller.setAutoTransferFormat(PhotoDownloadFormat.raw));
    unawaited(controller.setDeSqueeze(1.5));
    await pumpEventQueue();
    expect(store.writes, hasLength(1), reason: '同一时刻只允许一笔写盘');

    store.gate!.complete();
    await pumpEventQueue();
    await pumpEventQueue();

    expect(store.writes, hasLength(2), reason: '首笔 + 合并后的最新快照,不是四笔');
    expect(store.writes.last.autoTransfer, isTrue);
    expect(store.writes.last.autoTransferFormat, PhotoDownloadFormat.raw);
    expect(store.writes.last.deSqueeze, 1.5);
  });
}

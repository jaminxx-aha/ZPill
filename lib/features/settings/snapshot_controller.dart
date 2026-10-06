/// 拍摄配置快照控制器(TODO §三 菜单预设):拍当前配置 / 列表 / 恢复 /
/// 删除。快照纯读随时可用;恢复走 0x1016 写路径,总闸
/// [PtpSession.kSetPropEnabled] 紧急关断时按错误提示(不臆造流量)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/remote/config_snapshot.dart';
import '../../data/config_snapshot_store.dart';

final class SnapshotController extends ChangeNotifier {
  SnapshotController({
    required this.session,
    required this.connection,
    required this.store,
  }) {
    _statesSub = connection.states.listen((s) {
      linkUp = s == CameraLinkState.connected;
      notifyListeners();
    });
    unawaited(_load());
  }

  final PtpSession session;
  final CameraConnection connection;
  final ConfigSnapshotStore store;

  bool linkUp = false;
  bool busy = false;
  String? error;
  String? message;

  Map<String, CameraConfigSnapshot> snapshots = {};
  StreamSubscription<CameraLinkState>? _statesSub;

  Future<void> _load() async {
    try {
      snapshots = await store.loadAll();
    } on Object {
      snapshots = {}; // 通道未就绪(测试环境):空表可用
    }
    notifyListeners();
  }

  /// 拍下当前配置并以 [name] 保存(同名覆盖)。
  Future<void> capture(String name) async {
    if (busy) return;
    if (!linkUp) {
      error = '未连接相机,无法拍配置';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    message = null;
    notifyListeners();
    try {
      final snapshot = await CameraConfigSnapshotter.capture(session);
      await store.save(name, snapshot);
      snapshots = await store.loadAll();
      message = '已保存「$name」(${snapshot.props.length} 项属性)';
    } on Exception catch (e) {
      error = '快照失败:$e';
    } on Object {
      // 存储/通道异常:尽力报错,不留半开状态
      error = '快照保存失败';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 把命名快照恢复到相机(写路径,总闸未开时提示)。
  Future<void> restore(String name) async {
    if (busy) return;
    final snapshot = snapshots[name];
    if (snapshot == null) return;
    if (!linkUp) {
      error = '未连接相机,无法恢复';
      notifyListeners();
      return;
    }
    if (!PtpSession.kSetPropEnabled) {
      error = '恢复已被总闸关断(紧急关断)';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    message = null;
    notifyListeners();
    try {
      final report = await CameraConfigSnapshotter.restore(session, snapshot);
      message = '$report';
    } on Exception catch (e) {
      error = '恢复失败:$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> delete(String name) async {
    await store.delete(name);
    snapshots = await store.loadAll();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel());
    super.dispose();
  }
}

/// 设置页的快照区块(controller 从 [AppServices.instance] 取)。
Widget buildSnapshotSection(BuildContext context) {
  final controller = AppServices.instance.snapshotController;
  return ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      children: [
        const Divider(),
        ListTile(
          title: const Text('拍摄配置快照'),
          subtitle: Text(controller.linkUp
              ? '把当前机身设置存成命名预设,或把预设恢复回相机'
              : '连接相机后可拍下当前配置'),
          trailing: FilledButton.tonal(
            onPressed:
                controller.busy || !controller.linkUp ? null : () => _promptCapture(context, controller),
            child: controller.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('拍配置'),
          ),
        ),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (controller.message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(controller.message!,
                style: const TextStyle(color: Colors.green)),
          ),
        for (final e in controller.snapshots.entries)
          ListTile(
            dense: true,
            leading: const Icon(Icons.tune),
            title: Text(e.key),
            subtitle: Text(
                '${e.value.model} · ${e.value.props.length} 项 · ${e.value.capturedAt.toLocal().toString().split(' ').first}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '恢复到相机',
                  icon: const Icon(Icons.settings_backup_restore),
                  onPressed: controller.busy || !controller.linkUp
                      ? null
                      : () => controller.restore(e.key),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => controller.delete(e.key),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

Future<void> _promptCapture(BuildContext context, SnapshotController controller) async {
  final field = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('命名这份配置'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(hintText: '如:婚礼室内 · A 档'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(field.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  field.dispose();
  if (name == null || name.isEmpty) return;
  await controller.capture(name);
}

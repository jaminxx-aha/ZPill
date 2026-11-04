/// 拍摄配置快照控制器(菜单预设):拍当前配置 / 列表 / 恢复 /
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
import '../../design/app_colors.dart';
import '../../l10n/l10n.dart';
import '../../l10n/message.dart';
import '../remote/remote_controller.dart' show CaptureMode;

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
  L10nMessage? error;
  L10nMessage? message;

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
      error = (key: 'snapshot.notConnectedCapture', args: null);
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
      message = (
        key: 'snapshot.savedNamed',
        args: {
          'name': name,
          'n': snapshot.props.length,
        }
      );
    } on Exception catch (e) {
      error = (key: 'snapshot.captureFailed', args: {'e': e});
    } on Object {
      // 存储/通道异常:尽力报错,不留半开状态
      error = (key: 'snapshot.saveFailed', args: null);
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
      error = (key: 'snapshot.notConnectedRestore', args: null);
      notifyListeners();
      return;
    }
    if (!PtpSession.kSetPropEnabled) {
      error = (key: 'snapshot.restoreKilled', args: null);
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    message = null;
    notifyListeners();
    try {
      final report = await CameraConfigSnapshotter.restore(
        session,
        snapshot,
        // 视频档跳过照片向属性(0x5007/0x5013/0x5018):写进去会卡坏
        // 视频门(2026-11-05 真机 0xA004)。模式取当前相机镜像。
        videoMode: AppServices.instance.remoteController.cameraMode ==
            CaptureMode.video,
      );
      // report 来自 core/remote(本波未抽取,中文如实回落,后续波再收)
      message = (key: '$report', args: null);
    } on Exception catch (e) {
      error = (key: 'snapshot.restoreFailed', args: {'e': e});
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
          title: Text(context.t('snapshot.title')),
          subtitle: Text(controller.linkUp
              ? context.t('snapshot.subtitle')
              : context.t('snapshot.emptyHint')),
          trailing: FilledButton.tonal(
            onPressed: controller.busy || !controller.linkUp
                ? null
                : () => _promptCapture(context, controller),
            child: controller.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t('snapshot.capture')),
          ),
        ),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                context.t(controller.error!.key, controller.error!.args),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (controller.message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                context.t(controller.message!.key, controller.message!.args),
                style: TextStyle(color: AppColors.success(context))),
          ),
        for (final e in controller.snapshots.entries)
          ListTile(
            dense: true,
            leading: const Icon(Icons.tune),
            title: Text(e.key),
            subtitle: Text(context.t('snapshot.metaLine', {
              'model': e.value.model,
              'n': e.value.props.length,
              'date': e.value.capturedAt.toLocal().toString().split(' ').first,
            })),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.t('snapshot.restore'),
                  icon: const Icon(Icons.settings_backup_restore),
                  onPressed: controller.busy || !controller.linkUp
                      ? null
                      : () => controller.restore(e.key),
                ),
                IconButton(
                  tooltip: context.t('common.delete'),
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

Future<void> _promptCapture(
    BuildContext context, SnapshotController controller) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => const _SnapshotNameDialog(),
  );
  if (name == null || name.isEmpty) return;
  await controller.capture(name);
}

/// 命名对话框自持 controller:TextEditingController 必须在路由退场动画
/// 结束后才 dispose。旧实现在 showDialog 返回处立即 dispose,退场中的
/// TextField 继续使用它 → 「used after being disposed」并把 unmount
/// 级联成 _dependents.isEmpty 断言红屏(2026-11-05 真机)。
class _SnapshotNameDialog extends StatefulWidget {
  const _SnapshotNameDialog();

  @override
  State<_SnapshotNameDialog> createState() => _SnapshotNameDialogState();
}

class _SnapshotNameDialogState extends State<_SnapshotNameDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('snapshot.nameTitle')),
      content: TextField(
        controller: _field,
        autofocus: true,
        decoration: InputDecoration(hintText: context.t('snapshot.nameHint')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_field.text.trim()),
          child: Text(context.t('common.save')),
        ),
      ],
    );
  }
}

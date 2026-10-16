/// 传输页(图库页右上角徽标进入):下载任务列表(进度/速度/剩余时间/
/// 取消/导入结果)。应用内文件区块已移交图库 tab(LocalLibraryPage,
/// 同一 TransfersController 的 appFiles 数据源)。
///
/// TransfersController 是共享实例(AppServices 持有):订阅
/// TransferEngine.tasks 快照流;速度/剩余时间按字节增量真实计算
/// (SpeedEstimator 滑动窗口,禁全量平均)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/transfer/speed_estimator.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../l10n/l10n.dart';
import '../../platform/gallery_saver.dart';
import '../common/format.dart';
import '../common/widgets/states.dart';

final class TransfersController extends ChangeNotifier {
  TransfersController({required this.engine, required this.gallery}) {
    _sub = engine.tasks.listen((ts) {
      _absorb(ts);
      tasks = ts;
      notifyListeners();
    });
  }

  final TransferEngine engine;
  final GallerySaver gallery;

  List<TransferTask> tasks = const [];
  List<File> appFiles = const [];

  final Map<String, SpeedEstimator> _speeds = {};
  final Map<String, double?> _lastSpeed = {};
  final Set<String> _seenAppDone = {};
  late final StreamSubscription<List<TransferTask>> _sub;

  /// 当前速度(bytes/s);只在 running 时有意义。
  double? speedOf(String taskId) => _lastSpeed[taskId];

  /// 剩余时间;速度未知返回 null。
  Duration? etaOf(TransferTask task) =>
      _speeds[task.id]?.etaFor(task.totalBytes - task.receivedBytes);

  Future<void> cancel(String taskId) => engine.cancel(taskId);

  Future<void> clearHistory() async {
    await engine.clearHistory();
    _speeds.clear();
    _lastSpeed.clear();
    _seenAppDone.clear();
  }

  /// 「应用内文件」列表(downloadsDir);平台通道不可用时静默留空
  /// (非 ohos 平台/测试环境)。
  Future<void> refreshAppFiles() async {
    try {
      final dir = await gallery.downloadsDir();
      final d = Directory(dir);
      appFiles = d.existsSync()
          ? d.listSync().whereType<File>().toList(growable: false)
          : const <File>[];
    } on Exception {
      appFiles = const [];
    }
    notifyListeners();
  }

  /// 批量删除应用内文件:逐个删(单个失败不中断批次),一次刷新一次
  /// notify。
  Future<void> deleteAppFiles(Iterable<File> files) async {
    for (final file in files) {
      try {
        await file.delete();
      } on FileSystemException {
        // 删失败:刷新后自然回显
      }
    }
    await refreshAppFiles();
  }

  Future<void> deleteAppFile(File file) => deleteAppFiles([file]);

  void _absorb(List<TransferTask> ts) {
    var appFileLanded = false;
    for (final t in ts) {
      if (t.state == TransferState.running) {
        final est = _speeds.putIfAbsent(t.id, SpeedEstimator.new);
        est.add(DateTime.now(), t.receivedBytes);
        _lastSpeed[t.id] = est.bytesPerSecond();
      }
      // app 目的地新完成 → 应用内文件列表要出新人(页面常驻 IndexedStack,
      // initState 不会再来)。
      if (t.state == TransferState.completed &&
          t.destination == TransferDestination.app &&
          _seenAppDone.add(t.id)) {
        appFileLanded = true;
      }
    }
    if (appFileLanded) {
      refreshAppFiles();
    }
    // 终态任务的估算器可以丢了(速度只对 running 显示)。
    final active = {for (final t in ts) t.id};
    _speeds.removeWhere((id, _) => !active.contains(id));
    _lastSpeed.removeWhere((id, _) => !active.contains(id));
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  // 应用级共享实例;本页不持有、不 dispose。
  TransfersController get _controller =>
      AppServices.instance.transfersController;

  @override
  void initState() {
    super.initState();
    _controller.refreshAppFiles();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(context.t('transfers.title')),
          actions: [
            IconButton(
              tooltip: context.t('transfers.clearHistory'),
              onPressed: _controller.clearHistory,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    final tasks = _controller.tasks;
    if (tasks.isEmpty) {
      // EmptyState 显示端已包 t(),此处再包属双重包裹(无害,见 states.dart)
      return EmptyState(
          icon: Icons.download_outlined,
          message: context.t('transfers.empty'));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: tasks.length,
      itemBuilder: (_, i) => _TaskTile(task: tasks[i], controller: _controller),
    );
  }
}

/// 单任务行:状态文案 + 进度条(下载中)+ 取消按钮。
class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.controller});

  final TransferTask task;
  final TransfersController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speed = controller.speedOf(task.id);
    final eta = controller.etaOf(task);

    final Widget trailing;
    if (task.state == TransferState.queued ||
        task.state == TransferState.running) {
      trailing = IconButton(
        tooltip: context.t('common.cancel'),
        onPressed: () => controller.cancel(task.id),
        icon: const Icon(Icons.close),
      );
    } else {
      trailing = const SizedBox(width: 40); // 占位对齐
    }

    // 状态文案原文即 t() 键;字节量/速度为数字格式产物不抽,「剩 Ns」与
    // 失败串走参数模板(中文拼回逐字一致);error 运行期串经 t 未命中
    // 原样回落,「未知错误」为既有键可译。
    final subtitle = switch (task.state) {
      TransferState.queued => context.t('transfers.queued'),
      TransferState.running => [
          formatBytes(task.receivedBytes),
          if (task.totalBytes > 0) '/ ${formatBytes(task.totalBytes)}',
          if (speed != null) '${(speed / 1024 / 1024).toStringAsFixed(1)}MB/s',
          if (eta != null) context.t('transfers.secondsLeft', {'n': eta.inSeconds + 1}),
        ].join(' · '),
      TransferState.completed => switch (task.destination) {
          TransferDestination.gallery => task.galleryUri != null
              ? context.t('transfers.importedAlbum')
              : context.t('transfers.completedNotImported'),
          TransferDestination.app => context.t('transfers.savedInApp'),
        },
      TransferState.failed => context.t('transfers.failedRetries', {
          'e': context.t(task.error ?? 'common.unknownError'),
          'n': task.attempts,
        }),
      TransferState.cancelled => context.t('common.cancelled'),
    };

    return ListTile(
      dense: true,
      leading: Icon(
        task.destination == TransferDestination.gallery
            ? Icons.photo_library_outlined
            : Icons.folder_outlined,
      ),
      title: Text(task.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: task.state == TransferState.failed
                    ? theme.colorScheme.error
                    : null,
              )),
          if (task.state == TransferState.running)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: task.progress),
            ),
        ],
      ),
      trailing: trailing,
    );
  }
}

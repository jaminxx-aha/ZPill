/// 下载页:任务列表(进度/速度/剩余时间/取消/导入结果)+
/// 「应用内文件」区块(downloadsDir 直读、应用内查看、删除)。
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
import '../../platform/gallery_saver.dart';
import '../common/format.dart';

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

  Future<void> deleteAppFile(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // 删失败:刷新后自然回显
    }
    await refreshAppFiles();
  }

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
  TransfersController get _controller => AppServices.instance.transfersController;

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
          title: const Text('下载'),
          actions: [
            IconButton(
              tooltip: '清空历史',
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
    final files = _controller.appFiles;
    if (tasks.isEmpty && files.isEmpty) {
      return const Center(child: Text('暂无下载任务\n(在「相册」页多选或大图页单张下载)',
          textAlign: TextAlign.center));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: tasks.length + (files.isEmpty ? 0 : 1 + files.length),
      itemBuilder: (_, i) {
        if (i < tasks.length) {
          return _TaskTile(
            task: tasks[i],
            controller: _controller,
          );
        }
        final j = i - tasks.length;
        if (j == 0) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text('应用内文件', style: TextStyle(fontWeight: FontWeight.bold)),
          );
        }
        return _AppFileTile(file: files[j - 1], controller: _controller);
      },
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
        tooltip: '取消',
        onPressed: () => controller.cancel(task.id),
        icon: const Icon(Icons.close),
      );
    } else {
      trailing = const SizedBox(width: 40); // 占位对齐
    }

    final subtitle = switch (task.state) {
      TransferState.queued => '排队中',
      TransferState.running => [
          formatBytes(task.receivedBytes),
          if (task.totalBytes > 0) '/ ${formatBytes(task.totalBytes)}',
          if (speed != null) '${(speed / 1024 / 1024).toStringAsFixed(1)}MB/s',
          if (eta != null)
            '剩 ${(eta.inSeconds + 1)}s',
        ].join(' · '),
      TransferState.completed => switch (task.destination) {
          TransferDestination.gallery => task.galleryUri != null
              ? '已导入相册'
              : '已完成 · 未导入(可重新下载再试)',
          TransferDestination.app => '已保存到应用内',
        },
      TransferState.failed => '失败:${task.error ?? '未知错误'}(重试 ${task.attempts} 次)',
      TransferState.cancelled => '已取消',
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
              maxLines: 2, overflow: TextOverflow.ellipsis,
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

/// 应用内文件行:图片可应用内查看;删除按钮。
class _AppFileTile extends StatelessWidget {
  const _AppFileTile({required this.file, required this.controller});

  final File file;
  final TransfersController controller;

  static const _viewableExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  bool get _viewable {
    final name = file.uri.pathSegments.last.toLowerCase();
    return _viewableExts.any(name.endsWith);
  }

  @override
  Widget build(BuildContext context) {
    final stat = file.statSync();
    final name = file.uri.pathSegments.last;
    return ListTile(
      dense: true,
      leading: Icon(
          _viewable ? Icons.image_outlined : Icons.insert_drive_file_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        formatBytes(stat.size),
        if (formatDateTime(stat.modified) != null) formatDateTime(stat.modified)!,
      ].join(' · ')),
      onTap: _viewable ? () => _view(context, name) : null,
      trailing: IconButton(
        tooltip: '删除',
        onPressed: () => controller.deleteAppFile(file),
        icon: const Icon(Icons.delete_outline),
      ),
    );
  }

  void _view(BuildContext context, String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AppImageViewer(file: file, title: name),
      ),
    );
  }
}

/// 应用内图片查看(黑底 + 双指缩放;NEF 等原生格式 Flutter 解不了,
/// 此页只接待可解码扩展名)。
class _AppImageViewer extends StatelessWidget {
  const _AppImageViewer({required this.file, required this.title});

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }
}

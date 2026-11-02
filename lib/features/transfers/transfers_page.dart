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
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/gallery_saver.dart';
import '../common/format.dart';
import '../common/widgets/confirm_dialog.dart';
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

  /// 首次「应用内文件」扫描是否已回(含失败落空):false 期间图库页显
  /// 扫描态,与「真空库」区分(异步化后存在真实的扫描窗)。
  bool appFilesScanned = false;

  /// 刷新纪元:并发在途的旧结果不覆盖新结果(见 [refreshAppFiles])。
  int _refreshEpoch = 0;

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

  /// 失败/未导入任务能否重下(进程内批次仍持有原始对象;历史恢复的
  /// 任务为 false)。
  bool canRetry(String taskId) {
    final e = engine;
    if (e is! TransferRetry) return false;
    return (e as TransferRetry).canRetry(taskId);
  }

  /// 重下并重新走目的地流程(失败重试 / 未导入重新下载导入)。
  Future<bool> retry(String taskId) async {
    final e = engine;
    if (e is! TransferRetry) return false;
    return (e as TransferRetry).retry(taskId);
  }

  /// 取消全部进行中任务(队列/下载/后处理旗标;后处理不可中断)。
  Future<void> cancelAll() async {
    for (final task in tasks) {
      if (!task.isTerminal) await engine.cancel(task.id);
    }
  }

  /// 左滑单独删除一条历史记录(引擎侧仅终态响应)。
  Future<void> removeRecord(String taskId) => engine.removeRecord(taskId);

  Future<void> clearHistory() async {
    await engine.clearHistory();
    _speeds.clear();
    _lastSpeed.clear();
    _seenAppDone.clear();
  }

  /// 「应用内文件」列表(downloadsDir);平台通道不可用时静默留空
  /// (非 ohos 平台/测试环境)。
  ///
  /// 列目录走 `d.list()` 异步(旧 `listSync()` 在首帧装配期同步扫盘:
  /// HomeShell PageView 预建图库 tab,首帧就被目录枚举占住)。异步化
  /// 带来乱序完成窗口(删除沿刷新 vs 任务完成沿刷新可能并发在途):
  /// 单调纪元闸兜底,旧结果晚到即弃,不覆盖新结果;调用方
  /// (initState/fire-and-forget)无需新增守卫,notify 收口在此。
  Future<void> refreshAppFiles() async {
    final epoch = ++_refreshEpoch;
    try {
      final dir = await gallery.downloadsDir();
      final d = Directory(dir);
      final files = await d.exists()
          ? await d.list().where((e) => e is File).cast<File>().toList()
          : const <File>[];
      if (epoch != _refreshEpoch) return; // 更新的刷新已接管:旧结果弃
      appFiles = files;
      appFilesScanned = true;
    } on Exception {
      if (epoch != _refreshEpoch) return;
      appFiles = const [];
      appFilesScanned = true;
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

/// 传输页过滤档:全部 / 进行中 / 已完成 / 失败(计数实时取任务表)。
enum _TransferFilter { all, active, completed, failed }

/// 档位文案:词表暂无独立的「进行中 / 已完成 / 失败」档位键 ——
/// 进行中复用 processing 状态词(去掉省略号),失败取失败模板冒号前
/// 的状态词(中英模板同构),完成用 common.done。档位键补齐后改直取。
String _filterLabel(BuildContext context, _TransferFilter filter) =>
    switch (filter) {
      _TransferFilter.all => context.t('common.all'),
      _TransferFilter.active =>
        context.t('transfers.processing').replaceAll('…', '').trim(),
      _TransferFilter.completed => context.t('common.done'),
      _TransferFilter.failed => context.t('transfers.needsAttention'),
    };

/// 视频件(行图标按类型区分;MOV/MP4 为相机视频容器)。
bool _isVideoFile(String filename) {
  final upper = filename.toUpperCase();
  return upper.endsWith('.MOV') || upper.endsWith('.MP4');
}

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key, this.controller});

  /// 注入面(widget 测试);null = 应用级共享实例(AppServices 持有,
  /// 本页不持有、不 dispose)。
  final TransfersController? controller;

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  TransfersController get _controller =>
      widget.controller ?? AppServices.instance.transfersController;

  _TransferFilter _filter = _TransferFilter.all;

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
          toolbarHeight: AppSizes.appBarPortrait,
          centerTitle: true,
          title: Text(context.t('transfers.title'),
              style: Theme.of(context).textTheme.titleLarge),
          actions: [
            if (_controller.tasks.any((t) => !t.isTerminal))
              IconButton(
                tooltip: context.t('transfers.cancelAll'),
                onPressed: () => unawaited(_confirmCancelAll(context)),
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            IconButton(
              tooltip: context.t('transfers.clearHistory'),
              onPressed: _controller.tasks.isEmpty
                  ? null
                  : () => unawaited(_confirmClearHistory(context)),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Future<void> _confirmCancelAll(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('transfers.cancelAllConfirmTitle'),
      content: context.t('transfers.cancelAllConfirmBody'),
      confirmLabel: context.t('transfers.cancelAll'),
      destructive: true,
    );
    if (confirmed) await _controller.cancelAll();
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('transfers.clearHistoryConfirmTitle'),
      content: context.t('transfers.clearHistoryConfirmBody'),
      confirmLabel: context.t('transfers.clearHistory'),
      destructive: true,
    );
    if (confirmed) await _controller.clearHistory();
  }

  Widget _body() {
    final theme = Theme.of(context);
    final tasks = _controller.tasks;
    final counts = {
      for (final filter in _TransferFilter.values)
        filter: tasks.where((task) => filter.allows(task)).length,
    };
    final filtered = [
      for (final task in tasks)
        if (_filter.allows(task)) task,
    ];

    final Widget content;
    if (tasks.isEmpty) {
      // EmptyState 显示端已包 t(),此处再包属双重包裹(无害,见 states.dart)
      content = EmptyState(
          icon: Icons.download_outlined, message: context.t('transfers.empty'));
    } else if (filtered.isEmpty) {
      // 有任务但当前档为空:用既有「无」键,不假造「本档为空」文案。
      content = EmptyState(
          icon: Icons.filter_alt_off_outlined,
          message: context.t('common.none'));
    } else {
      content = _taskList(context, theme, filtered);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _filterBar(context, counts),
        Expanded(child: content),
      ],
    );
  }

  Widget _filterBar(BuildContext context, Map<_TransferFilter, int> counts) {
    final width = MediaQuery.sizeOf(context).width;
    final pad = AppBreakpoints.pagePadding(width);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.sm, pad, AppSpacing.xs),
      child: Row(
        children: [
          for (final filter in _TransferFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: _FilterPill(
                key: ValueKey('transfer-filter-${filter.name}'),
                label:
                    '${_filterLabel(context, filter)} ${counts[filter] ?? 0}',
                selected: _filter == filter,
                onSelected: () => setState(() => _filter = filter),
              ),
            ),
        ],
      ),
    );
  }

  Widget _taskList(
      BuildContext context, ThemeData theme, List<TransferTask> display) {
    // 排序:进行中在前(入队序),历史按下载时间倒序(持久化记录一并
    // 由引擎快照给出)。
    final actives = [
      for (final t in display)
        if (!t.isTerminal) t
    ];
    final history = [
      for (final t in display)
        if (t.isTerminal) t,
    ]..sort((a, b) {
        final epoch0 = DateTime.fromMillisecondsSinceEpoch(0);
        final fa = a.finishedAt ?? epoch0;
        final fb = b.finishedAt ?? epoch0;
        return fb.compareTo(fa);
      });
    final rows = [...actives, ...history];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final task = rows[i];
        final tile = _TaskTile(task: task, controller: _controller);
        if (!task.isTerminal) return tile; // 进行中:取消走行尾 ✕,不滑删
        // 左滑单独删除该记录(历史行);删除沿引擎同步出快照,行即消失。
        return Dismissible(
          key: ValueKey('transfer-${task.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: theme.colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: AppSpacing.xl),
            child: Icon(Icons.delete_outline, color: theme.colorScheme.onError),
          ),
          onDismissed: (_) => _controller.removeRecord(task.id),
          child: tile,
        );
      },
    );
  }
}

/// 999 胶囊过滤片(与设置页同款视觉;跨模块不复用私有件,故本地一份)。
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color:
                  selected ? AppColors.onBrandYellow : scheme.onSurfaceVariant,
            ),
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      selectedColor: AppColors.accentYellow,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: scheme.outlineVariant),
      shape: const StadiumBorder(),
      labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 单任务行:文件图标盒 + 文件名/状态/数据行 + 进度条(下载中)+ 行尾
/// 取消(进行中)或终态状态标(完成/失败/取消)。
class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.controller});

  final TransferTask task;
  final TransfersController controller;

  /// 耗时文案:分秒模板(m/n 占位序两语种一致,词表闸口径)。
  static String _durationLabel(BuildContext context, Duration d) {
    if (d.inMinutes >= 1) {
      return context.t('transfers.durationMinSec',
          {'m': d.inMinutes, 'n': d.inSeconds % 60});
    }
    return context.t('transfers.durationSec',
        {'n': (d.inMilliseconds / 1000).toStringAsFixed(1)});
  }

  Future<void> _retry(BuildContext context) async {
    final ok = await controller.retry(task.id);
    if (ok || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(context.t('transfers.retryUnavailable'))));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final speed = controller.speedOf(task.id);
    final eta = controller.etaOf(task);

    final notImported = task.state == TransferState.completed &&
        task.destination == TransferDestination.gallery &&
        task.galleryUri == null;
    final Widget trailing;
    if (task.needsAttention) {
      // 失败/未导入:能重下就给行内重试(进程内批次仍持有原始对象);
      // 历史恢复的任务没有条目,只给警告标,点重试会如实提示重新入队。
      trailing = controller.canRetry(task.id)
          ? IconButton(
              tooltip: context
                  .t(notImported ? 'transfers.redownload' : 'common.retry'),
              onPressed: () => unawaited(_retry(context)),
              icon: Icon(Icons.refresh, size: 22, color: scheme.error),
            )
          : Icon(Icons.warning_amber_rounded, size: 22, color: scheme.error);
    } else if (task.state == TransferState.queued ||
        task.state == TransferState.running) {
      trailing = IconButton(
        tooltip: context.t('common.cancel'),
        onPressed: () => controller.cancel(task.id),
        icon: const Icon(Icons.close),
      );
    } else {
      // processing 也不给取消钮:文件已完整落盘,后处理收尾后照常完成,
      // 取消钮点了没反应,不如不给。终态给状态标(非按钮,无假动作)。
      trailing = switch (task.state) {
        TransferState.completed =>
          Icon(Icons.check_circle, size: 22, color: AppColors.success(context)),
        TransferState.failed =>
          Icon(Icons.error_outline, size: 22, color: scheme.error),
        TransferState.cancelled =>
          Icon(Icons.block, size: 22, color: scheme.outline),
        _ => const SizedBox(width: 22),
      };
    }

    // 状态文案原文即 t() 键;字节量/速度为数字格式产物不抽,「剩 Ns」与
    // 失败串走参数模板(中文拼回逐字一致);error 运行期串经 t 未命中
    // 原样回落,「未知错误」为既有键可译。
    final subtitle = switch (task.state) {
      TransferState.queued => context.t('transfers.queued'),
      TransferState.running => [
          // 设计稿口径:已收 / 总量 是一段,不拆成两段夹「· /」。
          if (task.totalBytes > 0)
            '${formatBytes(task.receivedBytes)} / '
                '${formatBytes(task.totalBytes)}'
          else
            formatBytes(task.receivedBytes),
          if (speed != null) '${(speed / 1024 / 1024).toStringAsFixed(1)}MB/s',
          if (eta != null)
            context.t('transfers.secondsLeft', {'n': eta.inSeconds + 1}),
        ].join(' · '),
      // 已收满但还在拆分/水印/XMP(与下一文件的下载并行)。
      TransferState.processing => context.t('transfers.processing'),
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

    // 历史行补充数据(下载时间 · 大小 · 耗时 · 速度):下载速度只对
    // completed 设口径(失败/取消半程速度失真不显),耗时缺首跑(排队
    // 即取消)不显。数字格式产物不进词表,耗时单位走键。
    final meta = switch (task.state) {
      TransferState.completed => [
          formatRecentDateTime(task.finishedAt),
          if (task.receivedBytes > 0) formatBytes(task.receivedBytes),
          if (task.elapsed case final d?) _durationLabel(context, d),
          if (task.downloadSpeed case final s?)
            '${(s / 1024 / 1024).toStringAsFixed(1)}MB/s',
        ],
      TransferState.failed || TransferState.cancelled => [
          formatRecentDateTime(task.finishedAt),
          if (task.elapsed case final d?) _durationLabel(context, d),
        ],
      _ => const <String?>[],
    }
        .nonNulls
        .join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: AppSizes.iconVisual,
            height: AppSizes.iconVisual,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              // 行图标按文件类型(设计稿:照片=image、视频=movie);
              // 应用内目的地用文件夹表达去向。
              _isVideoFile(task.filename)
                  ? Icons.movie_outlined
                  : task.destination == TransferDestination.gallery
                      ? Icons.image_outlined
                      : Icons.folder_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(task.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.titleS),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyS.copyWith(
                      color: task.state == TransferState.failed
                          ? scheme.error
                          : AppColors.muted(context),
                    )),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyS
                            .copyWith(color: AppColors.muted(context))),
                  ),
                if (task.state == TransferState.running)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 4,
                        color: AppColors.accentYellow,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                if (task.state == TransferState.processing)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      // 不定进度:后处理无确定性刻度
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        color: AppColors.accentYellow,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          trailing,
        ],
      ),
    );
  }
}

extension on _TransferFilter {
  bool allows(TransferTask task) => switch (this) {
        _TransferFilter.all => true,
        _TransferFilter.active => !task.isTerminal,
        // 「已完成」只算真正落定(含已导入相册);未导入归「需处理」。
        _TransferFilter.completed =>
          task.state == TransferState.completed && !task.needsAttention,
        _TransferFilter.failed => task.needsAttention,
      };
}

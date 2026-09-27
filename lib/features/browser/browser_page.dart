/// 浏览页(TODO.md §三):目录列表 + 单文件下载(P0 闭环);
/// 多选/传输入队/过滤排序(P2)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/directory_navigator.dart';
import '../../core/browser/object_entry.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/ptpip/object_format.dart';
import '../../core/transfer/object_downloader.dart';
import '../../core/transfer/speed_estimator.dart';

class BrowserController extends ChangeNotifier {
  BrowserController({this.navigator, this.connection, this.downloader}) {
    // 连接成功 → 自动加载根目录(浏览页处于后台 tab 时也能就绪)。
    connection?.states.listen((s) {
      if (s == CameraLinkState.connected) {
        load();
      }
    });
  }

  final DirectoryNavigator? navigator;
  final CameraConnection? connection;
  final ObjectDownloader? downloader;

  List<ObjectEntry> entries = const [];
  bool loading = false;
  String? error;

  bool get canGoUp => navigator?.canGoUp ?? false;

  /// 当前文件夹;null 表示根目录(AppBar 标题用)。
  ObjectEntry? get currentFolder => navigator?.currentFolder;

  Future<void> load() async {
    final nav = navigator;
    if (nav == null || loading) {
      return;
    }
    await _run(nav.refresh);
  }

  Future<void> enter(ObjectEntry folder) async {
    final nav = navigator;
    if (nav == null || loading) {
      return;
    }
    await _run(() => nav.enter(folder));
  }

  Future<void> goUp() async {
    final nav = navigator;
    if (nav == null || loading) {
      return;
    }
    await _run(nav.goUp);
  }

  Future<void> _run(Future<List<ObjectEntry>> Function() op) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      entries = await op();
    } on Exception catch (e) {
      entries = const [];
      error = '加载失败:$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 单文件下载(P0;多选批量 → TransferEngine 留 P2)。
  Future<ObjectDownload> download(
    ObjectEntry entry, {
    void Function(int receivedBytes)? onProgress,
  }) {
    final d = downloader;
    if (d == null) {
      throw StateError('downloader 未注入');
    }
    return d.download(entry, onProgress: onProgress);
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  // 应用级共享实例;本页不持有、不 dispose。
  BrowserController get _controller => AppServices.instance.browserController;

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return PopScope(
          // 子文件夹内:返回键先退一级目录;根目录放行系统返回。
          canPop: !controller.canGoUp,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              controller.goUp();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(controller.currentFolder?.name ?? '浏览'),
              actions: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: controller.loading ? null : controller.load,
                  icon: const Icon(Icons.refresh),
                ),
                // TODO(P2): 类型过滤(JPEG/NEF/TIFF/MP4/MOV)与排序入口,
                // 过滤排序状态放 BrowserController,按钮绑这里。
                const Icon(Icons.filter_list),
                const SizedBox(width: 12),
              ],
            ),
            body: _body(controller),
          ),
        );
      },
    );
  }

  Widget _body(BrowserController controller) {
    if (controller.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在读取相机目录…\n(首次需枚举全部对象,约数秒)'),
            SizedBox(height: 8),
          ],
        ),
      );
    }
    if (controller.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(controller.error!),
            ),
            FilledButton(onPressed: controller.load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (controller.entries.isEmpty) {
      return const Center(child: Text('未连接:请先在「相机」页连接'));
    }
    return ListView.builder(
      itemCount: controller.entries.length,
      itemBuilder: (_, i) {
        final entry = controller.entries[i];
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(entry)),
          title: Text(
            entry.name,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          subtitle: Text(_subtitleFor(entry)),
          onTap: entry.isFolder
              ? () => controller.enter(entry)
              : () => _downloadWithDialog(entry),
        );
      },
    );
  }

  // ── 单文件下载 + 进度/结果对话框(P0 测速数据在此呈现) ────────────

  Future<void> _downloadWithDialog(ObjectEntry entry) async {
    final controller = _controller;
    final estimator = SpeedEstimator();
    final progress = ValueNotifier<_DownloadProgress>(
      _DownloadProgress(total: entry.sizeInBytes),
    );
    final watch = Stopwatch()..start();

    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<_DownloadProgress>(
        valueListenable: progress,
        builder: (dialogContext, p, _) =>
            _downloadDialog(dialogContext, entry, p, estimator),
      ),
    );

    try {
      final result = await controller.download(entry, onProgress: (n) {
        estimator.add(DateTime.now(), n);
        progress.value = progress.value.withReceived(n);
      });
      watch.stop();
      // P0 传输测速落档:文件名 / 字节数 / 耗时 / 平均速度。
      debugPrint('[NikonBridge] ${entry.name}: ${result.bytes}B in '
          '${result.elapsed.inMilliseconds}ms = '
          '${result.megabytesPerSecond.toStringAsFixed(2)}MB/s');
      progress.value = progress.value.withDone(result);
    } on Exception catch (e) {
      watch.stop();
      progress.value = progress.value.withError('$e');
    }

    await dialogClosed;
  }

  Widget _downloadDialog(
    BuildContext dialogContext,
    ObjectEntry entry,
    _DownloadProgress p,
    SpeedEstimator estimator,
  ) {
    final Widget content;
    final List<Widget> actions;
    if (p.error != null) {
      content = Text('下载失败:${p.error}');
      actions = [_closeButton(dialogContext)];
    } else if (p.result != null) {
      final r = p.result!;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已保存 ${_formatBytes(r.bytes)},'
                  '耗时 ${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s,'
                  '平均 ${r.megabytesPerSecond.toStringAsFixed(2)}MB/s',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (r.galleryUri != null)
            const Text('已导入系统相册')
          else
            SelectableText('保存位置(应用沙箱):${r.path}'),
        ],
      );
      actions = [_closeButton(dialogContext)];
    } else {
      final bps = estimator.bytesPerSecond();
      final speed = bps == null
          ? ''
          : ' · ${(bps / 1024 / 1024).toStringAsFixed(1)}MB/s';
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: p.total > 0 ? p.received / p.total : null,
          ),
          const SizedBox(height: 12),
          Text('${_formatBytes(p.received)} / ${_formatBytes(p.total)}$speed'),
        ],
      );
      actions = const [];
    }
    return AlertDialog(
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: content,
      actions: actions,
    );
  }

  Widget _closeButton(BuildContext dialogContext) => TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('关闭'),
      );

  // ── 展示辅助 ──────────────────────────────────────────────

  static IconData _iconFor(ObjectEntry entry) => switch (entry.kind) {
        ObjectKind.folder => Icons.folder_outlined,
        ObjectKind.image => Icons.photo_outlined,
        ObjectKind.video => Icons.videocam_outlined,
        ObjectKind.other => Icons.insert_drive_file_outlined,
      };

  static String _subtitleFor(ObjectEntry entry) {
    if (entry.isFolder) {
      return '文件夹';
    }
    final size = _formatBytes(entry.sizeInBytes);
    final d = entry.capturedAt?.toLocal();
    if (d == null) {
      return size;
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return '$size · '
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }
}

/// 下载对话框状态(进度 → 完成结果 / 失败)。
final class _DownloadProgress {
  const _DownloadProgress({
    required this.total,
    this.received = 0,
    this.result,
    this.error,
  });

  final int total;
  final int received;
  final ObjectDownload? result;
  final String? error;

  _DownloadProgress withReceived(int n) =>
      _DownloadProgress(total: total, received: n);

  _DownloadProgress withDone(ObjectDownload r) =>
      _DownloadProgress(total: total, received: r.bytes, result: r);

  _DownloadProgress withError(String e) =>
      _DownloadProgress(total: total, received: received, error: e);
}

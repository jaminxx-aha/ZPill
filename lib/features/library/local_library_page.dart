/// 图库页(底部导航 tab):「下载到应用」的文件网格(downloadsDir 直读,
/// TransfersController 的 appFiles 数据源)。**不含**已导入系统相册的
/// 文件 —— 那些归系统相册 App 管,这里只看应用自留的份。
///
/// 网格按修改时间倒序(新下载在前);顶栏下格式过滤 chips(全部/RAW/
/// JPG/视频,按文件名扩展名,与相机侧判定同源);Flutter 可解码的图片
/// 直接铺格(cacheWidth 限内存),NEF 等原生格式落图标格;点图片进黑底
/// 查看器(双指缩放),查看器/长按格可删除,查看器可把文件补导入系统
/// 相册。AppBar 传输徽标(进行中任务数)→ 传输页(任务列表)。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/ptpip/object_format.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/services.dart';
import '../transfers/transfers_page.dart';

/// 图库格式过滤:按扩展名分流,与相机侧条目判定同源。
enum _LibFilter {
  all('全部'),
  raw('RAW'),
  jpg('JPG'),
  video('视频');

  const _LibFilter(this.label);

  final String label;

  bool allows(String filename) => switch (this) {
        all => true,
        raw => isRawFilename(filename),
        jpg => isJpgFilename(filename),
        video => isVideoFilename(filename),
      };
}

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({super.key, this.controller, this.gallery});

  /// 测试注入;缺省用 AppServices 单例(应用级共享,本页不持有)。
  final TransfersController? controller;

  /// 测试注入;缺省用平台服务单例。
  final GallerySaver? gallery;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  TransfersController get _controller =>
      widget.controller ?? AppServices.instance.transfersController;

  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;

  /// Flutter 可解码的图片扩展名(NEF 等原生格式走图标格)。
  static const _viewableExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  _LibFilter _filter = _LibFilter.all;

  @override
  void initState() {
    super.initState();
    _controller.refreshAppFiles();
  }

  bool _isViewable(File file) {
    final name = file.uri.pathSegments.last.toLowerCase();
    return _viewableExts.any(name.endsWith);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        // 修改时间倒序:新下载在前。
        final files = List<File>.of(_controller.appFiles)
          ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
        final activeCount =
            _controller.tasks.where((t) => !t.isTerminal).length;
        final filtered = _filtered(files);
        return Scaffold(
          appBar: AppBar(
            title: const Text('图库'),
            actions: [
              // 传输徽标:进行中任务数角标,点击进传输页看任务列表。
              _transfersBadge(context, activeCount),
              IconButton(
                tooltip: '刷新',
                onPressed: _controller.refreshAppFiles,
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: files.isEmpty
              ? const Center(
                  child: Text('应用内还没有文件\n(在相机相册里选择「下载到应用」)',
                      textAlign: TextAlign.center),
                )
              : Column(
                  children: [
                    // 格式过滤:切换不清文件,只按扩展名收窄网格。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: SegmentedButton<_LibFilter>(
                        segments: [
                          for (final f in _LibFilter.values)
                            ButtonSegment(value: f, label: Text(f.label)),
                        ],
                        selected: {_filter},
                        onSelectionChanged: (s) =>
                            setState(() => _filter = s.first),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text('没有${_filter.label}格式的文件',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Theme.of(context).hintColor)),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(2),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 2,
                                crossAxisSpacing: 2,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (_, i) =>
                                  _cell(context, filtered[i]),
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  List<File> _filtered(List<File> files) => files
      .where((f) => _filter.allows(f.uri.pathSegments.last))
      .toList(growable: false);

  Widget _transfersBadge(BuildContext context, int activeCount) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: '传输',
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TransfersPage())),
          icon: const Icon(Icons.swap_vert),
        ),
        if (activeCount > 0)
          Positioned(
            top: 6,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(minWidth: 14),
              child: Text(
                '$activeCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, File file) {
    final viewable = _isViewable(file);
    final name = file.uri.pathSegments.last;
    return GestureDetector(
      onTap: viewable ? () => _openViewer(file, name) : null,
      onLongPress: () => _confirmDelete(file),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (viewable)
            Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (context, error, stackTrace) => const ColoredBox(
                color: Color(0x33808080),
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            )
          else
            ColoredBox(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 视频件用摄像机图标:与「视频」过滤 chips 视觉对上。
                    Icon(
                      isVideoFilename(name)
                          ? Icons.videocam_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 28,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name.contains('.')
                          ? name
                              .substring(name.lastIndexOf('.') + 1)
                              .toUpperCase()
                          : 'FILE',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openViewer(File file, String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LibraryViewer(
          file: file,
          title: name,
          controller: _controller,
          gallery: _gallery,
        ),
      ),
    );
  }

  /// 长按格 / 查看器删除:确认对话框把关(应用内文件,删了要重下)。
  Future<void> _confirmDelete(File file) async {
    final name = file.uri.pathSegments.last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除应用内文件?'),
        content: Text('将删除「$name」。\n此操作不可恢复(相机上的原件不受影响)。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _controller.deleteAppFile(file);
    }
  }
}

/// 应用内图片查看(黑底 + 双指缩放):删除 + 补导入系统相册。
/// NEF 等原生格式 Flutter 解不了,本页只接待可解码扩展名。
class _LibraryViewer extends StatelessWidget {
  const _LibraryViewer({
    required this.file,
    required this.title,
    required this.controller,
    required this.gallery,
  });

  final File file;
  final String title;
  final TransfersController controller;
  final GallerySaver gallery;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '导入系统相册',
            onPressed: () => _importToGallery(context),
            icon: const Icon(Icons.photo_library_outlined),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => _delete(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
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

  /// 补导入系统相册:文件本体保留(导入是复制不是移动);ohos 亮保存
  /// 面板,用户取消返回空列表(不报错)。
  Future<void> _importToGallery(BuildContext context) async {
    var imported = false;
    try {
      final uris = await gallery.importFiles([
        GalleryImportRequest(
          path: file.path,
          kind: kindForFilename(title),
          filename: title,
        ),
      ]);
      imported = uris.isNotEmpty;
    } on Exception {
      imported = false;
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(imported ? '已导入系统相册(应用内文件保留)' : '未导入(已取消或失败)')));
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除应用内文件?'),
        content: Text('将删除「$title」。\n此操作不可恢复(相机上的原件不受影响)。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    Navigator.of(context).pop(); // 先关查看器再删(格位即收)
    await controller.deleteAppFile(file);
  }
}

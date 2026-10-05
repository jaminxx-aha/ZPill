/// 大图预览:PageView 左右滑 + 双指缩放;底部单张下载到相册/应用,
/// 顶栏打星(本地评分,1-5 星/清除)。
///
/// 双格式(RAW+JPG)组下载前弹格式选择(仅 JPG/仅 RAW/两者);单格式
/// 组与视频直接下载。预览走 ThumbnailCache preview 档(Nikon
/// GetLargeThumb 的 JPEG,NEF 也有内嵌预览;相机不支持时缓存层回落
/// GetThumb)。视频显示预览帧 + 信息(播放不在本期)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/transfer/object_downloader.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/services.dart';
import '../common/format.dart';
import '../edit/edit_page.dart';
import 'download_format_sheet.dart';
import 'ratings_controller.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.thumbnails,
    this.engine,
    this.ratings,
    this.downloader,
    this.gallery,
  });

  final List<PhotoGroup> items;
  final int initialIndex;

  /// 测试注入;缺省用 AppServices 单例。
  final ThumbnailCache? thumbnails;

  /// 测试注入;缺省用 AppServices 单例。
  final TransferEngine? engine;

  /// 测试注入;缺省用 AppServices 单例(与网格页共享同一评分状态)。
  final RatingsController? ratings;

  /// 测试注入(编辑:拉原图);缺省用 AppServices 单例。
  final ObjectDownloader? downloader;

  /// 测试注入(编辑:导出相册);缺省平台通道。
  final GallerySaver? gallery;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final Map<int, Future<String>> _previewFutures = {};

  ThumbnailCache get _thumbnails =>
      widget.thumbnails ?? AppServices.instance.thumbnails;
  TransferEngine get _engine =>
      widget.engine ?? AppServices.instance.transferEngine;
  RatingsController get _ratings =>
      widget.ratings ?? AppServices.instance.ratings;
  ObjectDownloader get _downloader =>
      widget.downloader ?? AppServices.instance.downloader;
  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 打星面板:1-5 星 + 清除评分(0)。乐观上屏由控制器负责。
  Future<void> _rate(PhotoGroup group) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '评分',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var stars = 1; stars <= 5; stars++)
                    IconButton(
                      iconSize: 32,
                      color: stars <= _ratings.ratingOf(group)
                          ? Colors.amber
                          : Theme.of(context).disabledColor,
                      onPressed: () {
                        _ratings.rate(group, stars);
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.star),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: const Text('清除评分'),
              onTap: () {
                _ratings.rate(group, 0);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 下载:双格式组先选格式(取消即放弃);单格式/视频直接整组。
  Future<void> _download(
      PhotoGroup group, TransferDestination destination) async {
    var entries = group.members;
    PhotoDownloadFormat? format;
    if (!group.isVideo && group.hasJpg && group.hasRaw) {
      format = await showDownloadFormatSheet(context,
          subtitle: '这张照片有 JPG 和 RAW 两份文件');
      if (format == null) {
        return; // 取消,不下载
      }
      entries = group.membersFor(format);
    }
    await _engine.enqueue(entries, destination: destination);
    if (!mounted) {
      return;
    }
    final where = destination == TransferDestination.gallery ? '相册' : '应用';
    final tag = format == null ? '' : '(${format.short})';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已开始下载到$where$tag,进度见「图库」页')));
  }

  /// 编辑:拉取组内 JPG 原图到临时目录(相机会话串行,排队即得),
  /// 读字节后即删原件;编辑产物走相册导入,不在临时目录留档。
  Future<void> _edit(PhotoGroup group) async {
    final jpg = group.jpg;
    if (jpg == null) return;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 12),
              Text('拉取原图…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    ));
    try {
      final dl =
          await _downloader.download(jpg, targetDir: await _gallery.tempDir());
      final bytes = await File(dl.path).readAsBytes();
      try {
        await File(dl.path).delete();
      } on FileSystemException {
        // 删失败不挡编辑
      }
      if (!mounted) return;
      Navigator.of(context).pop(); // loading 对话框
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            EditPage(jpeg: bytes, filename: jpg.name, gallery: _gallery),
      ));
    } on Object {
      if (!mounted) return;
      Navigator.of(context).pop(); // loading 对话框
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('拉取原图失败,请检查连接后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.items[_index];
    // 顶栏星标随评分与翻页刷新(评分面板乐观上屏,回滚也刷)。
    return ListenableBuilder(
      listenable: _ratings,
      builder: (context, _) {
        final rating = _ratings.ratingOf(group);
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            title: Text('${_index + 1} / ${widget.items.length}'),
            actions: [
              if (group.hasJpg)
                IconButton(
                  tooltip: '编辑',
                  onPressed: () => _edit(group),
                  icon: const Icon(Icons.tune),
                ),
              IconButton(
                tooltip: '评分',
                onPressed: () => _rate(group),
                icon: Icon(
                  rating > 0 ? Icons.star : Icons.star_border,
                  color: rating > 0 ? Colors.amber : null,
                ),
              ),
            ],
          ),
          body: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _page(widget.items[i]),
          ),
          bottomNavigationBar: _infoBar(context, group),
        );
      },
    );
  }

  Widget _page(PhotoGroup group) {
    return InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: FutureBuilder<String>(
          future: _previewFutures.putIfAbsent(
            group.primary.handle,
            () => _thumbnails.pathFor(group.primary, ThumbSource.preview),
          ),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text('加载预览…', style: TextStyle(color: Colors.white70)),
                ],
              );
            }
            final path = snap.data;
            if (path == null || snap.hasError) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 48),
                  SizedBox(height: 8),
                  Text('预览不可用', style: TextStyle(color: Colors.white70)),
                ],
              );
            }
            return Image.file(
              File(path),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _infoBar(BuildContext context, PhotoGroup group) {
    // RAW+JPG 合并组:两份文件名都列出,大小取合计;连拍簇注明张数。
    final pair = group.hasJpg && group.hasRaw;
    final info = [
      pair ? '${group.jpg!.name} + ${group.raw!.name}' : group.name,
      formatBytes(group.totalBytes),
      if (group.isBurst) '连拍 ×${group.shotCount}',
      if (formatDateTime(group.capturedAt) != null)
        formatDateTime(group.capturedAt)!,
      if (group.isVideo) '视频',
    ].join(' · ');
    return SafeArea(
      top: false,
      // 不用 BottomAppBar:它的定高(80)+ 自身留白叠上两行内容必然
      // 溢出(真机 13px);Material+Padding 让内容自适应高度。
      child: Material(
        color: Colors.black87,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                info,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white12,
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          _download(group, TransferDestination.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('下载到相册'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white12,
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          _download(group, TransferDestination.app),
                      icon: const Icon(Icons.folder_outlined),
                      label: const Text('下载到应用'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 大图预览:PageView 左右滑 + 双指缩放;底部单张下载到相册/应用。
///
/// 预览走 ThumbnailCache preview 档(Nikon GetLargeThumb 的 JPEG,
/// NEF 也有内嵌预览;相机不支持时缓存层回落 GetThumb)。
/// 视频显示预览帧 + 信息(播放不在本期)。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../common/format.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<PhotoGroup> items;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final Map<int, Future<String>> _previewFutures = {};

  ThumbnailCache get _thumbnails => AppServices.instance.thumbnails;
  TransferEngine get _engine => AppServices.instance.transferEngine;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 下载 = 整组(RAW+JPG 合并组:两种格式都拿回)。
  Future<void> _download(PhotoGroup group, TransferDestination destination) async {
    await _engine.enqueue(group.members, destination: destination);
    if (!mounted) {
      return;
    }
    final where = destination == TransferDestination.gallery ? '相册' : '应用';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已开始下载到$where,详见「下载」页')));
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.items.length}'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => _page(widget.items[i]),
      ),
      bottomNavigationBar: _infoBar(context, group),
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
    // RAW+JPG 合并组:两份文件名都列出,大小取合计。
    final pair = group.hasJpg && group.hasRaw;
    final info = [
      pair ? '${group.jpg!.name} + ${group.raw!.name}' : group.name,
      formatBytes(group.totalBytes),
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
                      onPressed: () => _download(group, TransferDestination.app),
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

/// 相册缩略图网格:长按进入多选,选中项可批量下载到相册/应用。
///
/// 缩略图 Future 按 handle 缓存在本页 State(setState 重建不闪、
/// 不重发请求;PtpSession 串行锁 + ThumbnailCache 并发合并兜底)。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/ptpip/object_format.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import 'photo_viewer_page.dart';

class PhotoGridPage extends StatefulWidget {
  const PhotoGridPage({super.key, required this.album});

  final CameraAlbum album;

  @override
  State<PhotoGridPage> createState() => _PhotoGridPageState();
}

class _PhotoGridPageState extends State<PhotoGridPage> {
  final Set<int> _selected = {};
  final Map<int, Future<String>> _thumbFutures = {};

  ThumbnailCache get _thumbnails => AppServices.instance.thumbnails;
  TransferEngine get _engine => AppServices.instance.transferEngine;

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(ObjectEntry entry) {
    setState(() {
      if (!_selected.remove(entry.handle)) {
        _selected.add(entry.handle);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(widget.album.items.map((e) => e.handle));
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _downloadSelected(TransferDestination destination) async {
    final entries = widget.album.items
        .where((e) => _selected.contains(e.handle))
        .toList(growable: false);
    if (entries.isEmpty) {
      return;
    }
    await _engine.enqueue(entries, destination: destination);
    _clearSelection();
    if (!mounted) {
      return;
    }
    final where = destination == TransferDestination.gallery ? '相册' : '应用';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text('已开始下载 ${entries.length} 项到$where,详见「下载」页')));
  }

  void _openViewer(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: widget.album.items,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length} 项' : widget.album.name),
        actions: [
          if (_selecting) ...[
            IconButton(
              tooltip: '全选',
              onPressed: _selectAll,
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              tooltip: '取消选择',
              onPressed: _clearSelection,
              icon: const Icon(Icons.close),
            ),
          ] else
            const SizedBox(width: 8),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: widget.album.items.length,
        itemBuilder: (_, i) => _cell(widget.album.items[i], i),
      ),
      bottomSheet: _selecting ? _actionBar() : null,
    );
  }

  Widget _cell(ObjectEntry entry, int index) {
    final selected = _selected.contains(entry.handle);
    return GestureDetector(
      onTap: () => _selecting ? _toggle(entry) : _openViewer(index),
      onLongPress: () => _toggle(entry),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<String>(
            future: _thumbFutures.putIfAbsent(
              entry.handle,
              () => _thumbnails.pathFor(entry, ThumbSource.grid),
            ),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const ColoredBox(
                  color: Color(0x22808080),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final path = snap.data;
              if (path == null || snap.hasError) {
                return const ColoredBox(
                  color: Color(0x33808080),
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                );
              }
              return Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: Color(0x33808080),
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              );
            },
          ),
          if (entry.kind == ObjectKind.video)
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.videocam, size: 16, color: Colors.white),
              ),
            ),
          if (_selecting)
            Positioned.fill(
              child: ColoredBox(
                color: selected
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.55),
              ),
            ),
          if (_selecting)
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionBar() {
    return SafeArea(
      child: BottomAppBar(
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _downloadSelected(TransferDestination.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('下载到相册'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _downloadSelected(TransferDestination.app),
                icon: const Icon(Icons.folder_outlined),
                label: const Text('下载到应用'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

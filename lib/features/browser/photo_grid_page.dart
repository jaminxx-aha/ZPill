/// 相册缩略图网格:长按进入多选,选中项可批量下载到相册/应用。
///
/// 活页模式:随 [BrowserController] 的渐进发布增长(最新优先,新对象尾部
/// 追加);断连后保留最后快照(相册列表被控制器清空时,网格内容可见,
/// 缩略图走磁盘缓存)。缩略图 Future 按 handle 缓存在本页 State
/// (setState 重建不闪、不重发请求;PtpSession 串行锁 + ThumbnailCache
/// 并发合并兜底)。查看器仍按打开时刻的快照浏览(同步继续不追新,重进
/// 本页即刷新)。
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
import 'browser_controller.dart';
import 'photo_viewer_page.dart';

class PhotoGridPage extends StatefulWidget {
  const PhotoGridPage({
    super.key,
    required this.controller,
    required this.folderHandle,
    this.fallbackName,
    this.thumbnails,
  });

  /// 应用级共享控制器(本页不拥有、不 dispose);网格随其渐进发布增长。
  final BrowserController controller;

  /// 目标相册:[CameraAlbum.allPhotosHandle](汇总)或文件夹句柄。
  final int folderHandle;

  /// 控制器失效(断连清空)后的标题兜底。
  final String? fallbackName;

  /// 测试注入;缺省用 AppServices 单例。
  final ThumbnailCache? thumbnails;

  @override
  State<PhotoGridPage> createState() => _PhotoGridPageState();
}

class _PhotoGridPageState extends State<PhotoGridPage> {
  final Set<int> _selected = {};
  final Map<int, Future<String>> _thumbFutures = {};

  /// 最后一次解析到的活相册(断连后控制器清空,以它保持网格快照)。
  CameraAlbum? _lastAlbum;

  ThumbnailCache get _thumbnails =>
      widget.thumbnails ?? AppServices.instance.thumbnails;
  TransferEngine get _engine => AppServices.instance.transferEngine;

  bool get _selecting => _selected.isNotEmpty;

  /// 按 folderHandle 找活相册;无匹配(尚未建立/已断连)返回 null。
  CameraAlbum? _resolve(List<CameraAlbum> albums) {
    for (final album in albums) {
      if (album.folderHandle == widget.folderHandle) return album;
    }
    return null;
  }

  void _toggle(ObjectEntry entry) {
    setState(() {
      if (!_selected.remove(entry.handle)) {
        _selected.add(entry.handle);
      }
    });
  }

  /// 全选 = 当前已知项(渐进同步中张数随后续块增长,已选项不自动扩选)。
  void _selectAll(List<ObjectEntry> items) {
    setState(() {
      _selected
        ..clear()
        ..addAll(items.map((e) => e.handle));
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _downloadSelected(
      List<ObjectEntry> items, TransferDestination destination) async {
    final entries = items
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

  void _openViewer(List<ObjectEntry> items, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final live = _resolve(widget.controller.albums);
        if (live != null) _lastAlbum = live;
        final album = live ?? _lastAlbum;
        final items = album?.items ?? const <ObjectEntry>[];
        return Scaffold(
          appBar: AppBar(
            title: Text(_selecting
                ? '已选 ${_selected.length} 项'
                : (album?.name ?? widget.fallbackName ?? '相册')),
            actions: [
              if (_selecting) ...[
                IconButton(
                  tooltip: '全选',
                  onPressed: () => _selectAll(items),
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
            itemCount: items.length,
            // key 按 handle:增长期间尾部追加、条目重排时元素正确复用
            //(选中态与缩略图 Future 都按 handle 键控)。
            itemBuilder: (_, i) => _cell(items[i], i, items, key: ValueKey(items[i].handle)),
          ),
          bottomSheet: _selecting ? _actionBar(items) : null,
        );
      },
    );
  }

  Widget _cell(ObjectEntry entry, int index, List<ObjectEntry> items, {Key? key}) {
    final selected = _selected.contains(entry.handle);
    return GestureDetector(
      key: key,
      onTap: () => _selecting
          ? _toggle(entry)
          : _openViewer(items, index),
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

  Widget _actionBar(List<ObjectEntry> items) {
    return SafeArea(
      child: BottomAppBar(
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () =>
                    _downloadSelected(items, TransferDestination.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('下载到相册'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _downloadSelected(items, TransferDestination.app),
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

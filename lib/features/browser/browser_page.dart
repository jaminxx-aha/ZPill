/// 相册页(TODO.md §三 相册视图):「全部照片」+ 各文件夹相册卡片
/// (封面缩略图 / 张数 / 日期范围);点击进入缩略图网格。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../common/format.dart';
import 'browser_controller.dart';
import 'photo_grid_page.dart';

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
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('相册'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: controller.loading ? null : controller.load,
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _body(controller),
      ),
    );
  }

  Widget _body(BrowserController controller) {
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
    if (controller.loading) {
      final p = controller.progress;
      final label = p == null
          ? '正在读取相机对象…\n(首次需枚举全部对象,约数秒)'
          : '正在枚举相机对象 ${p.$1}/${p.$2}…';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (controller.albums.isEmpty) {
      return const Center(child: Text('相机里还没有照片\n(未连接时请先在「相机」页连接)',
          textAlign: TextAlign.center));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: controller.albums.length,
      itemBuilder: (_, i) {
        final album = controller.albums[i];
        return _AlbumTile(
          album: album,
          onTap: () => _openAlbum(album),
        );
      },
    );
  }

  void _openAlbum(CameraAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PhotoGridPage(album: album)),
    );
  }
}

/// 相册卡片:封面缩略图(最新一张)+ 名称 + 张数 + 日期范围。
class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album, required this.onTap});

  final CameraAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = album.cover;
    final dates = formatDateRange(
      album.newestAt,
      album.items.isEmpty ? null : album.items.last.capturedAt,
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 72,
          height: 72,
          child: cover == null ? const _CoverPlaceholder() : _Cover(cover),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              album.name,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (album.isAggregate) ...[
            const SizedBox(width: 8),
            _chip(context, '汇总'),
          ],
        ],
      ),
      subtitle: Text([
        '${album.items.length} 张',
        if (dates != null) dates,
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _chip(BuildContext context, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
        ),
      );
}

/// 封面缩略图:网格档(小图),失败/未取到时占位图标。
class _Cover extends StatelessWidget {
  const _Cover(this.entry);

  final ObjectEntry entry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: AppServices.instance.thumbnails.pathFor(entry, ThumbSource.grid),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: Color(0x33808080),
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
          return const _CoverPlaceholder();
        }
        return Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              const _CoverPlaceholder(),
        );
      },
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x22808080),
      child: Center(child: Icon(Icons.photo_outlined, color: Color(0xAAFFFFFF))),
    );
  }
}

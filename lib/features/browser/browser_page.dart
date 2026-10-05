/// 相册页(TODO.md §三 相册视图):「全部照片」+ 各文件夹相册卡片
/// (封面缩略图 / 张数 / 日期范围);点击进入缩略图网格。顶栏下方
/// 双卡槽余量卡(存储控制器连接成功即拉,见 StorageOverviewController)。
///
/// 渐进加载:枚举期间不再全屏阻塞 —— 首块到达即显示内容,后续对象
/// 后台同步(AppBar 细进度条推进,封面渐次点亮),支持下拉刷新。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/storage_info.dart';
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
      builder: (context, _) {
        final prog = controller.progress;
        return Scaffold(
          appBar: AppBar(
            title: const Text('相册'),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: controller.syncing ? null : controller.reload,
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 8),
            ],
            // 同步进度细条:首块前(无 progress)为不定进度动画。
            bottom: controller.syncing
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(2),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      value: (prog == null || prog.$2 == 0)
                          ? null
                          : prog.$1 / prog.$2,
                    ),
                  )
                : null,
          ),
          body: _body(controller),
        );
      },
    );
  }

  Widget _body(BrowserController controller) {
    if (controller.albums.isEmpty) {
      if (controller.error != null) {
        // 一块都没到:硬错误屏。
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(controller.error!),
              ),
              FilledButton(
                onPressed: controller.load,
                child: const Text('重试'),
              ),
            ],
          ),
        );
      }
      if (controller.syncing) {
        // 首块前的短窗口:轻量提示(非阻塞门,首块到达即被内容替换)。
        final p = controller.progress;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 16),
              Text(
                p == null ? '正在连接相机读取对象…' : '正在读取相机对象 ${p.$1}/${p.$2}…',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      }
      return const Center(
        child: Text('相机里还没有照片\n(未连接时请先在「相机」页连接)', textAlign: TextAlign.center),
      );
    }
    // 有内容:同步中断仅软横幅(已显示内容可继续浏览),下拉刷新重枚举。
    return Column(
      children: [
        if (controller.error != null) _syncErrorBanner(controller),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.reload,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: 1 + controller.albums.length,
              itemBuilder: (_, i) {
                if (i == 0) return const _StoragePanel();
                final album = controller.albums[i - 1];
                return _AlbumTile(
                  key: ValueKey(album.folderHandle),
                  album: album,
                  onTap: () => _openAlbum(album),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 同步中断横幅:内容已显示,重试只补缺失对象(断点续传)。
  Widget _syncErrorBanner(BrowserController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.sync_problem, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: controller.load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAlbum(CameraAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGridPage(
          controller: _controller,
          folderHandle: album.folderHandle,
          fallbackName: album.name,
        ),
      ),
    );
  }
}

/// 双卡槽余量卡:每槽一行(名 + 剩余/总容量 + 余量进度条),点按手动
/// 刷新(换卡不自动追新)。相机未上报容量只显示名字;无槽不占位。
class _StoragePanel extends StatelessWidget {
  const _StoragePanel();

  @override
  Widget build(BuildContext context) {
    final overview = AppServices.instance.storageOverview;
    return ListenableBuilder(
      listenable: overview,
      builder: (context, _) {
        final storages = overview.storages;
        if (storages.isEmpty) {
          return const SizedBox.shrink();
        }
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              children: [
                for (final storage in storages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _StorageRow(storage: storage),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.storage});

  final CameraStorage storage;

  @override
  Widget build(BuildContext context) {
    final ratio = storage.freeRatio;
    final colorScheme = Theme.of(context).colorScheme;
    // 低余量(<10%)转警示色。
    final barColor =
        ratio != null && ratio < 0.1 ? colorScheme.error : colorScheme.primary;
    return Row(
      children: [
        Icon(Icons.sd_card_outlined,
            size: 20, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(storage.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium),
              if (ratio != null) ...[
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: 1 - ratio, // 已用占比
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          storage.maxCapacityBytes > 0
              ? '${formatBytes(storage.freeSpaceBytes)} 可用 / ${formatBytes(storage.maxCapacityBytes)}'
              : '容量未知',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 相册卡片:封面缩略图(最新一张)+ 名称 + 张数 + 日期范围。
class _AlbumTile extends StatelessWidget {
  const _AlbumTile({super.key, required this.album, required this.onTap});

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
          child:
              cover == null ? const _CoverPlaceholder() : _Cover(cover.primary),
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
///
/// Stateful + Future 缓存:渐进发布期间每块触发 notifyListeners → 本卡片
/// 重建;Future 若在 build 里现取,FutureBuilder 会拿到新 Future 实例而
/// 闪回转圈。发布间 [ObjectEntry] 实例复用(仓库 _byHandle 存同一实例),
/// identical 时不重取。
class _Cover extends StatefulWidget {
  const _Cover(this.entry);

  final ObjectEntry entry;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future =
        AppServices.instance.thumbnails.pathFor(widget.entry, ThumbSource.grid);
  }

  @override
  void didUpdateWidget(_Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entry, widget.entry)) {
      _future = AppServices.instance.thumbnails
          .pathFor(widget.entry, ThumbSource.grid);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _future,
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
      child:
          Center(child: Icon(Icons.photo_outlined, color: Color(0xAAFFFFFF))),
    );
  }
}

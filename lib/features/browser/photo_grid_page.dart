/// 相册缩略图网格:按拍摄日期分段(段头点按 = 整日选择/取消),长按进入
/// 多选,选中项可批量下载到相册/应用(批次含双格式组时先选格式,缺格式
/// 的组跳过)、批量删除(相机侧逐文件 0x100B,确认对话框把关)。本地
/// 评分角标(左上星标)随 [RatingsController] 变化;连拍簇一条目
/// (typeLabel 带 ×N)。
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
import '../../core/browser/camera_file_ops.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../common/format.dart';
import 'browser_controller.dart';
import 'download_format_sheet.dart';
import 'photo_viewer_page.dart';
import 'ratings_controller.dart';

class PhotoGridPage extends StatefulWidget {
  const PhotoGridPage({
    super.key,
    required this.controller,
    required this.folderHandle,
    this.fallbackName,
    this.thumbnails,
    this.engine,
    this.fileOps,
    this.ratings,
  });

  /// 应用级共享控制器(本页不拥有、不 dispose);网格随其渐进发布增长。
  final BrowserController controller;

  /// 目标相册:[CameraAlbum.allPhotosHandle](汇总)或文件夹句柄。
  final int folderHandle;

  /// 控制器失效(断连清空)后的标题兜底。
  final String? fallbackName;

  /// 测试注入;缺省用 AppServices 单例。
  final ThumbnailCache? thumbnails;

  /// 测试注入;缺省用 AppServices 单例。
  final TransferEngine? engine;

  /// 测试注入;缺省用 AppServices 单例。
  final CameraFileOps? fileOps;

  /// 测试注入;缺省用 AppServices 单例。
  final RatingsController? ratings;

  @override
  State<PhotoGridPage> createState() => _PhotoGridPageState();
}

/// 网格日期段:同日本地日期的照片一段([day] null = 未知日期)。
final class _DateSection {
  _DateSection(this.day, this.items);

  final DateTime? day;
  final List<PhotoGroup> items;

  /// 段首在全局列表的下标(查看器按全局序翻页)。
  int firstIndex = 0;
}

class _PhotoGridPageState extends State<PhotoGridPage> {
  /// 选中集按组身份键(PhotoGroup.key):RAW+JPG 合并组算一项,
  /// 下载格式由选择面板决定(见 _downloadSelected)。
  final Set<int> _selected = {};

  /// 缩略图 Future 按代表文件句柄缓存:主文件变化(渐进配对完成
  /// NEF→JPG 切换)时取新 Future,其余重建不闪、不重发请求。
  final Map<int, Future<String>> _thumbFutures = {};

  /// 最后一次解析到的活相册(断连后控制器清空,以它保持网格快照)。
  CameraAlbum? _lastAlbum;

  ThumbnailCache get _thumbnails =>
      widget.thumbnails ?? AppServices.instance.thumbnails;
  TransferEngine get _engine =>
      widget.engine ?? AppServices.instance.transferEngine;
  CameraFileOps get _fileOps => widget.fileOps ?? AppServices.instance.fileOps;
  RatingsController get _ratings =>
      widget.ratings ?? AppServices.instance.ratings;

  bool get _selecting => _selected.isNotEmpty;

  /// 日期分段:items 按拍摄时间倒序(仓库序),本地日期变化即切段;
  /// 无时刻条目(排序必在尾)归「未知日期」段收尾。段记 [firstIndex]
  /// 让查看器仍按全局序翻页。
  List<_DateSection> _sectionsOf(List<PhotoGroup> items) {
    final dated = <_DateSection>[];
    final undated = <PhotoGroup>[];
    _DateSection? current;
    for (final group in items) {
      final at = group.capturedAt;
      if (at == null) {
        undated.add(group);
        continue;
      }
      final local = at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (current != null && current.day == day) {
        current.items.add(group);
      } else {
        current = _DateSection(day, [group]);
        dated.add(current);
      }
    }
    final sections = dated;
    if (undated.isNotEmpty) {
      sections.add(_DateSection(null, undated));
    }
    var offset = 0;
    for (final s in sections) {
      s.firstIndex = offset;
      offset += s.items.length;
    }
    return sections;
  }

  /// 段头:日期 + 张数;多选模式下点按整日选择/取消,右侧显示该日
  /// 是否已全选。
  Widget _sectionHeader(_DateSection section, List<PhotoGroup> items) {
    final label = section.day == null ? '未知日期' : sectionDateLabel(section.day!);
    final daySelected =
        _selecting && section.items.every((g) => _selected.contains(g.key));
    return InkWell(
      onTap: _selecting ? () => _toggleDay(section.items) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$label · ${section.items.length} 张',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_selecting)
              Icon(
                daySelected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: daySelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  /// 按 folderHandle 找活相册;无匹配(尚未建立/已断连)返回 null。
  CameraAlbum? _resolve(List<CameraAlbum> albums) {
    for (final album in albums) {
      if (album.folderHandle == widget.folderHandle) return album;
    }
    return null;
  }

  void _toggle(PhotoGroup group) {
    setState(() {
      if (!_selected.remove(group.key)) {
        _selected.add(group.key);
      }
    });
  }

  /// 全选 = 当前已知项(渐进同步中张数随后续块增长,已选项不自动扩选)。
  void _selectAll(List<PhotoGroup> items) {
    setState(() {
      _selected
        ..clear()
        ..addAll(items.map((group) => group.key));
    });
  }

  /// 整日选择/取消:段头点按(仅多选模式下生效)。
  void _toggleDay(List<PhotoGroup> dayItems) {
    final keys = dayItems.map((g) => g.key).toSet();
    final allSelected = keys.every(_selected.contains);
    setState(() {
      allSelected ? _selected.removeAll(keys) : _selected.addAll(keys);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// 批量下载:批次里有双格式组才弹格式选择(全是单一格式直接下,
  /// 行为同旧版);按所选格式过滤,缺格式的组跳过并计数提示;取消
  /// 选择面板则什么都不下,保留选中态(便于改选格式再下)。
  Future<void> _downloadSelected(
      List<PhotoGroup> items, TransferDestination destination) async {
    final groups =
        items.where((g) => _selected.contains(g.key)).toList(growable: false);
    if (groups.isEmpty) {
      return;
    }
    PhotoDownloadFormat? format;
    final pairCount =
        groups.where((g) => !g.isVideo && g.hasJpg && g.hasRaw).length;
    if (pairCount > 0) {
      format = await showDownloadFormatSheet(context,
          subtitle: '已选 ${groups.length} 项,其中 $pairCount 项为双格式');
      if (format == null) {
        return;
      }
      if (!mounted) {
        return;
      }
    }
    // 面板只在批次含双格式组时弹出,而双格式组对任意选择都非空,
    // entries 不可能为空(单格式组缺格式直接跳过)。
    final entries = <ObjectEntry>[];
    var included = 0;
    for (final group in groups) {
      final members = format == null ? group.members : group.membersFor(format);
      if (members.isEmpty) {
        continue;
      }
      included++;
      entries.addAll(members);
    }
    await _engine.enqueue(entries, destination: destination);
    _clearSelection();
    if (!mounted) {
      return;
    }
    final where = destination == TransferDestination.gallery ? '相册' : '应用';
    final skipped = groups.length - included;
    final tag = format == null ? '' : '(${format.short})';
    final skipNote = skipped > 0 ? ',跳过 $skipped 项无 ${format!.short}' : '';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(
              '已开始下载 $included/${groups.length} 项 / ${entries.length} 个文件$tag 到$where$skipNote,详见「下载」页')));
  }

  /// 批量删除(相机侧,不可逆):确认对话框点明项数与文件数;逐成员
  /// 0x100B,单文件失败只计数不拖死整批,成功句柄出仓库缓存(相册
  /// 立即收缩,无需全量重枚举)。部分失败给出计数提示。
  Future<void> _deleteSelected(List<PhotoGroup> items) async {
    final groups =
        items.where((g) => _selected.contains(g.key)).toList(growable: false);
    if (groups.isEmpty) {
      return;
    }
    final fileCount = groups.fold<int>(0, (n, g) => n + g.members.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除相机上的文件?'),
        content: Text('将删除 ${groups.length} 项(共 $fileCount 个文件)。\n此操作不可恢复。'),
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
    if (confirmed != true) {
      return;
    }
    if (!mounted) {
      return;
    }
    final result = await _fileOps.deleteGroups(groups);
    if (!mounted) {
      return;
    }
    _clearSelection();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (result.failed > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(
            '已删除 ${result.deleted} 个文件,${result.failed} 个失败(相机拒绝或传输中断,条目保留)'),
      ));
    } else {
      messenger
          .showSnackBar(SnackBar(content: Text('已删除 ${result.deleted} 个文件')));
    }
  }

  void _openViewer(List<PhotoGroup> items, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
          ratings: widget.ratings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 评分角标随本地评分变化刷新(枚举/相册结构仍由 controller 驱动)。
      listenable: Listenable.merge([widget.controller, _ratings]),
      builder: (context, _) {
        final live = _resolve(widget.controller.albums);
        if (live != null) _lastAlbum = live;
        final album = live ?? _lastAlbum;
        final items = album?.items ?? const <PhotoGroup>[];
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
          body: CustomScrollView(
            slivers: [
              for (final section in _sectionsOf(items)) ...[
                SliverToBoxAdapter(
                  child: _sectionHeader(section, items),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: section.items.length,
                    // key 按组身份键:增长期间尾部追加、条目重排时元素正确
                    // 复用(选中态与缩略图 Future 都按键控);渐进配对前后
                    // 键稳定,RAW+JPG 后到的那份并入时 cell 不漂移。
                    itemBuilder: (_, i) => _cell(
                      section.items[i],
                      section.firstIndex + i,
                      items,
                      key: ValueKey(section.items[i].key),
                    ),
                  ),
                ),
              ],
            ],
          ),
          bottomSheet: _selecting ? _actionBar(items) : null,
        );
      },
    );
  }

  Widget _cell(PhotoGroup group, int index, List<PhotoGroup> items,
      {Key? key}) {
    final selected = _selected.contains(group.key);
    return GestureDetector(
      key: key,
      onTap: () => _selecting ? _toggle(group) : _openViewer(items, index),
      onLongPress: () => _toggle(group),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<String>(
            future: _thumbFutures.putIfAbsent(
              group.primary.handle,
              () => _thumbnails.pathFor(group.primary, ThumbSource.grid),
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
          // 类型角标(左下):jpg / raw / jpg+raw,RAW+JPG 合并组可见性。
          if (group.typeLabel.isNotEmpty)
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    group.typeLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          if (group.isVideo)
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.videocam, size: 16, color: Colors.white),
              ),
            ),
          // 评分角标(左上):有星才显示;星数并入角标文本。
          if (_ratings.ratingOf(group) > 0)
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 9, color: Colors.white),
                      const SizedBox(width: 2),
                      Text(
                        '${_ratings.ratingOf(group)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
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
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionBar(List<PhotoGroup> items) {
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
                onPressed: () =>
                    _downloadSelected(items, TransferDestination.app),
                icon: const Icon(Icons.folder_outlined),
                label: const Text('下载到应用'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '删除',
              onPressed: () => _deleteSelected(items),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

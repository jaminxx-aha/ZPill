/// 相机相册页(相机页「相册」入口直达):全部照片网格按拍摄日期分段
/// (段头点按 = 整日选择/取消);文件夹筛选收进 AppBar 右上弹层(图库
/// 页同款 MenuAnchor 分区卡片,仅多相册时出相册分区),同文件夹内
/// RAW+JPG 仍合并。长按进入多选,底部操作栏默认单「下载」钮,点按
/// 换出「到相册/到应用」双目的地(批次含双格式组时先选格式,缺格式
/// 的组跳过)、批量删除(相机侧逐文件 0x100B,确认对话框把关)。筛选
/// 弹层的图片下载格式档(全部/仅 JPG/仅 RAW)只定批量下载的格式
/// 预选:非「全部」时跳过格式面板直接按该格式收集(网格显示不变)。
/// 本地评分角标(左上星标)随 [RatingsController] 变化;连拍簇一条目
/// (typeLabel 带 ×N)。
///
/// 活页模式:随 [BrowserController] 的渐进发布增长(最新优先,新对象尾部
/// 追加);AppBar 细进度条 + 刷新按钮 + 下拉刷新重枚举;首块前骨架态,
/// 同步中断 = 无内容硬错误屏 / 有内容软横幅(已显示内容可继续浏览)。
/// 断连后保留最后快照(相册列表被控制器清空时,网格内容可见,缩略图走
/// 磁盘缓存)。缩略图 Future 按 handle 缓存在本页 State(setState 重建
/// 不闪、不重发请求;PtpSession 串行锁 + ThumbnailCache 并发合并兜底)。
/// 查看器仍按打开时刻的快照浏览(同步继续不追新,重进本页即刷新)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/camera_file_ops.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../l10n/l10n.dart';
import '../common/format.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/states.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import 'browser_controller.dart';
import 'download_format_sheet.dart';
import '../transfers/transfers_page.dart';
import 'photo_viewer_page.dart';
import 'ratings_controller.dart';

/// 图片下载格式筛选(筛选弹层第三区):只定批量下载的格式预选,网格
/// 显示不受影响。全部 = 现状(双格式组/照片视频混选批次下载前仍弹
/// 格式面板);仅 JPG / 仅 RAW = 按该格式直接收集下载,不再弹面板
/// (缺该格式的组跳过计数提示,视频组照常全量 —— 与格式面板同义)。
/// label = t() 键,显示点包 t()。
enum _FormatFilter {
  all('libpage.all'),
  jpg('fmt.jpgOnly'),
  raw('fmt.rawOnly');

  const _FormatFilter(this.label);

  final String label;

  /// 映射到下载格式收集口径;null = 不预选(全部,下载沿自行弹面板)。
  PhotoDownloadFormat? get asDownloadFormat => switch (this) {
        all => null,
        jpg => PhotoDownloadFormat.jpg,
        raw => PhotoDownloadFormat.raw,
      };
}

/// 骨架态结构键(测试定位用)。
const _enumSkeletonKey = ValueKey('gridSkeleton');

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
    this.onOpenTransfers,
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

  /// 下载 SnackBar 的「查看进度」动作注入(测试;AppServices 里的传输
  /// 控制器在裸测试树不可建)。null = 默认推 TransfersPage(生产)。
  final VoidCallback? onOpenTransfers;

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
  @override
  void initState() {
    super.initState();
    // 懒枚举触发点:连接沿全库枚举已撤(0x9805 单笔 3.8s 曾插队起景、
    // 拖慢首帧与信息卡),进页才发起;仓库已载入(重开页)时 load() 瞬回
    // 不重枚举,断连期调用静默失败不上屏。
    unawaited(widget.controller.load());
  }

  /// 选中集按组身份键(PhotoGroup.key):RAW+JPG 合并组算一项,
  /// 下载格式由选择面板决定(见 _downloadSelected)。
  final Set<int> _selected = {};

  /// 当前过滤的相册(初始 = 入口句柄;chips 切换)。选中的文件夹在
  /// 重枚举后消失时回落汇总(见 build 里的 post-frame 兜底)。
  late int _filterHandle = widget.folderHandle;

  /// 图片下载格式筛选(筛选弹层;只定下载格式,不改网格)。
  _FormatFilter _formatFilter = _FormatFilter.all;

  /// 底栏两段式下载:「下载」钮点按后换出「到相册/到应用」双目的地;
  /// 选择集一变(改选/整日/全选/切相册/清空)即复位,重新从「下载」
  /// 第一段起(2026-10-17 真机:展开态残留,全选后直显双目的地)。
  bool _revealDownload = false;

  /// 缩略图 Future 按代表文件句柄缓存:主文件变化(渐进配对完成
  /// NEF→JPG 切换)时取新 Future,其余重建不闪、不重发请求。
  final Map<int, Future<String>> _thumbFutures = {};

  /// 缩略取数连续失败计数(句柄 → 次数):取数失败与图档级失败共享
  /// 预算(防真坏源无限循环),耗尽后滚动重建自然再试。
  final Map<int, int> _thumbRetries = {};

  /// 缩略图已落盘路径(future 完成沿记录):图档级失败时删坏档用。
  final Map<int, String> _thumbPaths = {};

  /// 图档级重试在途(句柄集合):errorBuilder 每帧可重复进,2s 去抖。
  final Set<int> _thumbFileRetryPending = {};

  /// 前瞻预取锚点(懒加载预热):已构建到的最深/最浅全局 index。cell
  /// 构建沿更新;新锚点沿把窗外一窗(24 张)先拉起来 —— 滚到即现,不
  /// 再「滚到才排队」。post-frame 批量发起(本帧可视 cell 的请求先入
  /// 串行队列,预取不插队)。items 换实例(刷新/切换相册)重置锚点。
  static const _prefetchWindow = 24;
  int _builtMaxIndex = -1;
  int _builtMinIndex = 1 << 30;
  List<PhotoGroup>? _prefetchItems;

  void _resetPrefetchAnchors(List<PhotoGroup> items) {
    if (identical(items, _prefetchItems)) return;
    _prefetchItems = items;
    _builtMaxIndex = -1;
    _builtMinIndex = 1 << 30;
  }

  void _noteBuilt(int index, List<PhotoGroup> items) {
    final newMax = index > _builtMaxIndex;
    final newMin = index < _builtMinIndex;
    if (!newMax && !newMin) return;
    if (newMax) _builtMaxIndex = index;
    if (newMin) _builtMinIndex = index;
    final targets = <PhotoGroup>[];
    void window(int lo, int hi) {
      for (var i = lo; i <= hi && i < items.length; i++) {
        if (i < 0) continue;
        if (!_thumbFutures.containsKey(items[i].primary.handle)) {
          targets.add(items[i]);
        }
      }
    }

    if (newMax) window(index + 1, index + _prefetchWindow);
    if (newMin) window(index - _prefetchWindow, index - 1);
    if (targets.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final g in targets) {
        _thumbFuture(g);
      }
    });
  }

  /// 最后一次解析到的活相册(断连后控制器清空,以它保持网格快照)。
  CameraAlbum? _lastAlbum;

  /// 最后一次非空的相册列表(chips 快照,断连后保持可切换)。
  List<CameraAlbum> _lastAlbums = const [];

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
    // 日期段(sectionDateLabel)是日期格式产物不抽,英文环境如实回落;
    // 「未知日期」与「· N 张」尾段走 t()。
    final label = section.day == null
        ? context.t('grid.undated')
        : sectionDateLabel(section.day!);
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
                context.t('grid.sectionHeader',
                    {'label': label, 'n': section.items.length}),
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

  /// 按当前过滤句柄找活相册;无匹配(尚未建立/已断连)返回 null。
  CameraAlbum? _resolve(List<CameraAlbum> albums) {
    for (final album in albums) {
      if (album.folderHandle == _filterHandle) return album;
    }
    return null;
  }

  /// 筛选弹层相册切换:清空选择(跨相册选择无意义)+ 弃旧快照。
  void _switchFilter(int handle) {
    if (handle == _filterHandle) return;
    setState(() {
      _filterHandle = handle;
      _selected.clear();
      _revealDownload = false;
      _lastAlbum = null;
    });
  }

  void _toggle(PhotoGroup group) {
    setState(() {
      if (!_selected.remove(group.key)) {
        _selected.add(group.key);
      }
      _revealDownload = false;
    });
  }

  /// 全选 = 当前已知项(渐进同步中张数随后续块增长,已选项不自动扩选)。
  void _selectAll(List<PhotoGroup> items) {
    setState(() {
      _selected
        ..clear()
        ..addAll(items.map((group) => group.key));
      _revealDownload = false;
    });
  }

  /// 整日选择/取消:段头点按(仅多选模式下生效)。
  void _toggleDay(List<PhotoGroup> dayItems) {
    final keys = dayItems.map((g) => g.key).toSet();
    final allSelected = keys.every(_selected.contains);
    setState(() {
      allSelected ? _selected.removeAll(keys) : _selected.addAll(keys);
      _revealDownload = false;
    });
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _revealDownload = false;
      });

  /// 批量下载:筛选弹层已定格式(仅 JPG/仅 RAW)直接按该格式收集,
  /// 不再弹面板;「全部」维持现状 —— 批次内容不单一才弹格式选择(含
  /// 双格式组(选 JPG/RAW)或照片视频混选(选「仅视频」可整批只要
  /// 视频));纯单一格式直接下,行为同旧版;按所选格式过滤,缺格式
  /// 的组跳过并计数提示;取消选择面板则什么都不下,保留选中态(便于
  /// 改选格式再下)。
  Future<void> _downloadSelected(
      List<PhotoGroup> items, TransferDestination destination) async {
    final groups =
        items.where((g) => _selected.contains(g.key)).toList(growable: false);
    if (groups.isEmpty) {
      return;
    }
    PhotoDownloadFormat? format = _formatFilter.asDownloadFormat;
    if (format == null) {
      final pairCount =
          groups.where((g) => !g.isVideo && g.hasJpg && g.hasRaw).length;
      final mixedPhotoVideo =
          groups.any((g) => g.isVideo) && groups.any((g) => !g.isVideo);
      if (pairCount > 0 || mixedPhotoVideo) {
        format = await showDownloadFormatSheet(context,
            subtitle: pairCount > 0
                ? context.t(
                    'grid.selectedDual', {'n': groups.length, 'm': pairCount})
                : context.t('grid.selectedMixed', {'n': groups.length}));
        if (format == null) {
          return;
        }
        if (!mounted) {
          return;
        }
      }
    }
    // 按所选格式收集;「仅视频」可能把整批照片全部筛掉(entries 空)。
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
    if (entries.isEmpty) {
      // 全批被格式筛空(如纯照片批次选「仅视频」):不下,只提示。
      _clearSelection();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(context.t('grid.noMatchNoDownload',
                {'label': context.t(format!.label)}))));
      return;
    }
    await _engine.enqueue(entries, destination: destination);
    _clearSelection();
    if (!mounted) {
      return;
    }
    final skipped = groups.length - included;
    // 目的地片段键「到相册/到应用」带介词(不立裸键「应用」—— edit 页的
    // 「应用」是 Apply 动词,撞义);格式 short 拉丁值未命中原文直返。
    final where = destination == TransferDestination.gallery
        ? context.t('grid.toAlbum')
        : context.t('grid.toApp');
    final tag = format == null ? '' : '(${context.t(format.short)})';
    final skipNote = skipped > 0
        ? context
            .t('grid.skipSuffix', {'n': skipped, 's': context.t(format!.short)})
        : '';
    // Navigator 在展示时刻捕获:SnackBar 活得比本页久(用户立即返回,
    // 提示挂到上一页),届时 State 已 unmount,Navigator.of(context) 会
    // 抛 defunct —— 捕获的根 Navigator 跨 pop 存活,窗口期内动作照常。
    final navigator = Navigator.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          // SDK #173084(2025-08)起带 action 的 SnackBar 默认 persist=
          // true 永不自动消失:显式关掉,恢复随 duration 自动隐藏。
          persist: false,
          content: Text(context
              .t('grid.downloadStarted', {
        'i': included,
        'g': groups.length,
        'f': entries.length,
        'tag': tag,
        'where': where,
        'skip': skipNote,
      })),
          action: SnackBarAction(
            label: context.t('viewer.viewProgress'),
            onPressed: widget.onOpenTransfers ??
                () => navigator.push(MaterialPageRoute<void>(
                    builder: (_) => const TransfersPage())),
          )));
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
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('grid.deleteCameraTitle'),
      content: context.t('grid.deleteCameraBody',
          {'n': groups.length, 'f': fileCount}),
      confirmLabel: context.t('common.delete'),
      destructive: true,
    );
    if (!confirmed) {
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
        content: Text(context.t('grid.deletedPartial',
            {'n': result.deleted, 'm': result.failed})),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text(context.t('grid.deleted', {'n': result.deleted}))));
    }
  }

  void _openViewer(List<PhotoGroup> items, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
          ratings: widget.ratings,
          // 筛选弹层预定的下载格式跟随进查看器(查看器下载不再弹面板)
          downloadFormat: _formatFilter.asDownloadFormat,
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
        final controller = widget.controller;
        final live = _resolve(controller.albums);
        if (live != null) _lastAlbum = live;
        // 过滤的文件夹在重枚举完成后消失:回落汇总相册(渐进同步期间
        // 不判 —— 早期块可能还没枚举到该文件夹)。post-frame 规避
        // build 内 setState。
        if (live == null &&
            !controller.syncing &&
            controller.albums.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _switchFilter(CameraAlbum.allPhotosHandle);
          });
        }
        final album = live ?? _lastAlbum;
        final items = album?.items ?? const <PhotoGroup>[];
        // 筛选弹层相册区源:活列表优先,断连后用快照(切换保持可用)。
        if (controller.albums.isNotEmpty) _lastAlbums = controller.albums;
        final filterAlbums =
            controller.albums.isNotEmpty ? controller.albums : _lastAlbums;
        return Scaffold(
          appBar: AppBar(
            title: Text(_selecting
                ? context.t('grid.selectedCount', {'n': _selected.length})
                // fallbackName 由入口页预翻译(context.t)传入
                : (widget.fallbackName ?? context.t('conn.cameraAlbum'))),
            actions: [
              if (_selecting) ...[
                IconButton(
                  tooltip: context.t('grid.selectAll'),
                  onPressed: () => _selectAll(items),
                  icon: const Icon(Icons.select_all),
                ),
                IconButton(
                  tooltip: context.t('grid.clearSelection'),
                  onPressed: _clearSelection,
                  icon: const Icon(Icons.close),
                ),
              ] else ...[
                IconButton(
                  tooltip: context.t('common.refresh'),
                  onPressed: controller.syncing ? null : controller.reload,
                  icon: const Icon(Icons.refresh),
                ),
                _filterMenuAnchor(context, filterAlbums),
                const SizedBox(width: 8),
              ],
            ],
            // 同步进度细条:首块前(无 progress)为不定进度动画。
            bottom: controller.syncing
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(2),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      value: (controller.progress == null ||
                              controller.progress!.$2 == 0)
                          ? null
                          : controller.progress!.$1 / controller.progress!.$2,
                    ),
                  )
                : null,
          ),
          body: _body(controller, filterAlbums, album, items),
          bottomSheet: _selecting ? _actionBar(items) : null,
        );
      },
    );
  }

  /// 主体四态:无内容硬错误屏 / 首块前骨架 / 空相册提示 / 内容网格
  /// (同步中断仅软横幅,已显示内容可继续浏览,下拉刷新重枚举)。
  Widget _body(BrowserController controller, List<CameraAlbum> filterAlbums,
      CameraAlbum? album, List<PhotoGroup> items) {
    _resetPrefetchAnchors(items); // items 换实例(刷新/切换):预取锚点重置
    if (items.isEmpty) {
      if (controller.error != null) {
        return ErrorRetryPanel(
            message: controller.error!, onRetry: controller.load);
      }
      if (controller.syncing) {
        final p = controller.progress;
        return _EnumSkeleton(
            key: _enumSkeletonKey,
            message: p == null
                ? context.t('grid.connectingObjects')
                : context.t('grid.readingObjects', {'a': p.$1, 'b': p.$2}));
      }
      return EmptyState(message: context.t('grid.emptyNotConnected'));
    }
    return Column(
      children: [
        if (controller.error != null) _syncErrorBanner(controller),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.reload,
            child: CustomScrollView(
              // 常可滚动:内容不足一屏时下拉刷新仍可用。
              physics: const AlwaysScrollableScrollPhysics(),
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
          ),
        ),
      ],
    );
  }

  /// 同步中断横幅:内容已显示,重试只补缺失对象(断点续传)。
  Widget _syncErrorBanner(BrowserController controller) {
    return InlineHint(
      // message 是控制器产出的运行期 $e 插值串,无静态键 —— 显示端
      // (InlineHint)已包 t,英文环境如实回落中文
      message: controller.error!,
      actionLabel: context.t('common.retry'),
      onAction: controller.load,
    );
  }

  /// 右上筛选弹层(图库页同款 MenuAnchor 分区卡片):相册区(汇总 +
  /// 各文件夹,仅多相册时出现)+ 图片下载格式区(全部/仅 JPG/仅 RAW)。
  /// 相册切换沿用旧 chips 规矩清空选择(跨相册选择无意义);格式切换
  /// 不动选择 —— 网格显示不变,选中项的下载格式跟着走。
  Widget _filterMenuAnchor(BuildContext context, List<CameraAlbum> albums) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        if (albums.length >= 2) ...[
          _menuHeader(context, 'grid.albums'),
          for (final album in albums)
            MenuItemButton(
              trailingIcon: _filterHandle == album.folderHandle
                  ? Icon(Icons.check, size: 18, color: scheme.primary)
                  : null,
              onPressed: () => _switchFilter(album.folderHandle),
              // 相册名 = 相机上报文件夹名(Latin,未命中原文直传)+
              // 汇总相册「全部照片」(core 常量,命中即译)
              child: Text(context.t(album.name)),
            ),
        ],
        _menuHeader(context, 'grid.downloadFormat'),
        for (final f in _FormatFilter.values)
          MenuItemButton(
            leadingIcon: Icon(_formatIcon(f)),
            trailingIcon: _formatFilter == f
                ? Icon(Icons.check, size: 18, color: scheme.primary)
                : null,
            onPressed: () => setState(() => _formatFilter = f),
            child: Text(context.t(f.label)),
          ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: context.t('libpage.filter'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.tune),
      ),
    );
  }

  Widget _menuHeader(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        context.t(key),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  IconData _formatIcon(_FormatFilter f) => switch (f) {
        _FormatFilter.all => Icons.apps,
        _FormatFilter.jpg => Icons.image_outlined,
        _FormatFilter.raw => Icons.raw_on_outlined,
      };

  /// 网格缩略取数(句柄去重):失败不驻留 —— 移除在途 future 并限次
  /// 自动重试(3 次,间隔 3s;耗尽留断图占位,滚动重建自然再试)。旧版
  /// 失败 future 永驻缓存,断图格直到重进页面都不再尝试(2026-10-16
  /// 真机复报「部分缩略图加载不出来」根因之一)。
  Future<String> _thumbFuture(PhotoGroup group) {
    final handle = group.primary.handle;
    return _thumbFutures.putIfAbsent(handle, () {
      final f = _thumbnails.pathFor(group.primary, ThumbSource.grid);
      // 落盘路径记账(图档级失败删坏档用);onError 吞掉防未处理异常。
      f.then<void>((p) => _thumbPaths[handle] = p,
          onError: (Object _) {});
      return f.catchError((Object e) {
        _thumbFutures.remove(handle);
        final tries = (_thumbRetries[handle] ?? 0) + 1;
        _thumbRetries[handle] = tries;
        if (mounted && tries <= 3) {
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted && !_thumbFutures.containsKey(handle)) {
              setState(() {});
            }
          });
        }
        throw e;
      });
    });
  }

  /// 图档级失败恢复(Image.file errorBuilder 沿):future 已完成但盘档
  /// 被 LRU 驱逐删档/内容损坏时,死路径 future 不失效格子就永远断图
  /// (2026-10-16 真机 440 张相册回拉全断图根因)。2s 去抖 → 删坏档
  /// (缓存层命中沿 existsSync 校验,档不在即当未命中重下)+ future
  /// 失效重建重取;与取数失败共享 5 次预算(防真坏源无限循环)。
  void _retryThumbAfterFileError(PhotoGroup group) {
    final handle = group.primary.handle;
    if (!_thumbFileRetryPending.add(handle)) return; // 已排程:去抖
    Future<void>.delayed(const Duration(seconds: 2)).then((_) {
      _thumbFileRetryPending.remove(handle);
      final path = _thumbPaths.remove(handle);
      if (path != null) {
        try {
          File(path).deleteSync(); // 坏档删掉:重取不走旧命中(同路径)
        } on FileSystemException {
          // 删失败不挡:缓存层命中沿 existsSync 校验兜底
        }
      }
      if (!mounted) return;
      if ((_thumbRetries[handle] ?? 0) >= 5) return; // 预算耗尽
      _thumbRetries[handle] = (_thumbRetries[handle] ?? 0) + 1;
      if (_thumbFutures.remove(handle) != null) {
        setState(() {});
      }
    });
  }

  /// [debugRetryThumbAfterFileError] 直调入口:errorBuilder 沿的引擎解
  /// 码失败在 fake-async 测试里无法落地,直调同款逻辑验证重取。
  @visibleForTesting
  void debugRetryThumbAfterFileError(PhotoGroup group) =>
      _retryThumbAfterFileError(group);

  Widget _cell(PhotoGroup group, int index, List<PhotoGroup> items,
      {Key? key}) {
    _noteBuilt(index, items); // 构建沿 = 预取锚点沿(前瞻预热)
    final selected = _selected.contains(group.key);
    return GestureDetector(
      key: key,
      onTap: () => _selecting ? _toggle(group) : _openViewer(items, index),
      onLongPress: () => _toggle(group),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<String>(
            future: _thumbFuture(group),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(
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
                return ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                );
              }
              return Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  _retryThumbAfterFileError(group); // 死路径/坏档:自愈
                  return ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(
                        child: Icon(Icons.broken_image_outlined)),
                  );
                },
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
                    // 品牌黄底深字(不随主题 —— 角标盖在照片上,黄底在
                    // 深浅主题下同形)
                    color: AppColors.brandYellow,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star,
                          size: 9, color: AppColors.onBrandYellow),
                      const SizedBox(width: 2),
                      Text(
                        '${_ratings.ratingOf(group)}',
                        style: const TextStyle(
                          color: AppColors.onBrandYellow,
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

  /// 底栏两段式下载:默认单「下载」钮,点按换出「到相册/到应用」双
  /// 目的地(选择清空沿复位,见 [_clearSelection]);删除钮常驻。
  Widget _actionBar(List<PhotoGroup> items) {
    return SafeArea(
      child: BottomAppBar(
        child: Row(
          children: [
            if (!_revealDownload)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => setState(() => _revealDownload = true),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(context.t('grid.download')),
                ),
              )
            else ...[
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () =>
                      _downloadSelected(items, TransferDestination.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(context.t('grid.downloadToAlbum')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () =>
                      _downloadSelected(items, TransferDestination.app),
                  icon: const Icon(Icons.folder_outlined),
                  label: Text(context.t('grid.downloadToApp')),
                ),
              ),
            ],
            const SizedBox(width: 8),
            IconButton(
              tooltip: context.t('common.delete'),
              onPressed: () => _deleteSelected(items),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 懒枚举首块前骨架(2026-10-17,替代旧转圈):0x9805 全库枚举单笔
/// ~3.8s 相机端编目(真机日志定案),期间界面不再是空心 spinner,而是
/// 4 列方块网格形占位(与真网格同几何:4 列/2px 缝/lg 圆角/日期头)。
/// **静态无动画**:AppBar 不定进度细条已承担「在动」反馈,页内再加
/// 无限动画会卡死测试的 pumpAndSettle(渐进时序用例全依赖它)。
class _EnumSkeleton extends StatelessWidget {
  const _EnumSkeleton({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 20, bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 平铺方块骨架:枚举中相册分野未定,不预设日期分组,只给
          // 「照片正在到来」的形状感。
          for (var r = 0; r < 6; r++)
            Row(
              children: [
                for (var c = 0; c < 4; c++)
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.06),
                          borderRadius:
                              BorderRadius.circular(AppRadius.lg),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

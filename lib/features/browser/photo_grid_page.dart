/// 相机相册页(相机页「相册」入口直达):全部照片网格按拍摄日期分段
/// (段头点按 = 整日选择/取消);文件夹筛选收进 AppBar 右上弹层(图库
/// 页同款 MenuAnchor 分区卡片,仅多相册时出相册分区),同文件夹内
/// RAW+JPG 仍合并。长按进入多选,底部操作栏默认单「下载」钮,点按
/// 换出「到相册/到应用」双目的地(格式按筛选弹层预定档直接收集,缺
/// 格式的组跳过)、批量删除(相机侧逐文件 0x100B,确认对话框把关)。
/// 筛选弹层的图片下载格式档(全部/仅 JPG/仅 RAW)只定批量下载的格式
/// 预选,全程不弹格式面板:「全部」整组全量直接下(双格式组 JPG+RAW
/// 全要,视频整段),仅 JPG / 仅 RAW 按该格式收集(网格显示不变)。
/// 评级角标(左上星标)随 [AlbumRatingsController] 变化,真源 = 相机
///(MTP 0xDC8A);评级筛选在相机评级数据建立后出现,二级面板多选
///(iOS 相册式:「全部」与各分类互斥,分类并集滤网)。连拍不聚合
///(2026-10-24 定稿,聚合只在图库):连拍簇进页拆回单快门组逐张显格。
///
/// 活页模式:随 [BrowserController] 的渐进发布增长(最新优先,新对象尾部
/// 追加);AppBar 细进度条 + 刷新按钮 + 下拉刷新重枚举;首块前骨架态,
/// 同步中断 = 无内容硬错误屏 / 有内容软横幅(已显示内容可继续浏览)。
/// 断连后保留最后快照(相册列表被控制器清空时,网格内容可见,缩略图走
/// 磁盘缓存)。缩略图 Future 按 handle 缓存在本页 State(setState 重建
/// 不闪、不重发请求;PtpSession 串行锁 + ThumbnailCache 并发合并兜底)。
/// 查看器仍按打开时刻的快照浏览(同步继续不追新,重进本页即刷新)。
///
/// 点格进查看器走渐进放大动效(iOS 图库式,HeroZoom 航班:格缩略从格
/// 位放大展开到全屏,收查看器反向落回格位);缩略未就绪的格无动效,
/// 照旧普通转场 —— 见 common/widgets/hero_zoom.dart。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';

import '../../app_services.dart';
import '../../core/browser/album.dart';
import '../../core/browser/camera_file_ops.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/media/video_duration.dart';
import '../../core/ptpip/object_format.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../data/ui_prefs_store.dart';
import '../../l10n/l10n.dart';
import '../common/media_grid.dart';
import '../common/rating_filter.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/hero_zoom.dart';
import '../common/widgets/states.dart';
import '../../design/app_dimens.dart';
import 'album_ratings_controller.dart';
import 'browser_controller.dart';
import '../transfers/transfers_page.dart';
import 'photo_viewer_page.dart';

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
    this.uiPrefs,
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
  final AlbumRatingsController? ratings;

  /// 下载 SnackBar 的「查看进度」动作注入(测试;AppServices 里的传输
  /// 控制器在裸测试树不可建)。null = 默认推 TransfersPage(生产)。
  final VoidCallback? onOpenTransfers;

  /// 弹层选项持久化注入(测试);缺省用 AppServices 单例。
  final UiPrefsStore? uiPrefs;

  @override
  State<PhotoGridPage> createState() => _PhotoGridPageState();
}

/// 展示格:组 × 格式档 —— RAW+JPG 等跨格式组拆分显示(每格式一格,
/// 用户定稿 2026-10-23:同一次快门不再只显示一张)。相机侧组已不聚合
/// 连拍(进页拆簇,见 build),评级/查看器语义仍在组上(同组各格同
/// 评级),选择与下载按格式的成员子集收集。
final class _GridItem {
  _GridItem(this.group, this.format);

  final PhotoGroup group;

  /// 该格格式档(null = 组内无已知格式,兜底整组一格)。
  final MediaFormat? format;

  /// 格身份键(组键 + 格式名;选择集/元素复用锚)。
  String get key =>
      format == null ? '${group.key}' : '${group.key}:${format!.name}';

  /// 该格成员(格式子集;双槽同格式副本同格,下载按基名去重在引擎侧)。
  late final List<ObjectEntry> members = format == null
      ? group.members
      : [
          for (final m in group.members)
            if (mediaFormatOfFilename(m.name) == format) m,
        ];

  /// 格代表文件(缩略/图档重试锚;格式子集首个)。
  ObjectEntry get rep => members.first;

  bool get isVideo => rep.kind == ObjectKind.video;

  /// 类型角标:格式短名(单快门组无连拍数;聚合 ×N 表示只在图库)。
  String get typeLabel => format?.label ?? '';
}

class _PhotoGridPageState extends State<PhotoGridPage> {
  @override
  void initState() {
    super.initState();
    // 懒枚举触发点:连接沿全库枚举已撤(0x9805 单笔 3.8s 曾插队起景、
    // 拖慢首帧与信息卡),进页才发起;仓库已载入(重开页)时 load() 瞬回
    // 不重枚举,断连期调用静默失败不上屏。
    unawaited(widget.controller.load());
    unawaited(_restorePrefs()); // 弹层选项:上次退出时的状态
  }

  /// 恢复弹层选项(排序/格式/评级/显示;文件夹不入账 —— 句柄随相机
  /// 内容漂移)。通道未就绪/损坏:吞掉走默认值。
  Future<void> _restorePrefs() async {
    try {
      final v = await _uiPrefs!.load();
      if (!mounted) return;
      setState(() {
        for (final k in MediaSortKey.values) {
          if (k.name == v['grid.sortKey']) _sort.key = k;
        }
        if (v['grid.sortDesc'] is bool) _sort.desc = v['grid.sortDesc'] as bool;
        _formatSelection.restore([
          for (final f in MediaFormat.values)
            if ((v['grid.formats'] as List<Object?>?)?.contains(f.name) ?? false)
              f,
        ]);
        _ratingSelection.restore([
          for (final r in RatingFilter.values)
            if ((v['grid.ratings'] as List<Object?>?)?.contains(r.index) ?? false)
              r,
        ]);
        if (v['grid.showRating'] is bool) {
          _show.rating = v['grid.showRating'] as bool;
        }
        if (v['grid.showFormat'] is bool) {
          _show.format = v['grid.showFormat'] as bool;
        }
        _persistedFolderNames =
            (v['grid.folderNames'] as List<Object?>?)?.cast<String>();
        _persistedFolderSel =
            (v['grid.folderSel'] as List<Object?>?)?.cast<String>();
      });
    } on Object {
      // 默认值(净格 + 时间降序)
    }
  }

  /// 落账弹层选项(每次变更沿;失败不挡交互)。
  Future<void> _savePrefs() async {
    try {
      await _uiPrefs!.save({
        'grid.sortKey': _sort.key.name,
        'grid.sortDesc': _sort.desc,
        'grid.formats': [for (final f in _formatSelection.values) f.name],
        'grid.ratings': [for (final r in _ratingSelection.values) r.index],
        'grid.showRating': _show.rating,
        'grid.showFormat': _show.format,
        'grid.folderNames': _persistedFolderNames ?? const <String>[],
        'grid.folderSel': [
          for (final a in _lastAlbums)
            if (!a.isAggregate && _folderSelection.contains(a.folderHandle))
              a.name,
        ],
      });
    } on Object {
      // 持久化失败不挡交互
    }
  }

  /// 选中集按格身份键(_GridItem.key = 组键:格式名):RAW+JPG 拆格
  /// 后各格式独立勾选,下载按格式的成员子集收集(见 _downloadSelected)。
  final Set<String> _selected = {};

  /// 文件夹筛选(共享选集件;初始 = 入口句柄,入口为汇总即「全部照片」)。
  /// 选中的文件夹在重枚举后消失时回落汇总(见 build 里的 post-frame 兜底);
  /// 持久化见 [_reconcileFolders](清单一致用配置,不一致更新并重置)。
  late final FolderFilterSelection _folderSelection =
      FolderFilterSelection()..seed(widget.folderHandle);

  /// 持久化的文件夹清单快照与选中名(对账输入;restore 读入)。
  List<String>? _persistedFolderNames;
  List<String>? _persistedFolderSel;

  /// 持久化选集是否已应用(对账幂等闸:只应用一次,此后用户实时改)。
  bool _folderSelApplied = false;

  /// 格式筛选(共享选集件:空集 = 全部,非空 = 各格式并集;格 = 组 ×
  /// 格式档,滤网直接作用在格上)。
  final FormatFilterSelection _formatSelection = FormatFilterSelection();

  /// 评级筛选(共享选集件:空集 = 全部,非空 = 各分类并集)。
  final RatingFilterSelection _ratingSelection = RatingFilterSelection();

  /// 排序(共享状态件:时间/文件名/文件大小 × 双向;默认时间从大到小,
  /// 与仓库序一致)。
  final MediaSortState _sort = MediaSortState();

  /// 「显示」开关(共享状态件:评级/格式角标按需上格,默认净格)。
  final ShowToggle _show = ShowToggle();

  /// 弹层分区折叠态(排序/筛选/显示头行点按收展)。
  final MenuSectionState _sections = MenuSectionState();

  /// 评级滤网:评级数据未建立时恒放行(防把「未取到」当「未评」筛空);
  /// 空选集 = 全部,非空 = 各分类任一命中即收(多选并集)。
  bool _ratingAllows(PhotoGroup group) => _ratingSelection.allows(
        rating: _ratings.ratingOf(group),
        trashStar: _ratings.trashStar(group),
        ratedUnknown: _ratings.ratedUnknown(group),
        available: _ratings.available,
      );

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
  List<_GridItem>? _prefetchItems;

  void _resetPrefetchAnchors(List<_GridItem> items) {
    if (identical(items, _prefetchItems)) return;
    _prefetchItems = items;
    _builtMaxIndex = -1;
    _builtMinIndex = 1 << 30;
  }

  void _noteBuilt(int index, List<_GridItem> cells) {
    final newMax = index > _builtMaxIndex;
    final newMin = index < _builtMinIndex;
    if (!newMax && !newMin) return;
    if (newMax) _builtMaxIndex = index;
    if (newMin) _builtMinIndex = index;
    final targets = <_GridItem>[];
    void window(int lo, int hi) {
      for (var i = lo; i <= hi && i < cells.length; i++) {
        if (i < 0) continue;
        if (!_thumbFutures.containsKey(cells[i].rep.handle)) {
          targets.add(cells[i]);
        }
      }
    }

    if (newMax) window(index + 1, index + _prefetchWindow);
    if (newMin) window(index - _prefetchWindow, index - 1);
    if (targets.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final c in targets) {
        final future = _thumbFuture(c.rep);
        // 评级轻量段(0xDC8A 一笔)与缩略图同窗预热:格滚到视口时星档
        // 已在手,不再落后整个预热窗(重发由仓库去重集空转)。
        _ratings.ensure(c.group);
        // 视频时长探测(容器行走,数次小读;去重,成果经 updates 回来)。
        if (c.isVideo) {
          _ratings.repository.requestVideoDuration(c.rep.handle);
        }
        // 解码缓存预热(与本地图库页同款,2026-10-26 首过猛滑黑格
        // 同案):小图路径在账直预热;在途的落地沿补预热 —— 缺了这层,
        // 首次猛滑的格滚走了解码才落地,回滚才秒出。失败人设已有重试,
        // onError 吞掉防未处理异常(_thumbFuture 失败会 rethrow)。
        final known = _thumbPaths[c.rep.handle];
        if (known != null) {
          _precacheGridThumb(known);
        } else {
          unawaited(future.then<void>(
            (path) {
              if (mounted) _precacheGridThumb(path);
            },
            onError: (Object _) {},
          ));
        }
      }
    });
  }

  /// 解码缓存预热(静默口同本地图库页:precache 失败走 onError 官方
  /// 静默道,不进 future 错误道,测试假 JPEG 不外冒)。
  void _precacheGridThumb(String path) {
    unawaited(precacheImage(gridThumbImageProvider(path), context,
        onError: (Object _, StackTrace? __) {}));
  }

  /// 最后一次解析到的可见内容(断连后控制器清空,以它保持网格快照)。
  List<PhotoGroup>? _lastItems;

  /// 文件夹清单对账(幂等):当前清单(文件夹名排序集)与持久化一致 →
  /// 把持久化选中名按当前相册映射成句柄应用一次;不一致(换卡/加减夹)
  /// → 更新清单快照并重置选集回「全部照片」。重置沿 post-frame setState。
  void _reconcileFolders(List<CameraAlbum> albums) {
    final current = [
      for (final a in albums)
        if (!a.isAggregate) a.name,
    ]..sort();
    final stored = _persistedFolderNames;
    if (stored != null && listEquals(stored, current)) {
      if (_folderSelApplied) return;
      _folderSelApplied = true;
      if (_persistedFolderSel case final sel? when sel.isNotEmpty) {
        for (final name in sel) {
          for (final a in albums) {
            if (!a.isAggregate && a.name == name) {
              _folderSelection.add(a.folderHandle);
            }
          }
        }
      }
      return;
    }
    // 清单变了(或首跑无账):落新清单 + 重置选集。
    _persistedFolderNames = current;
    _folderSelApplied = true;
    if (!_folderSelection.isAll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _folderSelection.clear());
          unawaited(_savePrefs());
        }
      });
    } else {
      unawaited(_savePrefs()); // 清单快照更新(选集本就空)
    }
  }

  /// 汇总相册(全部照片);无返回 null。
  CameraAlbum? _resolveAggregate(List<CameraAlbum> albums) {
    for (final album in albums) {
      if (album.folderHandle == CameraAlbum.allPhotosHandle) return album;
    }
    return null;
  }

  /// 最后一次非空的相册列表(chips 快照,断连后保持可切换)。
  List<CameraAlbum> _lastAlbums = const [];

  ThumbnailCache get _thumbnails =>
      widget.thumbnails ?? AppServices.instance.thumbnails;
  TransferEngine get _engine =>
      widget.engine ?? AppServices.instance.transferEngine;
  CameraFileOps get _fileOps => widget.fileOps ?? AppServices.instance.fileOps;
  AlbumRatingsController get _ratings =>
      widget.ratings ?? AppServices.instance.ratings;
  UiPrefsStore? get _uiPrefs => widget.uiPrefs ?? AppServices.instance.uiPrefs;
  bool get _selecting => _selected.isNotEmpty;

  /// 文件夹子面板选档(null = 全部照片):可见集变化沿清空网格选择与
  /// 下载展开(与格式/评级筛选同规);落账持久化。
  void _toggleFolder(int? handle) {
    setState(() {
      handle == null
          ? _folderSelection.clear()
          : _folderSelection.toggle(handle);
      _selected.clear();
      _revealDownload = false;
    });
    unawaited(_savePrefs());
  }

  void _toggle(_GridItem cell) {
    setState(() {
      if (!_selected.remove(cell.key)) {
        _selected.add(cell.key);
      }
      _revealDownload = false;
    });
  }

  /// 全选 = 当前已知项(渐进同步中张数随后续块增长,已选项不自动扩选)。
  void _selectAll(List<_GridItem> cells) {
    setState(() {
      _selected
        ..clear()
        ..addAll(cells.map((cell) => cell.key));
      _revealDownload = false;
    });
  }

  /// 整日选择/取消:段头点按(仅多选模式下生效)。
  void _toggleDay(List<_GridItem> dayCells) {
    final keys = dayCells.map((c) => c.key).toSet();
    final allSelected = keys.every(_selected.contains);
    setState(() {
      allSelected ? _selected.removeAll(keys) : _selected.addAll(keys);
      _revealDownload = false;
    });
  }

  /// 连拍簇 → 单快门组(同基名成员一组:RAW+JPG 孪生/双槽副本不拆)。
  /// 成员序保持(渐进枚举新→旧;byBase 为插入序 Map)。
  List<PhotoGroup> _splitBurst(PhotoGroup group) {
    final byBase = <String, List<ObjectEntry>>{};
    for (final m in group.members) {
      byBase.putIfAbsent(baseNameOf(m.name), () => []).add(m);
    }
    return [for (final members in byBase.values) PhotoGroup(members)];
  }

  /// 组 → 展示格:组内出现的各格式档各一格(RAW+JPG 拆分;组内无已知
  /// 格式兜底整组一格)。相机侧组已不聚合连拍(见 build),格 = 单快门
  /// × 格式档,×N 角标不再出现(聚合表示只在图库)。
  List<_GridItem> _expandGroup(PhotoGroup group) {
    final formats = <MediaFormat>[];
    for (final m in group.members) {
      final f = mediaFormatOfFilename(m.name);
      if (f != null && !formats.contains(f)) formats.add(f);
    }
    if (formats.isEmpty) return [_GridItem(group, null)];
    return [for (final f in formats) _GridItem(group, f)];
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _revealDownload = false;
      });

  /// 批量下载:格 = 组 × 格式档,选中格按各自格式子集收集成员(同组
  /// 两格都选 = 两格式都要);子集恒非空,无跳过计数。全程不弹格式面板。
  Future<void> _downloadSelected(
      List<_GridItem> cells, TransferDestination destination) async {
    final selected =
        cells.where((c) => _selected.contains(c.key)).toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    final entries = <ObjectEntry>[];
    for (final cell in selected) {
      entries.addAll(cell.members);
    }
    await _engine.enqueue(entries, destination: destination);
    _clearSelection();
    if (!mounted) {
      return;
    }
    // 目的地片段键「到相册/到应用」带介词(不立裸键「应用」—— edit 页的
    // 「应用」是 Apply 动词,撞义);格式 tag = 选中格格式短名去重拼接。
    final where = destination == TransferDestination.gallery
        ? context.t('grid.toAlbum')
        : context.t('grid.toApp');
    final formats =
        selected.map((c) => c.format?.label).whereType<String>().toSet();
    final tag = formats.isEmpty ? '' : '(${formats.join('+')})';
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
          content: Text(context.t('grid.downloadStarted', {
            'i': entries.length,
            'g': selected.length,
            'f': entries.length,
            'tag': tag,
            'where': where,
            'skip': '',
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
  Future<void> _deleteSelected(List<_GridItem> cells) async {
    final selected =
        cells.where((c) => _selected.contains(c.key)).toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    final fileCount = selected.fold<int>(0, (n, c) => n + c.members.length);
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('grid.deleteCameraTitle'),
      content: context
          .t('grid.deleteCameraBody', {'n': selected.length, 'f': fileCount}),
      confirmLabel: context.t('common.delete'),
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    if (!mounted) {
      return;
    }
    // 删除 = 逐格成员 0x100B(格是格式子集,同组另格不受牵连);成功句
    // 柄出仓库缓存后组内余成员照常显示。
    final result = await _fileOps.deleteGroups([
      for (final cell in selected) PhotoGroup(cell.members),
    ]);
    if (!mounted) {
      return;
    }
    _clearSelection();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (result.failed > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(context.t(
            'grid.deletedPartial', {'n': result.deleted, 'm': result.failed})),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text(context.t('grid.deleted', {'n': result.deleted}))));
    }
  }

  /// 动效配对键(格身份键;[_cell] 的 HeroZoom 与查看器侧同款)。
  String _heroTag(_GridItem cell) => 'camera-grid-${cell.key}';

  /// 打开查看器:按可见格去重后的组序翻页(同组两格同看一张照片),
  /// 初始页 = 被点格的组;被点格的格式跟随进查看器(查看器内下载按
  /// 该格式收集,翻页后各组的下载同样按它 —— 与网格筛选预定一致)。
  /// 渐进放大动效:格缩略已落盘才挂配对件(盘档路径作航班图源,
  /// 缓存命中首帧即真图);未就绪降级普通转场。
  void _openViewer(List<_GridItem> cells, int index) {
    final cell = cells[index];
    final groups = <PhotoGroup>[];
    for (final c in cells) {
      if (!groups.any((g) => g.key == c.group.key)) groups.add(c.group);
    }
    final thumbPath = _thumbPaths[cell.rep.handle];
    // ZoomPageRoute:整页淡入 + 网格原地不动(动效底图),与 Hero 航班
    // 同拍 —— 系统 zoom 转场的缩退/快隐会与飞行图打架(原生图库缩放里
    // 网格不动)。
    Navigator.of(context).push(
      ZoomPageRoute<void>(
        pageBuilder: (_, __, ___) => PhotoViewerPage(
          items: groups,
          initialIndex: groups.indexOf(cell.group),
          ratings: widget.ratings,
          formats: cell.format == null
              ? const <MediaFormat>{}
              : {cell.format!},
          heroTag: thumbPath == null ? null : _heroTag(cell),
          heroThumbPath: thumbPath,
          heroImage:
              thumbPath == null ? null : gridThumbImageProvider(thumbPath),
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
        // 相册快照:活列表优先,断连后沿用(切换/解析保持可用)。
        if (controller.albums.isNotEmpty) _lastAlbums = controller.albums;
        // 文件夹清单对账(同步收口后):与持久化清单一致 → 应用持久化
        // 选集(按名匹配);不一致 → 更新清单并重置回全部照片。
        if (!controller.syncing && controller.albums.isNotEmpty) {
          _reconcileFolders(controller.albums);
        }
        final albums =
            controller.albums.isNotEmpty ? controller.albums : _lastAlbums;
        final aggregate = _resolveAggregate(albums);
        // 文件夹多选并集:空选 = 汇总相册;所选夹在重枚举后全部消失时
        // 回落汇总(渐进同步期间不判 —— 早期块可能还没枚举到)。post-
        // frame 规避 build 内 setState。
        List<PhotoGroup> items;
        if (_folderSelection.isAll) {
          items = aggregate?.items ?? _lastItems ?? const <PhotoGroup>[];
          if (aggregate != null) _lastItems = aggregate.items;
        } else {
          final picked = <PhotoGroup>[
            for (final album in albums)
              if (!_folderSelection.isAll &&
                  album.folderHandle != CameraAlbum.allPhotosHandle &&
                  _folderSelection.contains(album.folderHandle))
                ...album.items,
          ];
          if (picked.isNotEmpty) {
            items = picked;
            _lastItems = items;
          } else {
            items = _lastItems ?? const <PhotoGroup>[];
            if (!controller.syncing && controller.albums.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _folderSelection.clear();
              });
            }
          }
        }
        // 相机相册不聚合连拍(2026-10-24 定稿,聚合只在图库):连拍簇
        // 按基名拆回单快门组 —— 同基名 RAW+JPG 孪生/双槽副本仍同组,
        // 实况对不动;评级/选择/查看器语义随单快门组走,每张各显各档。
        if (items.isNotEmpty) {
          final flat = <PhotoGroup>[
            for (final group in items)
              if (group.isBurst) ..._splitBurst(group) else group,
          ];
          items = flat;
          _lastItems = flat;
        }
        // 展示格 = 组 × 格式档(RAW+JPG 拆分,每格式一格);评级滤组、
        // 格式滤格;排序(共享件:时间/文件名/文件大小 × 双向)。
        final visible = sortMedia(
          [
            for (final group in items)
              if (_ratingAllows(group))
                ..._expandGroup(group)
                    .where((c) => _formatSelection.allows(c.format)),
          ],
          _sort,
          (c) => (
            c.group.capturedAt,
            c.rep.name,
            c.members.fold<int>(0, (n, m) => n + m.sizeInBytes),
          ),
        );
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
                  onPressed: () => _selectAll(visible),
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
          body: _body(controller, items, visible),
          bottomSheet: _selecting ? _actionBar(visible) : null,
        );
      },
    );
  }

  /// 主体四态:无内容硬错误屏 / 首块前骨架 / 空相册提示 / 内容网格
  /// (同步中断仅软横幅,已显示内容可继续浏览,下拉刷新重枚举)。
  Widget _body(BrowserController controller, List<PhotoGroup> items,
      List<_GridItem> cells) {
    _resetPrefetchAnchors(cells); // items 换实例(刷新/切换):预取锚点重置
    if (cells.isEmpty) {
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
                // 时间排序才按拍摄日分段;文件名/文件大小排序列平铺。
                if (_sort.key == MediaSortKey.time)
                  for (final section in groupMediaByDate(
                      cells, (c) => c.group.capturedAt)) ...[
                    SliverToBoxAdapter(
                      child: MediaSectionHeader(
                        day: section.day,
                        count: section.items.length,
                        selecting: _selecting,
                        daySelected: _selecting &&
                            section.items
                                .every((c) => _selected.contains(c.key)),
                        onToggle: () => _toggleDay(section.items),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                        itemCount: section.items.length,
                        // key 按格身份键(组键:格式名):增长期间尾部追加、
                        // 条目重排时元素正确复用(选中态与缩略图 Future 都
                        // 按键控);渐进配对前后键稳定。
                        itemBuilder: (_, i) => _cell(
                          section.items[i],
                          section.firstIndex + i,
                          cells,
                          key: ValueKey(section.items[i].key),
                        ),
                      ),
                    ),
                  ]
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2,
                      ),
                      itemCount: cells.length,
                      itemBuilder: (_, i) => _cell(
                        cells[i],
                        i,
                        cells,
                        key: ValueKey(cells[i].key),
                      ),
                    ),
                  ),
                // 尾部留白:滚到底最后一行不贴死底缘(ohos 真机底部安全
                // 区常报 0,手势条会压住最后一行;iOS 自动安全区外再垫一档)。
                const SliverPadding(
                  padding: EdgeInsets.only(bottom: 48),
                ),
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
      message: controller.error!,
      actionLabel: context.t('common.retry'),
      onAction: controller.load,
    );
  }

  /// 右上筛选弹层(共享 [FilterMenu] 卡片骨架):相册区(仅多相册)+
  /// 筛选区(共享格式/评级两级联子面板)。相册切换沿用旧 chips 规矩
  /// 清空选择(跨相册选择无意义)。
  Widget _filterMenuAnchor(BuildContext context, List<CameraAlbum> albums) {
    return FilterMenu(children: [
      // 排序区(共享,头行可折叠):时间/文件名/文件大小三行直切。
      ...sortMenuSection(context, _sort, _sections,
          () => setState(() {}), _onSort),
      menuSectionDivider,
      // 筛选区(共享三级联子面板,全部行选档不收层):文件夹(相机专属,
      // 多选并集,空选 = 全部照片)+ 格式 + 评级(评级数据建立后出现)。
      filterMenuSectionHeader(context, context.t('libpage.filter'), 'filter',
          _sections, () => setState(() {})),
      if (!_sections.isCollapsed('filter')) ...[
        if (albums.length >= 2)
          ...folderFilterMenuSection(
              context, albums, _folderSelection, _toggleFolder),
        ...formatFilterMenuSection(context, _formatSelection, _toggleFormat),
        if (_ratings.available)
          ...ratingFilterMenuSection(
              context, _ratingSelection, _toggleRatingFilter),
      ],
      menuSectionDivider,
      // 显示区(共享,头行可折叠):评级/格式角标按需上格。
      ...showMenuSection(context, _show, _sections, () {
        setState(() {
          _selected.clear();
          _revealDownload = false;
        });
        unawaited(_savePrefs());
      }),
    ]);
  }

  /// 格式子面板选档(null = 全部):可见格变化沿清空网格选择与下载
  /// 展开(与评级筛选同规);落账持久化。
  void _toggleFormat(MediaFormat? f) {
    setState(() {
      f == null ? _formatSelection.clear() : _formatSelection.toggle(f);
      _selected.clear();
      _revealDownload = false;
    });
    unawaited(_savePrefs());
  }

  /// 排序直切(共享件):点当前键翻方向,点他键切键(方向沿用);
  /// 可见集变化沿清空网格选择与下载展开。
  void _onSort(MediaSortKey key) {
    setState(() {
      if (_sort.key == key) {
        _sort.desc = !_sort.desc;
      } else {
        _sort.key = key;
      }
      _selected.clear();
      _revealDownload = false;
    });
    unawaited(_savePrefs());
  }

  /// 评级子面板选档(共享选集件):每次选档沿清空网格选择与下载展开
  ///(可见集变化,与旧单选同规)。
  void _toggleRatingFilter(RatingFilter r) {
    setState(() {
      _ratingSelection.toggle(r);
      _selected.clear();
      _revealDownload = false;
    });
    unawaited(_savePrefs());
  }

  /// 网格缩略取数(句柄去重):失败不驻留 —— 移除在途 future 并限次
  /// 自动重试(3 次,间隔 3s;耗尽留断图占位,滚动重建自然再试)。旧版
  /// 失败 future 永驻缓存,断图格直到重进页面都不再尝试(2026-10-16
  /// 真机复报「部分缩略图加载不出来」根因之一)。
  Future<String> _thumbFuture(ObjectEntry rep) {
    final handle = rep.handle;
    return _thumbFutures.putIfAbsent(handle, () {
      final f = _thumbnails.pathFor(rep, ThumbSource.grid);
      // 落盘路径记账(图档级失败删坏档用);onError 吞掉防未处理异常。
      f.then<void>((p) => _thumbPaths[handle] = p, onError: (Object _) {});
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
  void _retryThumbAfterFileError(ObjectEntry rep) {
    final handle = rep.handle;
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
      _retryThumbAfterFileError(group.primary);

  Widget _cell(_GridItem cell, int index, List<_GridItem> cells, {Key? key}) {
    final group = cell.group;
    _noteBuilt(index, cells); // 构建沿 = 预取锚点沿(前瞻预热)
    _ratings.ensure(group); // 评级轻量段即发(可见格先答,后台队只兜底)
    final selected = _selected.contains(cell.key);
    final stars = _ratings.ratingOf(group);
    final unknown = _ratings.ratedUnknown(group);
    final trash = _ratings.trashStar(group);
    return _CellDwell(
      onDwell: () {
        if (mounted) _ratings.ensureTrash(group); // 驻留 ~400ms 才探删除候选
      },
      child: MediaGridCell(
        key: key,
        selecting: _selecting,
        selected: selected,
        onTap: () => _selecting ? _toggle(cell) : _openViewer(cells, index),
        onLongPress: () => _toggle(cell),
        badges: [
          // 「显示」胶囊(左下,黑底 = 格式标签同款框):格式文案、评级
          // 图标同框;未勾选不占位(净格)。
          Align(
            alignment: Alignment.bottomLeft,
            child: ShowChip(
              format: _show.format ? cell.typeLabel : null,
              ratingIcon: _show.rating
                  ? ratingInlineIcon(
                      stars: stars, unknown: unknown, trash: trash)
                  : null,
            ),
          ),
          // 视频时长(右下,原摄像机角标位;横轴与「显示」胶囊同线)。
          if (cell.isVideo)
            DurationChip(
                text: formatVideoDurationOrNull(
                    _ratings.repository.durationFor(cell.rep.handle))),
        ],
        child: FutureBuilder<String>(
          future: _thumbFuture(cell.rep),
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
            // 渐进放大动效锚(tag 与查看器侧配对);图像用共享提供器
            // 构造(ResizeImage 300),航班梭子命中同一份已解码缓存。
            return HeroZoom(
              tag: _heroTag(cell),
              thumbPath: path,
              child: Image(
                image: gridThumbImageProvider(path),
                fit: BoxFit.cover,
                // 三列格宽约 130 逻辑像素(与本地图库网格同几何):0x90C4
                // ~1024px 缩略按 300 降采样解码(同图库网格 cacheWidth
                // 口径),免全尺寸解码白耗内存。
                errorBuilder: (context, error, stackTrace) {
                  _retryThumbAfterFileError(cell.rep); // 死路径/坏档:自愈
                  return ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child:
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// 底栏两段式下载:默认单「下载」钮,点按换出「到相册/到应用」双
  /// 目的地(选择清空沿复位,见 [_clearSelection]);删除钮常驻。
  Widget _actionBar(List<_GridItem> cells) {
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
                      _downloadSelected(cells, TransferDestination.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(context.t('grid.downloadToAlbum')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () =>
                      _downloadSelected(cells, TransferDestination.app),
                  icon: const Icon(Icons.folder_outlined),
                  label: Text(context.t('grid.downloadToApp')),
                ),
              ),
            ],
            const SizedBox(width: 8),
            IconButton(
              tooltip: context.t('common.delete'),
              onPressed: () => _deleteSelected(cells),
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
/// 3 列方块网格形占位(与真网格同几何:3 列/2px 缝/lg 圆角/日期头)。
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
                for (var c = 0; c < 3; c++)
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(AppRadius.lg),
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

/// 格驻留探针:挂载 ~400ms 后仍在树上(未被滚动丢弃)才回调一次。
/// 驻留 = 用户真的在看,才发昂贵的删除候选甄别(256KB XMP 头读);
/// 滚过格 dispose 沿取消,不占会话链。重建不重排(initState 一次)。
class _CellDwell extends StatefulWidget {
  const _CellDwell({required this.child, required this.onDwell});

  final Widget child;
  final VoidCallback onDwell;

  @override
  State<_CellDwell> createState() => _CellDwellState();
}

class _CellDwellState extends State<_CellDwell> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 400), widget.onDwell);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

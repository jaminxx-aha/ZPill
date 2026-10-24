/// 图库页(底部导航 tab):「下载到应用」的文件网格(downloadsDir 直读,
/// TransfersController 的 appFiles 数据源)。**不含**已导入系统相册的
/// 文件 —— 那些归系统相册 App 管,这里只看应用自留的份。
///
/// 网格默认按修改时间倒序(新下载在前,弹层可翻「旧→新」);筛选收进
/// AppBar 右上弹层(排序单行「时间+方向箭头」点按翻向 × 格式
/// 全部/RAW/JPG/视频 × 评级 全部/无评级/★1-5 × 视图选项 连拍聚合开关,
/// 内存态不落库,与旧 chips 同先例)。评级数据源 = 应用内文件快照
///([LibraryRatings],下载落盘沿按所在组相机评级写入、相册改评沿传播,
/// 见 [fileRatingKey]);「连拍聚合」开时相邻拍摄时刻的同段文件合为
/// 一格(×N 角标,与相机相册连拍簇同参,见 [groupLocalBurstRuns];
/// mtime = 拍摄时刻由下载引擎落盘回写)。可解码图与 NEF/HIF/MOV 同走缩略
/// 小档管线(≤512px 落盘,格双源 gapless 切换 —— cache 被系统内存警告
/// 清空后重解的也是毫秒级小档,2026-10-20「看大图返回缩略重刷新」根治;
/// NEF 原生解码缺席时回内嵌 160×120 缩略兜底 nef_thumb.dart)。
/// 点任意可看件进黑底查看器:PageView 左右滑翻页(网格过滤序同源),
/// 图片双指缩放、NEF/HIF 原生解码长边 ≤2560(会话缓存,翻回不重解)。视频
/// 在页面内直接播放(2026-10-09:点开即播,不再「海报帧 + 播放钮 +
/// 弹全屏新页」三步走;iOS 平台视图嵌 AVPlayerViewController,播放控制
/// 在 Flutter 侧自绘 —— 原生传输条关掉,横滑才归 PageView 翻页不抢手势;
/// 高帧率素材浮「24fps 顺帧」开关,非阻塞点了才变速静音;Android/ohos
/// 通道待补回落海报帧 + 说明文案)。查看器可删除/把文件补导入系统相册。
///
/// 多选:长按任意格进入(长按格预选);多选中点格
/// = 勾/取消(连拍格整段原子勾),AppBar 变「已选 {n} 项」+ 全选/
/// 退出,底部操作栏批量删除(确认把关)/批量导出系统相册(导出后
/// 应用内文件保留)。单删收进多选(选 1 删 1);查看器内单删不动。
/// 页面常驻 IndexedStack,选中态跨 tab 保活(计数从活控制器现取,
/// 文件被删自然缩)。AppBar 传输徽标(进行中任务数)→ 传输页。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../data/ui_prefs_store.dart';
import '../../core/browser/photo_group.dart';
import '../../core/media/cube_lut.dart';
import '../../core/media/jpeg_orientation.dart';
import '../../core/media/letterbox.dart';
import '../../core/media/nef_thumb.dart';
import '../../core/media/video_duration.dart';
import '../../core/media/xmp_rgb_table.dart' show parseXmpRgbTable;
import '../../core/ptpip/object_format.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../../platform/services.dart';
import '../../platform/video_lut_export.dart';
import '../../platform/video_player.dart';
import '../common/format.dart' show formatDateTime;
import '../common/media_grid.dart';
import '../common/rating_filter.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/de_squeezed_image.dart';
import '../common/widgets/embedded_video_player.dart';
import '../common/widgets/photo_info_sheet.dart';
import '../common/widgets/states.dart';
import '../transfers/transfers_page.dart';
import 'library_ratings.dart';
import 'lut_export_sheet.dart';

/// Flutter 可解码的图片扩展名(NEF/HIF 等原生解码格式走解码管线)。
const _viewableExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

bool _isViewableName(String name) =>
    _viewableExts.any(name.toLowerCase().endsWith);

String _nameOf(File file) => file.uri.pathSegments.last;

/// 本地图库连拍聚合(公开纯函数,测试直入):把**已按当前排序排好序**
/// 的文件列表按相邻修改时刻分段。
///
/// 与相机相册侧 buildPhotoGroups 第三遍连拍并组同参([kBurstShotGap]/
/// [kBurstMinShots] 直接复用,别处另造常量会两边口径不一):相邻文件
/// (列表序,间隔取差的绝对值 → 对排序方向不敏感)修改时刻差 ≤ 窗归
/// 同段;段内**不同基名数**(RAW+JPG 孪生同基名算一张,见 [baseNameOf])
/// ≥ 成段最少张数才算连拍段 —— 「一张照片的 JPG+NEF 两文件」永不
/// 误聚,「3 张连拍 × 双格式 6 文件」聚为一段 ×3。返回覆盖全部输入的
/// 段列表(未成段的每文件独立单元素段),顺序保持输入序。前提是
/// mtime = 拍摄时刻(下载引擎落盘回写,见 TransferEngine._run)。
///
/// [modifiedOf] 注入时刻读取:测试注入合成时刻(dart:io 的
/// setLastModifiedSync/statSync 秒级取整,宿主机实证:设 .600ms 读回
/// .000,毫秒级窗边界在真实文件系统上不可表达),图库页注入 stat 缓存
/// (进度事件高频重建不逐文件摸盘,见 LocalLibraryPage._statOf);
/// 缺省走 statSync。
List<List<File>> groupLocalBurstRuns(
    List<File> files, {
    DateTime Function(File file)? modifiedOf,
}) {
  final mtime = modifiedOf ?? (f) => f.statSync().modified;
  final out = <List<File>>[];
  var start = 0;
  for (var i = 1; i <= files.length; i++) {
    final inGap = i < files.length &&
        mtime(files[i]).difference(mtime(files[i - 1])).abs() <=
            kBurstShotGap;
    if (!inGap) {
      final run = files.sublist(start, i);
      final shots = run.map((f) => baseNameOf(_nameOf(f))).toSet().length;
      if (shots >= kBurstMinShots) {
        out.add(run);
      } else {
        // 不足成段(散拍/双格式孪生):逐文件独立段,平铺格照常
        for (final f in run) {
          out.add([f]);
        }
      }
      start = i;
    }
  }
  return out;
}

/// 网格布局(3 列,紧凑间距)。
const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 3,
  mainAxisSpacing: 2,
  crossAxisSpacing: 2,
);

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.controller,
    this.gallery,
    this.rawDecoder,
    this.videoPlayer,
    this.embeddedVideoView,
    this.videoLutExport,
    this.ratings,
    this.uiPrefs,
  });

  /// 测试注入;缺省用 AppServices 单例(应用级共享,本页不持有)。
  final TransfersController? controller;

  /// 测试注入;缺省用 AppServices 单例(评级快照,与相册改评传播共享)。
  final LibraryRatings? ratings;

  /// 弹层选项持久化注入(测试);缺省用 AppServices 单例。
  final UiPrefsStore? uiPrefs;

  /// 测试注入;缺省用平台服务单例。
  final GallerySaver? gallery;

  /// 测试注入;缺省用平台服务单例(NEF 网格缩略 + 查看器解码)。
  final RawDecoder? rawDecoder;

  /// 测试注入;缺省用平台服务单例(视频页内播放/顺帧探测)。
  final VideoPlayer? videoPlayer;

  /// 测试注入(视频页内嵌视图);缺省用 iOS 平台视图。仅在
  /// [VideoPlayer.supportsEmbeddedView] 为真时被构建。
  final EmbeddedVideoViewBuilder? embeddedVideoView;

  /// 测试注入(视频 LUT 导出宿主);缺省 MethodChannel 实现
  /// (ohos 无 native,入口按 isSupported 隐藏)。
  final VideoLutExportHost? videoLutExport;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  TransfersController get _controller =>
      widget.controller ?? AppServices.instance.transfersController;

  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;

  RawDecoder get _rawDecoder =>
      widget.rawDecoder ?? PlatformServices.rawDecoder;

  VideoPlayer get _videoPlayer =>
      widget.videoPlayer ?? PlatformServices.videoPlayer;

  LibraryRatings get _ratings =>
      widget.ratings ?? AppServices.instance.libraryRatings;
  UiPrefsStore? get _uiPrefs => widget.uiPrefs ?? AppServices.instance.uiPrefs;

  /// 格式筛选(共享选集件:空集 = 全部,非空 = 各格式并集;未知扩展
  /// 名仅空选集下显示)。
  final FormatFilterSelection _formatSelection = FormatFilterSelection();

  /// 排序(共享状态件:时间/文件名/文件大小 × 双向;默认时间从大到小)。
  final MediaSortState _sort = MediaSortState();

  /// 「显示」开关(共享状态件:评级/格式角标按需上格,默认净格)。
  final ShowToggle _show = ShowToggle();

  /// 弹层分区折叠态(排序/筛选/显示/视图选项头行点按收展)。
  final MenuSectionState _sections = MenuSectionState();

  /// 评级筛选(共享选集件:空集 = 全部,非空 = 各分类并集)。
  final RatingFilterSelection _ratingSelection = RatingFilterSelection();

  /// 连拍聚合开关(内存级,不落 AppSettings —— 与筛选弹层各档同
  /// 先例):开时网格条目 = [groupLocalBurstRuns] 的段,成段合为一格。
  bool _burstGrouped = false;

  /// 多选:显式模式位(「选择」钮进场时选中集为空,不能以非空推导),
  /// 键 = 文件绝对路径(删除/导出消费的就是路径;连拍格整段成员进出)。
  bool _selectMode = false;
  final Set<String> _selected = {};

  /// NEF/MOV 网格缩略:原生解码/抽帧一次(≤512px)落盘复用。会话内
  /// future 合并(滚动反复 build 不重复解码);解码串行(整档 RAW 解码
  /// 是秒级重活,并发解码挤内存)。失败不缓存失败态、图标格顶位。
  final Map<String, Future<String?>> _mediaThumbs = {};
  Future<String?> _thumbQueue = Future.value();

  /// 视频时长探测(容器 mvhd 行走,本地小读;会话内合并)。
  final Map<String, Future<Duration?>> _videoDurations = {};

  /// stat 缓存(path → mtime+size):传输进度事件会高频重建本页
  ///(ListenableBuilder 直吃 TransfersController 的每帧任务快照),
  /// 逐文件 statSync 的同步盘 IO 不能进热路径 —— 按 appFiles 列表
  /// 实例变化沿整表重建(落定/删除沿 refreshAppFiles 换列表;缓存期
  /// 内文件的 mtime/size 视为不变,引擎在文件进列表前落定两者)。
  List<File>? _statSource;
  final Map<String, (DateTime, int)> _statCache = {};

  /// 取排序/分段/聚合用的 (mtime, size);换源后首访逐文件补一次。
  (DateTime, int) _statOf(File file) {
    final source = _controller.appFiles;
    if (!identical(source, _statSource)) {
      _statSource = source;
      _statCache.clear();
    }
    return _statCache.putIfAbsent(file.path, () {
      final s = file.statSync();
      return (s.modified, s.size);
    });
  }

  Future<Duration?> _videoDurationFor(File file) {
    final key = _contentKey(file);
    return _videoDurations.putIfAbsent(key, () async {
      try {
        if (!isVideoFilename(_nameOf(file))) return null;
        final d = await readVideoDuration((off, len) async {
          final raf = await file.open();
          try {
            await raf.setPosition(off);
            return await raf.read(len);
          } finally {
            await raf.close();
          }
        });
        return d;
      } on Object {
        return null; // 读失败/病箱:不显时长
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.refreshAppFiles();
    unawaited(_restorePrefs()); // 弹层选项:上次退出时的状态
  }

  /// 恢复弹层选项(排序/格式/评级/显示/连拍聚合;文件夹不入账)。
  Future<void> _restorePrefs() async {
    try {
      final v = await _uiPrefs!.load();
      if (!mounted) return;
      setState(() {
        for (final k in MediaSortKey.values) {
          if (k.name == v['lib.sortKey']) _sort.key = k;
        }
        if (v['lib.sortDesc'] is bool) _sort.desc = v['lib.sortDesc'] as bool;
        _formatSelection.restore([
          for (final f in MediaFormat.values)
            if ((v['lib.formats'] as List<Object?>?)?.contains(f.name) ?? false)
              f,
        ]);
        _ratingSelection.restore([
          for (final r in RatingFilter.values)
            if ((v['lib.ratings'] as List<Object?>?)?.contains(r.index) ?? false)
              r,
        ]);
        if (v['lib.showRating'] is bool) {
          _show.rating = v['lib.showRating'] as bool;
        }
        if (v['lib.showFormat'] is bool) {
          _show.format = v['lib.showFormat'] as bool;
        }
        if (v['lib.burst'] is bool) _burstGrouped = v['lib.burst'] as bool;
      });
    } on Object {
      // 默认值(净格 + 时间降序 + 不聚合)
    }
  }

  /// 落账弹层选项(每次变更沿;失败不挡交互)。
  Future<void> _savePrefs() async {
    try {
      await _uiPrefs!.save({
        'lib.sortKey': _sort.key.name,
        'lib.sortDesc': _sort.desc,
        'lib.formats': [for (final f in _formatSelection.values) f.name],
        'lib.ratings': [for (final r in _ratingSelection.values) r.index],
        'lib.showRating': _show.rating,
        'lib.showFormat': _show.format,
        'lib.burst': _burstGrouped,
      });
    } on Object {
      // 持久化失败不挡交互
    }
  }

  bool _isViewable(File file) => _isViewableName(_nameOf(file));

  /// 缩略小档路径(磁盘缓存命中即回;否则排队解码/抽帧)。可解码图
  /// (JPG/PNG)与 NEF/MOV 同管线:格双源之一与查看器海报帧共用,
  /// 不重复解码。
  Future<String?> _thumbFor(File file) {
    final key = _contentKey(file);
    return _mediaThumbs.putIfAbsent(key, () {
      _thumbQueue = _thumbQueue.then((_) => _decodeThumb(file, key));
      return _thumbQueue;
    });
  }

  Future<String?> _decodeThumb(File file, String key) async {
    final name = _nameOf(file);
    try {
      final dir = await _gallery.thumbsDir();
      final cache = File('$dir/libv3_$key.jpg'); // 键全量升版:黑边裁剪放开到全部缩略
      if (cache.existsSync()) return cache.path;
      Uint8List jpeg;
      if (isVideoFilename(name)) {
        // 信箱黑边裁剪(提取器把画面信箱化进固定画布,失败原样;
        // 提取只调一次,裁剪失败不重提取)。
        final extracted =
            await _videoPlayer.thumbnail(file.path, maxPixelSize: 512);
        jpeg = await trimLetterboxJpeg(extracted) ?? extracted;
      } else {
        // 原生小图通道:iOS = CGImageSource 对格式无门槛(HIF 一并接,
        // CreateThumbnailFromImageAlways,45MP 全图下采样解码 ~50ms,
        // 内存友好);ohos = image kit 只接 HIF(插件侧扩展名闸 ——
        // image kit 无 RAW 解码,JPG 留给引擎原图源方向自理)。通道
        // 缺失/拒绝/失败:NEF 回内嵌 160×120 缩略兜底(裸 JPEG 无
        // EXIF,注入方向引擎解码即转正,与相机相册 GetThumb 同源),
        // 其余回落 null → 格走原图源(双源 gapless),不毒化串行链。
        try {
          jpeg = await _rawDecoder.decodeJpeg(file.path, maxPixelSize: 512);
        } on Object {
          final embedded =
              isRawFilename(name) ? await extractNefEmbeddedThumb(file.path) : null;
          if (embedded == null) {
            return null;
          }
          jpeg = injectJpegOrientation(embedded.jpeg, embedded.orientation);
        }
      }
      // 信箱黑边裁剪(HIF/NEF 预览同样信箱化;无黑边原样)。
      final trimmed = await trimLetterboxJpeg(jpeg);
      cache.writeAsBytesSync(trimmed ?? jpeg, flush: true);
      return cache.path;
    } on Object {
      return null; // 无解码器/抽帧/失败:原图源(吞掉,不毒化串行链)
    }
  }

  static String _contentKey(File file) {
    final name = _nameOf(file);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    int len;
    try {
      len = file.lengthSync();
    } on FileSystemException {
      len = 0;
    }
    return '${safe}_$len';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_controller, _ratings]),
      builder: (context, _) {
        // 排序(共享件):时间/文件名/文件大小 × 双向;默认新在前。
        // stat 走缓存(见 _statOf),进度事件高频重建不逐文件摸盘。
        final files = sortMedia(List<File>.of(_controller.appFiles), _sort,
            (f) => (_statOf(f).$1, _nameOf(f), _statOf(f).$2));
        final activeCount =
            _controller.tasks.where((t) => !t.isTerminal).length;
        final filtered = _filtered(files);
        return Scaffold(
          appBar: AppBar(
            // 二十轮:标题左对齐(iOS 默认居中)——与相机页左上「相机」
            // 标签同槽(左 16px)。centerTitle false 无 leading 时标题从
            // 默认 titleSpacing(24)起,须显式收窄。(设置页三十轮起
            // 唯一显式居中;二十九轮全局居中误扩当日收回。)
            centerTitle: false,
            titleSpacing: AppSpacing.lg,
            title: Text(_selectMode
                ? context.t('grid.selectedCount', {'n': _selected.length})
                : context.t('shell.gallery')),
            actions: [
              if (_selectMode) ...[
                IconButton(
                  tooltip: context.t('grid.selectAll'),
                  onPressed: () => _selectAll(filtered),
                  icon: const Icon(Icons.select_all),
                ),
                IconButton(
                  tooltip: context.t('grid.clearSelection'),
                  onPressed: _exitSelect,
                  icon: const Icon(Icons.close),
                ),
              ] else ...[
                // 传输徽标:进行中任务数角标,点击进传输页看任务列表。
                _transfersBadge(context, activeCount),
                _filterMenuAnchor(context),
                const SizedBox(width: 8),
              ],
            ],
          ),
          // 首扫未回:扫描态(异步列目录后存在真实扫描窗,与「真空库」
          // 区分);列表已回后按未筛/筛后分流空态。本页底是主题 surface
          // (非 AppMedia 深色媒体底),状态件直接用主题色,无需
          // edit_page 的 _statesOnMedia 深色适配。
          body: !_controller.appFilesScanned
              ? LoadingState(message: context.t('libpage.scanning'))
              : files.isEmpty
                  ? EmptyState(
                      icon: Icons.download_outlined,
                      // EmptyState 显示端已包 t(),此处再包属双重包裹(无害)
                      message: context.t('libpage.empty'),
                    )
                  : filtered.isEmpty
                      // 筛后空(未筛过不会到这:全部档 filtered == files):
                      // 与真空库分开表态,带「清除筛选」一键回全部。
                      ? EmptyState(
                          icon: Icons.tune, // 与筛选弹层入口同图标
                          message: _emptyMessage,
                          actionLabel: 'libpage.clearFilter',
                          onAction: () => setState(() {
                            _formatSelection.clear();
                            _ratingSelection.clear();
                          }),
                        )
                      : _grid(context, filtered),
          bottomSheet: _selectMode ? _actionBar() : null,
        );
      },
    );
  }

  // 格式筛子(共享选集,扩展名映射)+ 评级滤网(快照未装载恒放行,
  // 防「没读到」被「无评级」筛空;空选集 = 全部,非空 = 各分类并集)。
  List<File> _filtered(List<File> files) => files
      .where((f) =>
          _formatSelection.allows(mediaFormatOfFilename(_nameOf(f))) &&
          _ratingSelection.allows(
            rating: _ratings.ratingOf(f),
            trashStar: _ratings.trashMarked(f),
            available: _ratings.loaded,
          ))
      .toList(growable: false);

  /// 网格主体:平铺(现状)或连拍聚合。「连拍」开时条目 =
  /// [groupLocalBurstRuns] 的段 —— 成段合为一格(封面 + ×N 角标),
  /// 单文件段保持现状平铺格。聚合在 filtered(已排序已筛选)列表上做,
  /// 排序/筛选与聚合的叠加不用特判:两向排序、格式/类型筛选天然生效
  ///(筛 RAW 时连拍段只剩 NEF 成员,如实显示)。
  /// 网格主体:按修改日期分段(共享 [groupMediaByDate],与相机相册
  /// 同款段头;多选段头点按整日勾选)。条目 = 平铺单文件格或连拍聚合
  /// 段([groupLocalBurstRuns] 的段,成段合为一格 ×N,段日期取封面
  /// mtime;跨零点连拍归封面日)。聚合在 filtered(已排序已筛选)列表
  /// 上做,排序/筛选与聚合、分段叠加不用特判。
  Widget _grid(BuildContext context, List<File> filtered) {
    final runs = _burstGrouped
        ? groupLocalBurstRuns(filtered, modifiedOf: (f) => _statOf(f).$1)
        : [
            for (final f in filtered) [f]
          ];
    return CustomScrollView(
      slivers: [
        // 时间排序才按修改日分段;文件名/文件大小排序平铺(与相机相册
        // 同逻辑,共享排序件约定)。
        if (_sort.key == MediaSortKey.time)
          for (final section in groupMediaByDate<List<File>>(
              runs, (run) => _statOf(run.first).$1)) ...[
            SliverToBoxAdapter(
              child: MediaSectionHeader(
                day: section.day,
                count: section.items.length,
                selecting: _selectMode,
                daySelected: _selectMode &&
                    section.items.every(
                        (run) => run.every((f) => _selected.contains(f.path))),
                onToggle: () => setState(() => _togglePaths({
                      for (final run in section.items)
                        for (final f in run) f.path
                    })),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              sliver: SliverGrid.builder(
                gridDelegate: _gridDelegate,
                itemCount: section.items.length,
                itemBuilder: (_, i) {
                  final run = section.items[i];
                  return _isBurstRun(run)
                      ? _burstCell(context, run)
                      : _cell(context, run.single, filtered);
                },
              ),
            ),
          ]
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            sliver: SliverGrid.builder(
              gridDelegate: _gridDelegate,
              itemCount: runs.length,
              itemBuilder: (_, i) {
                final run = runs[i];
                return _isBurstRun(run)
                    ? _burstCell(context, run)
                    : _cell(context, run.single, filtered);
              },
            ),
          ),
      ],
    );
  }

  /// 连拍段判定(显示层):段内文件数 ≥ 2 或不同基名 ≥ 2(即非全单
  /// 文件段)→ 合为一格展示。
  bool _isBurstRun(List<File> run) =>
      run.length >= 2 ||
      run.map((f) => baseNameOf(_nameOf(f))).toSet().length >= 2;

  /// 连拍段格:封面 = 段内首个 JPG(无 JPG 用段首文件,与相机侧
  /// primary = jpg ?? first 同语义);左下角标 = 格式(可选)+ ×N 恒显,
  /// 评级不显(段是多次快门)。点开查看器 peers = 段内全部文件(可翻张),
  /// 初始页 = 封面;多选中整段成员原子勾/取消(格选中 = 段内全部都在)。
  Widget _burstCell(BuildContext context, List<File> run) {
    final cover = run.firstWhere((f) => isJpgFilename(_nameOf(f)),
        orElse: () => run.first);
    final shots = run.map((f) => baseNameOf(_nameOf(f))).toSet().length;
    return MediaGridCell(
      key: ValueKey(_nameOf(cover)), // 测试/定位锚:格 = 封面文件名
      onTap: _selectMode
          ? () => _toggleFiles(run)
          : (_openable(cover) ? () => _openViewer(cover, run) : null),
      onLongPress: () => _cellLongPress(run),
      badges: [
        // 「显示」角标(左下):连拍聚合计数恒显(×N,置于格式后 ——
        // 2026-10-24 定稿);评级不显于连拍格(段是多次快门,封面档位
        // 不代表段内)。格式文案按「显示·格式」开关跟随。
        Align(
          alignment: Alignment.bottomLeft,
          child: ShowChip(
            format: _show.format
                ? mediaFormatOfFilename(_nameOf(cover))?.label
                : null,
            extra: '×$shots',
          ),
        ),
        // 视频时长(右下,原摄像机角标位)。
        if (isVideoFilename(_nameOf(cover)))
          Align(
            alignment: Alignment.bottomRight,
            child: FutureBuilder<Duration?>(
              future: _videoDurationFor(cover),
              builder: (context, snap) => DurationChip(
                  text:
                      snap.data == null ? null : formatVideoDuration(snap.data!)),
            ),
          ),
      ],
      selecting: _selectMode,
      selected: run.every((f) => _selected.contains(f.path)),
      child: _cellBody(context, cover),
    );
  }

  /// 空筛选文案:格式名片段经 t() 内嵌(模板中文拼回与原串逐字一致);
  /// 评级档筛空走专用文案(格式档不背锅)。
  String get _emptyMessage => !_formatSelection.isAll
      ? context.t('libpage.noFormatFiles', {
          'label': _formatSelection.values.map((f) => f.label).join('+'),
        })
      : context.t('libpage.noRatingFiles');

  /// 筛选弹层(共享 [FilterMenu] 卡片骨架):排序区(共享三行入口 ×
  /// 方向子面板)/ 筛选区(格式 + 评级级联子面板)/ 视图选项。多选中
  /// 弹层不可达(actions 换了),setter 仍防御性清选中(与相机相册页
  /// 换筛选清选中同规矩)。
  Widget _filterMenuAnchor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilterMenu(children: [
      // 排序区(共享,头行可折叠):时间/文件名/文件大小三行直切。
      ...sortMenuSection(
          context, _sort, _sections, () => setState(() {}), _onSort),
      menuSectionDivider,
      // 筛选区(共享,头行可折叠):格式 + 评级级联子面板(快照装载且
      // 非空后出评级;已知档位 + 删除候选,「已评级」不设行)。
      filterMenuSectionHeader(context, context.t('libpage.filter'), 'filter',
          _sections, () => setState(() {})),
      if (!_sections.isCollapsed('filter')) ...[
        ...formatFilterMenuSection(context, _formatSelection, _toggleFormat),
        if (_ratings.loaded && _ratings.hasAny)
          ...ratingFilterMenuSection(
              context, _ratingSelection, _toggleRatingFilter),
      ],
      menuSectionDivider,
      // 显示区(共享,头行可折叠):评级/格式角标按需上格。
      ...showMenuSection(context, _show, _sections, () {
        setState(() {
          _selected.clear();
        });
        unawaited(_savePrefs());
      }),
      menuSectionDivider,
      // 视图选项(头行可折叠):连拍聚合开关。
      filterMenuSectionHeader(context, context.t('libpage.viewOptions'),
          'view', _sections, () => setState(() {})),
      if (!_sections.isCollapsed('view'))
        MenuItemButton(
          style: filterMenuChildRowStyle,
          closeOnActivate: false, // 全行不收层,点外才收
          trailingIcon: _burstGrouped
              ? Icon(Icons.check, size: kMenuIconSize, color: scheme.primary)
              : null,
          onPressed: _toggleBurstGrouped,
          child: filterMenuText(context.t('libpage.groupBursts')),
        ),
    ]);
  }

  /// 级联子面板选档(共享选集件):每次选档沿清空网格选择(可见集
  /// 变化,与旧单选同规)。
  void _toggleRatingFilter(RatingFilter r) {
    setState(() {
      _ratingSelection.toggle(r);
      _selected.clear();
    });
    unawaited(_savePrefs());
  }

  /// 格式子面板选档(null = 全部):可见集变化沿清空网格选择(与评级
  /// 筛选同规)。
  void _toggleFormat(MediaFormat? f) {
    setState(() {
      f == null ? _formatSelection.clear() : _formatSelection.toggle(f);
      _selected.clear();
    });
    unawaited(_savePrefs());
  }

  /// 排序直切(共享件):点当前键翻方向,点他键切键(方向沿用);
  /// 可见集变化沿清空网格选择(与各筛选同规)。
  void _onSort(MediaSortKey key) {
    setState(() {
      if (_sort.key == key) {
        _sort.desc = !_sort.desc;
      } else {
        _sort.key = key;
      }
      _selected.clear();
    });
    unawaited(_savePrefs());
  }

  void _toggleBurstGrouped() {
    setState(() {
      _burstGrouped = !_burstGrouped;
      _selected.clear();
    });
    unawaited(_savePrefs());
  }

  Widget _transfersBadge(BuildContext context, int activeCount) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: context.t('transfers.title'),
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

  /// 可点进查看器:Flutter 可解码图片 / HIF·NEF 原生解码 / MOV 原生
  /// 抽帧(HIF 与 NEF 同走原生解码通道,iOS ImageIO / ohos image kit)。
  bool _openable(File file) {
    final name = _nameOf(file);
    return _isViewableName(name) ||
        isRawFilename(name) ||
        isHeifFilename(name) ||
        isVideoFilename(name);
  }

  /// 单文件格:手势(多选中点格勾/取消,平时点开查看器;长按进多选并
  /// 预选)包内容(见 [_cellBody])。
  Widget _cell(BuildContext context, File file, List<File> peers) {
    final stars = _ratings.ratingOf(file);
    final trash = _ratings.trashMarked(file);
    final video = isVideoFilename(_nameOf(file));
    return MediaGridCell(
      key: ValueKey(_nameOf(file)), // 测试/定位锚:格 = 文件名
      onTap: _selectMode
          ? () => _toggleFiles([file])
          : (_openable(file) ? () => _openViewer(file, peers) : null),
      onLongPress: () => _cellLongPress([file]),
      badges: [
        // 「显示」胶囊(左下):格式文案、评级图标同框;未勾选不占位。
        Align(
          alignment: Alignment.bottomLeft,
          child: ShowChip(
            format:
                _show.format ? mediaFormatOfFilename(_nameOf(file))?.label : null,
            ratingIcon: _show.rating
                ? ratingInlineIcon(stars: stars, trash: trash)
                : null,
          ),
        ),
        // 视频时长(右下,原摄像机角标位;横轴与「显示」胶囊同线)。
        if (video)
          Align(
            alignment: Alignment.bottomRight,
            child: FutureBuilder<Duration?>(
              future: _videoDurationFor(file),
              builder: (context, snap) => DurationChip(
                  text:
                      snap.data == null ? null : formatVideoDuration(snap.data!)),
            ),
          ),
      ],
      selecting: _selectMode,
      selected: _selected.contains(file.path),
      child: _cellBody(context, file),
    );
  }

  /// 格内容(可解码图片铺格 / NEF·HIF·MOV 原生缩略 / 图标格)。
  ///
  /// 可解码图双源:小档未生成读原图(cacheWidth 300,首显速度不变),
  /// 小档生成完静默换小档源(gaplessPlayback 保帧无感切换)。cache 被
  /// 系统内存警告整体清空后(2026-10-20 复报「看大图返回缩略图经常重
  /// 新刷新」),滚回的格重解的是几十 KB 小档 —— 毫秒级,无感。
  Widget _cellBody(BuildContext context, File file) {
    final viewable = _isViewable(file);
    final name = _nameOf(file);
    final raw = !viewable && isRawFilename(name);
    final heif = !viewable && isHeifFilename(name);
    final video = !viewable && isVideoFilename(name);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (viewable)
          FutureBuilder<String?>(
            future: _thumbFor(file),
            builder: (context, snap) {
              final thumb = snap.data;
              return Image.file(
                thumb != null ? File(thumb) : file,
                fit: BoxFit.cover,
                cacheWidth: 300,
                gaplessPlayback: true, // 换源(原图 → 小档)保旧帧不闪
                errorBuilder: (context, error, stackTrace) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              );
            },
          )
        else if (raw || heif || video)
          // NEF/HIF/MOV:原生解码/抽帧缩略(缓存命中/解码完成后铺图;
          // 无解码器/失败 → NEF 内嵌缩略兜底,再退图标格)。HIF 曾落
          // 三分类外的图标格支路(2026-10-24 纳入缩略管线)。
          FutureBuilder<String?>(
            future: _thumbFor(file),
            builder: (context, snap) => snap.hasData && snap.data != null
                ? Image.file(
                    File(snap.data!),
                    fit: BoxFit.cover,
                    cacheWidth: 300,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) =>
                        _iconCell(context, name),
                  )
                : _iconCell(context, name),
          )
        else
          _iconCell(context, name),
      ],
    );
  }

  /// 图标格:视频件用摄像机图标(与「视频」过滤 chips 视觉对上),
  /// 其余原生格式用文件图标 + 扩展名。
  Widget _iconCell(BuildContext context, String name) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                  ? name.substring(name.lastIndexOf('.') + 1).toUpperCase()
                  : 'FILE',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开查看器:在网格过滤序(倒序)上翻页,初始页 = 被点的格。
  /// 返回后的缩略显示不靠这里善后 —— 格走小档双源(见 [_cellBody]),
  /// cache 被系统清空后重解的也是毫秒级小档,天然无感。
  void _openViewer(File file, List<File> peers) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LibraryViewer(
          files: peers,
          initialIndex: peers.indexOf(file),
          controller: _controller,
          gallery: _gallery,
          rawDecoder: _rawDecoder,
          videoPlayer: _videoPlayer,
          thumbFor: _thumbFor,
          embeddedVideoView: widget.embeddedVideoView,
          videoLutExport: widget.videoLutExport,
        ),
      ),
    );
  }

  // ── 多选(长按格进场;底部操作栏批量删/导出)──

  void _exitSelect() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  /// 全选当前筛选序全部文件(平铺列表本就含连拍段全部成员)。
  void _selectAll(List<File> filtered) => setState(() {
        _selected
          ..clear()
          ..addAll([for (final f in filtered) f.path]);
      });

  /// 勾/取消一组路径(连拍格 = 整段原子进出;组内全在则全出,否则全进)。
  void _togglePaths(Set<String> paths) {
    if (paths.every(_selected.contains)) {
      _selected.removeAll(paths);
    } else {
      _selected.addAll(paths);
    }
  }

  void _toggleFiles(List<File> files) =>
      setState(() => _togglePaths({for (final f in files) f.path}));

  /// 长按格:进多选并按组勾(未进场时 = 进入且预选该格)。
  void _cellLongPress(List<File> files) => setState(() {
        _selectMode = true;
        _togglePaths({for (final f in files) f.path});
      });

  /// 选中集 → 实文件(从活控制器现取,陈旧路径自然忽略)。
  List<File> get _selectedFiles => _controller.appFiles
      .where((f) => _selected.contains(f.path))
      .toList(growable: false);

  /// 批量删除:确认把关(应用内文件,删了要重下;相机原件不受影响)。
  /// 对话框显示端(confirm_dialog)已包 t(),此处再包属双重包裹(无害)。
  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('libpage.deleteAppTitle'),
      content: context.t(
        'libpage.deleteBody',
        {'n': files.length},
      ),
      confirmLabel: context.t('common.delete'),
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    await _controller.deleteAppFiles(files);
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(context.t('grid.deleted', {'n': files.length}))));
    }
  }

  /// 批量导出系统相册:导入是复制不是移动(应用内文件保留);ohos 亮
  /// 保存面板,用户取消返回空列表(不报错)。
  Future<void> _exportSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) {
      return;
    }
    var imported = false;
    try {
      final uris = await _gallery.importFiles([
        for (final f in files)
          GalleryImportRequest(
            path: f.path,
            kind: kindForFilename(_nameOf(f)),
            filename: _nameOf(f),
          ),
      ]);
      imported = uris.isNotEmpty;
    } on Exception {
      imported = false;
    }
    _exitSelect();
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(imported
                ? context.t('libpage.exportedAlbum', {'n': files.length})
                : context.t('libpage.notImported'))));
    }
  }

  /// 底部操作栏(多选常驻,空选禁用按钮 —— iPhone 图库式)。
  Widget _actionBar() {
    return SafeArea(
      child: BottomAppBar(
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _selected.isEmpty ? null : _exportSelected,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(context.t('libpage.exportToAlbum')),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: context.t('libpage.deleteSelected'),
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用内文件查看(黑底,PageView 左右滑翻页):双指缩放(JPG/NEF/HIF)、
/// NEF/HIF 原生解码长边 ≤2560(会话缓存,翻回不重解)、MOV 页内播放
/// (iOS 平台视图 + Flutter 自绘播放控制,见 EmbeddedVideoPlayer,
/// 点开不自动播)。视频页可全屏(原地旋转:锁横屏 + 隐顶栏,同一播
/// 放器,无新视图无跳变)。顶栏动作(导入系统相册/删除)作用于当前
/// 页;删除后列表收缩、尾页翻回前一页。
///
/// 翻页黑闪根修(2026-10-20):邻页预解码([_LibraryViewerState
/// ._warmNeighbors],settle 即拉 i±1)+ 查看器存续期抬高解码缓存预算
/// —— 全幅 Zf JPG 解码后 ≈180MB,Flutter 默认预算(100MiB)留不住
/// 任何一张:旧版邻页上屏才开始解(解码窗里只有黑底在屏 = 黑闪),
/// 已看的页滑走即被逐出(翻回必重解,每次翻都闪)。
class _LibraryViewer extends StatefulWidget {
  const _LibraryViewer({
    required this.files,
    required this.initialIndex,
    required this.controller,
    required this.gallery,
    required this.rawDecoder,
    required this.videoPlayer,
    required this.thumbFor,
    this.embeddedVideoView,
    this.videoLutExport,
  });

  /// 网格过滤序快照(修改时间倒序);查看器内删除只改本地列表,
  /// 底层网格由控制器刷新兜底。
  final List<File> files;
  final int initialIndex;
  final TransfersController controller;
  final GallerySaver gallery;
  final RawDecoder rawDecoder;
  final VideoPlayer videoPlayer;

  /// 海报帧缓存查询(页面级管线,网格已抽过的帧直接命中)。
  final Future<String?> Function(File file) thumbFor;

  /// 测试注入(视频页内嵌视图);缺省 iOS 平台视图。
  final EmbeddedVideoViewBuilder? embeddedVideoView;

  /// 测试注入(LUT 导出宿主);缺省 MethodChannel 实现(ohos 无
  /// native,入口按 isSupported 隐藏)。
  final VideoLutExportHost? videoLutExport;

  @override
  State<_LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<_LibraryViewer> {
  late final List<File> _files = List.of(widget.files);
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  /// LUT 导出宿主与支持位:探测异步落位前不显示入口(ohos 无实现
  /// → 永 false,入口不出现)。
  late final VideoLutExportHost _videoLut =
      widget.videoLutExport ?? MethodChannelVideoLutExport();
  bool? _lutSupported;

  /// 打开时的解码缓存预算(dispose 还原):查看器语境的临时抬升,
  /// 不动全局默认。
  late final int _cacheBudgetRestore;

  @override
  void initState() {
    super.initState();
    final cache = PaintingBinding.instance.imageCache;
    _cacheBudgetRestore = cache.maximumSizeBytes;
    // 全幅 Zf JPG 解码后 ≈180MB/张,Flutter 默认预算(100MiB)装不下
    // 任何一张:页滑走即逐出,翻回必重解(翻页黑闪的另一半)。抬到
    // 512MiB 容下当前页 ± 两侧邻居,收查看器还原。
    cache.maximumSizeBytes = 512 << 20;
    _videoLut.isSupported().then((v) {
      if (mounted) setState(() => _lutSupported = v);
    });
    // 预热经 context 取 MediaQuery(precacheImage),initState 里碰不了
    // inherited:过一帧再暖。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _warmNeighbors();
    });
  }

  /// 视频全屏(原地旋转):锁横屏 + 隐顶栏。平台视图不能搬家,但查看
  /// 器自身布局可以 —— 同一 UiKitView 随 Scaffold 转横填满屏幕,零跳变
  /// (对比旧法:推新路由自建第二个播放器,装载黑闪 + 位置来回搬运)。
  bool _fullscreen = false;

  /// NEF/HIF 大图解码缓存(会话内合并:页滑出视口被 dispose 后 future
  /// 仍在,翻回不重解 —— 整档原生解码是秒级重活)。
  ///
  /// LRU 封顶 16 张:解码产物 JPEG 每张 ~1-2MB,无界驻留会在大库翻页
  /// 时把内存吃穿(16 × ~2MB ≈ 32MB 上限,即单手翻页的回看窗口);
  /// 访问即提升,超限逐最旧。键 = 文件路径(旧版同语义,不改)。
  static const _decodeCacheLimit = 16;
  final Map<String, Future<Uint8List>> _decodes = {};

  @override
  void dispose() {
    PaintingBinding.instance.imageCache.maximumSizeBytes = _cacheBudgetRestore;
    _pageController.dispose();
    if (_fullscreen) {
      // 全屏中收查看器(返回手势/删除尾页):还原方向与系统栏再走
      _setChrome(fullscreen: false);
    }
    super.dispose();
  }

  void _setFullscreen(bool on) {
    setState(() => _fullscreen = on);
    _setChrome(fullscreen: on);
  }

  void _setChrome({required bool fullscreen}) {
    // 沉浸(隐状态栏/指示条)+ 钉/放方向;ohos fork 通道缺失时静默
    // 兜住(与 remote_page 方向锁同一手法)。退出**钉回竖屏**而非交还
    // 传感器集:查看器是竖排 UI,横屏只存在于全屏视频里 —— 交还
    // [竖,横左,横右] 会在设备横放时滞留横屏(2026-10-24 真机复报)。
    SystemChrome.setEnabledSystemUIMode(
            fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge)
        .catchError((Object _) {});
    SystemChrome.setPreferredOrientations(fullscreen
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp])
        .catchError((Object _) {});
  }

  Future<Uint8List> _decodeFor(File file) {
    final key = file.path;
    final cached = _decodes.remove(key); // 先摘:重插即提升到最新端
    if (cached != null) {
      _decodes[key] = cached;
      return cached;
    }
    final fresh = widget.rawDecoder.decodeJpeg(file.path, maxPixelSize: 2560);
    _decodes[key] = fresh;
    while (_decodes.length > _decodeCacheLimit) {
      _decodes.remove(_decodes.keys.first); // LinkedHashMap 首位 = 最旧
    }
    return fresh;
  }

  /// 邻页预解码(i±1,视频跳过):滑到前把邻居解好,上屏即缓存命中
  /// —— 旧版邻页上屏才开始解码全幅 JPG,解码窗里只有黑底在屏(翻页
  /// 黑闪的根)。JPG 走 precacheImage(与页内 DeSqueezedImage 同一
  /// FileImage 缓存键);NEF/HIF 走会话解码缓存([_decodes] 天然去重)。
  /// 视频跳过:平台视图只在真滑到时装载,预建等于白装(不引
  /// allowImplicitScrolling 同因)。解码在引擎线程不占 UI;失败静默
  /// (真滑到走原路兜底)。
  void _warmNeighbors() {
    final i = _index;
    for (final j in <int>[i - 1, i + 1]) {
      if (j < 0 || j >= _files.length) continue;
      final file = _files[j];
      final name = _nameOf(file);
      if (isVideoFilename(name)) continue;
      if (isRawFilename(name) || isHeifFilename(name)) {
        unawaited(_warmNativeDecode(file));
      } else if (_isViewableName(name)) {
        // 静默收口走 onError:precache 失败(邻档被删/不可解码)走
        // FlutterError.reportError 框架错误道,不进返回 future 的错误
        // 道 —— future 侧 .catchError 接不到,widget 测试里会翻成致命
        // 红屏;onError 是官方静默口(真滑到时 FutureBuilder 原路兜)。
        unawaited(precacheImage(FileImage(file), context,
            onError: (Object _, StackTrace? __) {}));
      }
    }
  }

  /// NEF/HIF 邻页预热(吞错:catchError 对带值 Future 须回值,包装一层;
  /// 失败不拦 —— 真滑到时 FutureBuilder 原路报错)。
  Future<void> _warmNativeDecode(File file) async {
    try {
      await _decodeFor(file);
    } on Object {
      // 静默:预热尽力而为
    }
  }

  File get _current => _files[_index];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppMedia.background,
      // 全屏收顶栏:视频页撑满(同一平台视图转横),照片页无顶栏照看
      appBar: _fullscreen
          ? null
          : AppBar(
              backgroundColor: AppMedia.chrome,
              foregroundColor: AppMedia.onMedia,
              title: Text(_nameOf(_current),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: context.t('info.title'),
                  onPressed: () => _showInfo(_current),
                  icon: const Icon(Icons.info_outline),
                ),
                IconButton(
                  tooltip: context.t('libpage.importAlbum'),
                  onPressed: _importToGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                ),
                if (isVideoFilename(_nameOf(_current)) &&
                    (_lutSupported ?? false))
                  IconButton(
                    tooltip: context.t('lut.exportTitle'),
                    onPressed: _exportWithLut,
                    icon: const Icon(Icons.movie_filter_outlined),
                  ),
                IconButton(
                  tooltip: context.t('common.delete'),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _files.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          _warmNeighbors(); // 新当前页的两侧邻居提前解码(翻页不黑闪)
          // 全屏是视频语境:滑到非视频页自动退出(还原方向与顶栏)
          if (_fullscreen && !isVideoFilename(_nameOf(_files[i]))) {
            _setFullscreen(false);
          }
        },
        itemBuilder: (_, i) => _page(_files[i], active: i == _index),
      ),
    );
  }

  Widget _page(File file, {required bool active}) {
    final name = _nameOf(file);
    if (isVideoFilename(name)) {
      return widget.videoPlayer.supportsEmbeddedView
          ? EmbeddedVideoPlayer(
              path: file.path,
              active: active,
              player: widget.videoPlayer,
              viewBuilder: widget.embeddedVideoView ?? embeddedVideoViewBuilder,
              fullscreen: _fullscreen,
              onToggleFullscreen: () => _setFullscreen(!_fullscreen),
              poster: _VideoPoster(file: file, thumbFor: widget.thumbFor),
            )
          : _VideoPlayPage(
              file: file, thumbFor: widget.thumbFor, player: widget.videoPlayer);
    }
    if (isRawFilename(name) || isHeifFilename(name)) {
      // HIF 与 NEF 同走原生解码通道(≤2560,会话缓存):iOS ImageIO /
      // ohos image kit 都不吃引擎直解 HEIF 的兜底,统一走 decodeJpeg。
      return InteractiveViewer(
        maxScale: 8,
        child: Center(child: _nativeBody(file)),
      );
    }
    if (_isViewableName(name)) {
      return InteractiveViewer(
        maxScale: 8,
        child: Center(child: _imageBody(file)),
      );
    }
    // 其余格式(「全部」chips 下网格里的图标格):占位页,可滑过。
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined,
              color: AppMedia.onMediaSubtle, size: 48),
          const SizedBox(height: 8),
          Text(name,
              style:
                  const TextStyle(color: AppMedia.onMediaMuted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _imageBody(File file) => DeSqueezedImage(
        image: FileImage(file),
        deSqueeze: AppServices.instance.settingsController.value.deSqueeze,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.broken_image_outlined,
          color: AppMedia.onMediaSubtle,
          size: 48,
        ),
      );

  Widget _nativeBody(File file) => FutureBuilder<Uint8List>(
        future: _decodeFor(file),
        builder: (context, snap) {
          if (snap.hasData) {
            return DeSqueezedImage(
              image: MemoryImage(snap.data!),
              deSqueeze:
                  AppServices.instance.settingsController.value.deSqueeze,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.broken_image_outlined,
                color: AppMedia.onMediaSubtle,
                size: 48,
              ),
            );
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                context.t('libpage.decodeFailed'),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppMedia.onMediaSubtle),
              ),
            );
          }
          return const CircularProgressIndicator();
        },
      );

  /// 照片信息底单:文件级信息立显,EXIF(机身/镜头/参数/拍摄时间)本地
  /// 头读懒加载;视频无 EXIF 语义只走第一段。
  void _showInfo(File file) {
    final name = _nameOf(file);
    showPhotoInfoSheet(
      context,
      filename: name,
      sizeBytes: file.lengthSync(),
      fallbackTime: formatDateTime(file.lastModifiedSync()),
      loadExif: isVideoFilename(name) ? null : () => readExifCardFromFile(file),
    );
  }

  /// 删除当前页:列表收缩,当前页位显示下一张滑入;删的是尾页先翻回
  /// 前一页(PageView 页位越界会白屏);最后一份则收查看器再删。
  Future<void> _delete() async {
    final file = _current;
    final name = _nameOf(file);
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('libpage.deleteAppTitle'),
      content: context.t('libpage.deleteAppBody', {'name': name}),
      confirmLabel: context.t('common.delete'),
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    if (_files.length == 1) {
      Navigator.of(context).pop(); // 先关查看器再删(格位即收)
      await widget.controller.deleteAppFile(file);
      return;
    }
    final i = _index;
    if (i == _files.length - 1 && _pageController.hasClients) {
      // 删尾页:先翻回前一页,收缩后页位不越界。
      _pageController.jumpToPage(i - 1); // onPageChanged → _index = i-1
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _files.removeAt(i);
      _index = _index.clamp(0, _files.length - 1);
    });
    await widget.controller.deleteAppFile(file);
  }

  /// 补导入系统相册:文件本体保留(导入是复制不是移动);ohos 亮保存
  /// 面板,用户取消返回空列表(不报错)。
  Future<void> _importToGallery() async {
    final file = _current;
    var imported = false;
    try {
      final uris = await widget.gallery.importFiles([
        GalleryImportRequest(
          path: file.path,
          kind: kindForFilename(_nameOf(file)),
          filename: _nameOf(file),
        ),
      ]);
      imported = uris.isNotEmpty;
    } on Exception {
      imported = false;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(imported
              ? context.t('libpage.importedAlbum')
              : context.t('libpage.notImported'))));
  }

  void _toastKey(String key) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.t(key))));
  }

  /// 视频 LUT 导出:选表 → 导出 → 落库(临时档用完即删)。入口仅
  /// 视频页且平台支持(ohos 永不出现,见 initState 探测)。
  void _exportWithLut() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => LutExportSheet(
        onPick: (lut) {
          Navigator.of(context).pop();
          _runLutExport(lut);
        },
        onImportFromClipboard: () => _importLutForExport(),
      ),
    );
  }

  /// 剪贴板导入(与编辑页 LUT 面板同一解析链:XMP 标记走 RGBTable,
  /// 否则按 .cube 文本);失败留在选表上提示,成功关表转导出。
  Future<void> _importLutForExport() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) _toastKey('edit.clipboardEmpty');
      return;
    }
    final CubeLut lut;
    try {
      lut = text.contains('rdf:Description') || text.contains('xmpmeta')
          ? parseXmpRgbTable(text).toCubeLut()
          : CubeLut.parse(text);
    } on FormatException {
      if (mounted) _toastKey('lut.parseFailed');
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
    await _runLutExport(lut);
  }

  Future<void> _runLutExport(CubeLut lut) async {
    final file = _current;
    final progress = ValueNotifier<int>(0);
    // 进度对话框:barrier 不可点、取消钮走 host.cancel(导出以
    // cancelled 收场)。dialogDone 防「用户已按返回键关掉对话框」时
    // our pop 误关查看器。
    var dialogDone = false;
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('lut.exporting')),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v == 0 ? null : v / 100),
              const SizedBox(height: 8),
              Text('$v%'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _videoLut.cancel,
            child: Text(context.t('common.cancel')),
          ),
        ],
      ),
    );
    unawaited(dialogFuture.whenComplete(() => dialogDone = true));
    var toast = '';
    try {
      final out = await _videoLut.export(
        file.path,
        lut,
        onProgress: (p) => progress.value = p,
      );
      final uris = await widget.gallery.importFiles([
        GalleryImportRequest(
          path: out,
          kind: ObjectKind.video,
          filename: _lutExportName(_nameOf(file)),
        ),
      ]);
      // 落库是拷贝:临时档用完即删(失败/取消的产物 native 侧自清)。
      try {
        File(out).deleteSync();
      } on FileSystemException {
        // 删不掉不挡(cache 目录,系统会收)。
      }
      toast = uris.isNotEmpty ? 'libpage.savedToAlbum' : 'libpage.notImported';
    } on PlatformException catch (e) {
      toast = e.code == 'cancelled' ? '' : 'lut.exportFailed';
    } on Exception {
      toast = 'lut.exportFailed';
    } finally {
      if (!dialogDone && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(); // 关进度对话框
      }
      progress.dispose();
      if (toast.isNotEmpty && mounted) {
        _toastKey(toast);
      }
    }
  }

  /// 导出产物文件名:原名去扩展 + `_LUT.mp4`(导出统一 MP4 容器)。
  String _lutExportName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot <= 0 ? name : name.substring(0, dot);
    return '${base}_LUT.mp4';
  }
}

/// 视频海报帧(与网格格共用缓存,不重复抽帧):查看器未播垫底与
/// Android 全屏路(_VideoPlayPage)共用。
class _VideoPoster extends StatelessWidget {
  const _VideoPoster({required this.file, required this.thumbFor});

  final File file;

  final Future<String?> Function(File file) thumbFor;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: thumbFor(file),
      builder: (context, snap) => snap.hasData && snap.data != null
          ? Image.file(
              File(snap.data!),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// 无内嵌播放视图的平台(Android):海报帧打底 + 播放钮,点了走
/// **原生全屏播放**(`play` 通道 3bb32c5 三端补齐:Android VideoActivity /
/// ohos VideoSheet,关闭 = Future 完成)。本页留守海报供重播;失败弹
/// 提示(Android 报错道上见;ohos 已对齐 iOS 走内嵌平台视图,不经此路)。
class _VideoPlayPage extends StatefulWidget {
  const _VideoPlayPage({
    required this.file,
    required this.thumbFor,
    required this.player,
  });

  final File file;

  /// 海报帧缓存查询(与网格格共用,不重复抽帧)。
  final Future<String?> Function(File file) thumbFor;

  final VideoPlayer player;

  @override
  State<_VideoPlayPage> createState() => _VideoPlayPageState();
}

class _VideoPlayPageState extends State<_VideoPlayPage> {
  /// 播放在途(原生层收口才复位):防连点重复 play(原生 busy 拒答
  /// 会折成一次无谓的错误提示)。
  bool _playing = false;

  void _play() {
    if (_playing) return;
    // 展示时刻捕获:messenger/文案取自点按语境,不跨异步用 context。
    final messenger = ScaffoldMessenger.of(context);
    final failText = context.t('viewer.playFailed');
    setState(() => _playing = true);
    unawaited(widget.player.play(widget.file.path).whenComplete(() {
      if (mounted) setState(() => _playing = false);
    }).catchError((Object _) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failText)));
      return null;
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _VideoPoster(file: widget.file, thumbFor: widget.thumbFor),
        // 播放钮:与相机相册视频页未播态同款中键圆钮。
        Center(
          child: Material(
            color: AppMedia.onMediaDim,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _playing ? null : _play,
              child: const Padding(
                padding: EdgeInsets.all(20),
                child: Icon(Icons.play_arrow,
                    color: AppMedia.onMedia, size: 48),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

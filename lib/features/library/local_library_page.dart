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
/// 滚动供数三件(2026-10-26 快速下滑黑块根修):前瞻预取(构建锚点沿
/// 把窗外一窗 24 格的封面先拉起来,与相机相册页同款)、格首帧就绪表
/// 直显(FutureBuilder 首帧空窗不再踢全幅原图解码,见 [_knownThumbSync])、
/// ohos JPG 小档(插件放行 .jpg/.jpeg,EXIF 方向原生转正,与 iOS
/// ImageIO WithTransform 同形)。
/// 点任意可看件进黑底查看器:PageView 左右滑翻页(网格过滤序同源),
/// 图片双指缩放、NEF/HIF 原生解码长边 ≤2560(会话缓存,翻回不重解;
/// NEF 在无原生解码平台回内嵌缩略兜底可看,见 [nefEmbeddedJpeg])。视频
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
///
/// 点格进查看器走渐进放大动效(iOS 图库式,HeroZoom 航班:格缩略从格
/// 位放大展开到全屏,收查看器反向落回格位);缩略未就绪(图标格态)
/// 无动效,照旧普通转场 —— 见 common/widgets/hero_zoom.dart。
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
import '../../core/log/app_log.dart';
import '../../core/media/video_duration.dart';
import '../../core/media/xmp_rgb_table.dart' show parseXmpRgbTable;
import '../../core/ptpip/object_format.dart';
import '../../design/app_colors.dart';
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
import '../common/widgets/hero_zoom.dart';
import '../common/widgets/pull_away.dart';
import '../common/widgets/photo_info_sheet.dart';
import '../common/widgets/states.dart';
import '../common/widgets/zoomable_page.dart';
import 'library_ratings.dart';
import '../transfers/transfers_page.dart';
import 'lut_export_sheet.dart';

part 'local_library_viewer.dart';

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
        mtime(files[i]).difference(mtime(files[i - 1])).abs() <= kBurstShotGap;
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

/// 保存成功反馈:居中 ✓ 卡片,~1.6s 自动散(替代底部
/// SnackBar 的成功态;失败态仍走 SnackBar 保留可读时长)。
void _showSaveCard(BuildContext context, String text) {
  if (!context.mounted) {
    return;
  }
  BuildContext? dialogCtx;
  final scheme = Theme.of(context).colorScheme;
  showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      // 142×142 方卡,图标+短文案竖排。勿用
      // Dialog:其 minWidth 280 硬约束会架空自定义宽(真机实证)。
      return Center(
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 142,
            height: 142,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_rounded,
                      size: 46, color: scheme.onSurface),
                  const SizedBox(height: 10),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.25,
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Future.delayed(const Duration(milliseconds: 1600), () {
    final ctx = dialogCtx;
    if (ctx != null && ctx.mounted && Navigator.of(ctx).canPop()) {
      Navigator.of(ctx).pop();
    }
  });
}

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

class _LocalLibraryPageState extends State<LocalLibraryPage>
    with WidgetsBindingObserver {
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

  /// 筛选是否偏离默认。
  bool get _hasActiveFilters =>
      !_formatSelection.isAll || !_ratingSelection.isAll;

  /// 筛选或排序任一偏离默认(筛选锚钮圆点)。
  bool get _hasActiveViewOptions =>
      _hasActiveFilters || _sort.key != MediaSortKey.time || !_sort.desc;

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

  /// NEF 缩略两档制(2026-10-25 真机复报「NEF 半天加载不出来」):
  /// 小档 = 内嵌 160×120 就地装配(毫秒级,快车道不排串行链),大档 =
  /// LibRaw 512 真解码(串行链后台升级)。[_nefHiScheduled] 每键一次
  /// (成败都不重试,小档永远顶着);升级落盘沿 [_thumbUpgrades] 通知
  /// 重建,下次 build 重查换 hi 档(gapless 不闪)。
  final Set<String> _nefHiScheduled = {};
  final _ThumbUpgrades _thumbUpgrades = _ThumbUpgrades();

  /// 视频时长探测(容器 mvhd 行走,本地小读;会话内合并)。
  final Map<String, Future<Duration?>> _videoDurations = {};

  /// thumbsDir 路径(initState 沿取一次):[_knownThumbSync] 是同步
  /// 通道,路径未就位(头几帧)回 null = 原图源,与旧行为同。
  String? _thumbsDirPath;

  /// 缩略就绪路径表(内容键 → 已落盘小档路径):`_thumbFor` 完成沿
  /// 记账 + [_knownThumbSync] 探盘沿补记。格构建沿**同步**可查 ——
  /// FutureBuilder 首帧快照必无数据,没有这张表,每个新滚入的格(即便
  /// 小档早已在盘/在会话缓存)都会先踢一次全幅原图解码、微任务后才换
  /// 小档源;快速滑动 = 原图解码风暴,黑块雪上加霜。表在手,首帧直接
  /// 小档提供器(几十 KB,毫秒级),不再黑。
  final Map<String, String> _resolvedThumbs = {};

  /// 格当前显示档(文件路径 → 缩略小档路径或原图路径):渐进放大动效
  /// 在点按沿取同源图源用(见 [_cellBody] 记账、[_openViewer] 消费);
  /// build 沿记账不 setState,点按时同步可查。
  final Map<String, String> _cellShownThumbs = {};

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
    unawaited(_gallery.thumbsDir().then(
          (d) => _thumbsDirPath = d, // 小档盘路径(首帧直显通道)
          onError: (Object _) {}, // 通道缺席(壳层测试/平台缺口):留空 = 原图源
        ));
    WidgetsBinding.instance.addObserver(this); // 后台返回沿重预热
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 退后台期间系统内存告警会整体清 imageCache(2026-10-20 既有账:
  /// 「看大图返回缩略重刷新」同源),回前台猛滑 = 解码全部重来;而
  /// 会话去重(_prefetchSent)仍挡着预取重发 → 黑格复现(2026-10-26
  /// 真机复报)。resume 沿清去重 + 当前锚点窗(可视±窗)整段重拉:
  /// 没被清的预热命中 imageCache 秒回(空转),被清的重解 —— 首开同待遇。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _rewarmAfterResume();
    }
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
            if ((v['lib.ratings'] as List<Object?>?)?.contains(r.index) ??
                false)
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

  /// 负缓存(带 TTL):HIF 解码失败(容器无 HEIF)驻留 10s,过期后格子
  /// 重建时重试一次 —— 伴生预览在传输完成沿才补写,补写后的首次重建即
  /// 命中;TTL 内返回同一失败 future(可沉降,不无限重试,2026-10-25
  /// 无限重试 churn 撞 pumpAndSettle 超时的教训)。
  static const _negThumbTtl = Duration(seconds: 10);
  final Map<String, DateTime> _negThumbAt = {};

  /// 缩略小档路径(磁盘缓存命中即回;否则排队解码/抽帧)。可解码图
  /// (JPG/PNG)与 NEF/MOV 同管线:格双源之一与查看器海报帧共用,
  /// 不重复解码。
  Future<String?> _thumbFor(File file) {
    final key = _contentKey(file);
    final existing = _mediaThumbs[key];
    if (existing != null) {
      final failedAt = _negThumbAt[key];
      if (failedAt == null ||
          DateTime.now().difference(failedAt) < _negThumbTtl) {
        return existing;
      }
      _mediaThumbs.remove(key); // 负缓存过期:重建沿重试一次
      _negThumbAt.remove(key);
    }
    return _mediaThumbs.putIfAbsent(key, () {
      final name = _nameOf(file);
      // NEF 快车道:内嵌缩略就地装配(毫秒级双小读),不排串行链 ——
      // 链上视频抽帧/LibRaw 各是秒级重活,NEF 排队尾 = 图标格挂半天;
      // LibRaw 真解码降级为后台升级档(见 [_scheduleNefHi])。
      final isNef = isRawFilename(name) && !isVideoFilename(name);
      final future = isNef
          ? _decodeNefThumb(file, key)
          : _thumbQueue.then((_) => _decodeThumb(file, key));
      if (!isNef) {
        _thumbQueue = future;
      }
      unawaited(future.then((path) {
        if (path == null) {
          _negThumbAt[key] = DateTime.now();
        } else {
          _resolvedThumbs[key] = path; // 就绪记账:格重建首帧同步直取
        }
      }));
      return future;
    });
  }

  /// 格首帧小档路径(同步解析,build 热路径直用):优先就绪表
  /// ([_resolvedThumbs],命中再验一次存在 —— cache 盘被系统回收时自动
  /// 出表),未记过才探盘上双档(libv5hi_ 优先,与 [_decodeNefThumb] 的
  /// 「hi 优先」同口径),探中回填就绪表。全 miss 回 null = 原图源
  /// (首显原图是既有行为,小档生成完 gapless 换档)。
  ///
  /// 有了它,FutureBuilder 首帧快照必无数据的空窗不再踢全幅原图解码
  /// —— 快速滑动黑块根之一。成本 = 每格 1-3 次 stat(µs 级,与既有
  /// _contentKey 的 lengthSync 同量级),不摸像素。
  String? _knownThumbSync(File file) {
    final dir = _thumbsDirPath;
    if (dir == null) return null;
    final key = _contentKey(file);
    final known = _resolvedThumbs[key];
    if (known != null) {
      if (File(known).existsSync()) return known;
      _resolvedThumbs.remove(key); // 盘档被回收:出表,重探双档
    }
    final hi = File('$dir/libv5hi_$key.jpg');
    if (hi.existsSync()) {
      return _resolvedThumbs[key] = hi.path;
    }
    final small = File('$dir/libv5_$key.jpg');
    if (small.existsSync()) {
      return _resolvedThumbs[key] = small.path;
    }
    return null;
  }

  /// NEF 网格缩略快车道:内嵌 160×120 缩略就地装配(IFD0 头读 + 缩略
  /// 段读两次小 IO,毫秒级)→ 落 libv5_ 小档上格,顺手排 LibRaw 升级
  /// 档;无内嵌缩略(异常头/截断件)才排队走旧链(LibRaw 512 → 内嵌
  /// 兜底)。返回值永不抛(失败回 null 交负缓存,不毒化串行链)。
  Future<String?> _decodeNefThumb(File file, String key) async {
    try {
      final dir = await _gallery.thumbsDir();
      final hi = File('$dir/libv5hi_$key.jpg');
      if (hi.existsSync()) return hi.path; // 升级档已就位:直给
      final small = File('$dir/libv5_$key.jpg');
      if (small.existsSync()) {
        _scheduleNefHi(file, key, dir); // 旧会话小档:补排升级
        return small.path;
      }
      final embedded = await extractNefEmbeddedThumb(file.path);
      if (embedded != null) {
        final oriented =
            injectJpegOrientation(embedded.jpeg, embedded.orientation);
        final jpeg = await trimLetterboxJpeg(oriented) ?? oriented;
        // 同步写、**不 fsync**:缩略档可再生,flush:true 每次 fsync 是
        // 冷缓存填格时的主要磁盘抖动;同步写保住 widget 测试的确定时钟
        // (异步写要 runAsync 排水,既有用例按同步语义写)。
        small.writeAsBytesSync(jpeg);
        _scheduleNefHi(file, key, dir);
        return small.path;
      }
      // 无内嵌缩略:排队走旧链(LibRaw 512 → 内嵌兜底)。快车道不在
      // 链上,回落须自己接尾巴,否则多个 NEF 同拍会并发解码挤内存。
      final job = _thumbQueue.then((_) => _decodeThumb(file, key));
      _thumbQueue = job;
      return await job;
    } on Object {
      return null;
    }
  }

  /// NEF 升级档排程(每键本会话一次):串行链上 LibRaw 512 真解码 →
  /// libv5hi_ 落盘 → 记忆表出键 + 通知重建(下次 build 缓存命中换 hi
  /// 档)。失败静默:内嵌小档继续顶着,不重试。链尾吞错(队列消费者
  /// 依赖链不抛)。
  void _scheduleNefHi(File file, String key, String dir) {
    if (_nefHiScheduled.contains(key)) return;
    _nefHiScheduled.add(key);
    _thumbQueue = _thumbQueue.then((_) => _decodeNefHi(file, key, dir));
  }

  /// 升级档解码落盘(串行链工作单元):成功出键 + 通知;任何失败静默。
  Future<String?> _decodeNefHi(File file, String key, String dir) async {
    try {
      final jpeg = await _rawDecoder.decodeJpeg(file.path, maxPixelSize: 512);
      final trimmed = await trimLetterboxJpeg(jpeg) ?? jpeg;
      await File('$dir/libv5hi_$key.jpg').writeAsBytes(trimmed, flush: true);
      unawaited(_mediaThumbs.remove(key));
      _negThumbAt.remove(key);
      _thumbUpgrades.fire();
    } on Object {
      // 升级失败:内嵌小档顶着(本会话不再试)
    }
    return null;
  }

  Future<String?> _decodeThumb(File file, String key) async {
    final name = _nameOf(file);
    try {
      final dir = await _gallery.thumbsDir();
      final cache = File(
          '$dir/libv5_$key.jpg'); // 键全量升版:NEF 缩略 LibRaw 真解码(旧 libv3_ 是内嵌缩略糊图)
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
        // 内存友好);ohos = image kit 接 HIF + JPG(2026-10-26 放行
        // .jpg/.jpeg,EXIF 方向插件侧转正,与 iOS 同形;NEF 等真 RAW
        // 仍走 LibRaw 通道,见 RawDecodePlugin 文件头)。通道
        // 缺失/拒绝/失败:NEF 回内嵌 160×120 缩略兜底(裸 JPEG 无
        // EXIF,注入方向引擎解码即转正,与相机相册 GetThumb 同源),
        // 其余回落 null → 格走原图源(双源 gapless),不毒化串行链。
        try {
          jpeg = await _rawDecoder.decodeJpeg(file.path, maxPixelSize: 512);
        } on Object catch (e) {
          // 通道缺失/拒绝/失败:落一条诊断(ohos JPG 首接期的排障唯一
          // 观测面,与下方 HIF 伴生预览诊断同位);NEF 回内嵌 160×120
          // 缩略兜底(裸 JPEG 无 EXIF,注入方向引擎解码即转正,与相机
          // 相册 GetThumb 同源),其余回落 null → 格走原图源(双源
          // gapless),不毒化串行链。
          AppLog.w(AppLog.browser, '网格小档解码失败 $name: $e');
          final embedded = isRawFilename(name)
              ? await extractNefEmbeddedThumb(file.path)
              : null;
          if (embedded == null) {
            // HIF:伴生预览诊断(键位/在否),容器排障唯一观测面。
            if (isHeifFilename(name)) {
              final companion = File('$dir/libv5_$key.jpg');
              AppLog.w(AppLog.browser,
                  'HIF 缩略解码失败:${companion.path} exists=${companion.existsSync()}');
            }
            return null;
          }
          jpeg = injectJpegOrientation(embedded.jpeg, embedded.orientation);
        }
      }
      // 信箱黑边裁剪只对固定画布预览(NEF/HIF/视频);普通 JPG 的
      // 黑边是画面内容,裁了会让缩略图与原图不同比、进查看器回缩。
      final needsTrim =
          isVideoFilename(name) || isRawFilename(name) || isHeifFilename(name);
      final trimmed = needsTrim ? await trimLetterboxJpeg(jpeg) : null;
      cache.writeAsBytesSync(trimmed ?? jpeg); // 同上:可再生档不 fsync
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
      listenable: Listenable.merge([_controller, _ratings, _thumbUpgrades]),
      builder: (context, _) {
        // 排序/筛选结果按（源表 + 排序 + 选集 + 评级版本）缓存:传输期
        // 本页 10Hz 重建,而 appFiles 与筛选条件往往几秒才变一次 ——
        // 旧实现每个 tick 都整表重排 + 重筛。stat 走 _statOf 缓存。
        final files = _derivedFiles();
        final filtered = _derivedFiltered(files);
        return Scaffold(
          appBar: AppBar(
            // 二十轮:标题左对齐(iOS 默认居中)——与相机页左上「相机」
            // 标签同槽(左 16px)。centerTitle false 无 leading 时标题从
            // 默认 titleSpacing(24)起,须显式收窄。(设置页三十轮起
            // 唯一显式居中;二十九轮全局居中误扩当日收回。)
            centerTitle: true,
            title: Text(
                _selectMode
                    ? context.t('grid.selectedCount', {'n': _selected.length})
                    : context.t('shell.gallery'),
                // 2026-10-30:顶栏标题与相机页「相机」同字号
                // (titleLarge),三 tab 统一。
                style: Theme.of(context).textTheme.titleLarge),
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
  // 评级查表用 _statOf 已缓存的字节数(免每文件每次重建两次同步 stat)。
  List<File> _filtered(List<File> files) => files
      .where((f) {
        if (!_formatSelection
            .allows(mediaFormatOfFilename(_nameOf(f)))) {
          return false;
        }
        final bytes = _statOf(f).$2;
        return _ratingSelection.allows(
          rating: _ratings.ratingOf(f, bytes: bytes),
          trashStar: _ratings.trashMarked(f, bytes: bytes),
          available: _ratings.loaded,
        );
      })
      .toList(growable: false);

  // ── 派生列表缓存(源表 identity + 排序 + 选集 + 评级版本)──
  List<File>? _derivedFilesCache;
  List<File>? _derivedFilteredCache;
  Object? _derivedKey;

  /// 当前派生键(轻量:选集只拼几个短串)。
  Object _deriveKey(List<File> source) => (
        identityHashCode(source),
        _sort.key,
        _sort.desc,
        _formatSelection.values.map((f) => f.name).join(','),
        _ratingSelection.values.map((r) => r.index).join(','),
        _ratings.revision,
        _ratings.loaded,
      );

  List<File> _derivedFiles() {
    final source = _controller.appFiles;
    final key = _deriveKey(source);
    final cached = _derivedFilesCache;
    if (cached != null && _derivedKey == key) return cached;
    final sorted = sortMedia(List<File>.of(source), _sort,
        (f) => (_statOf(f).$1, _nameOf(f), _statOf(f).$2));
    _derivedKey = key;
    _derivedFilesCache = sorted;
    _derivedFilteredCache = _filtered(sorted);
    return sorted;
  }

  List<File> _derivedFiltered(List<File> files) {
    final cached = _derivedFilteredCache;
    if (cached != null && identical(files, _derivedFilesCache)) {
      return cached;
    }
    final filtered = _filtered(files);
    _derivedFilteredCache = filtered;
    return filtered;
  }

  /// 网格主体:平铺(现状)或连拍聚合。「连拍」开时条目 =
  /// [groupLocalBurstRuns] 的段 —— 成段合为一格(封面 + ×N 角标),
  /// 单文件段保持现状平铺格。聚合在 filtered(已排序已筛选)列表上做,
  /// 排序/筛选与聚合的叠加不用特判:两向排序、格式/类型筛选天然生效
  ///(筛 RAW 时连拍段只剩 NEF 成员,如实显示)。
  // ── 前瞻预取(与相机相册页同款锚点机制,数据源 = 图库 runs)──

  /// 构建沿记最深/最浅全局 run 序号,新锚点沿把窗外一窗(24 格)的封面
  /// 缩略先拉起来 —— 滚到即现,不再「滚到才排队」。post-frame 批量发起
  ///(本帧可视格的请求随 build 先入串行队列,预取不插队);已发过的
  /// path 记账去重(重建/锚点回退不重发;失败重试走格内 `_thumbFor` 的
  /// 负缓存 TTL 通道)。runs 换实例(刷新/排序/筛选/聚合开关)重置锚点
  ///(_prefetchSent 不清 —— 文件还在,缩略 future 也还在,重发是空转)。
  static const _prefetchWindow = 24;
  int _builtMaxRun = -1;
  int _builtMinRun = 1 << 30;
  List<List<File>>? _prefetchRuns;
  final Set<String> _prefetchSent = {};

  void _resetPrefetchAnchors(List<List<File>> runs) {
    if (identical(runs, _prefetchRuns)) return;
    _prefetchRuns = runs;
    _builtMaxRun = -1;
    _builtMinRun = 1 << 30;
  }

  void _noteBuilt(int index, List<List<File>> runs) {
    final newMax = index > _builtMaxRun;
    final newMin = index < _builtMinRun;
    if (!newMax && !newMin) return;
    if (newMax) _builtMaxRun = index;
    if (newMin) _builtMinRun = index;
    final targets = <File>[];
    void window(int lo, int hi) {
      for (var i = lo; i <= hi && i < runs.length; i++) {
        if (i < 0) continue;
        final cover = _coverOf(runs[i]);
        if (_prefetchSent.add(cover.path)) {
          targets.add(cover);
        }
      }
    }

    if (newMax) window(index + 1, index + _prefetchWindow);
    if (newMin) window(index - _prefetchWindow, index - 1);
    _issuePrefetch(targets);
  }

  /// 预取窗批量发起(post-frame;空目标静默):缩略文件预热 + 解码缓存
  /// 预热(与格内同一提供器 → 同一缓存键,命中即不重复解码)。已知小档
  /// 直预热小档;未知的先预热原图源(原就是格首显源,提前 = 首过不再
  /// 黑),小档落地后补预热。缺了这层,首次猛滑的格滚走了解码才落地,
  /// 只能回滚才秒出(「第一遍黑、后续不黑」的真身);预热后首过即有图,
  /// Apple 图库同级。[evictStale] = resume 重预热档(见
  /// [_rewarmAfterResume]):先清键再预热。
  void _issuePrefetch(List<File> targets, {bool evictStale = false}) {
    if (targets.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final f in targets) {
        final future = _thumbFor(f);
        final known = _knownThumbSync(f);
        if (known != null) {
          _precacheGridThumb(known, evictStale: evictStale);
        } else {
          _precacheGridThumb(f.path, evictStale: evictStale);
          unawaited(future.then((path) {
            if (path != null && mounted) {
              _precacheGridThumb(path, evictStale: evictStale);
            }
          }));
        }
      }
    });
  }

  /// 后台返回沿重预热(见 didChangeAppLifecycleState):清会话去重,
  /// 按当前锚点把可视±窗整段重收(_rewarm 窗含可视格自身,与
  /// [_noteBuilt] 只收窗外不同 —— 可视格的缓存同样可能被清),并带
  /// [evictStale] 清键重预热。
  void _rewarmAfterResume() {
    _prefetchSent.clear();
    final runs = _prefetchRuns;
    if (runs == null || runs.isEmpty) return;
    final lo = (_builtMinRun - _prefetchWindow).clamp(0, runs.length - 1);
    final hi = (_builtMaxRun + _prefetchWindow).clamp(0, runs.length - 1);
    if (lo > hi) return;
    final targets = <File>[];
    for (var i = lo; i <= hi; i++) {
      final cover = _coverOf(runs[i]);
      if (_prefetchSent.add(cover.path)) {
        targets.add(cover);
      }
    }
    _issuePrefetch(targets, evictStale: true);
  }

  /// 解码缓存预热(静默口:precache 失败走 onError 官方静默道,不进
  /// future 错误道 —— 与查看器 _warmNeighbors 同款,测试假 JPEG 不外冒)。
  ///
  /// [evictStale](resume 重预热档):先 `imageCache.evict`(含 live 跟踪)
  /// 再预热。后台清缓存后,首过预热留下的 live 跟踪条目可能仍在(其
  /// 清理回调依赖监听器清零,precache 的监听器由框架 post-frame 摘除,
  /// 实测不清零)—— putIfAbsent 走 live 分支返回陈旧 completer,而该
  /// 分支的 _touch 因 sizeBytes 缺失不回插,预热永远落不了缓存(真机
  /// 「后台返回再滑仍黑格」的最后一环)。evict 强制 fresh loader 重解。
  void _precacheGridThumb(String path, {bool evictStale = false}) {
    final provider = gridThumbImageProvider(path);
    if (evictStale) {
      unawaited(provider.obtainKey(ImageConfiguration.empty).then((key) {
        PaintingBinding.instance.imageCache.evict(key);
      }).then((_) {
        if (!mounted) return;
        unawaited(precacheImage(provider, context,
            onError: (Object _, StackTrace? __) {}));
      }));
      return;
    }
    unawaited(precacheImage(provider, context,
        onError: (Object _, StackTrace? __) {}));
  }

  /// 连拍段封面(段内首个 JPG,无 JPG 用段首):预取与 [_burstCell]
  /// 显示同一文件,不打错工。
  File _coverOf(List<File> run) => run.firstWhere(
        (f) => isJpgFilename(_nameOf(f)),
        orElse: () => run.first,
      );

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
    _resetPrefetchAnchors(runs); // runs 换实例沿 = 预取锚点重置沿
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
                  // 构建沿 = 预取锚点沿(全局序 = 段首全局下标 + 段内位)。
                  _noteBuilt(section.firstIndex + i, runs);
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
                _noteBuilt(i, runs); // 构建沿 = 预取锚点沿
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
    final cover = _coverOf(run);
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
                  text: snap.data == null
                      ? null
                      : formatVideoDuration(snap.data!)),
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
    return FilterMenu(active: _hasActiveViewOptions, children: [
      // 排序区(共享,头行可折叠):时间/文件名/文件大小三行直切。
      ...sortMenuSection(
          context, _sort, _sections, () => setState(() {}), _onSort),
      menuSectionDivider,
      // 筛选区(共享,头行可折叠):格式 + 评级级联子面板。评级入口始终
      // 保留(空库也能筛「无评级」),数据就绪后筛选结果随快照刷新。
      filterMenuSectionHeader(context, context.t('libpage.filter'), 'filter',
          _sections, () => setState(() {})),
      if (!_sections.isCollapsed('filter')) ...[
        ...formatFilterMenuSection(context, _formatSelection, _toggleFormat),
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
      filterMenuSectionHeader(context, context.t('libpage.viewOptions'), 'view',
          _sections, () => setState(() {})),
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
            format: _show.format
                ? mediaFormatOfFilename(_nameOf(file))?.label
                : null,
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
                  text: snap.data == null
                      ? null
                      : formatVideoDuration(snap.data!)),
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
  ///
  /// 图像格包渐进放大动效锚([HeroZoom],tag 按文件路径与查看器初始页
  /// 配对,见 [_openViewer]);图标格态(缩略未就绪/未知格式)不挂
  /// —— 配对不成无航班,推入照旧普通转场。图像用共享提供器构造
  /// ([gridThumbImageProvider]),航班梭子命中同一份已解码缓存。
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
              // 显档记账(点按沿同步可查,动效图源与格同源;小档未生成
              // 显原图)。真缩略上格后小档可能再被 LRU 驱逐,以最近记账
              // 为准,解码失败沿 errorBuilder 自见。取值链 ② =
              // [_knownThumbSync] 同步通道:FutureBuilder 首帧快照必无
              // 数据,表命中即小档直显,不再踢全幅原图解码(快速滑动
              // 黑块根之一);future 落地同路径 → 同 provider 零闪。
              final shown = snap.data ?? _knownThumbSync(file) ?? file.path;
              _recordShownThumb(file, shown);
              return HeroZoom(
                tag: 'lib-grid-${file.path}',
                thumbPath: shown,
                child: Image(
                  image: gridThumbImageProvider(shown),
                  fit: BoxFit.cover,
                  gaplessPlayback: true, // 换源(原图 → 小档)保旧帧不闪
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child:
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              );
            },
          )
        else if (raw || heif || video)
          // NEF/HIF/MOV:原生解码/抽帧缩略(缓存命中/解码完成后铺图;
          // 无解码器/失败 → NEF 内嵌缩略兜底,再退图标格)。HIF 曾落
          // 三分类外的图标格支路(2026-10-24 纳入缩略管线)。显档记账
          // 与 viewable 分支同规(点按沿取同源图源挂动效)。
          FutureBuilder<String?>(
            future: _thumbFor(file),
            builder: (context, snap) {
              // 快照未到先查就绪表(同 viewable 分支):NEF 升级档换档
              // 重建沿(_mediaThumbs 出键 → 新 future)不再闪图标格。
              final known = snap.data ?? _knownThumbSync(file);
              if (known == null) {
                return _iconCell(context, name);
              }
              _recordShownThumb(file, known);
              return HeroZoom(
                tag: 'lib-grid-${file.path}',
                thumbPath: known,
                child: Image(
                  image: gridThumbImageProvider(known),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      _iconCell(context, name),
                ),
              );
            },
          )
        else
          _iconCell(context, name),
      ],
    );
  }

  /// NEF/HIF/MOV 缩略上格沿的显档记账(viewable 分支同规):点按沿
  /// [_openViewer] 取同源图源挂动效 —— 漏记则四类格式全部退化为普通
  /// 转场(真机复报「MOV/HIF/MP4/NEF 都没实现」的根因)。
  void _recordShownThumb(File file, String thumbPath) {
    _cellShownThumbs[file.path] = thumbPath;
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
  ///
  /// 渐进放大动效:格当前显示档已记账才挂配对件(图源 = 该档 300px
  /// 提供器,与格内解码缓存同键);图标格态(缩略未就绪)降级普通转场。
  void _openViewer(File file, List<File> peers) {
    final shown = _cellShownThumbs[file.path];
    // ZoomPageRoute:整页淡入 + 网格原地不动(动效底图),与 Hero 航班
    // 同拍 —— 系统 zoom 转场的缩退/快隐会与飞行图打架(原生图库缩放里
    // 网格不动)。
    Navigator.of(context).push(
      ZoomPageRoute<void>(
        pageBuilder: (_, __, ___) => _LibraryViewer(
          files: peers,
          initialIndex: peers.indexOf(file),
          controller: _controller,
          gallery: _gallery,
          rawDecoder: _rawDecoder,
          videoPlayer: _videoPlayer,
          thumbFor: _thumbFor,
          embeddedVideoView: widget.embeddedVideoView,
          videoLutExport: widget.videoLutExport,
          heroTag: shown == null ? null : 'lib-grid-${file.path}',
          heroThumbPath: shown,
          heroImage: shown == null ? null : gridThumbImageProvider(shown),
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
      if (imported) {
        _showSaveCard(context, context.t('libpage.exportedAlbum'));
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text(context.t('libpage.notImported'))));
      }
    }
  }

  /// 批量分享:交给系统分享面板(native 授权读);失败只提示,不改选择。
  Future<void> _shareSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) {
      return;
    }
    final host = _gallery;
    if (host is! ShareHost) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(context.t('common.shareFailed'))));
      return;
    }
    try {
      await (host as ShareHost).shareFiles([for (final f in files) f.path]);
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(context.t('common.shareFailed'))));
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
              tooltip: context.t('libpage.shareSelected'),
              onPressed: _selected.isEmpty ? null : _shareSelected,
              icon: const Icon(Icons.share_outlined),
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

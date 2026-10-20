/// 图库页(底部导航 tab):「下载到应用」的文件网格(downloadsDir 直读,
/// TransfersController 的 appFiles 数据源)。**不含**已导入系统相册的
/// 文件 —— 那些归系统相册 App 管,这里只看应用自留的份。
///
/// 网格默认按修改时间倒序(新下载在前,弹层可翻「旧→新」);筛选收进
/// AppBar 右上弹层(排序单行「时间+方向箭头」点按翻向 × 格式
/// 全部/RAW/JPG/视频 × 视图选项 连拍聚合开关,内存态不落库,与旧 chips
/// 同先例)。「连拍聚合」
/// 开时相邻拍摄时刻的同段文件合为一格(×N 角标,与相机相册连拍簇同参,
/// 见 [groupLocalBurstRuns];mtime = 拍摄时刻由下载引擎落盘回写)。
/// Flutter 可解码的图片直接铺格(cacheWidth 限内存);NEF 走原生解码、
/// MOV 走原生抽帧出网格缩略(iOS ImageIO / AVAssetImageGenerator,
/// ≤512px 同一管线落盘缓存,MOV 格内叠摄像机角标;无解码器/无抽帧/
/// 失败回落图标格)。点任意可看件进黑底查看器:PageView 左右滑翻页
/// (网格过滤序同源),图片双指缩放、NEF 原生解码长边 ≤2560(会话
/// 缓存,翻回不重解)。视频在页面内直接播放(2026-10-09:点开即播,
/// 不再「海报帧 + 播放钮 + 弹全屏新页」三步走;iOS 平台视图嵌
/// AVPlayerViewController,播放控制在 Flutter 侧自绘 —— 原生传输条
/// 关掉,横滑才归 PageView 翻页不抢手势;高帧率素材浮「24fps 顺帧」
/// 开关,非阻塞点了才变速静音;Android/ohos 通道待补回落海报帧 +
/// 说明文案)。查看器可删除/把文件补导入系统相册。
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
import '../../core/browser/photo_group.dart';
import '../../core/media/cube_lut.dart';
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
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/de_squeezed_image.dart';
import '../common/widgets/embedded_video_player.dart';
import '../common/widgets/photo_info_sheet.dart';
import '../common/widgets/states.dart';
import '../transfers/transfers_page.dart';
import 'lut_export_sheet.dart';

/// 图库格式过滤:按扩展名分流,与相机侧条目判定同源。
/// label = t() 键(RAW/JPG 走短格式键,值两侧同拉丁),显示点包 t()。
enum _LibFilter {
  all('libpage.all'),
  raw('fmt.shortRaw'),
  jpg('fmt.shortJpg'),
  video('common.video');

  const _LibFilter(this.label);

  final String label;

  bool allows(String filename) => switch (this) {
        all => true,
        raw => isRawFilename(filename),
        jpg => isJpgFilename(filename),
        video => isVideoFilename(filename),
      };
}

/// 图库排序:时间两向(新→旧 = 既有默认,下载的新货在前)。评分档
/// 不做 —— 本地评分键挂相机侧照片组(基名+组总字节),应用内文件
/// 没有现成评分数据源,不发明。方向不落词表:弹层只有单行「时间」,
/// 方向由行尾箭头表达(↓ = 大→小 = 新→旧,↑ = 小→大 = 旧→新)。
enum _LibSort {
  newestFirst,
  oldestFirst,
}

/// Flutter 可解码的图片扩展名(NEF 等原生格式走解码管线)。
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
List<List<File>> groupLocalBurstRuns(List<File> files) {
  final out = <List<File>>[];
  var start = 0;
  for (var i = 1; i <= files.length; i++) {
    final inGap = i < files.length &&
        files[i]
                .statSync()
                .modified
                .difference(files[i - 1].statSync().modified)
                .abs() <=
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

/// 网格布局(4 列,紧凑间距)。
const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 4,
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
  });

  /// 测试注入;缺省用 AppServices 单例(应用级共享,本页不持有)。
  final TransfersController? controller;

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

  _LibFilter _filter = _LibFilter.all;
  _LibSort _sort = _LibSort.newestFirst;

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

  @override
  void initState() {
    super.initState();
    _controller.refreshAppFiles();
  }

  bool _isViewable(File file) => _isViewableName(_nameOf(file));

  /// NEF/MOV 缩略路径(磁盘缓存命中即回;否则排队解码/抽帧)。
  /// 网格格与查看器海报帧共用此缓存,不重复抽帧。
  Future<String?> _thumbFor(File file) {
    final key = _contentKey(file);
    return _mediaThumbs.putIfAbsent(key, () {
      _thumbQueue = _thumbQueue.then((_) => _decodeThumb(file, key));
      return _thumbQueue;
    });
  }

  Future<String?> _decodeThumb(File file, String key) async {
    try {
      final dir = await _gallery.thumbsDir();
      final cache = File('$dir/lib_$key.jpg'); // lib_ 前缀避开相机缩略键
      if (cache.existsSync()) return cache.path;
      final name = _nameOf(file);
      final Uint8List jpeg;
      if (isRawFilename(name)) {
        jpeg = await _rawDecoder.decodeJpeg(file.path, maxPixelSize: 512);
      } else {
        jpeg = await _videoPlayer.thumbnail(file.path, maxPixelSize: 512);
      }
      cache.writeAsBytesSync(jpeg, flush: true);
      return cache.path;
    } on Exception {
      return null; // 无解码器/抽帧/失败:图标格(吞掉,不毒化串行链)
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
      listenable: _controller,
      builder: (context, _) {
        // 修改时间排序:默认新在前(新下载的先看),「旧→新」翻向。
        final newestFirst = _sort == _LibSort.newestFirst;
        final files = List<File>.of(_controller.appFiles)
          ..sort((a, b) => newestFirst
              ? b.statSync().modified.compareTo(a.statSync().modified)
              : a.statSync().modified.compareTo(b.statSync().modified));
        final activeCount =
            _controller.tasks.where((t) => !t.isTerminal).length;
        final filtered = _filtered(files);
        return Scaffold(
          appBar: AppBar(
            // 二十轮:标题左对齐(iOS 默认居中)——与相机页左上「相机」
            // 标签同槽(左 16px),三 tab 顶部左位一致。centerTitle false
            // 无 leading 时标题从默认 titleSpacing(24)起,须显式收窄。
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
          body: files.isEmpty
              ? EmptyState(
                  icon: Icons.download_outlined,
                  // EmptyState 显示端已包 t(),此处再包属双重包裹(无害)
                  message: context.t('libpage.empty'),
                )
              : filtered.isEmpty
                  ? Center(
                      child: Text(_emptyMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context).hintColor)),
                    )
                  : _grid(context, filtered),
          bottomSheet: _selectMode ? _actionBar() : null,
        );
      },
    );
  }

  // 格式筛子按扩展名收窄(筛选弹层唯一滤网)。
  List<File> _filtered(List<File> files) => files
      .where((f) => _filter.allows(_nameOf(f)))
      .toList(growable: false);

  /// 网格主体:平铺(现状)或连拍聚合。「连拍」开时条目 =
  /// [groupLocalBurstRuns] 的段 —— 成段合为一格(封面 + ×N 角标),
  /// 单文件段保持现状平铺格。聚合在 filtered(已排序已筛选)列表上做,
  /// 排序/筛选与聚合的叠加不用特判:两向排序、格式/类型筛选天然生效
  ///(筛 RAW 时连拍段只剩 NEF 成员,如实显示)。
  Widget _grid(BuildContext context, List<File> filtered) {
    if (!_burstGrouped) {
      return GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: _gridDelegate,
        itemCount: filtered.length,
        itemBuilder: (_, i) => _cell(context, filtered[i], filtered),
      );
    }
    final runs = groupLocalBurstRuns(filtered);
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: _gridDelegate,
      itemCount: runs.length,
      itemBuilder: (_, i) {
        final run = runs[i];
        return _isBurstRun(run)
            ? _burstCell(context, run)
            : _cell(context, run.single, filtered);
      },
    );
  }

  /// 连拍段判定(显示层):段内文件数 ≥ 2 或不同基名 ≥ 2(即非全单
  /// 文件段)→ 合为一格展示。
  bool _isBurstRun(List<File> run) =>
      run.length >= 2 ||
      run.map((f) => baseNameOf(_nameOf(f))).toSet().length >= 2;

  /// 连拍段格:封面 = 段内首个 JPG(无 JPG 用段首文件,与相机侧
  /// primary = jpg ?? first 同语义);左下 ×N 角标(N = 段内不同基名
  /// 数,即张数)。点开查看器 peers = 段内全部文件(可翻张),初始页
  /// = 封面;多选中整段成员原子勾/取消(格选中 = 段内全部都在)。
  Widget _burstCell(BuildContext context, List<File> run) {
    final cover = run.firstWhere((f) => isJpgFilename(_nameOf(f)),
        orElse: () => run.first);
    final shots = run.map((f) => baseNameOf(_nameOf(f))).toSet().length;
    return GestureDetector(
      key: ValueKey(_nameOf(cover)), // 测试/定位锚:格 = 封面文件名
      onTap: _selectMode
          ? () => _toggleFiles(run)
          : (_openable(cover) ? () => _openViewer(cover, run) : null),
      onLongPress: () => _cellLongPress(run),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _cellBody(context, cover),
          // ×N 角标(左下,半透明黑底白字小胶囊 —— 与相机相册网格
          // typeLabel 角标、本页视频格 videocam 角标同一写法)。
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '×$shots',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
          if (_selectMode) ..._selectOverlay(
              run.every((f) => _selected.contains(f.path))),
        ],
      ),
    );
  }

  /// 空筛选文案:格式名片段经 t() 内嵌(模板中文拼回与原串逐字一致)。
  String get _emptyMessage =>
      context.t('libpage.noFormatFiles', {'label': context.t(_filter.label)});

  /// 筛选弹层(AppBar 右上,iPhone 图库式分区卡片):排序单行「时间」
  /// (行尾方向箭头,点按翻向并收层)/ 格式四档 / 视图选项(连拍聚合)。
  /// MenuAnchor 锚按钮弹出,点任意行即收;当前档 trailing 打勾(排序行
  /// 以箭头示向,无勾)。多选中弹层不可达(actions 换了),setter 仍
  /// 防御性清选中(与相机相册页换筛选清选中同规矩)。
  ///
  /// 行宽/行距(2026-10-20 三轮真机收口):M3 菜单行默认最小高 48;
  /// 只改 minimumSize 会被移动端 tapTargetSize=padded 架空(仍 48,二轮
  /// 真机「行距还是太大」根因)—— 须 shrinkWrap 才真生效,36(竖
  /// padding 2)。宽度:行横 padding 8 + reservedPadding 只留竖 8(默认
  /// EdgeInsets.all(8) 的横向预留也是变宽一刀)。分区头保留(用户
  /// 实证「排序」头有导航价值,三轮回归)。
  Widget _filterMenuAnchor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final newestFirst = _sort == _LibSort.newestFirst;
    return MenuAnchor(
      reservedPadding: const EdgeInsets.symmetric(vertical: 8),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        _menuHeader(context, 'libpage.sort'),
        // 排序单行:时间 + 方向箭头(↓ = 大→小 = 新→旧,↑ = 小→大 =
        // 旧→新),点按翻向。两行文案并一行,行尾箭头示向。
        MenuItemButton(
          style: _menuRowStyle,
          trailingIcon: Icon(
            newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
            size: 20,
            color: scheme.primary,
          ),
          onPressed: () => _setSort(newestFirst
              ? _LibSort.oldestFirst
              : _LibSort.newestFirst),
          child: Text(context.t('libpage.sortTime')),
        ),
        _menuHeader(context, 'libpage.filterColon'),
        for (final f in _LibFilter.values)
          MenuItemButton(
            style: _menuRowStyle,
            leadingIcon: Icon(_filterIcon(f)),
            trailingIcon: _filter == f
                ? Icon(Icons.check, size: 18, color: scheme.primary)
                : null,
            onPressed: () => _setFilter(f),
            child: Text(context.t(f.label)),
          ),
        _menuHeader(context, 'libpage.viewOptions'),
        MenuItemButton(
          style: _menuRowStyle,
          leadingIcon: const Icon(Icons.burst_mode_outlined),
          trailingIcon: _burstGrouped
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null,
          onPressed: _toggleBurstGrouped,
          child: Text(context.t('libpage.groupBursts')),
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

  /// 弹层行统一收紧行高(48 → 36,shrinkWrap 必要性见
  /// [_filterMenuAnchor] 注)。
  static const _menuRowStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(64, 36)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  Widget _menuHeader(BuildContext context, String key) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
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

  IconData _filterIcon(_LibFilter f) => switch (f) {
        _LibFilter.all => Icons.apps,
        _LibFilter.raw => Icons.raw_on_outlined,
        _LibFilter.jpg => Icons.image_outlined,
        _LibFilter.video => Icons.videocam_outlined,
      };

  void _setFilter(_LibFilter f) {
    setState(() {
      _filter = f;
      _selected.clear();
    });
  }

  void _setSort(_LibSort s) {
    setState(() {
      _sort = s;
      _selected.clear();
    });
  }

  void _toggleBurstGrouped() {
    setState(() {
      _burstGrouped = !_burstGrouped;
      _selected.clear();
    });
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

  /// 可点进查看器:Flutter 可解码图片 / NEF 原生解码 / MOV 原生抽帧。
  bool _openable(File file) {
    final name = _nameOf(file);
    return _isViewableName(name) ||
        isRawFilename(name) ||
        isVideoFilename(name);
  }

  /// 单文件格:手势(多选中点格勾/取消,平时点开查看器;长按进多选并
  /// 预选)包内容(见 [_cellBody])。
  Widget _cell(BuildContext context, File file, List<File> peers) {
    return GestureDetector(
      key: ValueKey(_nameOf(file)), // 测试/定位锚:格 = 文件名
      onTap: _selectMode
          ? () => _toggleFiles([file])
          : (_openable(file) ? () => _openViewer(file, peers) : null),
      onLongPress: () => _cellLongPress([file]),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _cellBody(context, file),
          if (_selectMode) ..._selectOverlay(_selected.contains(file.path)),
        ],
      ),
    );
  }

  /// 选中覆盖层(与相机相册网格同款):压暗 + 右上勾圈。
  List<Widget> _selectOverlay(bool selected) => [
        Positioned.fill(
          child: ColoredBox(
            color: selected
                ? Colors.black.withValues(alpha: 0.3)
                : Colors.black.withValues(alpha: 0.55),
          ),
        ),
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
      ];

  /// 格内容(可解码图片铺格 / NEF·MOV 原生缩略 / 图标格)。
  Widget _cellBody(BuildContext context, File file) {
    final viewable = _isViewable(file);
    final name = _nameOf(file);
    final raw = !viewable && isRawFilename(name);
    final video = !viewable && isVideoFilename(name);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (viewable)
          Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: 300,
            errorBuilder: (context, error, stackTrace) => ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          )
        else if (raw || video)
          // NEF/MOV:原生解码/抽帧缩略(缓存命中/解码完成后铺图);
          // 无解码器/失败 → 图标格。视频格叠摄像机角标(与相机相册
          // 网格同款)。
          FutureBuilder<String?>(
            future: _thumbFor(file),
            builder: (context, snap) => snap.hasData && snap.data != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(snap.data!),
                        fit: BoxFit.cover,
                        cacheWidth: 300,
                        errorBuilder: (context, error, stackTrace) =>
                            _iconCell(context, name),
                      ),
                      if (video)
                        const Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.videocam,
                                size: 16, color: Colors.white),
                          ),
                        ),
                    ],
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
            content:
                Text(context.t('grid.deleted', {'n': files.length}))));
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
                ? context.t('libpage.exportedAlbum',
                    {'n': files.length})
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

/// 应用内文件查看(黑底,PageView 左右滑翻页):双指缩放(JPG/NEF)、
/// NEF 原生解码长边 ≤2560(会话缓存,翻回不重解)、MOV 页内播放
/// (iOS 平台视图 + Flutter 自绘播放控制,见 EmbeddedVideoPlayer,
/// 点开不自动播)。视频页可全屏(原地旋转:锁横屏 + 隐顶栏,同一播
/// 放器,无新视图无跳变)。顶栏动作(导入系统相册/删除)作用于当前
/// 页;删除后列表收缩、尾页翻回前一页。
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

  @override
  void initState() {
    super.initState();
    _videoLut.isSupported().then((v) {
      if (mounted) setState(() => _lutSupported = v);
    });
  }

  /// 视频全屏(原地旋转):锁横屏 + 隐顶栏。平台视图不能搬家,但查看
  /// 器自身布局可以 —— 同一 UiKitView 随 Scaffold 转横填满屏幕,零跳变
  /// (对比旧法:推新路由自建第二个播放器,装载黑闪 + 位置来回搬运)。
  bool _fullscreen = false;

  /// 应用全局方向集(main.dart 启动即设,传感器跟随);退出全屏还原。
  static const _appOrientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// NEF 大图解码缓存(会话内合并:页滑出视口被 dispose 后 future 仍
  /// 在,翻回不重解 —— 整档 RAW 解码是秒级重活)。
  final Map<String, Future<Uint8List>> _decodes = {};

  @override
  void dispose() {
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
    // 兜住(与 remote_page 方向锁同一手法)。
    SystemChrome.setEnabledSystemUIMode(
            fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge)
        .catchError((Object _) {});
    SystemChrome.setPreferredOrientations(fullscreen
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : _appOrientations)
        .catchError((Object _) {});
  }

  Future<Uint8List> _decodeFor(File file) => _decodes.putIfAbsent(
        file.path,
        () => widget.rawDecoder.decodeJpeg(file.path, maxPixelSize: 2560),
      );

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
                if (isVideoFilename(_nameOf(_current)) && (_lutSupported ?? false))
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
            )
          : _VideoFallbackPage(file: file, thumbFor: widget.thumbFor);
    }
    if (isRawFilename(name)) {
      return InteractiveViewer(
        maxScale: 8,
        child: Center(child: _rawBody(file)),
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

  Widget _rawBody(File file) => FutureBuilder<Uint8List>(
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
                context.t('libpage.rawDecodeFailed'),
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

/// 无内嵌播放视图的平台(Android/ohos 通道待补):海报帧打底 + 说明
/// 文案(不再给播放钮 —— play 通道同样未实现,点了也是报错)。
class _VideoFallbackPage extends StatelessWidget {
  const _VideoFallbackPage({required this.file, required this.thumbFor});

  final File file;

  /// 海报帧缓存查询(与网格格共用,不重复抽帧)。
  final Future<String?> Function(File file) thumbFor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<String?>(
          future: thumbFor(file),
          builder: (context, snap) => snap.hasData && snap.data != null
              ? Image.file(
                  File(snap.data!),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                )
              : const SizedBox.shrink(),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined,
                  color: AppMedia.onMediaSubtle, size: 48),
              const SizedBox(height: 8),
              Text(context.t('viewer.videoUnsupported'),
                  style: const TextStyle(color: AppMedia.onMediaMuted)),
            ],
          ),
        ),
      ],
    );
  }
}

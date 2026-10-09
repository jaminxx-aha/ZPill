/// 图库页(底部导航 tab):「下载到应用」的文件网格(downloadsDir 直读,
/// TransfersController 的 appFiles 数据源)。**不含**已导入系统相册的
/// 文件 —— 那些归系统相册 App 管,这里只看应用自留的份。
///
/// 网格按修改时间倒序(新下载在前);顶栏下格式过滤 chips(全部/RAW/
/// JPG/视频,按文件名扩展名,与相机侧判定同源)。Flutter 可解码的图片
/// 直接铺格(cacheWidth 限内存);NEF 走原生解码、MOV 走原生抽帧出
/// 网格缩略(iOS ImageIO / AVAssetImageGenerator,≤512px 同一管线
/// 落盘缓存,MOV 格内叠摄像机角标;无解码器/无抽帧/失败回落图标格)。
/// 点任意可看件进黑底查看器:PageView 左右滑翻页(网格过滤序同源),
/// 图片双指缩放、NEF 原生解码长边 ≤2560(会话缓存,翻回不重解)。
/// 视频在页面内直接播放(2026-10-09:点开即播,不再「海报帧 + 播放
/// 钮 + 弹全屏新页」三步走;iOS 平台视图嵌 AVPlayerViewController,
/// 播放控制在 Flutter 侧自绘 —— 原生传输条关掉,横滑才归 PageView
/// 翻页不抢手势;高帧率素材浮「24fps 顺帧」开关,非阻塞点了才变速
/// 静音;Android/ohos 通道待补回落海报帧 + 说明文案)。查看器/长按格
/// 可删除,查看器可把文件补导入系统相册。AppBar 传输徽标(进行中
/// 任务数)→ 传输页(任务列表)。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/ptpip/object_format.dart';
import '../../design/app_colors.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../../platform/services.dart';
import '../../platform/video_player.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/de_squeezed_image.dart';
import '../common/widgets/states.dart';
import '../common/widgets/video_conform.dart';
import '../transfers/transfers_page.dart';

/// 图库格式过滤:按扩展名分流,与相机侧条目判定同源。
enum _LibFilter {
  all('全部'),
  raw('RAW'),
  jpg('JPG'),
  video('视频');

  const _LibFilter(this.label);

  final String label;

  bool allows(String filename) => switch (this) {
        all => true,
        raw => isRawFilename(filename),
        jpg => isJpgFilename(filename),
        video => isVideoFilename(filename),
      };
}

/// Flutter 可解码的图片扩展名(NEF 等原生格式走解码管线)。
const _viewableExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

bool _isViewableName(String name) =>
    _viewableExts.any(name.toLowerCase().endsWith);

String _nameOf(File file) => file.uri.pathSegments.last;

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.controller,
    this.gallery,
    this.rawDecoder,
    this.videoPlayer,
    this.embeddedVideoView,
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
        // 修改时间倒序:新下载在前。
        final files = List<File>.of(_controller.appFiles)
          ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
        final activeCount =
            _controller.tasks.where((t) => !t.isTerminal).length;
        final filtered = _filtered(files);
        return Scaffold(
          appBar: AppBar(
            title: const Text('图库'),
            actions: [
              // 传输徽标:进行中任务数角标,点击进传输页看任务列表。
              _transfersBadge(context, activeCount),
              IconButton(
                tooltip: '刷新',
                onPressed: _controller.refreshAppFiles,
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: files.isEmpty
              ? const EmptyState(
                  icon: Icons.download_outlined,
                  message: '应用内还没有文件\n(在相机相册里选择「下载到应用」)',
                )
              : Column(
                  children: [
                    // 格式过滤:切换不清文件,只按扩展名收窄网格。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: SegmentedButton<_LibFilter>(
                        segments: [
                          for (final f in _LibFilter.values)
                            ButtonSegment(value: f, label: Text(f.label)),
                        ],
                        selected: {_filter},
                        onSelectionChanged: (s) =>
                            setState(() => _filter = s.first),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text('没有${_filter.label}格式的文件',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Theme.of(context).hintColor)),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(2),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 2,
                                crossAxisSpacing: 2,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (_, i) =>
                                  _cell(context, filtered[i], filtered),
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  List<File> _filtered(List<File> files) => files
      .where((f) => _filter.allows(_nameOf(f)))
      .toList(growable: false);

  Widget _transfersBadge(BuildContext context, int activeCount) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: '传输',
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

  Widget _cell(BuildContext context, File file, List<File> peers) {
    final viewable = _isViewable(file);
    final name = _nameOf(file);
    final raw = !viewable && isRawFilename(name);
    final video = !viewable && isVideoFilename(name);
    final openable =
        viewable || raw || video; // NEF/MOV 可点进查看器
    return GestureDetector(
      key: ValueKey(name), // 测试/定位锚:格 = 文件名
      onTap: openable ? () => _openViewer(file, peers) : null,
      onLongPress: () => _confirmDelete(file),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (viewable)
            Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (context, error, stackTrace) => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(
                    child: Icon(Icons.broken_image_outlined)),
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
      ),
    );
  }

  /// 图标格:视频件用摄像机图标(与「视频」过滤 chips 视觉对上),
  /// 其余原生格式用文件图标 + 扩展名。
  Widget _iconCell(BuildContext context, String name) {
    return ColoredBox(
      color:
          Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
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
        ),
      ),
    );
  }

  /// 长按格 / 查看器删除:确认对话框把关(应用内文件,删了要重下)。
  Future<void> _confirmDelete(File file) async {
    final name = _nameOf(file);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除应用内文件?',
      content: '将删除「$name」。\n此操作不可恢复(相机上的原件不受影响)。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed) {
      await _controller.deleteAppFile(file);
    }
  }
}

/// 应用内文件查看(黑底,PageView 左右滑翻页):双指缩放(JPG/NEF)、
/// NEF 原生解码长边 ≤2560(会话缓存,翻回不重解)、MOV 页内播放
/// (iOS 平台视图 + Flutter 自绘播放控制,见 [_VideoPage],点开不自动
/// 播)。视频页可全屏(原地旋转:锁横屏 + 隐顶栏,同一播放器,无新
/// 视图无跳变)。顶栏动作(导入系统相册/删除)作用于当前页;删除后
/// 列表收缩、尾页翻回前一页。
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

  @override
  State<_LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<_LibraryViewer> {
  late final List<File> _files = List.of(widget.files);
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

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
                  tooltip: '导入系统相册',
                  onPressed: _importToGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                ),
                IconButton(
                  tooltip: '删除',
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
          ? _VideoPage(
              file: file,
              active: active,
              player: widget.videoPlayer,
              viewBuilder:
                  widget.embeddedVideoView ?? embeddedVideoViewBuilder,
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
              style: const TextStyle(color: AppMedia.onMediaMuted, fontSize: 12)),
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
                'RAW 解码失败(该平台可能不支持)',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppMedia.onMediaSubtle),
              ),
            );
          }
          return const CircularProgressIndicator();
        },
      );

  /// 删除当前页:列表收缩,当前页位显示下一张滑入;删的是尾页先翻回
  /// 前一页(PageView 页位越界会白屏);最后一份则收查看器再删。
  Future<void> _delete() async {
    final file = _current;
    final name = _nameOf(file);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除应用内文件?',
      content: '将删除「$name」。\n此操作不可恢复(相机上的原件不受影响)。',
      confirmLabel: '删除',
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
          content: Text(imported ? '已导入系统相册(应用内文件保留)' : '未导入(已取消或失败)')));
  }
}

/// 视频页(查看器 PageView 的一页):iOS 内嵌平台视图在页面里播放 —
/// 点开**不自动播**(2026-10-09 复报改):首帧 + 播放钮常驻,点了才起
/// 播;从图片滑过来同理。
///
/// 播放控制在 Flutter 侧自绘(AVKit 传输条关掉:原生横滑手势会与
/// PageView 翻页抢 —— 裸视频面横滑归翻页,点按切控制浮层,进度条是
/// Flutter 件叠在上面不经过平台视图)。高帧率(>30.5fps)素材浮
/// 「24fps 顺帧」开关:非阻塞,点了才变速静音(顺帧是可选增强,不拦
/// 起播)。[active] = 页为当前页(翻页 settle)才起播,滑走即暂停。
///
/// 全屏走 [_fullscreen]/[onToggleFullscreen](查看器原地旋转,同一播
/// 放器);本页只换角钮图样。
class _VideoPage extends StatefulWidget {
  const _VideoPage({
    required this.file,
    required this.active,
    required this.player,
    required this.viewBuilder,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final File file;
  final bool active;
  final VideoPlayer player;

  /// 内嵌视图构建(测试注入;生产 = iOS 平台视图)。
  final EmbeddedVideoViewBuilder viewBuilder;

  /// 查看器全屏态(原地旋转):角钮在 全屏/退出全屏 间切换。
  final bool fullscreen;

  /// 切换查看器全屏。
  final VoidCallback onToggleFullscreen;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  static const _pollInterval = Duration(milliseconds: 250);
  static const _controlsHideDelay = Duration(seconds: 3);

  int? _viewId;
  double? _fps; // 标称帧率(未知/≤30.5 = 无顺帧开关)
  bool _conform = false;
  bool _controlsVisible = true;
  // 起播意图:点开不自动播(首帧 + 播放钮),点了播放才 true;暂停/
  // 播完跟随翻 false。滑走保持原意图,翻回继续(没点过播放的翻回仍停)。
  bool _playingIntent = false;
  bool _playing = false; // 原生观测(播完自停跟随)
  double _position = 0;
  double _duration = 0;
  bool _scrubbing = false;
  double _scrubTo = 0;
  Timer? _pollTimer;
  Timer? _hideTimer; // 播放中 3s 自动隐浮层;暂停/播完浮层常驻

  @override
  void initState() {
    super.initState();
    _probeFps();
    if (widget.active) {
      _startPolling();
    }
  }

  @override
  void didUpdateWidget(covariant _VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      _sync(); // settle 起播 / 滑走暂停
      widget.active ? _startPolling() : _stopPolling();
    }
  }

  @override
  void dispose() {
    // 显式暂停兜底:不等平台视图销毁链(引擎 dispose 时序不保证即时
    // —— 2026-10-09 退出查看器声音未停复报),通道先发暂停;原生侧
    // 若已摘表则静默无操作,双保险。
    final id = _viewId;
    if (id != null) {
      unawaited(widget.player
          .controlEmbeddedView(id, playing: false, rate: 1.0));
    }
    _stopPolling();
    _hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _probeFps() async {
    try {
      final fps = await widget.player.frameRate(widget.file.path);
      if (mounted) setState(() => _fps = fps);
    } on Exception {
      // 帧率探测失败 = 无顺帧开关,不拦播放
    }
  }

  bool get _highFps => _fps != null && _fps! > kConformFpsGate;

  double get _rate =>
      _conform && _highFps ? kConformTargetFps / _fps! : 1.0;

  Future<void> _onViewCreated(int viewId) async {
    _viewId = viewId;
    // 档案路径不走平台视图 creationParams(引擎编解码钩子不可靠,实测
    // 到不了原生侧),通道装载;同通道 FIFO 保证装载先于控制。
    await widget.player.loadEmbeddedView(viewId, widget.file.path);
    if (!mounted) return;
    _sync(); // 视图就位:按意图同步(默认暂停,点了播放才起播)
    unawaited(_pollStatus());
  }

  /// 把「起播意图 × 顺帧速率」推给原生视图。
  void _sync() {
    final id = _viewId;
    if (id == null) return;
    unawaited(widget.player.controlEmbeddedView(id,
        playing: widget.active && _playingIntent, rate: _rate));
  }

  void _startPolling() {
    _pollTimer ??=
        Timer.periodic(_pollInterval, (_) => _pollStatus());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollStatus() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final status = await widget.player.embeddedViewStatus(id);
      if (!mounted) return;
      final wasPlaying = _playing;
      // 值未变不重绘(测试 FakeAsync 里 pumpAndSettle 才能收)。
      if (status.playing == _playing &&
          status.position == _position &&
          status.duration == _duration) {
        return;
      }
      setState(() {
        _playing = status.playing;
        _playingIntent = status.playing; // 播完自停跟随观测
        _position = status.position;
        _duration = status.duration;
      });
      // 起播 → 计时隐浮层;停了(暂停/播完)→ 浮层常驻等下一次点按
      if (_playing && !wasPlaying) {
        _armHide();
      } else if (!_playing && wasPlaying) {
        _hideTimer?.cancel();
        _showControls();
      }
    } on Exception {
      // 视图销毁竞态/通道抖动:静默,下轮再试
    }
  }

  /// 播放中且浮层可见时,[_controlsHideDelay] 后自动隐掉(拖进度条
  /// 会取消、松手重新计时;暂停不计时 —— 浮层常驻才点得到播放)。
  void _armHide() {
    _hideTimer?.cancel();
    if (!_playingIntent || !_controlsVisible) return;
    _hideTimer = Timer(_controlsHideDelay, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _armHide(); // 播放中唤回 → 再计时隐掉;暂停时 armHide 自行跳过
    } else {
      _hideTimer?.cancel();
    }
  }

  Future<void> _togglePlay() async {
    final id = _viewId;
    if (id == null) return;
    setState(() => _playingIntent = !_playingIntent);
    // 播到底再按播放:回开头重放
    if (_playingIntent && _duration > 0 && _position >= _duration - 0.05) {
      await widget.player.seekEmbeddedView(id, position: 0);
    }
    await widget.player.controlEmbeddedView(id,
        playing: widget.active && _playingIntent, rate: _rate);
    if (_playingIntent) {
      _armHide(); // 原生起播观测要等下一轮 poll,先按意图计时
    } else {
      _hideTimer?.cancel();
    }
  }

  void _toggleConform() {
    setState(() => _conform = !_conform);
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 裸视频面:横滑归 PageView 翻页(原生不装传输条,不抢手势),
        // 点按(未被拖动认领)切控制浮层。opaque:整面吃点按(平台
        // 视图本就吸点;测试替身是透明盒,deferToChild 会漏下去)。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: widget.viewBuilder(widget.file.path, _onViewCreated),
        ),
        // 控制浮层(共用件):中键播放/暂停 + 底行顺帧开关与进度条 +
        // 右下全屏/退出全屏钮;播放中 3s 自动隐,点按唤回,暂停常驻。
        _VideoControlsOverlay(
          visible: _controlsVisible,
          playingIntent: _playingIntent,
          position: _position,
          duration: _duration,
          scrubbing: _scrubbing,
          scrubTo: _scrubTo,
          fps: _fps,
          conform: _conform,
          onTogglePlay: _togglePlay,
          onToggleConform: _toggleConform,
          onScrub: (v) {
            _hideTimer?.cancel(); // 拖动期间不隐
            setState(() {
              _scrubbing = true;
              _scrubTo = v;
            });
          },
          onScrubEnd: (v) {
            setState(() {
              _scrubbing = false;
              _position = v;
            });
            final id = _viewId;
            if (id != null) {
              unawaited(widget.player.seekEmbeddedView(id, position: v));
            }
            _armHide(); // 松手重新计时
          },
          bottomRight: IconButton(
            tooltip: widget.fullscreen ? '退出全屏' : '全屏播放',
            onPressed: widget.onToggleFullscreen,
            icon: Icon(
              widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: AppMedia.onMedia,
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放控制浮层:中键播放/暂停 + 底行顺帧开关与进度条,底行右端动作
/// 钮由调用方给(全屏/退出全屏切换,恒在右下角)。随 [visible] 淡入
/// 淡出,隐藏期间不吃指针。
class _VideoControlsOverlay extends StatelessWidget {
  const _VideoControlsOverlay({
    required this.visible,
    required this.playingIntent,
    required this.position,
    required this.duration,
    required this.scrubbing,
    required this.scrubTo,
    required this.fps,
    required this.conform,
    required this.onTogglePlay,
    required this.onToggleConform,
    required this.onScrub,
    required this.onScrubEnd,
    required this.bottomRight,
  });

  final bool visible;
  final bool playingIntent;
  final double position;
  final double duration;
  final bool scrubbing;
  final double scrubTo;
  final double? fps;
  final bool conform;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleConform;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onScrubEnd;
  final Widget bottomRight;

  @override
  Widget build(BuildContext context) {
    final highFps = fps != null && fps! > kConformFpsGate;
    final percent =
        highFps ? (kConformTargetFps / fps! * 100).round() : 0;
    final sliderMax = duration > 0 ? duration : 1.0;
    final shownPosition = scrubbing ? scrubTo : position;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Material(
                color: AppMedia.onMediaDim,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTogglePlay,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Icon(
                      playingIntent ? Icons.pause : Icons.play_arrow,
                      color: AppMedia.onMedia,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 8, left: 12, right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (highFps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilterChip(
                            selected: conform,
                            label: Text(conform
                                ? '顺帧 24fps · $percent%'
                                : '24fps 顺帧'),
                            onSelected: (_) => onToggleConform(),
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Text(_formatClock(shownPosition),
                            style: const TextStyle(
                                color: AppMedia.onMediaMuted, fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: shownPosition.clamp(0, sliderMax),
                            max: sliderMax,
                            onChanged: duration <= 0
                                ? null
                                : (v) => onScrub(v),
                            onChangeEnd: (v) => onScrubEnd(v),
                          ),
                        ),
                        Text(_formatClock(duration),
                            style: const TextStyle(
                                color: AppMedia.onMediaMuted, fontSize: 12)),
                        // 右下角动作钮(全屏/退出全屏):恒在底行右端
                        bottomRight,
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
              const Text('该平台暂不支持视频播放',
                  style: TextStyle(color: AppMedia.onMediaMuted)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 秒 → 「m:ss」(≥1h 用「h:mm:ss」)。
String _formatClock(double seconds) {
  final t =
      seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final s = t % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

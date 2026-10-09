/// 图库页(底部导航 tab):「下载到应用」的文件网格(downloadsDir 直读,
/// TransfersController 的 appFiles 数据源)。**不含**已导入系统相册的
/// 文件 —— 那些归系统相册 App 管,这里只看应用自留的份。
///
/// 网格按修改时间倒序(新下载在前);顶栏下格式过滤 chips(全部/RAW/
/// JPG/视频,按文件名扩展名,与相机侧判定同源)。Flutter 可解码的图片
/// 直接铺格(cacheWidth 限内存);NEF 走原生解码、MOV 走原生抽帧出
/// 网格缩略(iOS ImageIO / AVAssetImageGenerator,≤512px 同一管线
/// 落盘缓存,MOV 格内叠摄像机角标;无解码器/无抽帧/失败回落图标格)。
/// 点图片进黑底查看器(双指缩放):JPG 直看、NEF 原生解码查看(长边
/// ≤2560)、MOV 海报帧打底 + 播放钮全屏播放(nikonpill/video,文件
/// 保留);查看器/长按格可删除,查看器可把文件补导入系统相册。AppBar
/// 传输徽标(进行中任务数)→ 传输页(任务列表)。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/photo_group.dart';
import '../../core/ptpip/object_format.dart';
import '../../design/app_colors.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/raw_decoder.dart';
import '../../platform/services.dart';
import '../../platform/video_player.dart';
import '../common/widgets/confirm_dialog.dart';
import '../common/widgets/states.dart';
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

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.controller,
    this.gallery,
    this.rawDecoder,
    this.videoPlayer,
  });

  /// 测试注入;缺省用 AppServices 单例(应用级共享,本页不持有)。
  final TransfersController? controller;

  /// 测试注入;缺省用平台服务单例。
  final GallerySaver? gallery;

  /// 测试注入;缺省用平台服务单例(NEF 网格缩略 + 查看器解码)。
  final RawDecoder? rawDecoder;

  /// 测试注入;缺省用平台服务单例(MOV 查看器播放)。
  final VideoPlayer? videoPlayer;

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

  /// Flutter 可解码的图片扩展名(NEF 等原生格式走解码管线)。
  static const _viewableExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

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

  bool _isViewable(File file) {
    final name = file.uri.pathSegments.last.toLowerCase();
    return _viewableExts.any(name.endsWith);
  }

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
      final name = file.uri.pathSegments.last;
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
    final name = file.uri.pathSegments.last;
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
                                  _cell(context, filtered[i]),
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  List<File> _filtered(List<File> files) => files
      .where((f) => _filter.allows(f.uri.pathSegments.last))
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

  Widget _cell(BuildContext context, File file) {
    final viewable = _isViewable(file);
    final name = file.uri.pathSegments.last;
    final raw = !viewable && isRawFilename(name);
    final video = !viewable && isVideoFilename(name);
    final openable =
        viewable || raw || video; // NEF/MOV 可点进查看器
    return GestureDetector(
      key: ValueKey(name), // 测试/定位锚:格 = 文件名
      onTap: openable ? () => _openViewer(file, name) : null,
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

  void _openViewer(File file, String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LibraryViewer(
          file: file,
          title: name,
          controller: _controller,
          gallery: _gallery,
          rawDecoder: _rawDecoder,
          videoPlayer: _videoPlayer,
          thumbFor: _thumbFor,
        ),
      ),
    );
  }

  /// 长按格 / 查看器删除:确认对话框把关(应用内文件,删了要重下)。
  Future<void> _confirmDelete(File file) async {
    final name = file.uri.pathSegments.last;
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

/// 应用内文件查看(黑底 + 双指缩放):删除 + 补导入系统相册。
/// 三种货色:Flutter 直解图片(Image.file)/ NEF(原生解码长边 ≤2560,
/// 解码在 initState 起一次,重建不重解)/ MOV(海报帧打底 + 播放钮 →
/// 全屏原生播放;文件是应用内常驻档,播完不删)。
class _LibraryViewer extends StatefulWidget {
  const _LibraryViewer({
    required this.file,
    required this.title,
    required this.controller,
    required this.gallery,
    required this.rawDecoder,
    required this.videoPlayer,
    required this.thumbFor,
  });

  final File file;
  final String title;
  final TransfersController controller;
  final GallerySaver gallery;
  final RawDecoder rawDecoder;
  final VideoPlayer videoPlayer;

  /// 海报帧缓存查询(页面级管线,网格已抽过的帧直接命中)。
  final Future<String?> Function(File file) thumbFor;

  @override
  State<_LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<_LibraryViewer> {
  late final Future<Uint8List>? _decode;

  @override
  void initState() {
    super.initState();
    _decode = isRawFilename(widget.title)
        ? widget.rawDecoder.decodeJpeg(widget.file.path, maxPixelSize: 2560)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final video = isVideoFilename(widget.title);
    return Scaffold(
      backgroundColor: AppMedia.background,
      appBar: AppBar(
        backgroundColor: AppMedia.chrome,
        foregroundColor: AppMedia.onMedia,
        title: Text(widget.title,
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
      body: video
          ? Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [
                // 海报帧打底(网格缩略共用缓存,无抽帧/失败时空底)。
                FutureBuilder<String?>(
                  future: widget.thumbFor(widget.file),
                  builder: (context, snap) =>
                      snap.hasData && snap.data != null
                          ? Image.file(
                              File(snap.data!),
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  const SizedBox.shrink(),
                            )
                          : const SizedBox.shrink(),
                ),
                IconButton(
                  iconSize: 72,
                  color: AppMedia.onMedia,
                  onPressed: _play,
                  icon: const Icon(Icons.play_arrow),
                ),
              ],
            )
          : InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: _decode != null ? _rawBody() : _imageBody(),
              ),
            ),
    );
  }

  Widget _imageBody() => Image.file(
        widget.file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.broken_image_outlined,
          color: AppMedia.onMediaSubtle,
          size: 48,
        ),
      );

  Widget _rawBody() => FutureBuilder<Uint8List>(
        future: _decode,
        builder: (context, snap) {
          if (snap.hasData) {
            return Image.memory(
              snap.data!,
              fit: BoxFit.contain,
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

  Future<void> _play() async {
    try {
      await widget.videoPlayer.play(widget.file.path);
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('播放失败(该平台可能不支持视频播放)')));
    }
  }

  /// 补导入系统相册:文件本体保留(导入是复制不是移动);ohos 亮保存
  /// 面板,用户取消返回空列表(不报错)。
  Future<void> _importToGallery() async {
    var imported = false;
    try {
      final uris = await widget.gallery.importFiles([
        GalleryImportRequest(
          path: widget.file.path,
          kind: kindForFilename(widget.title),
          filename: widget.title,
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

  Future<void> _delete() async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除应用内文件?',
      content: '将删除「${widget.title}」。\n此操作不可恢复(相机上的原件不受影响)。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(); // 先关查看器再删(格位即收)
    await widget.controller.deleteAppFile(widget.file);
  }
}

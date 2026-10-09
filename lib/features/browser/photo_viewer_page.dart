/// 大图预览:PageView 左右滑 + 双指缩放;底部单张下载到相册/应用,
/// 顶栏打星(本地评分,1-5 星/清除)。
///
/// 双格式(RAW+JPG)组下载前弹格式选择(仅 JPG/仅 RAW/两者);单格式
/// 组与视频直接下载。预览走 ThumbnailCache preview 档的**小图先显 +
/// 高清换图**(2026-10-09 复报「点进去很小/模糊」):打开即显小图
/// (JPG = 0x90C4 直发 640×424,NEF = GetThumb;缓存层注入 EXIF 方向,
/// 见 jpeg_orientation.dart),页 settle 后 warmPreview 后台拉整档 +
/// 原生解码(长边 ≤ 2560,NEF 档内无大 JPEG 定案见 thumbnail_cache),
/// 升级事件到即换高清。
///
/// 视频组(2026-10-09 改):海报帧 + 播放钮 → 点播放弹进度(PTP 无
/// 流式,整档拉到临时目录,可取消)→ **页内**内嵌播放(Embedded
/// VideoPlayer,与图库查看器同款:自绘控制浮层、顺帧开关、原地旋转
/// 全屏 —— 不再推全屏 AVKit modal)。临时档随视频页存活(翻回不
/// 重拉,keep-alive),查看器关闭即删。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../core/browser/object_entry.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/ptpip/object_format.dart' show ObjectKind;
import '../../core/transfer/object_downloader.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../design/app_colors.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/services.dart';
import '../../platform/video_player.dart';
import '../common/format.dart';
import '../common/widgets/de_squeezed_image.dart';
import '../common/widgets/embedded_video_player.dart';
import '../common/widgets/loading_overlay.dart';
import '../edit/edit_page.dart';
import 'download_format_sheet.dart';
import 'ratings_controller.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.thumbnails,
    this.engine,
    this.ratings,
    this.downloader,
    this.gallery,
    this.videoPlayer,
    this.embeddedVideoView,
  });

  final List<PhotoGroup> items;
  final int initialIndex;

  /// 测试注入;缺省用 AppServices 单例。
  final ThumbnailCache? thumbnails;

  /// 测试注入;缺省用 AppServices 单例。
  final TransferEngine? engine;

  /// 测试注入;缺省用 AppServices 单例(与网格页共享同一评分状态)。
  final RatingsController? ratings;

  /// 测试注入(编辑:拉原图;视频:拉临时档);缺省用 AppServices 单例。
  final ObjectDownloader? downloader;

  /// 测试注入(编辑:导出相册);缺省平台通道。
  final GallerySaver? gallery;

  /// 测试注入(视频播放);缺省平台通道。
  final VideoPlayer? videoPlayer;

  /// 测试注入(视频页内嵌视图);缺省 iOS 平台视图。仅在
  /// [VideoPlayer.supportsEmbeddedView] 为真时被构建。
  final EmbeddedVideoViewBuilder? embeddedVideoView;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  /// 视频全屏(原地旋转):锁横屏 + 沉浸 + 收 AppBar/底栏。平台视图
  /// 不能搬家,但查看器自身布局可以 —— 同一 UiKitView 随 Scaffold 转横
  /// 填满屏幕,零跳变(与图库查看器同款机制)。
  bool _fullscreen = false;

  /// 应用全局方向集(main.dart 启动即设,传感器跟随);退出全屏还原。
  static const _appOrientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  ThumbnailCache get _thumbnails =>
      widget.thumbnails ?? AppServices.instance.thumbnails;
  TransferEngine get _engine =>
      widget.engine ?? AppServices.instance.transferEngine;
  RatingsController get _ratings =>
      widget.ratings ?? AppServices.instance.ratings;
  ObjectDownloader get _downloader =>
      widget.downloader ?? AppServices.instance.downloader;
  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;
  VideoPlayer get _videoPlayer =>
      widget.videoPlayer ?? PlatformServices.videoPlayer;

  @override
  void initState() {
    super.initState();
    _warmCurrent();
  }

  /// 当前页预览预热(高清席位):小图已先显,后台拉整档解码换高清;
  /// 翻页 settle 跟随(单槽排队,快速翻页只暖停留页,见
  /// [ThumbnailCache.warmPreview])。
  void _warmCurrent() {
    final group = widget.items[_index];
    if (!group.isVideo) {
      unawaited(_thumbnails.warmPreview(group.primary));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    if (_fullscreen) {
      // 全屏中收查看器(返回手势):还原方向与系统栏再走
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
    // 兜住(与图库查看器/remote_page 方向锁同一手法)。
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

  /// 打星面板:1-5 星 + 清除评分(0)。乐观上屏由控制器负责。
  Future<void> _rate(PhotoGroup group) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '评分',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var stars = 1; stars <= 5; stars++)
                    IconButton(
                      iconSize: 32,
                      color: stars <= _ratings.ratingOf(group)
                          ? AppColors.brandYellow
                          : Theme.of(context).disabledColor,
                      onPressed: () {
                        _ratings.rate(group, stars);
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.star),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: const Text('清除评分'),
              onTap: () {
                _ratings.rate(group, 0);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 下载:双格式组先选格式(取消即放弃);单格式/视频直接整组。
  Future<void> _download(
      PhotoGroup group, TransferDestination destination) async {
    var entries = group.members;
    PhotoDownloadFormat? format;
    if (!group.isVideo && group.hasJpg && group.hasRaw) {
      format = await showDownloadFormatSheet(context,
          subtitle: '这张照片有 JPG 和 RAW 两份文件');
      if (format == null) {
        return; // 取消,不下载
      }
      entries = group.membersFor(format);
    }
    await _engine.enqueue(entries, destination: destination);
    if (!mounted) {
      return;
    }
    final where = destination == TransferDestination.gallery ? '相册' : '应用';
    final tag = format == null ? '' : '(${format.short})';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已开始下载到$where$tag,进度见「图库」页')));
  }

  /// 编辑:拉取组内 JPG 原图到临时目录(相机会话串行,排队即得),
  /// 读字节后即删原件;编辑产物走相册导入,不在临时目录留档。
  Future<void> _edit(PhotoGroup group) async {
    final jpg = group.jpg;
    if (jpg == null) return;
    unawaited(
        showLoadingOverlay(context, message: '拉取原图…'));
    try {
      final dl =
          await _downloader.download(jpg, targetDir: await _gallery.tempDir());
      final bytes = await File(dl.path).readAsBytes();
      try {
        await File(dl.path).delete();
      } on FileSystemException {
        // 删失败不挡编辑
      }
      if (!mounted) return;
      Navigator.of(context).pop(); // loading 对话框
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            EditPage(jpeg: bytes, filename: jpg.name, gallery: _gallery),
      ));
    } on Object {
      if (!mounted) return;
      Navigator.of(context).pop(); // loading 对话框
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('拉取原图失败,请检查连接后重试')));
    }
  }

  /// 播放视频:整档下载到临时目录(进度对话框,可取消)→ **页内**
  /// 内嵌播放(EmbeddedVideoPlayer,与图库查看器同款)。PTP 相机没有
  /// 流式播放(Nikon moov 原子位置未验,亦无 HTTP range 语义),大文件
  /// 需等下载;取消 = 删半成品。临时档随视频页存活(翻回不重拉),
  /// 页面销毁(查看器关闭)时删除。
  Future<void> _startPlayback(_CameraVideoPageState page) async {
    final video = page.widget.group.movie;
    if (video == null) return;
    final cancel = _DownloadCancel();
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _VideoDownloadDialog(
          totalBytes: video.sizeInBytes, cancel: cancel),
    ));
    ObjectDownload? dl;
    try {
      dl = await _downloader.download(video,
          targetDir: await _gallery.tempDir(),
          onProgress: (received) => cancel.progress.value = received,
          isCancelled: () => cancel.cancelled);
    } on DownloadCancelledException {
      _closeDialog();
      _snack('已取消');
      page.onFetchFailed(); // 播放钮复位(可再点)
      return;
    } on Exception {
      _closeDialog();
      _snack('加载视频失败,请检查连接后重试');
      page.onFetchFailed(); // 同上:不留卡死的菊花
      return;
    }
    _closeDialog();
    if (!mounted) {
      unawaited(_deleteQuietly(dl.path)); // 页面已走:临时档直接清
      return;
    }
    page.onDownloaded(dl.path);
  }

  void _closeDialog() {
    if (mounted) {
      Navigator.of(context).pop(); // 进度对话框
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.items[_index];
    // 顶栏星标随评分与翻页刷新(评分面板乐观上屏,回滚也刷)。
    return ListenableBuilder(
      listenable: _ratings,
      builder: (context, _) {
        final rating = _ratings.ratingOf(group);
        return Scaffold(
          backgroundColor: AppMedia.background,
          // 全屏收顶栏与底栏:视频页撑满(同一平台视图转横)
          appBar: _fullscreen
              ? null
              : AppBar(
                  backgroundColor: AppMedia.chrome,
                  foregroundColor: AppMedia.onMedia,
                  title: Text('${_index + 1} / ${widget.items.length}'),
                  actions: [
                    if (group.hasJpg)
                      IconButton(
                        tooltip: '编辑',
                        onPressed: () => _edit(group),
                        icon: const Icon(Icons.tune),
                      ),
                    IconButton(
                      tooltip: '评分',
                      onPressed: () => _rate(group),
                      icon: Icon(
                        rating > 0 ? Icons.star : Icons.star_border,
                        color: rating > 0 ? AppColors.brandYellow : null,
                      ),
                    ),
                  ],
                ),
          body: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _warmCurrent();
              // 全屏是视频语境:滑到非视频页自动退出(还原方向与栏)
              if (_fullscreen && !widget.items[i].isVideo) {
                _setFullscreen(false);
              }
            },
            itemBuilder: (_, i) => _page(widget.items[i], active: i == _index),
          ),
          bottomNavigationBar: _fullscreen ? null : _infoBar(context, group),
        );
      },
    );
  }

  Widget _page(PhotoGroup group, {required bool active}) {
    final zoomable = InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: _PreviewImage(entry: group.primary, thumbs: _thumbnails),
      ),
    );
    if (!group.isVideo) {
      return zoomable;
    }
    // 视频页:自带 海报(未下载时垫底)/播放钮/下载/内嵌播放。
    return _CameraVideoPage(
      key: ValueKey(group.key),
      group: group,
      active: active,
      poster: zoomable,
      player: _videoPlayer,
      viewBuilder: widget.embeddedVideoView ?? embeddedVideoViewBuilder,
      fullscreen: _fullscreen,
      onToggleFullscreen: () => _setFullscreen(!_fullscreen),
      onStartPlayback: _startPlayback,
    );
  }

  Widget _infoBar(BuildContext context, PhotoGroup group) {
    // RAW+JPG 合并组:两份文件名都列出,大小取合计;连拍簇注明张数。
    final pair = group.hasJpg && group.hasRaw;
    final info = [
      pair ? '${group.jpg!.name} + ${group.raw!.name}' : group.name,
      formatBytes(group.totalBytes),
      if (group.isBurst) '连拍 ×${group.shotCount}',
      if (formatDateTime(group.capturedAt) != null)
        formatDateTime(group.capturedAt)!,
      if (group.isVideo) '视频',
    ].join(' · ');
    return SafeArea(
      top: false,
      // 不用 BottomAppBar:它的定高(80)+ 自身留白叠上两行内容必然
      // 溢出(真机 13px);Material+Padding 让内容自适应高度。
      child: Material(
        color: AppMedia.chrome,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                info,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppMedia.onMediaMuted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppMedia.onMediaDim,
                        foregroundColor: AppMedia.onMedia,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          _download(group, TransferDestination.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('下载到相册'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppMedia.onMediaDim,
                        foregroundColor: AppMedia.onMedia,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          _download(group, TransferDestination.app),
                      icon: const Icon(Icons.folder_outlined),
                      label: const Text('下载到应用'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 静默删临时档:删失败不挡(临时目录系统可回收)。
Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // 同上
  }
}

/// 大图预览(小图先显 → 高清换图):打开即取小图席位(0x90C4 /
/// GetThumb,缓存层已注入 EXIF 方向,引擎解码即转正);页 settle 后
/// 宿主 [ThumbnailCache.warmPreview] 后台拉整档解码,升级事件到即换
/// 高清(AnimatedSwitcher 淡切,长边 ≤ 2560 与变宽还原同享)。
class _PreviewImage extends StatefulWidget {
  const _PreviewImage({required this.entry, required this.thumbs});

  final ObjectEntry entry;
  final ThumbnailCache thumbs;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  late final Future<String> _future =
      widget.thumbs.pathFor(widget.entry, ThumbSource.preview);
  String? _hqPath; // 高清席位路径(升级事件到即有)
  StreamSubscription<PreviewUpgrade>? _upgrades;

  @override
  void initState() {
    super.initState();
    _upgrades = widget.thumbs.previewUpgrades.listen((u) {
      if (u.handle == widget.entry.handle &&
          u.sizeInBytes == widget.entry.sizeInBytes &&
          mounted) {
        setState(() => _hqPath = u.path);
      }
    });
  }

  @override
  void dispose() {
    _upgrades?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.entry.kind == ObjectKind.video;
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        final path = _hqPath ??
            (snap.connectionState == ConnectionState.done ? snap.data : null);
        if (path != null) {
          // 变宽还原:设置 >1 时按倍率水平拉伸(见 DeSqueezedImage)。
          // key 跟路径:小图 → 高清走 AnimatedSwitcher 淡切(高清到时
          // 小图还在屏上,不闪白)。
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(
              key: ValueKey<String>(path),
              child: DeSqueezedImage(
                image: FileImage(File(path)),
                deSqueeze:
                    AppServices.instance.settingsController.value.deSqueeze,
                errorBuilder: (context, error, stackTrace) => Icon(
                  isVideo
                      ? Icons.movie_outlined
                      : Icons.broken_image_outlined,
                  color: AppMedia.onMediaSubtle,
                  size: 48,
                ),
              ),
            ),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppMedia.onMedia),
              SizedBox(height: 12),
              Text('加载预览…',
                  style: TextStyle(color: AppMedia.onMediaMuted)),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.movie_outlined : Icons.broken_image_outlined,
              color: AppMedia.onMediaSubtle,
              size: 48,
            ),
            const SizedBox(height: 8),
            Text(
              isVideo ? '点按播放键观看' : '预览不可用',
              style: const TextStyle(color: AppMedia.onMediaMuted),
            ),
          ],
        );
      },
    );
  }
}

/// 视频下载的进度与取消态(onProgress 回调线程 → ValueNotifier 单向驱动)。
final class _DownloadCancel {
  final ValueNotifier<int> progress = ValueNotifier<int>(0);
  bool cancelled = false;
}

/// 视频播放准备进度对话框:进度条 + 已收/总量 + 取消(置位后下载层删
/// 半成品抛 DownloadCancelledException,对话框由 _startPlayback 收口)。
/// 文案按播放口径(「准备播放」)—— 整档拉取是 PTP 无流式的代价,
/// 不是一次「下载」操作(2026-10-09 复报「点击视频是下载」)。
class _VideoDownloadDialog extends StatelessWidget {
  const _VideoDownloadDialog(
      {required this.totalBytes, required this.cancel});

  final int totalBytes;
  final _DownloadCancel cancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('准备播放'),
      content: ListenableBuilder(
        listenable: cancel.progress,
        builder: (context, _) {
          final received = cancel.progress.value;
          final ratio =
              totalBytes > 0 ? (received / totalBytes).clamp(0.0, 1.0) : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: ratio),
              const SizedBox(height: 12),
              Text(
                '${formatBytes(received)}'
                ' / ${formatBytes(totalBytes)}'
                '${ratio == null ? '' : ' · ${(ratio * 100).toInt()}%'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => cancel.cancelled = true,
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 相机相册查看器的视频页(查看器 PageView 的一页)。
///
/// 三态:① 未播放 —— 海报(查看器的预览管线垫底)+ 播放钮;② 拉取中
/// —— 进度对话框由宿主 [_PhotoViewerPageState._startPlayback] 弹,
/// 播放钮转菊花防重复点;③ 已就绪 —— [EmbeddedVideoPlayer] 页内播放
/// (autoplay:用户点播放钮已是意图),控制浮层/顺帧开关/原地旋转
/// 全屏与图库查看器同款。
///
/// keep-alive:视频临时档(可能几十 MB)随本页存活 —— PageView 滑走
/// 页不销毁、翻回不重拉;页面真正销毁(查看器关闭)时删档。无内嵌
/// 播放视图的平台(Android/ohos 通道待补)点播放直接提示,不再先拉
/// 整档再报错。
class _CameraVideoPage extends StatefulWidget {
  const _CameraVideoPage({
    super.key,
    required this.group,
    required this.active,
    required this.poster,
    required this.player,
    required this.viewBuilder,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onStartPlayback,
  });

  final PhotoGroup group;

  /// 页为当前页(翻页 settle);转给内嵌播放器(滑走即暂停)。
  final bool active;

  /// 未播放时的海报(查看器预览管线,含加载/占位态)。
  final Widget poster;

  final VideoPlayer player;

  /// 内嵌视图构建(测试注入;生产 = iOS 平台视图)。
  final EmbeddedVideoViewBuilder viewBuilder;

  /// 查看器全屏态(原地旋转)。
  final bool fullscreen;

  /// 切换查看器全屏。
  final VoidCallback onToggleFullscreen;

  /// 点播放:宿主弹进度对话框 + 拉临时档,完成后回调 [onDownloaded]。
  final Future<void> Function(_CameraVideoPageState page) onStartPlayback;

  @override
  State<_CameraVideoPage> createState() => _CameraVideoPageState();
}

class _CameraVideoPageState extends State<_CameraVideoPage>
    with AutomaticKeepAliveClientMixin {
  /// 已就绪的本地临时档(下载完成即有);null = 未播放/拉取中。
  String? _localPath;
  bool _fetching = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    final path = _localPath;
    if (path != null) {
      unawaited(_deleteQuietly(path));
    }
    super.dispose();
  }

  /// 宿主拉取完成/失败的回投(失败含取消:[_PhotoViewerPageState
  /// ._startPlayback] 的 catch 路);失败复位播放钮 —— 否则菊花卡死
  /// 再点不了。
  void onFetchFailed() {
    if (!mounted) return;
    setState(() => _fetching = false);
  }

  /// 宿主拉取完成的回投([_PhotoViewerPageState._startPlayback] 调)。
  void onDownloaded(String path) {
    if (!mounted) return;
    setState(() {
      _localPath = path;
      _fetching = false;
    });
  }

  void _startPlayback() {
    if (_fetching || _localPath != null) return;
    if (!widget.player.supportsEmbeddedView) {
      // 无内嵌播放视图的平台:不拉整档,直接说明。
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('该平台暂不支持视频播放')));
      return;
    }
    setState(() => _fetching = true);
    widget.onStartPlayback(this); // 完成回投 onDownloaded;失败弹 snack
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive
    final path = _localPath;
    if (path != null) {
      return EmbeddedVideoPlayer(
        path: path,
        active: widget.active,
        player: widget.player,
        viewBuilder: widget.viewBuilder,
        fullscreen: widget.fullscreen,
        onToggleFullscreen: widget.onToggleFullscreen,
        autoplay: true, // 点播放钮已是意图:装载即起播
      );
    }
    // 海报 + 播放钮(浮层在 InteractiveViewer 之外:不随缩放/拖动移位);
    // 拉取中转菊花防重复点(进度在宿主对话框里)。
    return Stack(
      alignment: Alignment.center,
      children: [
        widget.poster,
        Material(
          color: AppMedia.onMediaDim,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _fetching ? null : _startPlayback,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _fetching
                  ? const SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: AppMedia.onMedia),
                    )
                  : const Icon(Icons.play_arrow,
                      color: AppMedia.onMedia, size: 48),
            ),
          ),
        ),
      ],
    );
  }
}

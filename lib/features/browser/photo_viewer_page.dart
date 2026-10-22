/// 大图预览:PageView 左右滑 + 双指缩放;底部单「下载」钮,点按换出
/// 到相册/到应用双目的地(翻页/入队完成复位);顶栏打星(本地评分,
/// 1-5 星/清除)。
///
/// 下载全程不弹格式面板:单格式组与视频直接整组;双格式(RAW+JPG)
/// 组按相册页筛选弹层预定的下载格式([PhotoViewerPage.downloadFormat])
/// 收集 —— 仅 JPG/仅 RAW 取该格式,null(全部)= 整组 JPG+RAW 全要。
/// 预览走 ThumbnailCache preview 档的**小图先显 +
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
import '../../core/ptp/ptp_session.dart';
import '../../core/browser/photo_group.dart';
import '../../core/browser/thumbnail_cache.dart';
import '../../core/ptpip/object_format.dart' show ObjectKind;
import '../transfers/transfers_page.dart';
import '../../core/transfer/object_downloader.dart';
import '../../core/transfer/transfer_engine.dart';
import '../../core/transfer/transfer_task.dart';
import '../../design/app_colors.dart';
import '../../l10n/l10n.dart';
import '../../platform/gallery_saver.dart';
import '../../platform/services.dart';
import '../../platform/video_player.dart';
import '../common/format.dart';
import '../common/widgets/de_squeezed_image.dart';
import '../common/widgets/embedded_video_player.dart';
import '../common/widgets/loading_overlay.dart';
import '../common/widgets/photo_info_sheet.dart';
import '../edit/edit_page.dart';
import 'album_ratings_controller.dart';

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
    this.session,
    this.onOpenTransfers,
    this.downloadFormat,
  });

  final List<PhotoGroup> items;
  final int initialIndex;

  /// 相册页筛选弹层预定的下载格式(仅 JPG/仅 RAW;null = 全部:整组
  /// 直接下,JPG+RAW 全要)。非 null 时按该格式收集,组内缺该格式提示
  /// 不下。网格显示不受影响,仅下载口径跟随相册页筛选。
  final PhotoDownloadFormat? downloadFormat;

  /// 测试注入;缺省用 AppServices 单例。
  final ThumbnailCache? thumbnails;

  /// 测试注入;缺省用 AppServices 单例。
  final TransferEngine? engine;

  /// 测试注入;缺省用 AppServices 单例(与网格页共享同一评分状态;
  /// 真源 = 相机 MTP 0xDC8A)。
  final AlbumRatingsController? ratings;

  /// 测试注入(编辑:拉原图;视频:拉临时档);缺省用 AppServices 单例。
  final ObjectDownloader? downloader;

  /// 测试注入(编辑:导出相册);缺省平台通道。
  final GallerySaver? gallery;

  /// 测试注入(视频播放);缺省平台通道。
  final VideoPlayer? videoPlayer;

  /// 测试注入(视频页内嵌视图);缺省 iOS 平台视图。仅在
  /// [VideoPlayer.supportsEmbeddedView] 为真时被构建。
  final EmbeddedVideoViewBuilder? embeddedVideoView;

  /// 测试注入(保护标记 0x1012);缺省 AppServices 遥控会话。
  /// 相机侧文件保护,断连时点按失败走 SnackBar。
  final PtpSession? session;

  /// 下载 SnackBar 的「查看进度」动作注入(测试;AppServices 里的传输
  /// 控制器在裸测试树不可建)。null = 默认推 TransfersPage(生产)。
  final VoidCallback? onOpenTransfers;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  /// 底栏两段式下载:「下载」钮点按后换出「到相册/到应用」双目的地;
  /// 翻页沿与入队完成沿复位(下张照片重新从「下载」起)。
  bool _revealDownload = false;

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
  AlbumRatingsController get _ratings =>
      widget.ratings ?? AppServices.instance.ratings;
  ObjectDownloader get _downloader =>
      widget.downloader ?? AppServices.instance.downloader;
  GallerySaver get _gallery => widget.gallery ?? PlatformServices.gallery;
  VideoPlayer get _videoPlayer =>
      widget.videoPlayer ?? PlatformServices.videoPlayer;
  PtpSession get _session =>
      widget.session ?? AppServices.instance.remoteController.session;

  /// 保护态显示(会话乐观 Map 优先,ObjectInfo 真值兜底):Map 记本会话
  /// 的写入与读回(0x1012 无应答读回);列表基线 = ObjectInfo 的
  /// ProtectionStatus(重列即新)。
  bool _isProtected(PhotoGroup group) {
    final handle = group.primary.handle;
    return _session.protectionOptimistic[handle] ?? group.primary.isProtected;
  }

  /// 本页发出的保护写代数(读回在途时用户写入 → 代际不符丢弃)。
  int _protectWrites = 0;

  /// 开页/翻页沿读真实保护态(GetObjectInfo 0x1008,ProtectionStatus
  /// 定长头 @6):0x9803 读回在 Zf 上不在册;相册列表的 0x9805 批量路
  /// 实测不带该字段(2026-10-16 真机:断开重连后仍显未锁)—— 逐对象
  /// GetObjectInfo 是唯一在册真值源(整个浏览器都靠它)。读回写会话
  /// 乐观 Map(读写同账);失败(旧机身拒/无会话)静默保持现状。
  void _readProtectState(PhotoGroup group) {
    final handle = group.primary.handle;
    final gen = _protectWrites;
    unawaited(() async {
      try {
        final info = await _session.getObjectInfo(handle);
        if (!mounted || gen != _protectWrites) return;
        final value = info.protectionStatus;
        if (value != 0 && value != 1) return; // 未知值不猜
        if (_session.protectionOptimistic[handle] == (value == 1)) return;
        setState(() => _session.protectionOptimistic[handle] = value == 1);
      } on Exception {
        // 读回失败:保持现状(下页翻回再试)
      } on Object catch (e) {
        // 意外(Error 类:无会话测试桩等)尽力而为,不挡查看
        debugPrint('[查看器] 保护态读回失败 0x${handle.toRadixString(16)}: $e');
      }
    }());
  }

  /// 保护标记开关(2026-10-12 官方 §6.2.1.14:SetObjectProtection 0x1012,
  /// 参数 [句柄, 0x0000 不保护/0x0001 只读];SDRAM/目录对象会被拒)。
  /// 失败 SnackBar 指路(断链/卡写保护是常见因)。
  Future<void> _toggleProtect(PhotoGroup group) async {
    final handle = group.primary.handle;
    final protect = !_isProtected(group);
    _protectWrites++; // 在途读回代际作废:用户的写优先于旧读回
    try {
      await _session.setObjectProtection(handle, protect: protect);
      if (!mounted) return;
      setState(() => _session.protectionOptimistic[handle] = protect);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(protect ? context.t('viewer.protected') : context.t('viewer.unprotected')),
          duration: const Duration(seconds: 2)));
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.t('viewer.protectFailed', {'e': e})),
          duration: const Duration(seconds: 3)));
    }
  }

  @override
  void initState() {
    super.initState();
    _warmCurrent();
    _readProtectState(widget.items[_index]);
    // 当前组评级即时补读(后台补读未到的先拉,已问过空转)。
    _ratings.ensure(widget.items[_index]);
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

  /// 打星面板:1-5 星 + 清除评分(0)。乐观上屏由仓库负责;写相机
  /// 失败(链路断/相机拒)回滚后 SnackBar 提示。
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
                  context.t('viewer.rating'),
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
                        Navigator.of(context).pop();
                        _applyRating(group, stars);
                      },
                      icon: const Icon(Icons.star),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: Text(context.t('viewer.clearRating')),
              onTap: () {
                Navigator.of(context).pop();
                _applyRating(group, 0);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 打星落相机(0xDC8A):失败回滚由仓库负责,这里只提示。
  Future<void> _applyRating(PhotoGroup group, int stars) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _ratings.rate(group, stars);
    } on Object {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(context.t('viewer.ratingFail'))));
    }
  }

  /// 照片信息底单:文件级信息立显(名称/大小/连拍/时间),EXIF(机身/
  /// 镜头/参数/拍摄时间)走 64KB 头读懒加载 —— 优先组内 JPG(Zf 实证
  /// 头读形状),无 JPG 的 RAW 组走 NEF TIFF 头(同路);视频只走
  /// 第一段。
  void _showInfo(PhotoGroup group) {
    final pair = group.hasJpg && group.hasRaw;
    showPhotoInfoSheet(
      context,
      filename: pair ? '${group.jpg!.name} + ${group.raw!.name}' : group.name,
      sizeBytes: group.totalBytes,
      // 连拍张数(值列)在本页预翻译,信息底单只包行标签
      burstLabel:
          group.isBurst ? context.t('viewer.burstCount', {'n': group.shotCount}) : null,
      fallbackTime: formatDateTime(group.capturedAt),
      loadExif: group.isVideo
          ? null
          : () => _thumbnails.exifCardOf(group.jpg ?? group.primary),
    );
  }

  /// 下载:全程不弹格式面板 —— 筛选弹层预定格式(widget.downloadFormat
  /// 非 null)按该格式收集,组内缺该格式(纯 JPG 组 × 仅 RAW 等)提示
  /// 不下;null(全部)整组直接入队,双格式组 JPG+RAW 全要。
  Future<void> _download(
      PhotoGroup group, TransferDestination destination) async {
    var entries = group.members;
    final format = widget.downloadFormat;
    if (format != null) {
      entries = group.membersFor(format);
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(context.t('grid.noMatchNoDownload',
                  {'label': context.t(format.label)}))));
        return;
      }
    }
    await _engine.enqueue(entries, destination: destination);
    if (!mounted) {
      return;
    }
    setState(() => _revealDownload = false);
    // 目的地片段键「到相册/到应用」带介词(不立裸键「应用」,与网格页同;
    // 模板不写「到」—— 介词在片段里,中文拼回才与原串逐字一致)
    final where = destination == TransferDestination.gallery
        ? context.t('grid.toAlbum')
        : context.t('grid.toApp');
    final tag = format == null ? '' : '(${context.t(format.short)})';
    // Navigator 在展示时刻捕获(网格页同款):SnackBar 活得比本页久
    // (pop 后提示挂到上一页),届时 State 已 unmount,Navigator.of 会
    // 抛 defunct —— 捕获的根 Navigator 跨 pop 存活,窗口期内动作照常。
    final navigator = Navigator.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          // SDK #173084(2025-08)起带 action 的 SnackBar 默认 persist=
          // true 永不自动消失:显式关掉,恢复随 duration 自动隐藏。
          persist: false,
          content: Text(context.t(
              'viewer.downloadStarted', {'where': where, 'tag': tag})),
          action: SnackBarAction(
            label: context.t('viewer.viewProgress'),
            onPressed: widget.onOpenTransfers ??
                () => navigator.push(MaterialPageRoute<void>(
                    builder: (_) => const TransfersPage())),
          )));
  }

  /// 编辑:拉取组内 JPG 原图到临时目录(相机会话串行,排队即得),
  /// 读字节后即删原件;编辑产物走相册导入,不在临时目录留档。
  Future<void> _edit(PhotoGroup group) async {
    final jpg = group.jpg;
    if (jpg == null) return;
    unawaited(showLoadingOverlay(context, message: context.t('viewer.fetchingOriginal')));
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
        ..showSnackBar(SnackBar(content: Text(context.t('viewer.fetchFailed'))));
    }
  }

  /// 播放视频:整档下载到临时目录(进度对话框,可取消)→ **页内**
  /// 内嵌播放(EmbeddedVideoPlayer,与图库查看器同款)。PTP 相机没有
  /// 流式播放(Nikon moov 原子位置未验,亦无 HTTP range 语义),大文件
  /// 需等下载;取消 = 删半成品。临时档随视频页存活(翻回不重拉),
  /// 页面销毁(查看器关闭)时交给 [_PlayedVideoCache] 会话级持有
  /// (容量 2 LRU,翻回/重开查看器秒开;驱逐时才删)。
  Future<void> _startPlayback(_CameraVideoPageState page) async {
    final video = page.widget.group.movie;
    if (video == null) return;
    final key = _PlayedVideoCache.keyOf(video.name, video.sizeInBytes);
    final cached = _PlayedVideoCache.instance.get(key);
    if (cached != null) {
      page.onDownloaded(cached); // 会话内播过:秒开,不进下载
      return;
    }
    final cancel = _DownloadCancel();
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _VideoDownloadDialog(totalBytes: video.sizeInBytes, cancel: cancel),
    ));
    ObjectDownload? dl;
    try {
      dl = await _downloader.download(video,
          targetDir: await _gallery.tempDir(),
          onProgress: (received) => cancel.progress.value = received,
          isCancelled: () => cancel.cancelled);
    } on DownloadCancelledException {
      _closeDialog();
      _snack('common.cancelled');
      page.onFetchFailed(); // 播放钮复位(可再点)
      return;
    } on Exception {
      _closeDialog();
      _snack('viewer.videoLoadFailed');
      page.onFetchFailed(); // 同上:不留卡死的菊花
      return;
    }
    _closeDialog();
    if (!mounted) {
      unawaited(_deleteQuietly(dl.path)); // 页面已走:临时档直接清
      return;
    }
    _PlayedVideoCache.instance.put(key, dl.path);
    page.onDownloaded(dl.path);
  }

  void _closeDialog() {
    if (mounted) {
      Navigator.of(context).pop(); // 进度对话框
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    // 显示点收口包 t():调用方传中文原文键(await 后语境,mounted 检查
    // 内取译文,不跨异步用 context)
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.t(message))));
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
                    IconButton(
                      tooltip: context.t('info.title'),
                      onPressed: () => _showInfo(group),
                      icon: const Icon(Icons.info_outline),
                    ),
                    IconButton(
                      tooltip: _isProtected(group)
                          ? context.t('viewer.unprotect')
                          : context.t('viewer.protect'),
                      onPressed: () => _toggleProtect(group),
                      icon: Icon(
                        _isProtected(group)
                            ? Icons.lock
                            : Icons.lock_outline,
                      ),
                    ),
                    if (group.hasJpg)
                      IconButton(
                        tooltip: context.t('viewer.edit'),
                        onPressed: () => _edit(group),
                        icon: const Icon(Icons.tune),
                      ),
                    IconButton(
                      tooltip: context.t('viewer.rating'),
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
              setState(() {
                _index = i;
                _revealDownload = false; // 翻页复位两段式下载
              });
              _warmCurrent();
              _readProtectState(widget.items[i]);
              _ratings.ensure(widget.items[i]); // 评级即时补读
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
      if (group.isBurst) context.t('viewer.burstCount', {'n': group.shotCount}),
      if (formatDateTime(group.capturedAt) != null)
        formatDateTime(group.capturedAt)!,
      if (group.isVideo) context.t('common.video'),
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
                style:
                    const TextStyle(color: AppMedia.onMediaMuted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (!_revealDownload)
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppMedia.onMediaDim,
                          foregroundColor: AppMedia.onMedia,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            setState(() => _revealDownload = true),
                        icon: const Icon(Icons.download_outlined),
                        label: Text(context.t('grid.download')),
                      ),
                    )
                  else ...[
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
                        label: Text(context.t('grid.downloadToAlbum')),
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
                        label: Text(context.t('grid.downloadToApp')),
                      ),
                    ),
                  ],
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
                  isVideo ? Icons.movie_outlined : Icons.broken_image_outlined,
                  color: AppMedia.onMediaSubtle,
                  size: 48,
                ),
              ),
            ),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppMedia.onMedia),
              const SizedBox(height: 12),
              Text(context.t('viewer.loadingPreview'),
                  style: const TextStyle(color: AppMedia.onMediaMuted)),
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
              context.t(isVideo ? 'viewer.tapPlay' : 'viewer.previewUnavailable'),
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

/// 播放过的临时视频缓存(应用会话级 LRU-2,内容键 → 临时路径):
/// 相机相册视频的整档下载是首次播放的固有代价(PTP 无流式),翻回/
/// 重开查看器不再重拉 —— 秒开。超容量驱逐删档;系统回收临时目录的
/// 情形在命中时 existsSync 校验(缺档当未命中)。
final class _PlayedVideoCache {
  _PlayedVideoCache._();
  static final _PlayedVideoCache instance = _PlayedVideoCache._();

  final Map<String, String> _entries = {}; // LinkedHashMap:插入序 = LRU 序
  static const _capacity = 2;

  /// 内容键(与缩略缓存同构:文件名去非法字符 + 字节数)。
  static String keyOf(String name, int sizeInBytes) =>
      '${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}_$sizeInBytes';

  String? get(String key) {
    final path = _entries.remove(key);
    if (path == null) return null;
    if (!File(path).existsSync()) return null; // 系统已回收:当未命中
    _entries[key] = path; // 刷到 LRU 最新端
    return path;
  }

  void put(String key, String path) {
    final old = _entries.remove(key);
    if (old != null && old != path) _delete(old);
    _entries[key] = path;
    while (_entries.length > _capacity) {
      _delete(_entries.remove(_entries.keys.first)!);
    }
  }

  /// 该键当前是否持有 [path](视频页 dispose 决定删不删临时档用)。
  bool holds(String key, String path) => _entries[key] == path;

  void _delete(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // 盘上已无:索引已清即可
    }
  }
}

/// 视频播放准备进度对话框:进度条 + 已收/总量 + 取消(置位后下载层删
/// 半成品抛 DownloadCancelledException,对话框由 _startPlayback 收口)。
/// 文案按播放口径(「准备播放」)—— 整档拉取是 PTP 无流式的代价,
/// 不是一次「下载」操作(2026-10-09 复报「点击视频是下载」)。
class _VideoDownloadDialog extends StatelessWidget {
  const _VideoDownloadDialog({required this.totalBytes, required this.cancel});

  final int totalBytes;
  final _DownloadCancel cancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('viewer.preparingPlay')),
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
          child: Text(context.t('common.cancel')),
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
      final video = widget.group.movie;
      final held = video != null &&
          _PlayedVideoCache.instance.holds(
              _PlayedVideoCache.keyOf(video.name, video.sizeInBytes), path);
      if (!held) {
        unawaited(_deleteQuietly(path)); // 未进会话缓存(取消/失败残留):清
      }
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
        ..showSnackBar(SnackBar(content: Text(context.t('viewer.videoUnsupported'))));
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

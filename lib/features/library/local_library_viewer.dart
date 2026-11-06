part of 'local_library_page.dart';

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
    this.heroTag,
    this.heroThumbPath,
    this.heroImage,
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

  /// 渐进放大动效配对(网格页点格沿传入,见 hero_zoom.dart):初始页
  /// 挂同 tag 的 HeroZoom,航班图源 = 格缩略。三者同给同缺;[heroTag]
  /// 为空 = 无动效(降级普通转场)。
  final Object? heroTag;

  /// 格缩略盘档路径(动效梭子图源与初始页垫底)。
  final String? heroThumbPath;

  /// 格缩略的 300px 缓存命中提供器([gridThumbImageProvider])。
  final ImageProvider<Object>? heroImage;

  @override
  State<_LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<_LibraryViewer>
    with TickerProviderStateMixin {
  late final List<File> _files = List.of(widget.files);
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  /// 下拉跟手返回(缩放态/全屏不启用,见 _onPullStart)。
  /// initState 现建(同相机侧,弃内联惰性)。
  late final PullAwayController _pull;

  /// InteractiveViewer 缩放态(缩放中纵向平移归 IV,跟手闸关)。
  bool _ivZoomed = false;

  /// LUT 导出宿主与支持位:探测异步落位前不显示入口(ohos 无实现
  /// → 永 false,入口不出现)。
  late final VideoLutExportHost _videoLut =
      widget.videoLutExport ?? MethodChannelVideoLutExport();
  bool? _lutSupported;

  /// 打开时的解码缓存预算(dispose 还原):查看器语境的临时抬升,
  /// 不动全局默认。
  late final int _cacheBudgetRestore;

  // ── 下拉跟手返回(图片页)──

  /// 单页真实缩放态:放大期间禁翻页/下拉,手势全交给缩放层。
  void _onPageZoomChanged(bool zoomed) {
    if (_ivZoomed == zoomed || !mounted) return;
    setState(() => _ivZoomed = zoomed);
  }

  void _onPullStart(DragStartDetails details) {
    if (_fullscreen || _ivZoomed) return;
    _pull.beginDrag();
  }

  void _onPullUpdate(DragUpdateDetails details) {
    if (_fullscreen || _ivZoomed) return;
    _pull.update(_pull.dy + details.delta.dy);
  }

  void _onPullEnd(DragEndDetails details) {
    if (_fullscreen || _ivZoomed) return;
    final vy = details.velocity.pixelsPerSecond.dy;
    final commit =
        _pull.dy >= kPullAwayCommitDistance || vy >= kPullAwayCommitVelocity;
    if (commit) {
      // 位移冻结在释放位:初始页 Hero 以拖拽后的绘制位为起点飞回格位
      // (绘制变换进入框架实测;非初始页无配对,普通淡出收场)。
      Navigator.of(context).pop();
    } else {
      _pull.settleBack();
    }
  }

  @override
  void initState() {
    super.initState();
    _pull = PullAwayController(vsync: this); // initState 现建(弃内联惰性)
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
    _pull.dispose();
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
    final fresh = _decodeWithFallback(file);
    _decodes[key] = fresh;
    while (_decodes.length > _decodeCacheLimit) {
      _decodes.remove(_decodes.keys.first); // LinkedHashMap 首位 = 最旧
    }
    return fresh;
  }

  /// 原生解码,NEF 失败回内嵌缩略兜底:无原生 RAW 解码器平台(ohos/
  /// Android,`zpill/raw` 缺席或扩展名闸拒绝)查看 NEF 不再死在
  /// 「解码失败」—— 回 IFD0 内嵌 160×120 缩略([nefEmbeddedJpeg]:
  /// 方向注入 + 黑边裁剪,与网格缩略同源同质;撑满全屏糊,可看而不够
  /// 清晰,真清晰仍须原生 RAW 解码器,见 raw_decoder.dart 库注)。非
  /// RAW(HIF 解码失败等)或无内嵌缩略原样上抛,报错占位不变。
  Future<Uint8List> _decodeWithFallback(File file) async {
    try {
      return await widget.rawDecoder.decodeJpeg(file.path, maxPixelSize: 2560);
    } on Object {
      if (isHeifFilename(_nameOf(file))) {
        // 容器等无 HEIF 解码:HIF 读伴生预览(传输完成沿抓的相机 JPEG,
        // ~1024px 预览画质);无伴生(旧档/抓取失败)原样上抛报错占位。
        // 键与页面态 _contentKey 同式(安全名_字节数)。
        try {
          final name = _nameOf(file);
          final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final key = '${safe}_${file.lengthSync()}';
          final dir = await widget.gallery.thumbsDir();
          final bytes = await File('$dir/libv5_$key.jpg').readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        } on Object {
          // 落到底:原样上抛
        }
      }
      if (!isRawFilename(_nameOf(file))) rethrow;
      // 网格升级档优先(libv5hi_ = LibRaw 512 真解码,比内嵌 160×120
      // 清晰):LibRaw 大图解码失败时多半 512 档也失败,但升级档在场
      // 就用。无升级档回内嵌缩略装配(方向注入 + 黑边裁剪)。
      try {
        final name = _nameOf(file);
        final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final key = '${safe}_${file.lengthSync()}';
        final dir = await widget.gallery.thumbsDir();
        return await File('$dir/libv5hi_$key.jpg').readAsBytes();
      } on Object {
        // 无升级档:落回内嵌缩略
      }
      final jpeg = await nefEmbeddedJpeg(file.path);
      if (jpeg == null) rethrow;
      return jpeg;
    }
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
    // 查看器顶栏(下拉跟手沿 PullAwayFade 渐隐;PreferredSize 适配
    // Scaffold appBar 的尺寸契约)。
    final viewerBar = AppBar(
      backgroundColor: AppMedia.chrome,
      foregroundColor: AppMedia.onMedia,
      title:
          Text(_nameOf(_current), maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: context.t('info.title'),
          onPressed: () => _showInfo(_current),
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: context.t('common.share'),
          onPressed: _share,
          icon: const Icon(Icons.share_outlined),
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
    );
    return Scaffold(
      backgroundColor: AppMedia.background,
      // 全屏收顶栏:视频页撑满(同一平台视图转横),照片页无顶栏照看;
      // 下拉跟手沿 PullAwayFade 渐隐。
      appBar: _fullscreen
          ? null
          : PreferredSize(
              preferredSize: viewerBar.preferredSize,
              child: PullAwayFade(controller: _pull, child: viewerBar),
            ),
      body: GestureDetector(
        // 下拉跟手返回(闸见 _onPullStart)。垂直识别器只认
        // 纵向,水平翻页归 PageView;缩放态归 InteractiveViewer。
        onVerticalDragStart: _ivZoomed ? null : _onPullStart,
        onVerticalDragUpdate: _ivZoomed ? null : _onPullUpdate,
        onVerticalDragEnd: _ivZoomed ? null : _onPullEnd,
        child: PullAwayTransform(
          controller: _pull,
          child: PageView.builder(
            controller: _pageController,
            physics: _ivZoomed
                ? const NeverScrollableScrollPhysics()
                : null,
            itemCount: _files.length,
            onPageChanged: (i) {
              setState(() {
                _index = i;
                _ivZoomed = false; // 翻页复位缩放闸
              });
              _warmNeighbors(); // 新当前页的两侧邻居提前解码(翻页不黑闪)
              // 全屏是视频语境:滑到非视频页自动退出(还原方向与顶栏)
              if (_fullscreen && !isVideoFilename(_nameOf(_files[i]))) {
                _setFullscreen(false);
              }
            },
            itemBuilder: (_, i) => _page(_files[i],
                active: i == _index, isInitial: i == widget.initialIndex),
          ),
        ),
      ),
    );
  }

  Widget _page(File file, {required bool active, bool isInitial = false}) {
    final name = _nameOf(file);
    // 渐进放大动效只在初始页挂 HeroZoom(其余页无此 tag,翻页后收查看
    // 器无航班,自然回落普通转场)。aspectBox(图片/海报显示盒)= hero
    // 盒即图片 contain 显示位 —— 框架航班终点追踪 toHero 盒原点,盒必须
    // 是显示位本身,落点才不错位;视频页整页包(控制浮层不进显示盒,
    // 收程落点随海报盒,既有行为)。
    final hero = isInitial &&
        widget.heroTag != null &&
        widget.heroImage != null &&
        widget.heroThumbPath != null;
    Widget zoomHero(Widget child,
            {bool aspectBox = false, String? imagePath}) =>
        hero
            ? HeroZoom(
                tag: widget.heroTag!,
                thumbPath: widget.heroThumbPath!,
                imagePath: imagePath,
                deSqueeze:
                    AppServices.instance.settingsController.value.deSqueeze,
                aspectBox: aspectBox,
                child: child,
              )
            : child;
    if (isVideoFilename(name)) {
      // 动效锚:海报显示位上挂透明 Hero(aspectBox 盒 = 海报 contain
      // 显示位);可见海报层铺满(contain 绘制)同位,航班落点即显示位,
      // 收梭子无缝。播放控制浮层等兄弟层保持整页,不受显示盒约束。
      Widget? heroAnchor;
      if (hero) {
        heroAnchor = HeroZoom(
          tag: widget.heroTag!,
          thumbPath: widget.heroThumbPath!,
          aspectBox: true,
          child: const SizedBox.shrink(),
        );
      }
      if (widget.videoPlayer.supportsEmbeddedView) {
        return EmbeddedVideoPlayer(
          path: file.path,
          active: active,
          player: widget.videoPlayer,
          viewBuilder: widget.embeddedVideoView ?? embeddedVideoViewBuilder,
          fullscreen: _fullscreen,
          onToggleFullscreen: () => _setFullscreen(!_fullscreen),
          poster: Stack(fit: StackFit.expand, children: [
            _VideoPoster(file: file, thumbFor: widget.thumbFor),
            if (heroAnchor != null) Align(child: heroAnchor),
          ]),
        );
      }
      return _VideoPlayPage(
        file: file,
        thumbFor: widget.thumbFor,
        player: widget.videoPlayer,
        heroAnchor: heroAnchor,
      );
    }
    if (isRawFilename(name) || isHeifFilename(name)) {
      // HIF 与 NEF 同走原生解码通道(≤2560,会话缓存):iOS ImageIO /
      // ohos image kit 都不吃引擎直解 HEIF 的兜底,统一走 decodeJpeg。
      return ZoomablePage(
        active: active,
        onZoomChanged: _onPageZoomChanged,
        child: Center(
          child: zoomHero(
            // 300px 档垫底(缓存命中即显):航班收梭子沿原生大图解码未
            // 回、缩略垫层自身读档也未上屏的空窗不闪黑(真机复报「HIF/
            // RAW 放大后黑屏闪一下」根因);两层解码产物到后原位盖过。
            hero
                ? Stack(fit: StackFit.expand, children: [
                    Image(
                      image: widget.heroImage!,
                      // 与航班梭子同 cover:落点收梭子时缩略层不换 fit,
                      // 避免 contain/cover 切换造成「突然缩小」。
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                    _nativeBody(file),
                  ])
                : _nativeBody(file),
            aspectBox: true,
            imagePath: file.path,
          ),
        ),
      );
    }
    if (_isViewableName(name)) {
      return ZoomablePage(
        active: active,
        onZoomChanged: _onPageZoomChanged,
        child: Center(
          child: zoomHero(
            // 缩略垫底:全幅解码完成前顶黑底(航班落点即同图不闪白),
            // 解码完成原位盖过。显示盒内两源同比,contain 即满铺。
            hero
                ? Stack(fit: StackFit.expand, children: [
                    Image(
                      image: widget.heroImage!,
                      // 与航班梭子同 cover:落点收梭子时缩略层不换 fit,
                      // 避免 contain/cover 切换造成「突然缩小」。
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                    _imageBody(file),
                  ])
                : _imageBody(file),
            aspectBox: true,
            imagePath: file.path,
          ),
        ),
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
          // 缩略图常驻垫底、原生大图就位后原位盖上 —— 换子树会出空帧,
          // HIF 读档时表现为「模糊→闪一下→清晰」。无缩略(深链冷启)
          // 才转圈。
          return FutureBuilder<String?>(
            future: widget.thumbFor(file),
            builder: (context, thumbSnap) {
              final path = thumbSnap.hasData ? thumbSnap.data : null;
              final Widget thumb = path != null
                  ? Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    )
                  : (snap.hasData
                      ? const SizedBox.shrink()
                      : const CircularProgressIndicator());
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
              if (!snap.hasData) return thumb;
              return Stack(fit: StackFit.expand, children: [
                thumb,
                DeSqueezedImage(
                  image: MemoryImage(snap.data!),
                  deSqueeze:
                      AppServices.instance.settingsController.value.deSqueeze,
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.broken_image_outlined,
                    color: AppMedia.onMediaSubtle,
                    size: 48,
                  ),
                ),
              ]);
            },
          );
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
    if (imported) {
      _showSaveCard(context, context.t('libpage.importedAlbum'));
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(context.t('libpage.notImported'))));
    }
  }

  /// 系统分享当前文件(native 面板;失败只提示,不影响图库)。
  Future<void> _share() async {
    final host = widget.gallery;
    if (host is! ShareHost) {
      _toastKey('common.shareFailed');
      return;
    }
    try {
      await (host as ShareHost).shareFiles([_current.path]);
    } on Exception {
      if (!mounted) return;
      _toastKey('common.shareFailed');
    }
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
      // ohos:createAsset 落库时系统自己弹「已保存」提示,
      // 我们的 SnackBar 叠上去是重复提示 → 成功态留系统卡,只报失败。
      toast = uris.isNotEmpty
          ? (Platform.operatingSystem == 'ohos' ? '' : 'libpage.savedToAlbum')
          : 'libpage.notImported';
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
        if (toast == 'libpage.savedToAlbum') {
          _showSaveCard(context, context.t(toast));
        } else {
          _toastKey(toast);
        }
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
    this.heroAnchor,
  });

  final File file;

  /// 海报帧缓存查询(与网格格共用,不重复抽帧)。
  final Future<String?> Function(File file) thumbFor;

  final VideoPlayer player;

  /// 动效锚(初始页且格缩略就绪时传入):海报显示位上的透明 Hero
  /// (aspectBox 盒),铺在海报层之上、播放钮之下。
  final Widget? heroAnchor;

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
        // 动效锚(海报显示位上的透明 Hero;海报 contain 绘制同位)。
        if (widget.heroAnchor != null) Align(child: widget.heroAnchor!),
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
                child:
                    Icon(Icons.play_arrow, color: AppMedia.onMedia, size: 48),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// NEF 升级档换图通知(libv5hi_ 落盘沿 fire;网格 ListenableBuilder
/// 合并监听,重建沿 _thumbFor 重查换 hi 档)。裸 ChangeNotifier 的
/// notifyListeners 是 protected,子类包一层。
class _ThumbUpgrades extends ChangeNotifier {
  void fire() => notifyListeners();
}

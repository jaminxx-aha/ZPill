/// 查看器视频页共用件(图库本地档 + 相机相册临时档同用):iOS 内嵌
/// 平台视图在页面里播放。
///
/// 播放控制在 Flutter 侧自绘(AVKit 传输条关掉,原生侧无触摸诉求:
/// 裸视频面上盖一层点按层收点按/唤回浮层 —— 点按层必须**盖在**平台
/// 视图上而非包在其外,直接落在平台视图上的 tap 在抬手结算时竞争不过
/// 原生视图,见 build 注释;横滑归 PageView 翻页,进度条是 Flutter
/// 件叠在上面不经过平台视图)。高帧率(>30.5fps)素材浮
/// 「24fps 顺帧」开关:非阻塞,点了才变速静音(顺帧是可选增强,不拦
/// 起播)。[active] = 页为当前页(翻页 settle)才起播,滑走即暂停。
/// 起播意图:图库路径 [autoplay] = false(2026-10-09 复报改:点开
/// **不自动播**,首帧 + 播放钮常驻,点了才起播);相机路径下载完成
/// 后以 autoplay = true 装载(用户点播放钮即是意图)。
///
/// 全屏走 [fullscreen]/[onToggleFullscreen](查看器**原地旋转**,同一
/// 播放器:平台视图不能搬家,但查看器自身布局可以 —— 锁横屏 + 沉浸
/// + 收 AppBar,同一 UiKitView 随布局转横零跳变);本页只换角钮图样。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design/app_colors.dart';
import '../../../platform/video_player.dart';

/// 顺帧门槛:标称帧率高于此值才算高帧率素材(30 与 29.97 都不算)。
const double kConformFpsGate = 30.5;

/// 顺帧目标帧率(24fps 影视口径)。
const double kConformTargetFps = 24;

class EmbeddedVideoPlayer extends StatefulWidget {
  const EmbeddedVideoPlayer({
    super.key,
    required this.path,
    required this.active,
    required this.player,
    required this.viewBuilder,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.autoplay = false,
  });

  /// 本地档案路径(图库 = 应用内文件;相机相册 = 临时目录下载件)。
  final String path;

  /// 页为当前页(翻页 settle)才起播,滑走即暂停。
  final bool active;

  final VideoPlayer player;

  /// 内嵌视图构建(测试注入;生产 = iOS 平台视图)。
  final EmbeddedVideoViewBuilder viewBuilder;

  /// 查看器全屏态(原地旋转):角钮在 全屏/退出全屏 间切换。
  final bool fullscreen;

  /// 切换查看器全屏。
  final VoidCallback onToggleFullscreen;

  /// 装载即起播(相机路径:点播放钮下载完成后装载;图库默认 false:
  /// 点开不自动播)。
  final bool autoplay;

  @override
  State<EmbeddedVideoPlayer> createState() => _EmbeddedVideoPlayerState();
}

class _EmbeddedVideoPlayerState extends State<EmbeddedVideoPlayer> {
  static const _pollInterval = Duration(milliseconds: 250);
  static const _controlsHideDelay = Duration(seconds: 3);

  int? _viewId;
  double? _fps; // 标称帧率(未知/≤30.5 = 无顺帧开关)
  bool _conform = false;
  bool _controlsVisible = true;
  // 起播意图:autoplay/点播放才 true;暂停/播完跟随翻 false。滑走保持
  // 原意图,翻回继续(没点过播放的翻回仍停)。
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
    _playingIntent = widget.autoplay;
    _probeFps();
    if (widget.active) {
      _startPolling();
    }
  }

  @override
  void didUpdateWidget(EmbeddedVideoPlayer oldWidget) {
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
      final fps = await widget.player.frameRate(widget.path);
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
    await widget.player.loadEmbeddedView(viewId, widget.path);
    if (!mounted) return;
    _sync(); // 视图就位:按意图同步(默认暂停,autoplay/点了播放才起播)
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
        // 裸视频面(底层):平台视图本体。原生传输条关闭,原生侧没有
        // 任何需要触摸的东西。
        widget.viewBuilder(widget.path, _onViewCreated),
        // 点按层:必须**盖在**平台视图上(Stack 后位者画在上),不能
        // 包在它外面 —— 引擎对「直接落在平台视图上」的触摸走手势竞技场
        // 异步仲裁,父级 tap 识别器在抬手结算时竞争不过原生视图(拖动类
        // 手势越 slop 即抢先认领,所以横滑翻页一直是好的;tap 只在 up
        // 时结算 —— 2026-10-09 真机:浮层 3s 自动隐后点按唤不回,图库/
        // 相机相册同患)。盖上后走引擎的同步命中拦截:touchesBegan 起
        // 原生即被挡,触摸全归 Flutter(点按层只注册 tap,拖动越过 slop
        // 即弃权给 PageView 翻页)。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: const SizedBox.expand(),
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

/// 拍摄页(底部导航 tab):Live View 监看 + 快门释放 + 拍摄参数展示与调节。
///
/// PTP 操作:0x9201/0x9203/0x9202 取景三步(候选码,待真机核对)、
/// 快门码按相机 op 表选(在册 0x9207 直用,见 RemoteController.
/// [_fireShutter])、GetDevicePropDesc 0x1014 拍摄参数(可写性/取值域
/// 驱动调节控件;参数表见 [kShootingParams])。
/// SetDevicePropValue(0x1016)被 [PtpSession.kSetPropEnabled] 门禁 ——
/// 真机实证已开(2026-10-05);总闸紧急关断时调节入口静默只读。
/// 受机身拨盘控制的参数(快门)调节前弹「APP 接管控制」确认
/// (0x90C2 remote 模式,影控台同款;接管期间机身拨盘锁定)。
///
/// 对焦域(候选码,待真机核对):点取景画面 = 触控对焦(0x9205 移动
/// 对焦区域 + 0x90C1 驱动,对焦框回投);「对焦」按钮单独驱动;
/// 「对焦后拍」开关切快门 0x9207 的 CaptureSort 首参。
///
/// tab 模式:IndexedStack 常驻挂载,离开 tab([active] 变 false)即停
/// 取景(相机侧 Live View 高功耗,后台白白打链路)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/remote/frame_analysis.dart';
import '../../core/remote/live_view_engine.dart';
import '../../platform/motion_host.dart';
import '../../platform/services.dart';
import 'live_view_overlays.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, this.controller, this.active = true});

  final RemoteController? controller;

  /// tab 是否在前台(IndexedStack 常驻):false 时停取景。
  final bool active;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final RemoteController controller;

  // 监看辅助开关(页面级视图偏好,不入持久化设置)。
  bool _showGrid = false;
  bool _showZebra = false;
  bool _showHistogram = false;
  bool _showLevel = false;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
    controller.analyzer.enabled.addListener(_syncAnalyzerEnabled);
  }

  @override
  void didUpdateWidget(RemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切走 tab 即停取景(引擎单例持有,后台持续打链路不可取);
    // 切回不自动重启 —— 取景是显式动作。
    if (!widget.active && oldWidget.active && controller.liveViewActive) {
      unawaited(controller.toggleLiveView());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.analyzer.enabled.removeListener(_syncAnalyzerEnabled);
    // 离页即停取景:引擎归 AppServices 单例持有,不停会在后台持续打链路。
    if (controller.liveViewActive) {
      unawaited(controller.toggleLiveView());
    }
    super.dispose();
  }

  /// 斑马纹/直方图共享同一份帧分析:任一开启即启用分析器。
  void _syncAnalyzerEnabled() {
    if (controller.analyzer.enabled.value != (_showZebra || _showHistogram)) {
      controller.analyzer.enabled.value = _showZebra || _showHistogram;
    }
  }

  void _toggleAssist(void Function(bool) set, bool current) {
    setState(() => set(!current));
    _syncAnalyzerEnabled();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台停取景:相机侧 Live View 是高功耗状态,且 iOS/ohos 后台
    // 网络不保活(与下载页同款约束)。
    if (state == AppLifecycleState.paused && controller.liveViewActive) {
      unawaited(controller.toggleLiveView());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('拍摄')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            controller.engine.frame,
            controller.engine.status,
          ]),
          builder: (context, _) {
            return Column(
              children: [
                Expanded(child: _frameArea(context)),
                _assistToolbar(context),
                if (!controller.linkUp)
                  _banner(context, '未连接相机 —— 请先在「相机」页建立连接',
                      Colors.orange)
                else if (controller.error != null)
                  _banner(context, controller.error!, Colors.red),
                if (controller.notice != null)
                  _banner(context, controller.notice!, Colors.green),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      for (final p in kShootingParams.where((p) => p.prominent))
                        _bigParamChip(context, p),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  // 参数多了改横滚行(Wrap 会溢出);行尾挂「对焦后拍」
                  child: SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      children: [
                        for (final p
                            in kShootingParams.where((p) => !p.prominent))
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _smallParamChip(context, p),
                          ),
                        _focusBeforeCaptureChip(context),
                        _takeoverChip(context),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _liveViewToggle(context),
                      _focusButton(context),
                      _shutterButton(context),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _frameArea(BuildContext context) {
    final Uint8List? frame = controller.engine.frame.value;
    final status = controller.engine.status;
    return LayoutBuilder(builder: (context, constraints) {
      // 取景图像在画面里的实际显示矩形(BoxFit.contain 数学):
      // 点按坐标 → 归一化帧坐标、对焦框回投,共用这一份映射。
      final boxSize = constraints.biggest;
      final frameSize = controller.frameSize.value;
      Rect? imageRect;
      if (frameSize != null && frameSize.width > 0 && frameSize.height > 0) {
        final iw = frameSize.width.toDouble();
        final ih = frameSize.height.toDouble();
        final scale =
            boxSize.width / iw < boxSize.height / ih ? boxSize.width / iw : boxSize.height / ih;
        imageRect = Rect.fromLTWH((boxSize.width - iw * scale) / 2,
            (boxSize.height - ih * scale) / 2, iw * scale, ih * scale);
      }
      return GestureDetector(
        // 点按取景画面 = 触控对焦(无帧/未取景时控制器内静默忽略)
        onTapUp: (d) => _handleTapFocus(d, imageRect),
        child: Container(
          color: Colors.black,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (frame != null)
                Image.memory(frame, fit: BoxFit.contain,
                    gaplessPlayback: true) // 换帧不闪黑
              else
                Center(
                  child: Text(
                    status.value == LiveViewStatus.running
                        ? '取景中…(等待首帧)'
                        : status.value == LiveViewStatus.failed
                            ? '取景失败(${controller.engine.lastError ?? "未知错误"})'
                            : '取景已关闭\n开启「取景」查看实时画面\n点按画面可触控对焦',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              if (_showGrid)
                ValueListenableBuilder(
                  valueListenable: controller.analyzer.analysis,
                  builder: (context, FrameAnalysis? analysis, _) => GridOverlay(
                      aspect: analysis == null
                          ? null
                          : analysis.width / analysis.height),
                ),
              if (_showZebra)
                ValueListenableBuilder(
                  valueListenable: controller.analyzer.analysis,
                  builder: (context, FrameAnalysis? analysis, _) =>
                      ZebraOverlay(analysis: analysis),
                ),
              if (_showHistogram)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ValueListenableBuilder(
                      valueListenable: controller.analyzer.analysis,
                      builder: (context, FrameAnalysis? analysis, _) =>
                          HistogramView(analysis: analysis),
                    ),
                  ),
                ),
              if (_showLevel)
                StreamBuilder<MotionOrientation>(
                  stream: PlatformServices.motion.attitudes,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    return LevelOverlay(orientation: snapshot.data!);
                  },
                ),
              if (controller.afBox != null && imageRect != null)
                _afBoxOverlay(imageRect, controller.afBox!),
            ],
          ),
        ),
      );
    });
  }

  /// 点按 → 触控对焦:屏幕坐标经 contain 矩形归一化到取景帧坐标系。
  void _handleTapFocus(TapUpDetails d, Rect? imageRect) {
    if (imageRect == null) return;
    final nx = ((d.localPosition.dx - imageRect.left) / imageRect.width)
        .clamp(0.0, 1.0);
    final ny = ((d.localPosition.dy - imageRect.top) / imageRect.height)
        .clamp(0.0, 1.0);
    unawaited(controller.touchFocus(nx, ny));
  }

  /// 触控对焦框:位置回投 contain 矩形;尺寸是视觉占位(相机侧实际
  /// 对焦区域大小无从得知)。
  Widget _afBoxOverlay(Rect imageRect, AfBox box) {
    final side = imageRect.width * 0.18;
    return Positioned(
      left: imageRect.left + box.nx * imageRect.width - side / 2,
      top: imageRect.top + box.ny * imageRect.height - side / 2,
      width: side,
      height: side,
      child: const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.fromBorderSide(
                BorderSide(color: Color(0xFFFFC107), width: 2)),
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
      ),
    );
  }

  /// 监看辅助开关排:网格 / 斑马纹 / 直方图 / 水平仪。
  Widget _assistToolbar(BuildContext context) {
    Widget toggle(IconData icon, String label, bool current,
        void Function(bool) set) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              isSelected: current,
              onPressed: () => _toggleAssist(set, current),
              icon: Icon(icon),
              tooltip: label,
            ),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          toggle(Icons.grid_on, '网格', _showGrid, (v) => _showGrid = v),
          toggle(Icons.warning_amber, '斑马纹', _showZebra, (v) => _showZebra = v),
          toggle(Icons.bar_chart, '直方图', _showHistogram,
              (v) => _showHistogram = v),
          toggle(Icons.linear_scale, '水平仪', _showLevel, (v) => _showLevel = v),
        ],
      ),
    );
  }

  Widget _banner(BuildContext context, String text, Color color) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: color)),
    );
  }

  /// 曝光三要素大芯片(值 + 标签两行)。
  Widget _bigParamChip(BuildContext context, ShootingParam p) {
    final value = controller.paramProps[p.code]?.value;
    final writable = controller.propWritable(p.code);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: writable ? () => _editParam(context, p) : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                  color: writable ? Theme.of(context).colorScheme.primary
                      : Colors.grey),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text(p.label,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text(p.display(value),
                    style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 其余拍摄参数小芯片(标签 + 值单行,横滚行排布)。
  Widget _smallParamChip(BuildContext context, ShootingParam p) {
    final value = controller.paramProps[p.code]?.value;
    final writable = controller.propWritable(p.code);
    return InkWell(
      onTap: writable ? () => _editParam(context, p) : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(
              color: writable ? Theme.of(context).colorScheme.primary
                  : Colors.grey),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 4),
            Text(p.display(value), style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  /// 拍摄参数编辑面板:取值域 = 目录 pickValues 直供(快门:标准档
  /// 打包表)或相机 PropDesc 枚举;范围域 → 滑条;域未知 → 只读提示。
  /// 选中即写(0x1016)并按读码路由回读刷新,不额外确认 —— 相机侧可
  /// 随时再调。拨盘拥有参数(快门)先过「APP 接管控制」确认。
  Future<void> _editParam(BuildContext context, ShootingParam p) async {
    if (p.dialOwned && !controller.takeoverActive) {
      if (!await _confirmTakeover(context) || !context.mounted) return;
    }
    final state = controller.paramProps[p.code];
    final desc = state?.desc;
    final enums = p.pickValues ??
        desc?.enumValues?.whereType<int>().toList(growable: false);
    final rangeMin = desc?.rangeMin as int?;
    final rangeMax = desc?.rangeMax as int?;
    final rangeStep = desc?.rangeStep as int? ?? 1;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final current =
                controller.paramProps[p.code]?.value;
            final writing = controller.writing; // 写中防连点
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(p.label,
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: Colors.grey)),
                ),
                if (enums != null && enums.isNotEmpty)
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final v in enums)
                          ListTile(
                            title: Text(p.display(v)),
                            trailing: v == current
                                ? const Icon(Icons.check)
                                : null,
                            onTap: writing
                                ? null
                                : () {
                                    Navigator.of(sheetContext).pop();
                                    controller.setParam(p.code, v);
                                  },
                          ),
                      ],
                    ),
                  )
                else if (rangeMin != null &&
                    rangeMax != null &&
                    rangeMax > rangeMin &&
                    current != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      children: [
                        Text(p.display(current),
                            style: Theme.of(sheetContext)
                                .textTheme
                                .headlineSmall),
                        Slider(
                          value: (current.clamp(rangeMin, rangeMax))
                              .toDouble(),
                          min: rangeMin.toDouble(),
                          max: rangeMax.toDouble(),
                          divisions:
                              ((rangeMax - rangeMin) ~/ rangeStep).clamp(1, 1 << 20),
                          label: p.display(current),
                          onChanged: writing ? null : (_) {},
                          onChangeEnd: (v) =>
                              controller.setParam(p.code, v.round()),
                        ),
                      ],
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('该属性的取值域未知,暂不可调(待真机核对)'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 「启用 APP 接管控制」确认(影控台同款语义):受机身物理拨盘控制
  /// 的参数需先接管(0x90C2 remote 模式)才能遥控调整;接管期间机身
  /// 拨盘可能被锁定、机身屏幕可能熄灭。返回是否已接管(含已激活直通)。
  Future<bool> _confirmTakeover(BuildContext context) async {
    if (controller.takeoverActive) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('启用 APP 接管控制?'),
        content: const Text('该设置项受相机物理拨盘控制,启用接管后应用才能调整。'
            '接管期间机身拨盘可能被锁定、机身屏幕可能熄灭;'
            '点按「APP 接管中」或断开连接可解除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('启用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    return controller.enableTakeover();
  }

  /// APP 接管控制状态芯片:未接管 = 点按弹确认启用;已接管 = 点按解除
  /// (0x90C2 remote 模式;机身拨盘锁定,host 写入保值)。
  Widget _takeoverChip(BuildContext context) {
    final active = controller.takeoverActive;
    final color = active ? Colors.amber : Colors.grey;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: !controller.linkUp
            ? null
            : (active
                ? controller.releaseTakeover
                : () => _confirmTakeover(context)),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(active ? Icons.lock : Icons.lock_open,
                  size: 14, color: color),
              const SizedBox(width: 4),
              Text(active ? 'APP 接管中' : 'APP 接管',
                  style: TextStyle(fontSize: 13, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _liveViewToggle(BuildContext context) {
    final active = controller.liveViewActive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'liveview',
          onPressed: () => controller.toggleLiveView(),
          child: Icon(active ? Icons.videocam_off : Icons.videocam),
        ),
        const SizedBox(height: 4),
        Text(active ? '取景中' : '取景'),
      ],
    );
  }

  /// 对焦按钮:驱动一次自动对焦(0x90C1,候选码待真机核对;
  /// 取景开启是前置条件 —— 未开取景机身回 0xA00B)。
  Widget _focusButton(BuildContext context) {
    final usable = controller.linkUp && controller.liveViewActive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'focus',
          backgroundColor: usable ? null : Colors.grey,
          onPressed:
              usable && !controller.focusing ? controller.afDriveNow : null,
          child: controller.focusing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : const Icon(Icons.center_focus_strong),
        ),
        const SizedBox(height: 4),
        Text(controller.focusing ? '对焦中' : '对焦'),
      ],
    );
  }

  /// 「对焦后拍」开关:快门 0x9207 首参 CaptureSort —— 开 = 0xFFFFFFFE
  /// (先驱动 AF 再释放,OpenZCine 候选语义);关 = 0x0000(Zf 已实证)。
  Widget _focusBeforeCaptureChip(BuildContext context) {
    return Tooltip(
      message: '释放快门前先自动对焦(半按-全按;候选参数,待真机核对)',
      child: FilterChip(
        label: const Text('对焦后拍'),
        selected: controller.focusBeforeCapture,
        onSelected: (_) =>
            controller.focusBeforeCapture = !controller.focusBeforeCapture,
      ),
    );
  }

  Widget _shutterButton(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: FloatingActionButton(
            heroTag: 'shutter',
            backgroundColor: controller.linkUp ? null : Colors.grey,
            onPressed:
                controller.capturing || !controller.linkUp
                    ? null
                    : () => controller.capture(),
            child: controller.capturing
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Icon(Icons.photo_camera, size: 36),
          ),
        ),
        const SizedBox(height: 4),
        const Text('快门'),
      ],
    );
  }
}

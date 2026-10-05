/// 拍摄页(底部导航 tab):Live View 监看 + 快门释放 + 拍摄参数展示与调节。
///
/// PTP 操作:0x9201/0x9203/0x9202 取景三步(候选码,待真机核对)、
/// InitiateCapture 0x100E 快门、GetDevicePropDesc 0x1014 拍摄参数
/// (可写性/取值域驱动调节控件;参数表见 [kShootingParams])。
/// SetDevicePropValue(0x1016)被 [PtpSession.kSetPropEnabled] 门禁 ——
/// 真机核对前调节入口静默只读,翻开后台同一 UI 即可写。
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
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final p
                          in kShootingParams.where((p) => !p.prominent))
                        _smallParamChip(context, p),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _liveViewToggle(context),
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
    return Container(
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
                        : '取景已关闭\n开启「取景」查看实时画面',
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
        ],
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

  /// 其余拍摄参数小芯片(标签 + 值单行,Wrap 流式排布)。
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

  /// 拍摄参数编辑面板:枚举域 → 列表单选;范围域 → 滑条;域未知 → 只读
  /// 提示。选中即写(0x1016)并回读刷新,不额外确认 —— 相机侧可随时再调。
  Future<void> _editParam(BuildContext context, ShootingParam p) {
    final state = controller.paramProps[p.code];
    final desc = state?.desc;
    final enums =
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

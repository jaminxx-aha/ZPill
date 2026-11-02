import 'package:flutter/material.dart';

/// 查看器单页缩放层:统一处理「放大态」判定与双击缩放。
///
/// 旧实现只在 `onInteractionStart/End` 翻转 `_ivZoomed`,手势一松就
/// 复位 —— 放大后下一次横向拖拽仍会被外层 PageView 抢走翻页,纵向
/// 拖拽还会触发下拉返回。本组件把真实 scale 暴露给宿主,由宿主在放大
/// 期间禁用 PageView/下拉手势;翻页离开时自动复位。
class ZoomablePage extends StatefulWidget {
  const ZoomablePage({
    super.key,
    required this.child,
    required this.active,
    this.onZoomChanged,
    this.maxScale = 8,
  });

  final Widget child;

  /// 当前页是否可见;从可见变不可见时复位缩放(翻页回来是 1x)。
  final bool active;

  /// 真实缩放态(scale > 1.01 为 true)。
  final ValueChanged<bool>? onZoomChanged;

  final double maxScale;

  @override
  State<ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<ZoomablePage> {
  final TransformationController _controller = TransformationController();
  bool _zoomed = false;
  Offset _doubleTapAt = Offset.zero;

  double get _scale => _controller.value.getMaxScaleOnAxis();

  @override
  void didUpdateWidget(covariant ZoomablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _resetZoom();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _notifyZoomed(bool zoomed) {
    if (_zoomed == zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  void _resetZoom() {
    _controller.value = Matrix4.identity();
    if (!_zoomed) return;
    _zoomed = false;
    final callback = widget.onZoomChanged;
    if (callback == null) return;
    // 翻页离开时本组件在父级 build 中被更新,直接回调会触发
    // setState-during-build;下一帧再回传放大态。
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(false));
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    _notifyZoomed(_scale > 1.01);
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _notifyZoomed(_scale > 1.01);
  }

  void _toggleDoubleTap() {
    if (_scale > 1.01) {
      _resetZoom();
      return;
    }
    const target = 2.0;
    final p = _doubleTapAt;
    // 以双击点为中心放大:先把点移到原点,再缩放。
    _controller.value = Matrix4.identity()
      ..translateByDouble(-p.dx * (target - 1), -p.dy * (target - 1), 0, 1)
      ..scaleByDouble(target, target, target, 1);
    _notifyZoomed(true);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
      onDoubleTap: _toggleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        maxScale: widget.maxScale,
        onInteractionUpdate: _onInteractionUpdate,
        onInteractionEnd: _onInteractionEnd,
        child: widget.child,
      ),
    );
  }
}

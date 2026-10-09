/// 查看器变宽还原(anamorphic de-squeeze):按 [deSqueeze] 倍率水平
/// 拉伸 [image] 显示。精确矩形路线:ImageStream 解出自然宽高 →
/// AspectRatio(aspect = w·ds/h)定盒 → Image(fit: fill) 整格填满
/// —— 拉伸恰好等于 ds,不像「contain 后再 Transform.scale」会溢出
/// 屏盒。ds ≤ 1 直通 contain(零开销路径);解码未完/失败回 contain
/// 原样。[errorBuilder] 语义同 [Image.errorBuilder]。
library;

import 'package:flutter/material.dart';

class DeSqueezedImage extends StatefulWidget {
  const DeSqueezedImage({
    super.key,
    required this.image,
    required this.deSqueeze,
    this.errorBuilder,
  });

  final ImageProvider image;

  /// 水平还原倍率(设置页口径 1.0 = 关)。
  final double deSqueeze;

  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  State<DeSqueezedImage> createState() => _DeSqueezedImageState();
}

class _DeSqueezedImageState extends State<DeSqueezedImage> {
  ImageInfo? _info;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(DeSqueezedImage old) {
    super.didUpdateWidget(old);
    if (widget.image != old.image) _resolve();
  }

  @override
  void dispose() {
    _removeListener();
    super.dispose();
  }

  void _resolve() {
    _removeListener();
    final stream = widget.image.resolve(ImageConfiguration.empty);
    _stream = stream;
    _listener = ImageStreamListener(_onImage);
    stream.addListener(_listener!);
  }

  void _removeListener() {
    if (_listener != null) {
      _stream?.removeListener(_listener!);
    }
    _listener = null;
    _stream = null;
  }

  void _onImage(ImageInfo info, bool _) {
    if (!mounted) return;
    setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final ds = widget.deSqueeze;
    if (ds <= 1.0 || info == null || info.image.width <= 0) {
      // 关/未解出:普通 contain
      return Image(
        image: widget.image,
        fit: BoxFit.contain,
        errorBuilder: widget.errorBuilder,
        filterQuality: FilterQuality.medium,
      );
    }
    return AspectRatio(
      aspectRatio: info.image.width * ds / info.image.height,
      child: Image(
        image: widget.image,
        fit: BoxFit.fill, // 拉伸恰好 = ds(AspectRatio 定的盒)
        errorBuilder: widget.errorBuilder,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

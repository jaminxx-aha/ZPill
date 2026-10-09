/// 取景「高质量」画面档(fragment shader 路线):引擎侧解码帧 →
/// ui.Image 双采样(当前/前帧)→ Catmull-Rom 上采样 + 运动自适应
/// 时域降噪 + 细节增强(见 shaders/feed_quality.frag)。
///
/// 采样坐标不依赖绘制矩形的位置:shader 收 CTM 逆映射的边向量/
/// 原点(canvas.getTransform 回算),外层 FeedTransform 的 contain/
/// 缩放/旋转/变宽全数计入 —— 本件画满自身盒(图像坐标系)即可。
///
/// 帧节奏(代数跳旧帧):解码中只记最新待解字节,解码完直接解最新
/// —— 解码速率 < 帧率时丢中间帧,永不排队积压、永不落后多于一代。
/// shader 加载失败(老 GPU/编译失败)整件回落 [Image.memory] +
/// [fallbackQuality],画面照常。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 单例加载(pubspec `flutter: shaders` 注册的预编译产物);
/// null = 加载失败(整 app 会话内回落,不再重试)。
Future<ui.FragmentProgram?>? _programFuture;

class ShaderFeed extends StatefulWidget {
  const ShaderFeed({
    super.key,
    required this.frame,
    required this.temporalDenoise,
    this.fallbackQuality = FilterQuality.high,
    this.programLoader,
  });

  /// 当前帧 JPEG 字节(引擎帧流)。
  final Uint8List frame;

  /// 时域降噪(混合强度;false = 0 不混合)。
  final bool temporalDenoise;

  /// shader 不可用时的回落档(「高质量」回落 fast = FilterQuality.high)。
  final FilterQuality fallbackQuality;

  /// 程序加载器(测试注 null 走回落;默认 pubspec 资产单例)。
  final Future<ui.FragmentProgram?> Function()? programLoader;

  @override
  State<ShaderFeed> createState() => _ShaderFeedState();
}

class _ShaderFeedState extends State<ShaderFeed> {
  static const String _asset = 'shaders/feed_quality.frag';

  ui.FragmentProgram? _program;
  bool _programResolved = false;

  ui.Image? _image;
  ui.Image? _prev;
  Uint8List? _displayedBytes;
  bool _decoding = false;
  Uint8List? _pending;

  @override
  void initState() {
    super.initState();
    final loader = widget.programLoader;
    if (loader != null) {
      unawaited(loader().then((p) {
        if (!mounted) return;
        setState(() {
          _program = p;
          _programResolved = true;
        });
      }));
    } else {
      _programFuture ??= ui.FragmentProgram.fromAsset(_asset)
          .then<ui.FragmentProgram?>((p) => p)
          .catchError((Object _) => null);
      unawaited(_programFuture!.then((p) {
        if (!mounted) return;
        setState(() {
          _program = p;
          _programResolved = true;
        });
      }));
    }
    _decode(widget.frame);
  }

  @override
  void didUpdateWidget(ShaderFeed old) {
    super.didUpdateWidget(old);
    if (!identical(widget.frame, old.frame)) _decode(widget.frame);
  }

  @override
  void dispose() {
    _image?.dispose();
    _prev?.dispose();
    super.dispose();
  }

  void _decode(Uint8List bytes) {
    if (_decoding) {
      _pending = bytes; // 只留最新:中间帧直接丢
      return;
    }
    _decoding = true;
    unawaited(_decodeStep(bytes));
  }

  Future<void> _decodeStep(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _prev?.dispose();
        _prev = _image; // 前帧留给时域采样
        _image = frame.image;
        _displayedBytes = bytes;
      });
    } on Object {
      // 解码失败:保留旧画面等下一帧
    } finally {
      _decoding = false;
      final next = _pending;
      _pending = null;
      if (next != null && !identical(next, _displayedBytes)) {
        _decode(next);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final program = _program;
    if (!_programResolved || program == null || image == null) {
      // 加载中/不可用:走 Image 回落(与 fast 档同观感)
      return Image.memory(
        widget.frame,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        filterQuality: widget.fallbackQuality,
      );
    }
    return CustomPaint(
      painter: _ShaderFeedPainter(
        program: program,
        image: image,
        prev: widget.temporalDenoise && _prev != null ? _prev! : image,
        motion: widget.temporalDenoise ? 0.6 : 0.0,
        sharpen: 0.3,
      ),
    );
  }
}

class _ShaderFeedPainter extends CustomPainter {
  _ShaderFeedPainter({
    required this.program,
    required this.image,
    required this.prev,
    required this.motion,
    required this.sharpen,
  });

  final ui.FragmentProgram program;
  final ui.Image image;
  final ui.Image prev;
  final double motion;
  final double sharpen;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fs = program.fragmentShader();
    fs.setImageSampler(0, image);
    fs.setImageSampler(1, prev);
    // CTM 逆映射基(图像坐标 → 层空间):两条边向量 + 原点。绘制
    // 盒在图像坐标系原点,Transform 的缩放/旋转/变宽全在其中。
    // getTransform 回 Float64List(列主序:x' = m0x+m4y+m12)。
    final m = canvas.getTransform();
    Offset apply(Offset p) => Offset(
        m[0] * p.dx + m[4] * p.dy + m[12],
        m[1] * p.dx + m[5] * p.dy + m[13]);
    final o = apply(Offset.zero);
    final ex = apply(Offset(size.width, 0)) - o;
    final ey = apply(Offset(0, size.height)) - o;
    fs.setFloat(0, ex.dx);
    fs.setFloat(1, ex.dy);
    fs.setFloat(2, ey.dx);
    fs.setFloat(3, ey.dy);
    fs.setFloat(4, o.dx);
    fs.setFloat(5, o.dy);
    fs.setFloat(6, image.width.toDouble());
    fs.setFloat(7, image.height.toDouble());
    fs.setFloat(8, motion);
    fs.setFloat(9, sharpen);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = fs
        ..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_ShaderFeedPainter old) =>
      !identical(image, old.image) ||
      !identical(prev, old.prev) ||
      motion != old.motion ||
      sharpen != old.sharpen;
}

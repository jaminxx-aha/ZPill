/// 取景「高质量」画面档(fragment shader 路线):引擎侧解码帧(按
/// 显示分辨率降采样,解码开销随屏幕走不随源帧走)→ ui.Image 双采样
/// (当前/前帧)→ Catmull-Rom 上采样 + 运动自适应时域降噪 + 细节
/// 增强(见 shaders/feed_quality.frag)。
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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/media/cube_lut.dart';

/// 单例加载(pubspec `flutter: shaders` 注册的预编译产物);
/// null = 加载失败(整 app 会话内回落,不再重试)。
Future<ui.FragmentProgram?>? _programFuture;

/// 解码目标长边上限(物理像素)。防「显示远大于源」的极端布局(平板
/// 全屏高 DPR、双指放大到 8 倍)把目标反推到源帧之上 —— 取景显示
/// 永远吃不满那么大,2048 已盖过任何取景档的单边。
const int _decodeTargetLongEdgeCap = 2048;

/// 「视作满分辨率」容差:目标长边达到源长边九成即不降。留 10% 是为
/// 防盒尺寸在临界值附近抖动,解码分辨率逐帧来回跳(画质呼吸感)。
const double _decodeFullResTolerance = 0.9;

/// 取景帧解码目标宽(喂 [ui.ImageDescriptor.instantiateCodec] 的
/// targetWidth;null = 全分辨率)。
///
/// 为什么:解码开销随源尺寸走而与显示无关 —— 取景档 XGA(1024×768)
/// 在手机竖屏上的实际显示长边往往只有几百物理像素,全分辨率解码纯属
/// 白费;按显示盒实尺(逻辑 × DPR = 物理)降采样,开销随屏幕走。
/// 降下来的帧对 shader 透明:纹理尺寸 uniform 每帧带解码后实值,
/// uv 采样天然与分辨率无关。规则:只降不升(目标 ≥ 源 × 容差 →
/// null 保源);长边落在源宽轴直接给长边,落在竖轴(竖幅帧)按源
/// 宽高比折算到宽 —— instantiateCodec 单传 targetWidth 高由引擎保比。
int? feedDecodeTargetWidth({
  required int sourceWidth,
  required int sourceHeight,
  required Size displayBox,
  required double devicePixelRatio,
}) {
  if (sourceWidth < 1 || sourceHeight < 1) return null;
  final sourceLong = math.max(sourceWidth, sourceHeight);
  // 目标长边(物理)= 盒长边 × DPR;极端小盒钳 1,大屏封顶。
  final rawLong =
      math.max(displayBox.width, displayBox.height) * devicePixelRatio;
  final targetLong =
      rawLong.clamp(1.0, _decodeTargetLongEdgeCap.toDouble()).round();
  if (targetLong >= sourceLong * _decodeFullResTolerance) return null;
  final double widthScale =
      sourceWidth >= sourceHeight ? 1.0 : sourceWidth / sourceHeight;
  return math.max(1, (targetLong * widthScale).round());
}

class ShaderFeed extends StatefulWidget {
  const ShaderFeed({
    super.key,
    required this.frame,
    required this.temporalDenoise,
    this.lut,
    this.fallbackQuality = FilterQuality.high,
    this.programLoader,
  });

  /// 当前帧 JPEG 字节(引擎帧流)。
  final Uint8List frame;

  /// 时域降噪(混合强度;false = 0 不混合)。
  final bool temporalDenoise;

  /// 监看 LUT(shader 末段三线性查表,纯显示层调色);null = 直通。
  /// 纹理构建失败(LUT 非法/GPU 不可)静默不套色,画面照常。
  final CubeLut? lut;

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

  /// 最近一次绘制的显示盒(逻辑尺寸;painter 从画布 CTM 实测回填,
  /// 适配/旋转/变宽/双指缩放/DPR 全数计入)。null = 首帧未测得,
  /// 解码走全分辨率兜底。
  Size? _displayBox;

  /// 显示盒逻辑/物理折算用(painter 实测回传的是物理边长)。
  double _devicePixelRatio = 1.0;

  /// 监看 LUT 纹理(异步构建;构建沿 = [CubeLut] 实例变化)。
  ui.Image? _lutImage;
  CubeLut? _lutBuilding;

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
    _syncLut();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // maybeOf:裸树(无 MediaQuery)也不断言,取不到维持 1.0。
    _devicePixelRatio =
        MediaQuery.maybeDevicePixelRatioOf(context) ?? _devicePixelRatio;
  }

  /// painter 实测回填显示盒(物理 ÷ DPR = 逻辑)。刻意不 setState:
  /// 显示尺寸只喂下一帧的解码目标,不参与 build —— 盒尺寸变化不触发
  /// 重解码,下一帧自然按新尺解码,同帧内也就没有多余 rebuild。
  void _handlePaintedExtent(Size physicalExtent) {
    final dpr = _devicePixelRatio;
    _displayBox =
        Size(physicalExtent.width / dpr, physicalExtent.height / dpr);
  }

  @override
  void didUpdateWidget(ShaderFeed old) {
    super.didUpdateWidget(old);
    if (!identical(widget.frame, old.frame)) _decode(widget.frame);
    if (!identical(widget.lut, old.lut)) _syncLut();
  }

  @override
  void dispose() {
    _image?.dispose();
    _prev?.dispose();
    _lutImage?.dispose();
    super.dispose();
  }

  /// LUT 沿:实例变化即重建纹理(异步;迟到结果按最新实例丢弃)。
  /// 同步路径不 setState —— didUpdateWidget/initState 后框架本就
  /// 会重建,异步完成沿才需要。
  void _syncLut() {
    final lut = widget.lut;
    if (identical(lut, _lutBuilding)) return;
    _lutBuilding = lut;
    if (lut == null) {
      _lutImage?.dispose();
      _lutImage = null;
      return;
    }
    unawaited(_buildLutTexture(lut));
  }

  Future<void> _buildLutTexture(CubeLut lut) async {
    try {
      final buffer =
          await ui.ImmutableBuffer.fromUint8List(lut.textureRgba());
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: lut.size * lut.size,
        height: lut.size,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      if (!mounted || !identical(lut, _lutBuilding)) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _lutImage?.dispose();
        _lutImage = frame.image;
      });
    } on Object {
      // 纹理构建失败:LUT 静默不生效(画面照常,不阻塞取景)。
    }
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
      // 按显示分辨率降采样:descriptor 宽高是头信息(不解码即可读);
      // 盒未实测(首帧)→ null 全分辨率兜底。帧代数跳旧不动 —— 目标
      // 只随盒走,解码中盒再变也是下一帧的事。
      final displayBox = _displayBox;
      final targetWidth = displayBox == null
          ? null
          : feedDecodeTargetWidth(
              sourceWidth: descriptor.width,
              sourceHeight: descriptor.height,
              displayBox: displayBox,
              devicePixelRatio: _devicePixelRatio);
      final codec =
          await descriptor.instantiateCodec(targetWidth: targetWidth);
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
        lutImage: _lutImage,
        lutSize: _lutImage != null ? _lutBuilding!.size : 0,
        onPaintedExtent: _handlePaintedExtent,
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
    required this.lutImage,
    required this.lutSize,
    required this.onPaintedExtent,
  });

  final ui.FragmentProgram program;
  final ui.Image image;
  final ui.Image prev;
  final double motion;
  final double sharpen;

  /// 监看 LUT 纹理(null = 直通,sampler 槽 2 挂当前帧占位不采样)。
  final ui.Image? lutImage;

  /// LUT 每轴格点 N(纹理宽 = N²;与 [lutImage] 成对)。
  final int lutSize;

  /// 绘制盒的屏幕物理占用量测回传(ex/ey 边向量长度)。为什么不走
  /// LayoutBuilder:本件住在图像坐标系(父级 SizedBox 定的是源帧
  /// 尺寸,外层 Transform 才缩放到屏幕),布局量出来的恒是源尺寸;
  /// 只有画布 CTM 把适配/旋转/变宽/双指缩放/DPR 全数折进,才是真实
  /// 的显示占用 —— 降采样解码目标只能从这取。
  final void Function(Size physicalExtent) onPaintedExtent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fs = program.fragmentShader();
    fs.setImageSampler(0, image);
    fs.setImageSampler(1, prev);
    fs.setImageSampler(2, lutImage ?? image);
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
    // 显示盒实测:整幅画面的屏幕物理占用(盒两轴边向量的长度),
    // 喂下一帧的解码目标(本帧已解完,不回头重解)。
    final extent = Size(ex.distance, ey.distance);
    if (extent.width > 0 && extent.height > 0) onPaintedExtent(extent);
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
    fs.setFloat(10, lutImage != null ? 1.0 : 0.0);
    fs.setFloat(11, lutSize.toDouble());
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
      !identical(lutImage, old.lutImage) ||
      motion != old.motion ||
      sharpen != old.sharpen;
}
